//! Generate the GitHub-Wiki-native reference for zigfitsio's public Zig API.
//!
//! Discovery is deliberately rooted at `src/root.zig`: a declaration elsewhere is included
//! only when a root export exposes it as a type, function alias, or namespace. The root export
//! set is independently compared with compiler reflection over the `zigfitsio` module, making
//! it impossible for an AST parsing regression to silently omit a top-level public symbol.
//!
//! Usage:
//!   zig build wiki-zig -- <output-dir> [--tag vX.Y.Z] [--sha SHA]
//!       [--repo-url URL] [--project-root DIR] [--strict-docs]
const std = @import("std");
const reflected_api = @import("zigfitsio");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;

const default_repo_url = "https://github.com/anhydrous99/zigfitsio";
const public_root = "src/root.zig";
const max_source_bytes = 16 * 1024 * 1024;
const max_expansion_depth = 12;

const Options = struct {
    out_dir: []const u8,
    project_root: []const u8 = ".",
    tag: []const u8 = "unreleased",
    sha: []const u8 = "WORKTREE",
    repo_url: []const u8 = default_repo_url,
    strict_docs: bool = false,
};

const SourceFile = struct {
    /// Repository-relative path, always normalized with `/` separators.
    path: []const u8,
    source: [:0]const u8,
    tree: Ast,
};

const DeclRef = struct {
    file: *SourceFile,
    node: Node.Index,
};

const Target = union(enum) {
    module: *SourceFile,
    decl: DeclRef,
};

const Symbol = struct {
    path: []const u8,
    kind: []const u8,
    source: []const u8,
    line: usize,
    documented: bool,
};

const Doc = struct {
    text: []const u8,
    documented: bool,
};

const Coverage = struct {
    ast_root_exports: usize,
    compiler_root_exports: usize,
    emitted_root_exports: usize,
    root_percent: u8,
    compiler_generic_return_members: usize,
    emitted_generic_return_members: usize,
};

const Manifest = struct {
    schema_version: u8 = 1,
    generator: []const u8 = "tools/wiki/zig_api.zig",
    source_root: []const u8 = public_root,
    release: []const u8,
    commit: []const u8,
    symbol_count: usize,
    documented_symbols: usize,
    undocumented_symbols: usize,
    coverage: Coverage,
    symbols: []const Symbol,
};

const Generator = struct {
    alloc: Allocator,
    io: std.Io,
    opts: Options,
    files: std.StringHashMapUnmanaged(*SourceFile) = .empty,
    emitted: std.StringHashMapUnmanaged(void) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    page: std.Io.Writer.Allocating,
    root_discovered: usize = 0,
    root_emitted: usize = 0,
    generic_return_compiler: usize = 0,
    generic_return_emitted: usize = 0,
    documented: usize = 0,
    strict_missing: usize = 0,

    fn init(alloc: Allocator, io: std.Io, opts: Options) Generator {
        return .{
            .alloc = alloc,
            .io = io,
            .opts = opts,
            .page = .init(alloc),
        };
    }

    fn generate(g: *Generator) !void {
        const root = try g.loadFile(public_root);
        try g.writePreamble();
        try g.emitRoot(root);
        try g.validateRootCoverage(root);

        if (g.opts.strict_docs and g.strict_missing != 0) {
            std.debug.print(
                "wiki-zig: strict documentation check failed: {d} public declarations lack /// comments\n",
                .{g.strict_missing},
            );
            for (g.symbols.items) |symbol| {
                if (!symbol.documented and requiresDeclarationDoc(symbol.kind)) {
                    std.debug.print("  {s} ({s}:{d})\n", .{ symbol.path, symbol.source, symbol.line });
                }
            }
            return error.UndocumentedPublicSymbol;
        }

        try g.writeOutputs();
    }

    fn writePreamble(g: *Generator) !void {
        const w = &g.page.writer;
        try w.writeAll("# Zig API Reference\n\n");
        try w.writeAll("> Generated from `src/root.zig`; do not edit this page by hand.\n\n");
        try w.print("- Release: `{s}`\n", .{g.opts.tag});
        try w.print("- Commit: `{s}`\n", .{g.opts.sha});
        try w.writeAll("- Public boundary: `src/root.zig`\n\n");
        try w.writeAll(
            "Only declarations reachable through the consumer import are listed. " ++
                "Source links are pinned to the release commit.\n\n",
        );
    }

    fn emitRoot(g: *Generator, root: *SourceFile) !void {
        for (root.tree.rootDecls()) |node| {
            if (!isPublicDecl(root, node)) continue;
            const name = declName(root, node) orelse return error.UnnamedPublicDeclaration;
            g.root_discovered += 1;
            try g.emitDeclaration(.{ .file = root, .node = node }, name, 2, "root-export", true);
            g.root_emitted += 1;
        }
    }

    fn emitDeclaration(
        g: *Generator,
        original: DeclRef,
        api_path: []const u8,
        heading_depth: usize,
        forced_kind: ?[]const u8,
        expand: bool,
    ) anyerror!void {
        if (heading_depth > max_expansion_depth) return error.PublicApiExpansionTooDeep;
        if (g.emitted.contains(api_path)) return;
        try g.emitted.put(g.alloc, api_path, {});

        const doc = try docForNode(g.alloc, original.file, original.node);
        const kind = forced_kind orelse declarationKind(original.file, original.node);
        try g.addSymbol(api_path, kind, original, doc.documented);

        const w = &g.page.writer;
        try writeHeading(w, heading_depth, api_path);
        if (doc.documented) {
            try w.writeAll(doc.text);
            if (!std.mem.endsWith(u8, doc.text, "\n")) try w.writeByte('\n');
            try w.writeByte('\n');
        } else {
            try w.writeAll("_No API documentation comment._\n\n");
        }

        const signature = try signatureForNode(g.alloc, original.file, original.node);
        try writeCodeBlock(w, signature);
        try g.writeSourceLink(original);

        if (!expand) return;
        const initial = try g.targetForDeclaration(original, 32) orelse Target{ .decl = original };
        const resolved = try g.canonicalize(initial, 32);

        if (resolved == .decl) {
            const canonical = resolved.decl;
            if (!sameDecl(original, canonical)) {
                const resolved_sig = try signatureForNode(g.alloc, canonical.file, canonical.node);
                if (!std.mem.eql(u8, signature, resolved_sig)) {
                    try w.writeAll("Resolved declaration:\n\n");
                    try writeCodeBlock(w, resolved_sig);
                }
            }
        }

        try g.expandTarget(resolved, api_path, heading_depth + 1);
    }

    fn expandTarget(g: *Generator, target: Target, prefix: []const u8, depth: usize) anyerror!void {
        if (depth > max_expansion_depth) return error.PublicApiExpansionTooDeep;
        switch (target) {
            .module => |file| try g.emitNamespace(file, prefix, depth),
            .decl => |decl| try g.emitDeclarationMembers(decl, prefix, depth),
        }
    }

    fn emitNamespace(g: *Generator, file: *SourceFile, prefix: []const u8, depth: usize) !void {
        for (file.tree.rootDecls()) |node| {
            if (!isPublicDecl(file, node)) continue;
            const name = declName(file, node) orelse return error.UnnamedPublicDeclaration;
            const path = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ prefix, name });
            try g.emitDeclaration(.{ .file = file, .node = node }, path, depth, null, true);
        }
    }

    fn emitDeclarationMembers(g: *Generator, decl: DeclRef, prefix: []const u8, depth: usize) !void {
        if (decl.file.tree.fullVarDecl(decl.node)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse return;

            if (decl.file.tree.nodeTag(init_node) == .error_set_decl or
                decl.file.tree.nodeTag(init_node) == .merge_error_sets)
            {
                try g.emitErrorMembers(decl.file, init_node, prefix, depth, 24);
                // The umbrella set includes `std.mem.Allocator.Error`. Local AST traversal cannot
                // enter Zig's standard-library module, so use compiler reflection to close (and
                // independently validate) that final part of the public error set.
                if (std.mem.eql(u8, decl.file.path, "src/errors.zig") and
                    std.mem.eql(u8, declName(decl.file, decl.node) orelse "", "Error"))
                {
                    try g.emitReflectedRootErrorMembers(decl, prefix, depth);
                } else if (std.mem.eql(u8, decl.file.path, "src/iterator.zig") and
                    std.mem.eql(u8, declName(decl.file, decl.node) orelse "", "RunError"))
                {
                    // RunError composes the root Error with caller-supplied E. Reflection over
                    // the root Error closes the std.mem.Allocator.Error branch that local AST
                    // traversal cannot enter, without inventing members for the caller's E.
                    try g.emitReflectedRootErrorMembers(decl, prefix, depth);
                }
                return;
            }

            try g.emitContainerMembers(decl.file, init_node, prefix, depth);
            return;
        }

        // A public comptime function may return an anonymous type. Those declarations and
        // fields are consumer-visible through the returned value even though the function is
        // not itself a var declaration (for example Iterator(...).run and .Binding).
        if (decl.file.tree.nodeTag(decl.node) != .fn_decl) return;
        const body = decl.file.tree.nodeData(decl.node).node_and_node[1];
        var statements_buffer: [2]Node.Index = undefined;
        const statements = decl.file.tree.blockStatements(&statements_buffer, body) orelse return;
        for (statements) |statement| {
            if (decl.file.tree.nodeTag(statement) != .@"return") continue;
            const expression = decl.file.tree.nodeData(statement).opt_node.unwrap() orelse continue;
            try g.emitContainerMembers(decl.file, expression, prefix, depth);
        }
    }

    fn emitContainerMembers(
        g: *Generator,
        file: *SourceFile,
        container_node: Node.Index,
        prefix: []const u8,
        depth: usize,
    ) !void {
        var buffer: [2]Node.Index = undefined;
        const container = file.tree.fullContainerDecl(&buffer, container_node) orelse return;
        const is_enum = file.tree.tokenTag(container.ast.main_token) == .keyword_enum;

        for (container.ast.members) |member| {
            if (file.tree.fullContainerField(member) != null) {
                const name = declName(file, member) orelse continue;
                const path = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ prefix, name });
                const kind: []const u8 = if (is_enum) "enum-member" else "field";
                try g.emitDeclaration(.{ .file = file, .node = member }, path, depth, kind, false);
                continue;
            }
            if (!isPublicDecl(file, member)) continue;
            const name = declName(file, member) orelse return error.UnnamedPublicDeclaration;
            const path = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ prefix, name });
            try g.emitDeclaration(.{ .file = file, .node = member }, path, depth, null, true);
        }
    }

    fn emitErrorMembers(
        g: *Generator,
        file: *SourceFile,
        expression: Node.Index,
        prefix: []const u8,
        depth: usize,
        budget: usize,
    ) !void {
        if (budget == 0) return error.PublicApiResolutionTooDeep;
        const tree = &file.tree;
        switch (tree.nodeTag(expression)) {
            .error_set_decl => {
                const braces = tree.nodeData(expression).token_and_token;
                var tok = braces[0] + 1;
                while (tok < braces[1]) : (tok += 1) {
                    if (tree.tokenTag(tok) != .identifier) continue;
                    const name = tree.tokenSlice(tok);
                    const path = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ prefix, name });
                    if (g.emitted.contains(path)) continue;
                    try g.emitted.put(g.alloc, path, {});
                    const documented = hasDocBeforeToken(file, tok);
                    const line = tree.tokenLocation(0, tok).line + 1;
                    try g.symbols.append(g.alloc, .{
                        .path = path,
                        .kind = "error-member",
                        .source = file.path,
                        .line = line,
                        .documented = documented,
                    });
                    if (documented) g.documented += 1;

                    try writeHeading(&g.page.writer, depth, path);
                    const member_doc = try docBeforeToken(g.alloc, file, tok);
                    if (member_doc.documented) {
                        try g.page.writer.writeAll(member_doc.text);
                        try g.page.writer.writeAll("\n");
                    } else {
                        try g.page.writer.writeAll("_Error member._\n\n");
                    }
                    const member_sig = try std.fmt.allocPrint(g.alloc, "error.{s}", .{name});
                    try writeCodeBlock(&g.page.writer, member_sig);
                    try g.writeSourceLinkAt(file, line);
                }
            },
            .merge_error_sets => {
                const operands = tree.nodeData(expression).node_and_node;
                try g.emitErrorMembers(file, operands[0], prefix, depth, budget - 1);
                try g.emitErrorMembers(file, operands[1], prefix, depth, budget - 1);
            },
            else => {
                const target = try g.resolveExpr(file, expression, budget - 1) orelse return;
                const canonical = try g.canonicalize(target, budget - 1);
                if (canonical != .decl) return;
                const nested = canonical.decl;
                const nested_var = nested.file.tree.fullVarDecl(nested.node) orelse return;
                const nested_init = nested_var.ast.init_node.unwrap() orelse return;
                try g.emitErrorMembers(nested.file, nested_init, prefix, depth, budget - 1);
            },
        }
    }

    fn emitReflectedRootErrorMembers(g: *Generator, decl: DeclRef, prefix: []const u8, depth: usize) !void {
        inline for (std.meta.fields(reflected_api.Error)) |error_field| {
            const path = try std.fmt.allocPrint(g.alloc, "{s}.{s}", .{ prefix, error_field.name });
            if (!g.emitted.contains(path)) {
                try g.emitted.put(g.alloc, path, {});
                const line = decl.file.tree.tokenLocation(0, decl.file.tree.firstToken(decl.node)).line + 1;
                try g.symbols.append(g.alloc, .{
                    .path = path,
                    .kind = "error-member",
                    .source = decl.file.path,
                    .line = line,
                    .documented = false,
                });

                try writeHeading(&g.page.writer, depth, path);
                try g.page.writer.writeAll("_Included through a compiler-reflected composed error set._\n\n");
                const member_sig = try std.fmt.allocPrint(g.alloc, "error.{s}", .{error_field.name});
                try writeCodeBlock(&g.page.writer, member_sig);
                try g.writeSourceLinkAt(decl.file, line);
            }
        }
    }

    fn addSymbol(g: *Generator, api_path: []const u8, kind: []const u8, decl: DeclRef, documented: bool) !void {
        const line = decl.file.tree.tokenLocation(0, decl.file.tree.firstToken(decl.node)).line + 1;
        try g.symbols.append(g.alloc, .{
            .path = api_path,
            .kind = kind,
            .source = decl.file.path,
            .line = line,
            .documented = documented,
        });
        if (documented) g.documented += 1;
        if (!documented and requiresDeclarationDoc(kind)) g.strict_missing += 1;
    }

    fn writeSourceLink(g: *Generator, decl: DeclRef) !void {
        const line = decl.file.tree.tokenLocation(0, decl.file.tree.firstToken(decl.node)).line + 1;
        try g.writeSourceLinkAt(decl.file, line);
    }

    fn writeSourceLinkAt(g: *Generator, file: *SourceFile, line: usize) !void {
        const repo = std.mem.trimEnd(u8, g.opts.repo_url, "/");
        try g.page.writer.print(
            "[Source]({s}/blob/{s}/{s}#L{d})\n\n",
            .{ repo, g.opts.sha, file.path, line },
        );
    }

    fn targetForDeclaration(g: *Generator, decl: DeclRef, budget: usize) !?Target {
        if (budget == 0) return error.PublicApiResolutionTooDeep;
        const var_decl = decl.file.tree.fullVarDecl(decl.node) orelse return null;
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        if (isContainerExpression(decl.file, init_node)) return Target{ .decl = decl };
        return g.resolveExpr(decl.file, init_node, budget - 1);
    }

    fn canonicalize(g: *Generator, target: Target, budget: usize) anyerror!Target {
        if (budget == 0) return error.PublicApiResolutionTooDeep;
        return switch (target) {
            .module => target,
            .decl => |decl| blk: {
                const var_decl = decl.file.tree.fullVarDecl(decl.node) orelse break :blk target;
                const init_node = var_decl.ast.init_node.unwrap() orelse break :blk target;
                if (isContainerExpression(decl.file, init_node) or
                    decl.file.tree.nodeTag(init_node) == .merge_error_sets)
                {
                    break :blk target;
                }
                const next = try g.resolveExpr(decl.file, init_node, budget - 1) orelse break :blk target;
                if (next == .decl and sameDecl(decl, next.decl)) break :blk target;
                break :blk try g.canonicalize(next, budget - 1);
            },
        };
    }

    fn resolveExpr(g: *Generator, file: *SourceFile, node: Node.Index, budget: usize) !?Target {
        if (budget == 0) return error.PublicApiResolutionTooDeep;
        const tree = &file.tree;
        return switch (tree.nodeTag(node)) {
            .identifier => blk: {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                const found = findTopLevelDecl(file, name) orelse break :blk null;
                break :blk Target{ .decl = found };
            },
            .grouped_expression => g.resolveExpr(file, tree.nodeData(node).node_and_token[0], budget - 1),
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => blk: {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) break :blk null;
                var params_buffer: [2]Node.Index = undefined;
                const params = tree.builtinCallParams(&params_buffer, node) orelse break :blk null;
                if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) break :blk null;
                const quoted = tree.tokenSlice(tree.nodeMainToken(params[0]));
                if (quoted.len < 2) break :blk null;
                const imported = quoted[1 .. quoted.len - 1];
                if (!std.mem.endsWith(u8, imported, ".zig")) break :blk null;
                const path = try normalizeImportPath(g.alloc, file.path, imported);
                break :blk Target{ .module = try g.loadFile(path) };
            },
            .field_access => blk: {
                const lhs_node, const field_token = tree.nodeData(node).node_and_token;
                const lhs_unresolved = try g.resolveExpr(file, lhs_node, budget - 1) orelse break :blk null;
                const lhs = try g.canonicalize(lhs_unresolved, budget - 1);
                const name = tree.tokenSlice(field_token);
                break :blk switch (lhs) {
                    .module => |module| if (findTopLevelDecl(module, name)) |decl|
                        Target{ .decl = decl }
                    else
                        null,
                    .decl => |decl| if (findContainerMember(decl, name)) |member|
                        Target{ .decl = member }
                    else
                        null,
                };
            },
            else => null,
        };
    }

    fn loadFile(g: *Generator, path: []const u8) !*SourceFile {
        if (g.files.get(path)) |cached| return cached;
        const disk_path = if (std.mem.eql(u8, g.opts.project_root, "."))
            path
        else
            try std.fs.path.join(g.alloc, &.{ g.opts.project_root, path });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            g.io,
            disk_path,
            g.alloc,
            .limited(max_source_bytes),
        );
        const source = try g.alloc.dupeZ(u8, bytes);
        const tree = try Ast.parse(g.alloc, source, .zig);
        if (tree.errors.len != 0) {
            std.debug.print("wiki-zig: {s} has {d} parse error(s)\n", .{ path, tree.errors.len });
            return error.InvalidZigSource;
        }

        const owned_path = try g.alloc.dupe(u8, path);
        const file = try g.alloc.create(SourceFile);
        file.* = .{ .path = owned_path, .source = source, .tree = tree };
        try g.files.put(g.alloc, owned_path, file);
        return file;
    }

    fn validateRootCoverage(g: *Generator, root: *SourceFile) !void {
        const compiler_decls = @typeInfo(reflected_api).@"struct".decls;
        if (g.root_discovered != compiler_decls.len or g.root_emitted != compiler_decls.len) {
            std.debug.print(
                "wiki-zig: root coverage mismatch: AST={d}, compiler={d}, emitted={d}\n",
                .{ g.root_discovered, compiler_decls.len, g.root_emitted },
            );
            return error.RootCoverageMismatch;
        }

        inline for (compiler_decls) |compiler_decl| {
            const ast_decl = findTopLevelDecl(root, compiler_decl.name) orelse {
                std.debug.print("wiki-zig: compiler declaration '{s}' was not found in the AST\n", .{compiler_decl.name});
                return error.RootCoverageMismatch;
            };
            if (!isPublicDecl(root, ast_decl.node) or !g.emitted.contains(compiler_decl.name)) {
                std.debug.print("wiki-zig: compiler declaration '{s}' was not emitted\n", .{compiler_decl.name});
                return error.RootCoverageMismatch;
            }
        }

        // Instantiate the public generic with a minimal valid consumer shape. Compiler
        // reflection then independently closes the AST coverage check for its anonymous
        // returned type; only public declarations and fields appear in this type information.
        const ReflectedIterator = reflected_api.Iterator(
            struct { value: []f64 },
            error{Callback},
        );
        const iterator_info = @typeInfo(ReflectedIterator).@"struct";
        g.generic_return_compiler = iterator_info.decls.len + iterator_info.fields.len;
        inline for (iterator_info.decls) |decl| {
            const path = try std.fmt.allocPrint(g.alloc, "Iterator.{s}", .{decl.name});
            if (!g.emitted.contains(path)) {
                std.debug.print("wiki-zig: generic returned declaration '{s}' was not emitted\n", .{path});
                return error.GenericReturnCoverageMismatch;
            }
            g.generic_return_emitted += 1;
        }
        inline for (iterator_info.fields) |field| {
            const path = try std.fmt.allocPrint(g.alloc, "Iterator.{s}", .{field.name});
            if (!g.emitted.contains(path)) {
                std.debug.print("wiki-zig: generic returned field '{s}' was not emitted\n", .{path});
                return error.GenericReturnCoverageMismatch;
            }
            g.generic_return_emitted += 1;
        }
        inline for (std.meta.fields(ReflectedIterator.Role)) |field| {
            g.generic_return_compiler += 1;
            const path = try std.fmt.allocPrint(g.alloc, "Iterator.Role.{s}", .{field.name});
            if (!g.emitted.contains(path)) {
                std.debug.print("wiki-zig: nested generic enum member '{s}' was not emitted\n", .{path});
                return error.GenericReturnCoverageMismatch;
            }
            g.generic_return_emitted += 1;
        }
        inline for (std.meta.fields(ReflectedIterator.Binding)) |field| {
            g.generic_return_compiler += 1;
            const path = try std.fmt.allocPrint(g.alloc, "Iterator.Binding.{s}", .{field.name});
            if (!g.emitted.contains(path)) {
                std.debug.print("wiki-zig: nested generic struct field '{s}' was not emitted\n", .{path});
                return error.GenericReturnCoverageMismatch;
            }
            g.generic_return_emitted += 1;
        }
        inline for (std.meta.fields(ReflectedIterator.RunError)) |error_field| {
            // Callback belongs to the representative caller error set, not to zigfitsio.
            if (comptime std.mem.eql(u8, error_field.name, "Callback")) continue;
            g.generic_return_compiler += 1;
            const path = try std.fmt.allocPrint(g.alloc, "Iterator.RunError.{s}", .{error_field.name});
            if (!g.emitted.contains(path)) {
                std.debug.print("wiki-zig: nested generic error member '{s}' was not emitted\n", .{path});
                return error.GenericReturnCoverageMismatch;
            }
            g.generic_return_emitted += 1;
        }

        // Every public root declaration is required to carry a contract-level doc comment.
        for (root.tree.rootDecls()) |node| {
            if (!isPublicDecl(root, node)) continue;
            if (!(try docForNode(g.alloc, root, node)).documented) {
                std.debug.print("wiki-zig: undocumented root export '{s}'\n", .{declName(root, node).?});
                return error.UndocumentedRootExport;
            }
        }
    }

    fn writeOutputs(g: *Generator) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(g.io, g.opts.out_dir);
        const page_path = try std.fs.path.join(g.alloc, &.{ g.opts.out_dir, "Zig-API.md" });
        try cwd.writeFile(g.io, .{ .sub_path = page_path, .data = g.page.written() });

        var json: std.Io.Writer.Allocating = .init(g.alloc);
        const manifest = Manifest{
            .release = g.opts.tag,
            .commit = g.opts.sha,
            .symbol_count = g.symbols.items.len,
            .documented_symbols = g.documented,
            .undocumented_symbols = g.symbols.items.len - g.documented,
            .coverage = .{
                .ast_root_exports = g.root_discovered,
                .compiler_root_exports = @typeInfo(reflected_api).@"struct".decls.len,
                .emitted_root_exports = g.root_emitted,
                .root_percent = 100,
                .compiler_generic_return_members = g.generic_return_compiler,
                .emitted_generic_return_members = g.generic_return_emitted,
            },
            .symbols = g.symbols.items,
        };
        try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &json.writer);
        try json.writer.writeByte('\n');
        const manifest_path = try std.fs.path.join(g.alloc, &.{ g.opts.out_dir, "zig-api-symbols.json" });
        try cwd.writeFile(g.io, .{ .sub_path = manifest_path, .data = json.written() });

        std.debug.print(
            "wiki-zig: wrote {d} symbols ({d}/{d} documented) to {s}\n",
            .{ g.symbols.items.len, g.documented, g.symbols.items.len, g.opts.out_dir },
        );
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    const opts = parseOptions(argv) catch |err| {
        usage();
        return err;
    };

    var threaded: std.Io.Threaded = .init_single_threaded;
    var generator = Generator.init(alloc, threaded.io(), opts);
    try generator.generate();
}

fn parseOptions(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingOutputDirectory;
    var opts = Options{ .out_dir = argv[1] };
    var i: usize = 2;
    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--strict-docs")) {
            opts.strict_docs = true;
            i += 1;
            continue;
        }
        if (i + 1 >= argv.len) return error.MissingOptionValue;
        const value = argv[i + 1];
        if (std.mem.eql(u8, arg, "--tag")) {
            opts.tag = value;
        } else if (std.mem.eql(u8, arg, "--sha")) {
            opts.sha = value;
        } else if (std.mem.eql(u8, arg, "--repo-url")) {
            opts.repo_url = value;
        } else if (std.mem.eql(u8, arg, "--project-root")) {
            opts.project_root = value;
        } else {
            return error.UnknownOption;
        }
        i += 2;
    }
    return opts;
}

fn usage() void {
    std.debug.print(
        "usage: wiki-zig <output-dir> [--tag vX.Y.Z] [--sha SHA] " ++
            "[--repo-url URL] [--project-root DIR] [--strict-docs]\n",
        .{},
    );
}

fn isPublicDecl(file: *const SourceFile, node: Node.Index) bool {
    if (file.tree.fullVarDecl(node)) |decl| return decl.visib_token != null;
    var fn_buffer: [1]Node.Index = undefined;
    if (file.tree.fullFnProto(&fn_buffer, node)) |decl| return decl.visib_token != null;
    return false;
}

fn declName(file: *const SourceFile, node: Node.Index) ?[]const u8 {
    if (file.tree.fullVarDecl(node)) |decl| {
        return file.tree.tokenSlice(decl.ast.mut_token + 1);
    }
    var fn_buffer: [1]Node.Index = undefined;
    if (file.tree.fullFnProto(&fn_buffer, node)) |decl| {
        if (decl.name_token) |tok| return file.tree.tokenSlice(tok);
        return null;
    }
    if (file.tree.fullContainerField(node)) |field| {
        return file.tree.tokenSlice(field.ast.main_token);
    }
    return null;
}

fn declarationKind(file: *const SourceFile, node: Node.Index) []const u8 {
    var fn_buffer: [1]Node.Index = undefined;
    if (file.tree.fullFnProto(&fn_buffer, node) != null) return "function";
    if (file.tree.fullContainerField(node) != null) return "field";
    if (file.tree.fullVarDecl(node)) |decl| {
        if (decl.ast.init_node.unwrap()) |init_node| {
            if (isContainerExpression(file, init_node)) return "type";
        }
        return "constant";
    }
    return "declaration";
}

/// Fields and enum/error members are included in the reference but do not require individual
/// `///` comments: a containing type's contract often documents them as a group. Named public
/// declarations and functions do require their own attached documentation in strict mode.
fn requiresDeclarationDoc(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "root-export") or
        std.mem.eql(u8, kind, "function") or
        std.mem.eql(u8, kind, "constant") or
        std.mem.eql(u8, kind, "type") or
        std.mem.eql(u8, kind, "declaration");
}

fn isContainerExpression(file: *const SourceFile, node: Node.Index) bool {
    if (file.tree.nodeTag(node) == .error_set_decl) return true;
    var buffer: [2]Node.Index = undefined;
    return file.tree.fullContainerDecl(&buffer, node) != null;
}

fn findTopLevelDecl(file: *SourceFile, name: []const u8) ?DeclRef {
    for (file.tree.rootDecls()) |node| {
        const candidate = declName(file, node) orelse continue;
        if (std.mem.eql(u8, candidate, name)) return .{ .file = file, .node = node };
    }
    return null;
}

fn findContainerMember(decl: DeclRef, name: []const u8) ?DeclRef {
    const var_decl = decl.file.tree.fullVarDecl(decl.node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    var buffer: [2]Node.Index = undefined;
    const container = decl.file.tree.fullContainerDecl(&buffer, init_node) orelse return null;
    for (container.ast.members) |member| {
        const candidate = declName(decl.file, member) orelse continue;
        if (std.mem.eql(u8, candidate, name)) return .{ .file = decl.file, .node = member };
    }
    return null;
}

fn sameDecl(a: DeclRef, b: DeclRef) bool {
    return a.file == b.file and a.node == b.node;
}

fn signatureForNode(alloc: Allocator, file: *const SourceFile, node: Node.Index) ![]const u8 {
    var fn_buffer: [1]Node.Index = undefined;
    if (file.tree.fullFnProto(&fn_buffer, node)) |fn_proto| {
        return alloc.dupe(u8, file.tree.getNodeSource(fn_proto.ast.proto_node));
    }

    if (file.tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (isContainerExpression(file, init_node)) {
                const first = file.tree.tokenStart(file.tree.firstToken(node));
                const main_token = file.tree.nodeMainToken(init_node);
                const end = file.tree.tokenStart(main_token) + file.tree.tokenSlice(main_token).len;
                return std.fmt.allocPrint(alloc, "{s} {{ ... }};", .{std.mem.trim(u8, file.source[first..end], " \t\r\n")});
            }
        }
    }

    const source = std.mem.trim(u8, file.tree.getNodeSource(node), " \t\r\n");
    if (source.len <= 1200) return alloc.dupe(u8, source);
    return std.fmt.allocPrint(alloc, "{s}\n// … initializer omitted …", .{source[0..1200]});
}

fn docForNode(alloc: Allocator, file: *const SourceFile, node: Node.Index) !Doc {
    return docBeforeToken(alloc, file, file.tree.firstToken(node));
}

fn hasDocBeforeToken(file: *const SourceFile, token: Ast.TokenIndex) bool {
    return token > 0 and file.tree.tokenTag(token - 1) == .doc_comment;
}

fn docBeforeToken(alloc: Allocator, file: *const SourceFile, token: Ast.TokenIndex) !Doc {
    if (!hasDocBeforeToken(file, token)) return .{ .text = "", .documented = false };
    var first = token - 1;
    while (first > 0 and file.tree.tokenTag(first - 1) == .doc_comment) first -= 1;

    var out: std.Io.Writer.Allocating = .init(alloc);
    var i = first;
    while (i < token) : (i += 1) {
        var line = file.tree.tokenSlice(i);
        if (std.mem.startsWith(u8, line, "///")) line = line[3..];
        if (line.len > 0 and line[0] == ' ') line = line[1..];
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }
    return .{ .text = try out.toOwnedSlice(), .documented = true };
}

fn writeHeading(writer: *std.Io.Writer, depth: usize, name: []const u8) !void {
    const actual_depth = @min(depth, 6);
    for (0..actual_depth) |_| try writer.writeByte('#');
    try writer.print(" `{s}`\n\n", .{name});
}

fn writeCodeBlock(writer: *std.Io.Writer, source: []const u8) !void {
    try writer.writeAll("```zig\n");
    try writer.writeAll(source);
    if (!std.mem.endsWith(u8, source, "\n")) try writer.writeByte('\n');
    try writer.writeAll("```\n\n");
}

fn normalizeImportPath(alloc: Allocator, current_file: []const u8, imported: []const u8) ![]const u8 {
    const directory = std.fs.path.dirname(current_file) orelse ".";
    const joined = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ directory, imported });
    defer alloc.free(joined);
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(alloc);
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len == 0) return error.ImportEscapesRepository;
            _ = components.pop();
            continue;
        }
        try components.append(alloc, component);
    }
    if (components.items.len == 0) return error.EmptyImportPath;
    return std.mem.join(alloc, "/", components.items);
}

test "normalizes imports relative to the declaring source" {
    const alloc = std.testing.allocator;
    const actual = try normalizeImportPath(alloc, "src/compress/tiled.zig", "../errors.zig");
    defer alloc.free(actual);
    try std.testing.expectEqualStrings("src/errors.zig", actual);
}

test "extracts attached declaration documentation" {
    const alloc = std.testing.allocator;
    const source = try alloc.dupeZ(u8,
        \\/// First line.
        \\/// Second line.
        \\pub const Thing = struct {};
    );
    defer alloc.free(source);
    var tree = try Ast.parse(alloc, source, .zig);
    defer tree.deinit(alloc);
    var file = SourceFile{ .path = "fixture.zig", .source = source, .tree = tree };
    const doc = try docForNode(alloc, &file, file.tree.rootDecls()[0]);
    defer alloc.free(doc.text);
    try std.testing.expect(doc.documented);
    try std.testing.expectEqualStrings("First line.\nSecond line.\n", doc.text);
}
