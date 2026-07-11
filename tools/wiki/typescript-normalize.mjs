import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

export const TYPESCRIPT_PAGE_PREFIX = "TypeScript-API";
export const TYPESCRIPT_ENTRY_PAGE = `${TYPESCRIPT_PAGE_PREFIX}.md`;
export const TYPESCRIPT_PROTOS_PAGE = `${TYPESCRIPT_PAGE_PREFIX}-Low-Level-Prototypes.md`;
export const TYPESCRIPT_MANIFEST_FILE = "typescript-api-manifest.json";
export const TYPESCRIPT_COVERAGE_FILE = "typescript-api-coverage.json";
export const TYPESCRIPT_ENTRY_POINTS = Object.freeze([
  "bindings/typescript/src/index.ts",
  "bindings/typescript/src/lowlevel/index.ts",
]);

const NATIVE_TYPES = new Set([
  "void",
  "int",
  "u32",
  "i64",
  "u64",
  "f32",
  "f64",
  "long",
  "usize",
  "handle",
  "buf",
  "cstr",
  "cstr_arr",
  "cstring_ret",
]);

const KIND_NAMES = new Map([
  [2, "Module"],
  [4, "Namespace"],
  [8, "Enum"],
  [16, "EnumMember"],
  [32, "Variable"],
  [64, "Function"],
  [128, "Class"],
  [256, "Interface"],
  [512, "Constructor"],
  [1024, "Property"],
  [2048, "Method"],
  [4096, "CallSignature"],
  [8192, "IndexSignature"],
  [16384, "ConstructorSignature"],
  [32768, "Parameter"],
  [65536, "TypeLiteral"],
  [131072, "TypeParameter"],
  [262144, "Accessor"],
  [524288, "GetSignature"],
  [1048576, "SetSignature"],
  [2097152, "TypeAlias"],
  [4194304, "Reference"],
  [8388608, "Document"],
]);

// Declaration kinds which form the consumer-visible API. Signatures, parameters, type
// parameters, and anonymous type literals are rendered inside their owning declaration and are
// deliberately not double-counted as standalone symbols.
const PUBLIC_DECLARATION_KINDS = new Set([
  4, // Namespace
  8, // Enum
  16, // EnumMember
  32, // Variable
  64, // Function
  128, // Class
  256, // Interface
  512, // Constructor
  1024, // Property
  2048, // Method
  262144, // Accessor
  2097152, // TypeAlias
  4194304, // Reference
]);

const ARG_TYPES = Object.freeze({
  int: "number",
  u32: "number",
  long: "number | bigint",
  f32: "number",
  f64: "number",
  i64: "bigint | number",
  u64: "bigint | number",
  usize: "bigint | number",
  handle: "bigint | number | null",
  buf: "ArrayBufferView | null",
  cstr: "string | null",
  cstr_arr: "readonly (string | null)[] | null",
});

const RETURN_TYPES = Object.freeze({
  void: "undefined",
  int: "number",
  u32: "number",
  long: "number",
  f32: "number",
  f64: "number",
  i64: "bigint",
  u64: "bigint",
  usize: "bigint",
  handle: "bigint",
  cstring_ret: "string",
});

function jsonText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function compareText(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizeText(value) {
  return `${value.replace(/\r\n?/g, "\n").trimEnd()}\n`;
}

function markdownEscape(value) {
  return value.replace(/([\\`*_[\]<>])/g, "\\$1");
}

function sourceOf(reflection) {
  const source = reflection.sources?.[0];
  if (!source) return null;
  return {
    file: String(source.fileName).replaceAll("\\", "/"),
    line: source.line,
  };
}

/** Parse the literal p("zf_*", ...) calls in the exported PROTOS array. */
export function parseTypeScriptProtos(source) {
  const declaration = /export\s+const\s+PROTOS[^=]*=\s*\[/.exec(source);
  if (!declaration) throw new Error("could not find the exported PROTOS array");
  const bodyStart = declaration.index + declaration[0].length;
  const bodyEnd = source.indexOf("\n];", bodyStart);
  if (bodyEnd < 0) throw new Error("could not find the end of the exported PROTOS array");
  const body = source.slice(bodyStart, bodyEnd);
  const callCount = [...body.matchAll(/\bp\s*\(/g)].length;
  const callPattern = /\bp\(\s*"([^"]+)"\s*,\s*"([^"]+)"((?:\s*,\s*"[^"]+")*)\s*\)/g;
  const protos = [];

  for (const match of body.matchAll(callPattern)) {
    const [, name, returns, tail] = match;
    const args = [...tail.matchAll(/"([^"]+)"/g)].map((item) => item[1]);
    if (!/^zf_[a-z0-9_]+$/.test(name)) throw new Error(`invalid PROTOS symbol ${name}`);
    if (!NATIVE_TYPES.has(returns)) throw new Error(`unknown return type ${returns} on ${name}`);
    for (const arg of args) {
      if (!NATIVE_TYPES.has(arg) || arg === "void" || arg === "cstring_ret") {
        throw new Error(`unknown argument type ${arg} on ${name}`);
      }
    }
    protos.push({ name, returns, args });
  }

  if (protos.length !== callCount) {
    throw new Error(`parsed ${protos.length} of ${callCount} PROTOS calls; declarations must remain literal`);
  }
  const duplicates = protos.filter((proto, index) => protos.findIndex((item) => item.name === proto.name) !== index);
  if (duplicates.length) throw new Error(`duplicate PROTOS symbols: ${duplicates.map((item) => item.name).join(", ")}`);
  if (!protos.length) throw new Error("PROTOS must not be empty");
  return protos;
}

export function formatTypeScriptProtoSignature(proto) {
  const args = proto.args.map((kind, index) => `arg${index}: ${ARG_TYPES[kind]}`).join(", ");
  return `lib.${proto.name}(${args}): ${RETURN_TYPES[proto.returns]}`;
}

/** Map TypeDoc's flattened wiki page names into this language's collision-free namespace. */
export function managedTypeScriptPageName(rawName) {
  if (rawName === TYPESCRIPT_ENTRY_PAGE) return rawName;
  if (rawName === "index.md") return `${TYPESCRIPT_PAGE_PREFIX}-High-Level.md`;
  if (rawName.startsWith("index.") && rawName.endsWith(".md")) {
    return `${TYPESCRIPT_PAGE_PREFIX}-High-Level.${rawName.slice("index.".length)}`;
  }
  if (rawName === "lowlevel.md") return `${TYPESCRIPT_PAGE_PREFIX}-Low-Level.md`;
  if (rawName.startsWith("lowlevel.") && rawName.endsWith(".md")) {
    return `${TYPESCRIPT_PAGE_PREFIX}-Low-Level.${rawName.slice("lowlevel.".length)}`;
  }
  throw new Error(`unexpected TypeDoc page ${rawName}; refusing to emit an unprefixed wiki page`);
}

export function rewriteTypeScriptWikiLinks(markdown, rawToManaged) {
  const unresolved = [];
  const rewritten = markdown.replace(/\]\(\.\.\/wiki\/([^)]+)\)/g, (whole, destination) => {
    const hashAt = destination.indexOf("#");
    const rawTarget = hashAt < 0 ? destination : destination.slice(0, hashAt);
    const fragment = hashAt < 0 ? "" : destination.slice(hashAt);
    let decoded;
    try {
      decoded = decodeURI(rawTarget);
    } catch {
      unresolved.push(destination);
      return whole;
    }
    const managed = rawToManaged.get(decoded);
    if (!managed) {
      unresolved.push(destination);
      return whole;
    }
    return `](../wiki/${encodeURI(managed)}${fragment})`;
  });
  return { markdown: rewritten, unresolved };
}

function renderPrototypeSupplement(protos, metadata) {
  const entryStem = TYPESCRIPT_ENTRY_PAGE.slice(0, -3);
  const lines = [
    `<!-- Generated by zigfitsio TypeScript API tooling for ${metadata.tag} (${metadata.sha}). Do not edit. -->`,
    "",
    "# TypeScript low-level `zf_*` prototypes",
    "",
    `[TypeScript API index](../wiki/${entryStem})`,
    "",
    "The low-level `lib` object is populated dynamically from `PROTOS`, so TypeDoc can document the object but cannot discover each property as a declaration. This supplement lists every callable in source order.",
    "",
    "Argument names are positional because `PROTOS` records ABI kinds rather than C parameter names. `ArrayBufferView` arguments are copied to or from WebAssembly linear memory; `null` represents a null pointer.",
    "",
  ];
  for (const proto of protos) {
    lines.push(
      `## \`${proto.name}\``,
      "",
      "```ts",
      formatTypeScriptProtoSignature(proto),
      "```",
      "",
      `Native IR: \`(${proto.args.join(", ")}) -> ${proto.returns}\``,
      "",
    );
  }
  return normalizeText(lines.join("\n"));
}

function pageForSymbol(moduleName, namespacePath, symbol, rawNames, rawToManaged, parentAllowsOwnPage, ownerPage) {
  const kind = KIND_NAMES.get(symbol.kind);
  if (!kind || kind === "Reference" || !parentAllowsOwnPage) return ownerPage;
  const scope = namespacePath.length ? `${moduleName}.${namespacePath.join(".")}` : moduleName;
  const dedicated = `${scope}.${kind}.${symbol.name}`;
  return rawNames.has(dedicated) ? rawToManaged.get(dedicated) : ownerPage;
}

function githubHeadingInventory(markdown) {
  const lines = markdown.split("\n");
  let fence = null;
  const visible = lines.map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)?.[1] ?? null;
    if (marker) {
      if (fence === null) fence = marker[0];
      else if (marker[0] === fence) fence = null;
      return "";
    }
    return fence === null ? line : "";
  }).join("\n");

  const records = [];
  const anchors = new Set();
  const counts = new Map();
  const rawHeadings = [...visible.matchAll(/^(#{1,6})\s+(.+?)\s*#*$/gm)];
  for (let index = 0; index < rawHeadings.length; index += 1) {
    const match = rawHeadings[index];
    const level = match[1].length;
    const text = match[2]
      .replace(/\\(.)/g, "$1")
      .replace(/<[^>]+>/g, "")
      .replace(/[`*~]/g, "")
      .trim();
    const base = text
      .toLowerCase()
      .replace(/[^\p{L}\p{N}_\- ]/gu, "")
      .replace(/ +/g, "-");
    const count = counts.get(base) ?? 0;
    counts.set(base, count + 1);
    const anchor = count === 0 ? base : `${base}-${count}`;
    anchors.add(anchor);

    let name = text.replace(
      /^(?:Abstract Class|Class|Interface|Function|Type Alias|Variable|Namespace):\s*/,
      "",
    );
    if (name === "Constructor") name = "constructor";
    else name = name.split(/[<(]/, 1)[0].replace(/\?$/, "").trim();
    const next = rawHeadings.slice(index + 1).find((item) => item[1].length <= level);
    const bodyStart = (match.index ?? 0) + match[0].length;
    const bodyEnd = next?.index ?? visible.length;
    records.push({ name, anchor, level, body: visible.slice(bodyStart, bodyEnd) });
  }
  for (const match of visible.matchAll(/<a\s+(?:id|name)=["']([^"']+)["']/gi)) {
    anchors.add(match[1].toLowerCase());
  }
  return { records, anchors };
}

function renderedSymbol(contents, symbol) {
  if (!contents) return { documented: false, anchor: null };
  const inventory = githubHeadingInventory(contents);
  const headings = inventory.records.filter((item) => item.name === symbol.name);
  for (const heading of headings) {
    const kind = KIND_NAMES.get(symbol.kind);
    if (["Class", "Interface", "Namespace"].includes(kind)) {
      return { documented: true, anchor: heading.anchor };
    }
    const plainBody = heading.body.replace(/\\(.)/g, "$1");
    const signature = kind === "Constructor"
      ? /^>\s+.*\*\*new\s+/m.test(plainBody)
      : new RegExp(
        `^>\\s+.*\\*\\*${escapeRegExp(symbol.name)}\\??\\*\\*`,
        "m",
      ).test(plainBody);
    if (signature) return { documented: true, anchor: heading.anchor };
  }
  // TypeDoc references are re-export aliases represented as links in the owning module page,
  // rather than as declaration headings. They duplicate a declaration validated elsewhere.
  if (symbol.kind === 4194304 && contents.replace(/\\(.)/g, "$1").includes(symbol.name)) {
    return { documented: true, anchor: null };
  }
  return { documented: false, anchor: null };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function collectSymbols(reflection, rawNames, rawToManaged, pageContents) {
  const modules = (reflection.children ?? []).filter((child) => child.kind === 2);
  const moduleNames = modules.map((module) => module.name).sort();
  if (JSON.stringify(moduleNames) !== JSON.stringify(["index", "lowlevel"])) {
    throw new Error(`TypeDoc entry modules changed: expected index, lowlevel; got ${moduleNames.join(", ")}`);
  }

  const symbols = [];
  const missing = [];
  for (const module of modules) {
    const modulePage = rawToManaged.get(module.name);
    if (!modulePage) throw new Error(`TypeDoc did not render module page ${module.name}.md`);

    const visit = (symbol, qualifiedPath, namespacePath, parentAllowsOwnPage, ownerPage) => {
      if (!PUBLIC_DECLARATION_KINDS.has(symbol.kind)) return;
      const kind = KIND_NAMES.get(symbol.kind) ?? `Unknown(${symbol.kind})`;
      const page = pageForSymbol(
        module.name,
        namespacePath,
        symbol,
        rawNames,
        rawToManaged,
        parentAllowsOwnPage,
        ownerPage,
      );
      const nextQualifiedPath = [...qualifiedPath, symbol.name];
      const qualifiedName = [module.name, ...nextQualifiedPath].join(".");
      const contents = page ? pageContents.get(`${page}.md`) : null;
      const rendered = renderedSymbol(contents, symbol);
      if (!rendered.documented) missing.push(qualifiedName);
      symbols.push({
        qualifiedName,
        name: symbol.name,
        kind,
        entryPoint: module.name === "index" ? TYPESCRIPT_ENTRY_POINTS[0] : TYPESCRIPT_ENTRY_POINTS[1],
        page: page ? `${page}.md` : null,
        anchor: rendered.anchor,
        source: sourceOf(symbol),
        inherited: Boolean(symbol.flags?.isInherited),
      });

      const nextNamespacePath = kind === "Namespace" ? [...namespacePath, symbol.name] : namespacePath;
      const childrenCanOwnPages = kind === "Namespace";
      for (const child of symbol.children ?? []) {
        visit(child, nextQualifiedPath, nextNamespacePath, childrenCanOwnPages, page);
      }
    };

    for (const symbol of module.children ?? []) visit(symbol, [], [], true, modulePage);
  }
  symbols.sort((a, b) => compareText(a.qualifiedName, b.qualifiedName));
  const duplicates = symbols
    .filter((symbol, index) => symbols.findIndex((item) => item.qualifiedName === symbol.qualifiedName) !== index)
    .map((symbol) => symbol.qualifiedName);
  return { symbols, missing: [...new Set(missing)].sort(), duplicates: [...new Set(duplicates)].sort() };
}

function findDanglingLinks(pages) {
  const stems = new Set([...pages.keys()].map((name) => name.slice(0, -3)));
  const anchors = new Map(
    [...pages.entries()].map(([name, contents]) => [name.slice(0, -3), githubHeadingInventory(contents).anchors]),
  );
  const dangling = [];
  for (const [page, contents] of pages) {
    for (const match of contents.matchAll(/\]\(\.\.\/wiki\/([^\s)#]+)(?:#([^)]*))?\)/g)) {
      let target = match[1];
      let fragment = match[2] ?? "";
      try {
        target = decodeURI(target);
        fragment = decodeURIComponent(fragment).toLowerCase();
      } catch {
        // Leave the encoded value in the diagnostic.
      }
      if (!stems.has(target)) dangling.push(`${page} -> ${target}`);
      else if (fragment && !anchors.get(target)?.has(fragment)) {
        dangling.push(`${page} -> ${target}#${fragment}`);
      }
    }
  }
  return [...new Set(dangling)].sort();
}

function addGeneratedHeader(contents, metadata) {
  const marker = `<!-- Generated by zigfitsio TypeScript API tooling for ${metadata.tag} (${metadata.sha}). Do not edit. -->`;
  return normalizeText(`${marker}\n\n${contents}`);
}

function enhanceEntryPage(contents, metadata) {
  const releaseUrl = `https://github.com/${metadata.repository}/releases/tag/${encodeURIComponent(metadata.tag)}`;
  const commitUrl = `https://github.com/${metadata.repository}/commit/${metadata.sha}`;
  const protosStem = TYPESCRIPT_PROTOS_PAGE.slice(0, -3);
  const body = contents.replace(/^# zigfitsio\s*/m, "# TypeScript API reference\n\n");
  const provenance = [
    `Reference for release [\`${markdownEscape(metadata.tag)}\`](${releaseUrl}) at [\`${metadata.sha.slice(0, 12)}\`](${commitUrl}).`,
    "",
    `- [Individual dynamic \`zf_*\` prototypes](../wiki/${protosStem})`,
    "",
    "",
  ].join("\n");
  const bodyWithoutHeading = body.replace(/^# TypeScript API reference\s*/m, "");
  return addGeneratedHeader(`# TypeScript API reference\n\n${provenance}${bodyWithoutHeading}`, metadata);
}

function enhanceModulePage(contents, moduleName) {
  if (moduleName === "index") return contents.replace(/^# index$/m, "# High-level TypeScript API");
  const protosStem = TYPESCRIPT_PROTOS_PAGE.slice(0, -3);
  return contents
    .replace(/^# lowlevel$/m, "# Low-level TypeScript API")
    .replace(/^# Low-level TypeScript API$/m, `# Low-level TypeScript API\n\nSee also: [individual dynamic \`zf_*\` prototypes](../wiki/${protosStem}).`);
}

/** Normalize TypeDoc output, synthesize PROTOS docs, and build deterministic metadata. */
export async function normalizeTypeScriptWiki({ rawDirectory, reflection, protosSource, metadata, toolchain }) {
  const rawEntries = await readdir(rawDirectory, { withFileTypes: true });
  const rawFiles = rawEntries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".md"))
    .map((entry) => entry.name)
    .sort();
  if (!rawFiles.includes(TYPESCRIPT_ENTRY_PAGE)) throw new Error(`TypeDoc did not emit ${TYPESCRIPT_ENTRY_PAGE}`);
  const forbiddenRaw = rawFiles.filter((name) => /^_?sidebar\.md$/i.test(name) || /^home\.md$/i.test(name));
  if (forbiddenRaw.length) throw new Error(`TypeDoc emitted globally owned wiki pages: ${forbiddenRaw.join(", ")}`);

  const rawToManaged = new Map();
  for (const rawFile of rawFiles) {
    const rawStem = rawFile.slice(0, -3);
    const managedStem = managedTypeScriptPageName(rawFile).slice(0, -3);
    if ([...rawToManaged.values()].includes(managedStem)) throw new Error(`duplicate managed page ${managedStem}`);
    rawToManaged.set(rawStem, managedStem);
  }

  const pages = new Map();
  const unresolvedLinks = [];
  for (const rawFile of rawFiles) {
    const rawStem = rawFile.slice(0, -3);
    const target = `${rawToManaged.get(rawStem)}.md`;
    let contents = normalizeText(await readFile(path.join(rawDirectory, rawFile), "utf8"));
    const rewritten = rewriteTypeScriptWikiLinks(contents, rawToManaged);
    unresolvedLinks.push(...rewritten.unresolved.map((link) => `${rawFile} -> ${link}`));
    contents = rewritten.markdown;
    if (rawFile === TYPESCRIPT_ENTRY_PAGE) contents = enhanceEntryPage(contents, metadata);
    else {
      if (rawFile === "index.md") contents = enhanceModulePage(contents, "index");
      if (rawFile === "lowlevel.md") contents = enhanceModulePage(contents, "lowlevel");
      contents = addGeneratedHeader(contents, metadata);
    }
    pages.set(target, contents);
  }

  const protos = parseTypeScriptProtos(protosSource);
  pages.set(TYPESCRIPT_PROTOS_PAGE, renderPrototypeSupplement(protos, metadata));
  const rawNames = new Set(rawFiles.map((name) => name.slice(0, -3)));
  const symbolCoverage = collectSymbols(reflection, rawNames, rawToManaged, pages);
  const prototypeSymbols = protos.map((proto) => ({
    qualifiedName: `lowlevel.lib.${proto.name}`,
    name: proto.name,
    kind: "DynamicPrototype",
    page: TYPESCRIPT_PROTOS_PAGE,
    signature: formatTypeScriptProtoSignature(proto),
    nativeIR: { returns: proto.returns, args: proto.args },
  }));
  const missingPrototypes = prototypeSymbols
    .filter((symbol) => !pages.get(TYPESCRIPT_PROTOS_PAGE).includes(`## \`${symbol.name}\``))
    .map((symbol) => symbol.name);
  const duplicatePrototypes = prototypeSymbols
    .filter((symbol, index) => prototypeSymbols.findIndex((item) => item.name === symbol.name) !== index)
    .map((symbol) => symbol.name);

  const managedPages = [...pages.keys()].sort();
  const forbiddenPages = managedPages.filter(
    (name) => !name.startsWith(TYPESCRIPT_PAGE_PREFIX) || /^_?sidebar\.md$/i.test(name) || /^home\.md$/i.test(name),
  );
  const emptyPages = managedPages.filter((name) => !pages.get(name).trim());
  const danglingLinks = findDanglingLinks(pages);
  const coverage = {
    schemaVersion: 1,
    language: "typescript",
    valid: false,
    entryPoints: {
      expected: TYPESCRIPT_ENTRY_POINTS,
      reflectedModules: (reflection.children ?? []).filter((child) => child.kind === 2).map((child) => child.name).sort(),
      reflectedSources: (reflection.children ?? [])
        .filter((child) => child.kind === 2)
        .map((child) => sourceOf(child)?.file ?? null)
        .sort(),
    },
    pages: {
      expected: managedPages.length,
      documented: managedPages.length - emptyPages.length,
      empty: emptyPages,
      forbidden: forbiddenPages,
      unresolvedDuringRewrite: [...new Set(unresolvedLinks)].sort(),
      danglingLinks,
    },
    typedocSymbols: {
      expected: symbolCoverage.symbols.length,
      documented: symbolCoverage.symbols.length - symbolCoverage.missing.length,
      missing: symbolCoverage.missing,
      duplicates: symbolCoverage.duplicates,
    },
    dynamicPrototypes: {
      expected: prototypeSymbols.length,
      documented: prototypeSymbols.length - missingPrototypes.length,
      missing: missingPrototypes,
      duplicates: [...new Set(duplicatePrototypes)].sort(),
    },
  };
  coverage.valid =
    coverage.entryPoints.reflectedModules.join(",") === "index,lowlevel" &&
    coverage.entryPoints.reflectedSources.join(",") === "src/index.ts,src/lowlevel/index.ts" &&
    coverage.pages.empty.length === 0 &&
    coverage.pages.forbidden.length === 0 &&
    coverage.pages.unresolvedDuringRewrite.length === 0 &&
    coverage.pages.danglingLinks.length === 0 &&
    coverage.typedocSymbols.missing.length === 0 &&
    coverage.typedocSymbols.duplicates.length === 0 &&
    coverage.dynamicPrototypes.missing.length === 0 &&
    coverage.dynamicPrototypes.duplicates.length === 0;

  const manifest = {
    schemaVersion: 1,
    language: "typescript",
    package: "zigfitsio",
    packageVersion: metadata.packageVersion,
    release: {
      tag: metadata.tag,
      sha: metadata.sha,
      repository: metadata.repository,
    },
    sourceRoot: "bindings/typescript",
    entryPoints: TYPESCRIPT_ENTRY_POINTS,
    generator: toolchain,
    managedPages,
    coverageFile: TYPESCRIPT_COVERAGE_FILE,
    symbols: {
      typedoc: symbolCoverage.symbols,
      dynamicPrototypes: prototypeSymbols,
    },
  };
  return { pages, manifest, coverage, manifestText: jsonText(manifest), coverageText: jsonText(coverage) };
}

export function assertValidTypeScriptCoverage(coverage) {
  if (coverage.valid) return;
  const details = [];
  const diagnosticArrays = new Set([
    "empty",
    "forbidden",
    "unresolvedDuringRewrite",
    "danglingLinks",
    "missing",
    "duplicates",
  ]);
  for (const [section, values] of Object.entries(coverage)) {
    if (!values || typeof values !== "object" || Array.isArray(values)) continue;
    for (const [name, value] of Object.entries(values)) {
      if (diagnosticArrays.has(name) && Array.isArray(value) && value.length) {
        details.push(`${section}.${name}: ${value.join(", ")}`);
      }
    }
  }
  throw new Error(`TypeScript wiki coverage validation failed${details.length ? `\n${details.join("\n")}` : ""}`);
}
