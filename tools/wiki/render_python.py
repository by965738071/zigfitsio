#!/usr/bin/env python3
"""Generate the Python API portion of the release Wiki without importing zigfitsio.

The package loads its native library at import time, so release documentation must be
extractable before a wheel exists.  This renderer uses only the standard-library AST:
``zigfitsio.__all__`` and ``zigfitsio.lowlevel.__all__`` are the public contracts, and
``lowlevel._PROTOS`` is parsed separately for the runtime-bound ``lib.zf_*`` functions.
"""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
import inspect
import json
from pathlib import Path
import re
from typing import Iterable, Sequence


DEFAULT_REPOSITORY = "https://github.com/anhydrous99/zigfitsio"
MANAGED_FILES = ("Python-API-Low-Level.md", "Python-API.md", "python-symbols.json")
PUBLIC_PROTOCOL_METHODS = frozenset(
    {
        "__contains__",
        "__delitem__",
        "__enter__",
        "__eq__",
        "__exit__",
        "__getitem__",
        "__iter__",
        "__len__",
        "__repr__",
        "__setitem__",
    }
)


class ApiContractError(RuntimeError):
    """The statically declared Python API is incomplete or cannot be rendered."""


@dataclass(frozen=True)
class SourceModule:
    name: str
    path: Path
    text: str
    tree: ast.Module

    @classmethod
    def read(cls, name: str, path: Path) -> "SourceModule":
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ApiContractError(f"cannot read Python API source {path}: {exc}") from exc
        try:
            tree = ast.parse(text, filename=str(path))
        except SyntaxError as exc:
            raise ApiContractError(f"cannot parse Python API source {path}: {exc}") from exc
        return cls(name=name, path=path, text=text, tree=tree)


@dataclass(frozen=True)
class Definition:
    public_name: str
    source_name: str
    module: SourceModule
    node: ast.AST | None
    kind: str


@dataclass(frozen=True)
class Member:
    name: str
    kind: str
    node: ast.AST
    defined_in: str
    writable: bool = False


@dataclass(frozen=True)
class Prototype:
    name: str
    restype: str
    argtypes: tuple[str, ...]
    group: str
    lineno: int


def _assignment_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        return node.targets[0].id
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        return node.target.id
    return None


def _assignment_value(node: ast.AST) -> ast.AST | None:
    if isinstance(node, ast.Assign):
        return node.value
    if isinstance(node, ast.AnnAssign):
        return node.value
    return None


def _top_level_nodes(module: SourceModule) -> dict[str, ast.AST]:
    found: dict[str, ast.AST] = {}
    for node in module.tree.body:
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            found[node.name] = node
        else:
            name = _assignment_name(node)
            if name is not None:
                found[name] = node
    return found


def _literal_string_list(module: SourceModule, name: str) -> list[str]:
    node = _top_level_nodes(module).get(name)
    value = _assignment_value(node) if node is not None else None
    if value is None:
        raise ApiContractError(f"{module.name}.{name} must be a literal list or tuple of strings")
    try:
        result = ast.literal_eval(value)
    except (ValueError, TypeError) as exc:
        raise ApiContractError(f"{module.name}.{name} is not statically readable") from exc
    if not isinstance(result, (list, tuple)) or not all(isinstance(item, str) for item in result):
        raise ApiContractError(f"{module.name}.{name} must contain only strings")
    if len(result) != len(set(result)):
        raise ApiContractError(f"{module.name}.{name} contains duplicate exports")
    return list(result)


def _kind(node: ast.AST | None, name: str) -> str:
    if node is None:
        return "module"
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return "function"
    if isinstance(node, ast.ClassDef):
        bases = {_expr(base) for base in node.bases}
        if any(base.endswith("Structure") for base in bases):
            return "structure"
        if name.startswith("Fits") or name == "KeywordNotFound":
            return "exception"
        return "class"
    value = _assignment_value(node)
    if name == "lib":
        return "library"
    if isinstance(value, ast.Constant):
        return "constant"
    if value is not None and ("_c." in _expr(value) or "ctypes." in _expr(value)):
        return "type_alias"
    return "variable"


def _relative_imports(module: SourceModule) -> dict[str, tuple[str, str | None]]:
    imports: dict[str, tuple[str, str | None]] = {}
    for node in module.tree.body:
        if not isinstance(node, ast.ImportFrom) or node.level == 0:
            continue
        if node.module is None:
            for alias in node.names:
                imports[alias.asname or alias.name] = (alias.name, None)
        else:
            leaf = node.module.rsplit(".", 1)[-1]
            for alias in node.names:
                imports[alias.asname or alias.name] = (leaf, alias.name)
    return imports


def _resolve_root_exports(
    root: SourceModule, modules: dict[str, SourceModule], exports: Sequence[str]
) -> list[Definition]:
    local = _top_level_nodes(root)
    imports = _relative_imports(root)
    resolved: list[Definition] = []
    for public_name in exports:
        if public_name in imports:
            module_name, source_name = imports[public_name]
            source_module = modules.get(module_name)
            if source_module is None:
                raise ApiContractError(
                    f"public export {public_name!r} refers to unknown module {module_name!r}"
                )
            if source_name is None:
                node = None
                kind = "module"
                source_name = module_name
            else:
                node = _top_level_nodes(source_module).get(source_name)
                if node is None:
                    raise ApiContractError(
                        f"public export {public_name!r} cannot resolve {module_name}.{source_name}"
                    )
                kind = _kind(node, source_name)
            resolved.append(Definition(public_name, source_name, source_module, node, kind))
            continue
        node = local.get(public_name)
        if node is None:
            raise ApiContractError(f"public export {public_name!r} has no static definition")
        resolved.append(Definition(public_name, public_name, root, node, _kind(node, public_name)))
    return resolved


def _expr(node: ast.AST | None) -> str:
    if node is None:
        return "None"
    return ast.unparse(node).replace("_c.", "ctypes.")


_NO_DEFAULT = object()


def _arg(arg: ast.arg, default: ast.AST | object = _NO_DEFAULT) -> str:
    rendered = arg.arg
    if arg.annotation is not None:
        rendered += f": {_expr(arg.annotation)}"
    if default is not _NO_DEFAULT:
        rendered += f" = {_expr(default)}"  # type: ignore[arg-type]
    return rendered


def _function_signature(
    node: ast.FunctionDef | ast.AsyncFunctionDef,
    display_name: str,
    *,
    drop_first: bool = False,
    include_return: bool = True,
) -> str:
    args = node.args
    positional = list(args.posonlyargs) + list(args.args)
    defaults: list[ast.AST | object] = [_NO_DEFAULT] * (len(positional) - len(args.defaults))
    defaults.extend(args.defaults)
    posonly_count = len(args.posonlyargs)
    if drop_first and positional and positional[0].arg in {"self", "cls"}:
        positional.pop(0)
        defaults.pop(0)
        posonly_count = max(0, posonly_count - 1)

    parts: list[str] = []
    for index, (argument, default) in enumerate(zip(positional, defaults), start=1):
        parts.append(_arg(argument, default))
        if posonly_count and index == posonly_count:
            parts.append("/")
    if args.vararg is not None:
        parts.append("*" + _arg(args.vararg))
    elif args.kwonlyargs:
        parts.append("*")
    for argument, default in zip(args.kwonlyargs, args.kw_defaults):
        parts.append(_arg(argument, _NO_DEFAULT if default is None else default))
    if args.kwarg is not None:
        parts.append("**" + _arg(args.kwarg))
    signature = f"{display_name}({', '.join(parts)})"
    if include_return and node.returns is not None:
        signature += f" -> {_expr(node.returns)}"
    return signature


def _class_index(module: SourceModule) -> dict[str, ast.ClassDef]:
    return {
        node.name: node for node in module.tree.body if isinstance(node, ast.ClassDef)
    }


def _base_name(base: ast.AST) -> str:
    rendered = _expr(base)
    return rendered.rsplit(".", 1)[-1]


def _find_constructor(
    cls: ast.ClassDef, module: SourceModule, seen: set[str] | None = None
) -> ast.FunctionDef | ast.AsyncFunctionDef | None:
    seen = set() if seen is None else seen
    if cls.name in seen:
        return None
    seen.add(cls.name)
    for node in cls.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "__init__":
            return node
    classes = _class_index(module)
    for base in cls.bases:
        parent = classes.get(_base_name(base))
        if parent is not None:
            constructor = _find_constructor(parent, module, seen)
            if constructor is not None:
                return constructor
    return None


def _private_lineage(cls: ast.ClassDef, module: SourceModule) -> list[ast.ClassDef]:
    """Return the class and private implementation bases that own its visible API."""

    result = [cls]
    classes = _class_index(module)
    for base in cls.bases:
        name = _base_name(base)
        parent = classes.get(name)
        if parent is not None and name.startswith("_"):
            result.extend(_private_lineage(parent, module))
    return result


def _decorator_names(node: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    return {_expr(decorator) for decorator in node.decorator_list}


def _self_attributes(constructor: ast.FunctionDef | ast.AsyncFunctionDef) -> list[ast.AST]:
    found: list[ast.AST] = []
    for node in ast.walk(constructor):
        targets: Iterable[ast.AST]
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = (node.target,)
        else:
            continue
        if any(
            isinstance(target, ast.Attribute)
            and isinstance(target.value, ast.Name)
            and target.value.id == "self"
            and not target.attr.startswith("_")
            for target in targets
        ):
            found.append(node)
    return found


def _target_member_name(node: ast.AST) -> str | None:
    targets: Iterable[ast.AST]
    if isinstance(node, ast.Assign):
        targets = node.targets
    elif isinstance(node, ast.AnnAssign):
        targets = (node.target,)
    else:
        return None
    for target in targets:
        if isinstance(target, ast.Name):
            return target.id
        if (
            isinstance(target, ast.Attribute)
            and isinstance(target.value, ast.Name)
            and target.value.id == "self"
        ):
            return target.attr
    return None


def _class_members(cls: ast.ClassDef, module: SourceModule) -> list[Member]:
    members: list[Member] = []
    seen: set[str] = set()
    for owner in _private_lineage(cls, module):
        property_setters: set[str] = set()
        for node in owner.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for decorator in node.decorator_list:
                    if isinstance(decorator, ast.Attribute) and decorator.attr == "setter":
                        property_setters.add(node.name)

        candidates: list[Member] = []
        for node in owner.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name.startswith("_") and node.name not in PUBLIC_PROTOCOL_METHODS:
                    continue
                decorators = _decorator_names(node)
                if any(name.endswith(".setter") or name.endswith(".deleter") for name in decorators):
                    continue
                kind = "method"
                if "property" in decorators:
                    kind = "property"
                elif "classmethod" in decorators:
                    kind = "classmethod"
                elif "staticmethod" in decorators:
                    kind = "staticmethod"
                candidates.append(
                    Member(node.name, kind, node, owner.name, node.name in property_setters)
                )
                continue
            name = _assignment_name(node)
            if name and not name.startswith("_"):
                candidates.append(Member(name, "attribute", node, owner.name))

        constructor = _find_constructor(owner, module)
        if constructor is not None:
            for node in _self_attributes(constructor):
                name = _target_member_name(node)
                if name:
                    candidates.append(Member(name, "attribute", node, owner.name))

        for candidate in sorted(candidates, key=lambda item: item.node.lineno):
            if candidate.name not in seen:
                seen.add(candidate.name)
                members.append(candidate)
    return members


def _extract_struct_fields(cls: ast.ClassDef) -> list[tuple[str, str, int]]:
    for node in cls.body:
        if _assignment_name(node) != "_fields_":
            continue
        value = _assignment_value(node)
        if not isinstance(value, (ast.List, ast.Tuple)):
            break
        fields: list[tuple[str, str, int]] = []
        for item in value.elts:
            if not isinstance(item, (ast.List, ast.Tuple)) or len(item.elts) != 2:
                raise ApiContractError(f"{cls.name}._fields_ contains an unsupported field")
            try:
                field_name = ast.literal_eval(item.elts[0])
            except (ValueError, TypeError) as exc:
                raise ApiContractError(f"{cls.name} has a non-literal field name") from exc
            if not isinstance(field_name, str):
                raise ApiContractError(f"{cls.name} has a non-string field name")
            fields.append((field_name, _expr(item.elts[1]), item.lineno))
        return fields
    return []


def _extract_prototypes(module: SourceModule) -> list[Prototype]:
    assignment = _top_level_nodes(module).get("_PROTOS")
    value = _assignment_value(assignment) if assignment is not None else None
    if not isinstance(value, (ast.List, ast.Tuple)):
        raise ApiContractError("zigfitsio.lowlevel._PROTOS must be a literal list")
    lines = module.text.splitlines()
    cursor = value.lineno
    group = "Other"
    result: list[Prototype] = []
    for item in value.elts:
        if not isinstance(item, (ast.List, ast.Tuple)) or len(item.elts) != 3:
            raise ApiContractError("each lowlevel._PROTOS item must be (name, restype, argtypes)")
        for line in lines[cursor - 1 : item.lineno]:
            match = re.match(r"\s*#\s*(.+?)\s*$", line)
            if match:
                group = match.group(1)
        cursor = getattr(item, "end_lineno", item.lineno) + 1
        try:
            name = ast.literal_eval(item.elts[0])
        except (ValueError, TypeError) as exc:
            raise ApiContractError("a low-level prototype has a non-literal name") from exc
        args = item.elts[2]
        if not isinstance(name, str) or not isinstance(args, (ast.List, ast.Tuple)):
            raise ApiContractError("a low-level prototype has an invalid name or argument list")
        result.append(
            Prototype(
                name=name,
                restype=_expr(item.elts[1]),
                argtypes=tuple(_expr(arg) for arg in args.elts),
                group=group,
                lineno=item.lineno,
            )
        )
    names = [prototype.name for prototype in result]
    if len(names) != len(set(names)):
        raise ApiContractError("zigfitsio.lowlevel._PROTOS contains duplicate function names")
    return result


def _doc(node: ast.AST | None) -> str:
    if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
        text = ast.get_docstring(node, clean=True) or ""
    else:
        text = ""
    text = inspect.cleandoc(text)
    text = re.sub(r":(?:class|func|meth|mod|attr):`~?([^`]+)`", r"`\1`", text)
    return text


def _summary(text: str) -> str:
    if not text:
        return "Public API symbol."
    first = " ".join(text.splitlines()).split(". ", 1)[0].strip()
    if first and not first.endswith("."):
        first += "."
    return first.replace("|", "\\|")


def _anchor(symbol: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", symbol.lower()).strip("-")
    return f"py-{slug}"


def _find_repo_root(path: Path) -> Path:
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists() or (candidate / "build.zig").exists():
            return candidate
    return path.parent


def _source_path(path: Path, repo_root: Path, source_root: Path) -> str:
    try:
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return f"zigfitsio/{path.resolve().relative_to(source_root.resolve()).as_posix()}"


def _source_record(
    module: SourceModule, node: ast.AST | None, repo_root: Path, source_root: Path
) -> str:
    line = getattr(node, "lineno", 1)
    return f"{_source_path(module.path, repo_root, source_root)}:{line}"


def _source_url(
    repository: str,
    sha: str,
    module: SourceModule,
    node: ast.AST | None,
    repo_root: Path,
    source_root: Path,
) -> str:
    path = _source_path(module.path, repo_root, source_root)
    line = getattr(node, "lineno", 1)
    return f"{repository.rstrip('/')}/blob/{sha}/{path}#L{line}"


def _symbol(
    symbol_id: str,
    name: str,
    kind: str,
    page: str,
    source: str,
    scope: str,
) -> dict[str, str]:
    return {
        "id": symbol_id,
        "name": name,
        "kind": kind,
        "page": page,
        "anchor": _anchor(symbol_id),
        "source": source,
        "scope": scope,
    }


def _class_signature(cls: ast.ClassDef, module: SourceModule, public_name: str) -> str:
    public_bases = [
        _expr(base) for base in cls.bases if not _base_name(base).startswith("_")
    ]
    declaration = f"class {public_name}"
    if public_bases:
        declaration += f"({', '.join(public_bases)})"
    constructor = _find_constructor(cls, module)
    if constructor is None:
        call = f"{public_name}()"
    else:
        call = _function_signature(
            constructor, public_name, drop_first=True, include_return=False
        )
    return f"{declaration}\n{call}"


def _member_signature(member: Member, class_name: str) -> str:
    if isinstance(member.node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if member.kind == "property":
            result = f"{class_name}.{member.name}"
            if member.node.returns is not None:
                result += f": {_expr(member.node.returns)}"
            if member.writable:
                result += "  # readable and writable"
            return result
        return _function_signature(
            member.node, f"{class_name}.{member.name}", drop_first=member.kind != "staticmethod"
        )
    value = _assignment_value(member.node)
    rendered = f"{class_name}.{member.name}"
    if isinstance(member.node, ast.AnnAssign) and member.node.annotation is not None:
        rendered += f": {_expr(member.node.annotation)}"
    elif value is not None and isinstance(value, ast.Constant):
        rendered += f" = {_expr(value)}"
    return rendered


def _render_class(
    definition: Definition,
    page: str,
    repository: str,
    sha: str,
    repo_root: Path,
    source_root: Path,
    symbols: list[dict[str, str]],
    *,
    scope: str,
    heading_level: int = 3,
) -> list[str]:
    assert isinstance(definition.node, ast.ClassDef)
    cls = definition.node
    symbol_id = (
        f"zigfitsio.{definition.public_name}"
        if scope == "root_export"
        else f"zigfitsio.lowlevel.{definition.public_name}"
    )
    source = _source_record(definition.module, cls, repo_root, source_root)
    symbols.append(_symbol(symbol_id, definition.public_name, definition.kind, page, source, scope))
    lines = [
        f'<a id="{_anchor(symbol_id)}"></a>',
        f"{'#' * heading_level} {definition.public_name}",
        "",
        "```python",
        _class_signature(cls, definition.module, definition.public_name),
        "```",
        "",
        _doc(cls),
        "",
        f"[Source]({_source_url(repository, sha, definition.module, cls, repo_root, source_root)})",
        "",
    ]
    if definition.kind == "structure":
        fields = _extract_struct_fields(cls)
        if fields:
            lines.extend([f"{'#' * (heading_level + 1)} Fields", ""])
            for field_name, field_type, lineno in fields:
                field_id = f"{symbol_id}.{field_name}"
                field_source = (
                    f"{_source_path(definition.module.path, repo_root, source_root)}:{lineno}"
                )
                symbols.append(
                    _symbol(field_id, field_name, "field", page, field_source, "class_member")
                )
                lines.extend(
                    [
                        f'<a id="{_anchor(field_id)}"></a>',
                        f"{'#' * (heading_level + 2)} {definition.public_name}.{field_name}",
                        "",
                        f"```python\n{definition.public_name}.{field_name}: {field_type}\n```",
                        "",
                    ]
                )
    for member in _class_members(cls, definition.module):
        member_id = f"{symbol_id}.{member.name}"
        member_source = _source_record(definition.module, member.node, repo_root, source_root)
        symbols.append(
            _symbol(member_id, member.name, member.kind, page, member_source, "class_member")
        )
        member_doc = _doc(member.node)
        if not member_doc:
            if member.kind == "attribute":
                member_doc = "Public attribute."
            elif member.defined_in == cls.name:
                member_doc = f"Public {member.kind} defined by ``{definition.public_name}``."
            else:
                member_doc = f"Public {member.kind} inherited from ``{member.defined_in}``."
        lines.extend(
            [
                f'<a id="{_anchor(member_id)}"></a>',
                f"{'#' * (heading_level + 1)} {definition.public_name}.{member.name}",
                "",
                "```python",
                _member_signature(member, definition.public_name),
                "```",
                "",
                member_doc,
                "",
                f"[Source]({_source_url(repository, sha, definition.module, member.node, repo_root, source_root)})",
                "",
            ]
        )
    return lines


def _render_root(
    definitions: Sequence[Definition],
    tag: str,
    sha: str,
    repository: str,
    repo_root: Path,
    source_root: Path,
    symbols: list[dict[str, str]],
) -> str:
    page = "Python-API.md"
    lines = [
        "# Python API",
        "",
        "> Generated from the public ``zigfitsio.__all__`` contract. Do not edit this page by hand.",
        "",
        f"Release: **{tag}**  ",
        f"Source commit: [`{sha}`]({repository.rstrip('/')}/tree/{sha})",
        "",
        "The high-level API is NumPy-first. The direct ctypes ABI is documented in "
        "[Python low-level API](Python-API-Low-Level).",
        "",
        "## Public exports",
        "",
        "| Name | Kind | Summary |",
        "| --- | --- | --- |",
    ]
    for definition in definitions:
        if definition.kind == "module":
            description = _summary(_doc(definition.module.tree))
        elif definition.public_name == "__version__":
            description = "Version reported by the loaded zigfitsio native library."
        else:
            description = _summary(_doc(definition.node))
        lines.append(
            f"| [`{definition.public_name}`](#{_anchor(f'zigfitsio.{definition.public_name}')}) "
            f"| {definition.kind} | {description} |"
        )
    lines.extend(["", "## Reference", ""])

    for definition in definitions:
        symbol_id = f"zigfitsio.{definition.public_name}"
        if isinstance(definition.node, ast.ClassDef):
            lines.extend(
                _render_class(
                    definition,
                    page,
                    repository,
                    sha,
                    repo_root,
                    source_root,
                    symbols,
                    scope="root_export",
                )
            )
            continue
        source = _source_record(definition.module, definition.node, repo_root, source_root)
        symbols.append(
            _symbol(symbol_id, definition.public_name, definition.kind, page, source, "root_export")
        )
        lines.extend([f'<a id="{_anchor(symbol_id)}"></a>', f"### {definition.public_name}", ""])
        if isinstance(definition.node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            signature = _function_signature(definition.node, definition.public_name)
            description = _doc(definition.node)
        elif definition.kind == "module":
            signature = "from zigfitsio import lowlevel"
            description = (
                "The explicitly supported ctypes namespace. See the "
                "[low-level reference](Python-API-Low-Level)."
            )
        elif definition.public_name == "__version__":
            signature = "__version__: str"
            description = "The version string returned by the loaded native library."
        else:
            value = _assignment_value(definition.node) if definition.node is not None else None
            signature = f"{definition.public_name} = {_expr(value)}"
            description = _doc(definition.node) or "Public package value."
        lines.extend(
            [
                "```python",
                signature,
                "```",
                "",
                description,
                "",
                f"[Source]({_source_url(repository, sha, definition.module, definition.node, repo_root, source_root)})",
                "",
            ]
        )
    lines.extend(["---", "", f"Generated for {tag} from `{sha}`.", ""])
    return "\n".join(lines)


def _lowlevel_description(definition: Definition) -> str:
    if definition.kind == "library":
        return "Loaded native-library handle containing the runtime-bound ``zf_*`` functions."
    if definition.kind == "type_alias":
        return "Public ctypes alias used by low-level function signatures."
    if definition.kind == "constant":
        return "Public C ABI constant."
    return _doc(definition.node) or "Public low-level API symbol."


def _render_lowlevel(
    module: SourceModule,
    definitions: Sequence[Definition],
    prototypes: Sequence[Prototype],
    tag: str,
    sha: str,
    repository: str,
    repo_root: Path,
    source_root: Path,
    symbols: list[dict[str, str]],
) -> str:
    page = "Python-API-Low-Level.md"
    lines = [
        "# Python low-level API",
        "",
        "> Generated from ``zigfitsio.lowlevel.__all__`` and ``lowlevel._PROTOS``. "
        "Do not edit this page by hand.",
        "",
        f"Release: **{tag}**  ",
        f"Source commit: [`{sha}`]({repository.rstrip('/')}/tree/{sha})",
        "",
        _doc(module.tree),
        "",
        "## Module exports",
        "",
    ]
    for definition in definitions:
        if isinstance(definition.node, ast.ClassDef):
            lines.extend(
                _render_class(
                    definition,
                    page,
                    repository,
                    sha,
                    repo_root,
                    source_root,
                    symbols,
                    scope="lowlevel_export",
                )
            )
            continue
        symbol_id = f"zigfitsio.lowlevel.{definition.public_name}"
        source = _source_record(module, definition.node, repo_root, source_root)
        symbols.append(
            _symbol(
                symbol_id,
                definition.public_name,
                definition.kind,
                page,
                source,
                "lowlevel_export",
            )
        )
        lines.extend([f'<a id="{_anchor(symbol_id)}"></a>', f"### {definition.public_name}", ""])
        if isinstance(definition.node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            signature = _function_signature(definition.node, definition.public_name)
        elif definition.kind == "library":
            signature = "lib: ctypes.CDLL"
        else:
            signature = f"{definition.public_name} = {_expr(_assignment_value(definition.node))}"
        lines.extend(
            [
                "```python",
                signature,
                "```",
                "",
                _lowlevel_description(definition),
                "",
                f"[Source]({_source_url(repository, sha, module, definition.node, repo_root, source_root)})",
                "",
            ]
        )

    lines.extend(
        [
            "## Runtime-bound C ABI functions",
            "",
            "These functions are attributes of ``zigfitsio.lowlevel.lib``. Their positional "
            "``argN`` labels are generated because ctypes prototypes contain types but not C "
            "parameter names. Nonzero integer status returns should normally be passed to ``check``.",
            "",
        ]
    )
    current_group: str | None = None
    source_path = _source_path(module.path, repo_root, source_root)
    for prototype in prototypes:
        if prototype.group != current_group:
            current_group = prototype.group
            lines.extend([f"### {current_group.title()}", ""])
        symbol_id = f"zigfitsio.lowlevel.lib.{prototype.name}"
        symbols.append(
            _symbol(
                symbol_id,
                prototype.name,
                "c_function",
                page,
                f"{source_path}:{prototype.lineno}",
                "lowlevel_function",
            )
        )
        arguments = ", ".join(
            f"arg{index}: {argtype}" for index, argtype in enumerate(prototype.argtypes)
        )
        lines.extend(
            [
                f'<a id="{_anchor(symbol_id)}"></a>',
                f"#### lib.{prototype.name}",
                "",
                "```python",
                f"lib.{prototype.name}({arguments}) -> {prototype.restype}",
                "```",
                "",
                f"[Source]({repository.rstrip('/')}/blob/{sha}/{source_path}#L{prototype.lineno})",
                "",
            ]
        )
    lines.extend(["---", "", f"Generated for {tag} from `{sha}`.", ""])
    return "\n".join(lines)


def _validate_manifest(
    manifest: dict[str, object], root_exports: Sequence[str], lowlevel_exports: Sequence[str],
    prototypes: Sequence[Prototype]
) -> None:
    symbols = manifest["symbols"]
    assert isinstance(symbols, list)
    ids = [entry["id"] for entry in symbols]
    if len(ids) != len(set(ids)):
        duplicates = sorted({symbol_id for symbol_id in ids if ids.count(symbol_id) > 1})
        raise ApiContractError(f"generated duplicate Python symbols: {duplicates}")

    def names_for(scope: str) -> set[str]:
        return {entry["name"] for entry in symbols if entry["scope"] == scope}

    checks = {
        "root exports": (set(root_exports), names_for("root_export")),
        "low-level exports": (set(lowlevel_exports), names_for("lowlevel_export")),
        "low-level functions": ({item.name for item in prototypes}, names_for("lowlevel_function")),
    }
    missing: dict[str, list[str]] = {}
    extra: dict[str, list[str]] = {}
    for label, (expected, documented) in checks.items():
        if expected - documented:
            missing[label] = sorted(expected - documented)
        if documented - expected:
            extra[label] = sorted(documented - expected)
    if missing or extra:
        raise ApiContractError(f"Python API coverage mismatch: missing={missing}, extra={extra}")


def generate(
    source_root: str | Path,
    output_dir: str | Path,
    tag: str,
    sha: str,
    repository: str = DEFAULT_REPOSITORY,
    *,
    repo_root: str | Path | None = None,
) -> dict[str, object]:
    """Generate deterministic Python Wiki pages and return their symbol manifest."""

    if not tag or not sha:
        raise ApiContractError("both release tag and source SHA are required")
    source_root = Path(source_root).resolve()
    output_dir = Path(output_dir).resolve()
    repo_root_path = Path(repo_root).resolve() if repo_root is not None else _find_repo_root(source_root)

    root = SourceModule.read("zigfitsio", source_root / "__init__.py")
    modules = {
        name: SourceModule.read(f"zigfitsio.{name}", source_root / f"{name}.py")
        for name in ("core", "header", "lowlevel")
    }
    all_modules = {**modules, "__init__": root}
    root_exports = _literal_string_list(root, "__all__")
    root_definitions = _resolve_root_exports(root, all_modules, root_exports)

    lowlevel = modules["lowlevel"]
    lowlevel_exports = _literal_string_list(lowlevel, "__all__")
    low_nodes = _top_level_nodes(lowlevel)
    low_definitions: list[Definition] = []
    for name in lowlevel_exports:
        node = low_nodes.get(name)
        if node is None:
            raise ApiContractError(f"low-level public export {name!r} has no static definition")
        low_definitions.append(Definition(name, name, lowlevel, node, _kind(node, name)))
    prototypes = _extract_prototypes(lowlevel)

    undocumented = [
        definition.public_name
        for definition in (*root_definitions, *low_definitions)
        if definition.kind in {"class", "structure", "exception", "function"}
        and not _doc(definition.node)
    ]
    if undocumented:
        raise ApiContractError(f"public Python exports lack docstrings: {sorted(set(undocumented))}")

    undocumented_protocols = [
        f"{definition.public_name}.{member.name}"
        for definition in (*root_definitions, *low_definitions)
        if isinstance(definition.node, ast.ClassDef)
        for member in _class_members(definition.node, definition.module)
        if member.name in PUBLIC_PROTOCOL_METHODS and not _doc(member.node)
    ]
    if undocumented_protocols:
        raise ApiContractError(
            "public Python protocol methods lack docstrings: "
            f"{sorted(set(undocumented_protocols))}"
        )

    symbols: list[dict[str, str]] = []
    root_markdown = _render_root(
        root_definitions, tag, sha, repository, repo_root_path, source_root, symbols
    )
    lowlevel_markdown = _render_lowlevel(
        lowlevel,
        low_definitions,
        prototypes,
        tag,
        sha,
        repository,
        repo_root_path,
        source_root,
        symbols,
    )

    counts = {
        "public_exports": len(root_exports),
        "public_class_members": sum(1 for item in symbols if item["scope"] == "class_member"),
        "lowlevel_exports": len(lowlevel_exports),
        "lowlevel_functions": len(prototypes),
        "total_symbols": len(symbols),
    }
    manifest: dict[str, object] = {
        "schema_version": 1,
        "language": "python",
        "tag": tag,
        "sha": sha,
        "managed_files": list(MANAGED_FILES),
        "counts": counts,
        "coverage": {
            "root_exports": root_exports,
            "lowlevel_exports": lowlevel_exports,
            "lowlevel_functions": [prototype.name for prototype in prototypes],
            "missing": [],
        },
        "abi_prototypes": [
            {
                "name": prototype.name,
                "returns": prototype.restype,
                "args": list(prototype.argtypes),
            }
            for prototype in prototypes
        ],
        "symbols": symbols,
    }
    _validate_manifest(manifest, root_exports, lowlevel_exports, prototypes)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "Python-API.md").write_text(root_markdown, encoding="utf-8")
    (output_dir / "Python-API-Low-Level.md").write_text(
        lowlevel_markdown, encoding="utf-8"
    )
    (output_dir / "python-symbols.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def _parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=repo_root / "bindings/python/src/zigfitsio",
        help="directory containing zigfitsio/__init__.py",
    )
    parser.add_argument("--out", type=Path, required=True, help="clean Wiki staging directory")
    parser.add_argument("--tag", required=True, help="release tag, for example v0.1.5")
    parser.add_argument("--sha", required=True, help="full source commit SHA")
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY, help="GitHub repository URL")
    parser.add_argument("--repo-root", type=Path, default=repo_root, help="repository root")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    manifest = generate(
        args.source_root,
        args.out,
        args.tag,
        args.sha,
        args.repository,
        repo_root=args.repo_root,
    )
    print(json.dumps({"managed_files": manifest["managed_files"], "counts": manifest["counts"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
