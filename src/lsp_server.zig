const std = @import("std");
const lsp = @import("lsp");
const build_options = @import("build_options");
const analysis = @import("analysis.zig");
const backend_bootstrap = @import("backend_bootstrap.zig");
const compiler_session = @import("compiler_session.zig");
const compile_units = @import("compile_units.zig");
const document_module = @import("document.zig");
const language_hover = @import("language_hover.zig");
const hover = @import("hover.zig");
const syntax_types = @import("syntax_types.zig");
const action_lsp = @import("actions/lsp_adapter.zig");
const project_actions = @import("actions/project.zig");
const zig_actions = @import("actions/registry.zig");

const Document = document_module.Document;
const Declaration = document_module.Declaration;

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio = lsp.Transport.Stdio.init(&read_buffer, .stdin(), .stdout());
    var server = Server.init(io, allocator, environ, &stdio.transport);
    defer server.deinit();
    try lsp.basic_server.run(io, allocator, &stdio.transport, &server, std.log.err);
    if (!server.shutdown_requested) return error.ExitWithoutShutdown;
}

pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    transport: *lsp.Transport,
    documents: document_module.Store,
    compiler: ?compiler_session.Session = null,
    compiler_root_uri: ?[]u8 = null,
    compiler_root_version: i32 = 0,
    zig_lib_directory: ?[]u8 = null,
    compiler_start_attempted: bool = false,
    compiler_restart_available: bool = true,
    shutdown_requested: bool = false,
    workspace_document_changes: bool = false,
    workspace_create_file: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        transport: *lsp.Transport,
    ) Server {
        return .{
            .io = io,
            .allocator = allocator,
            .environ = environ,
            .transport = transport,
            .documents = .init(allocator),
        };
    }

    pub fn deinit(server: *Server) void {
        if (server.compiler) |*compiler| compiler.deinit();
        if (server.compiler_root_uri) |uri| server.allocator.free(uri);
        if (server.zig_lib_directory) |directory| server.allocator.free(directory);
        server.documents.deinit();
        server.* = undefined;
    }

    pub fn initialize(
        server: *Server,
        _: std.mem.Allocator,
        params: lsp.ParamsType("initialize"),
    ) lsp.ResultType("initialize") {
        if (params.capabilities.workspace) |workspace| {
            if (workspace.workspaceEdit) |workspace_edit| {
                server.workspace_document_changes = workspace_edit.documentChanges orelse false;
                if (workspace_edit.resourceOperations) |operations| {
                    for (operations) |operation| switch (operation) {
                        .create => server.workspace_create_file = true,
                        else => {},
                    };
                }
            }
        }
        return .{
            .capabilities = .{
                .positionEncoding = .{ .@"utf-16" = {} },
                .textDocumentSync = .{ .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Incremental,
                    .save = .{ .bool = true },
                } },
                .completionProvider = .{ .triggerCharacters = &.{ ".", "{", "\"", "/" } },
                .hoverProvider = .{ .bool = true },
                .signatureHelpProvider = .{
                    .triggerCharacters = &.{ "(", "," },
                    .retriggerCharacters = &.{","},
                },
                .definitionProvider = .{ .bool = true },
                .referencesProvider = .{ .bool = true },
                .documentSymbolProvider = .{ .bool = true },
                .codeLensProvider = .{ .resolveProvider = false },
                .codeActionProvider = .{ .code_action_options = .{
                    .codeActionKinds = &.{
                        .quickfix,
                        .@"refactor.extract",
                        .@"refactor.rewrite",
                        .@"source.organizeImports",
                        .@"source.fixAll",
                    },
                    .resolveProvider = false,
                } },
                .workspaceSymbolProvider = .{ .bool = true },
                .documentFormattingProvider = .{ .bool = true },
                .renameProvider = .{ .rename_options = .{ .prepareProvider = false } },
                .semanticTokensProvider = .{ .semantic_tokens_options = .{
                    .legend = .{
                        .tokenTypes = semantic_token_types,
                        .tokenModifiers = semantic_token_modifiers,
                    },
                    .range = .{ .bool = true },
                    .full = .{ .bool = true },
                } },
                .inlayHintProvider = .{ .inlay_hint_options = .{ .resolveProvider = false } },
                .executeCommandProvider = .{ .commands = &.{"zig-analyzer.peekResolvedType"} },
                .callHierarchyProvider = .{ .call_hierarchy_options = .{} },
                .workspace = .{ .workspaceFolders = .{
                    .supported = true,
                    .changeNotifications = .{ .bool = true },
                } },
            },
            .serverInfo = .{
                .name = "zig-analyzer",
                .version = build_options.version_string,
            },
        };
    }

    pub fn initialized(_: *Server, _: std.mem.Allocator, _: lsp.ParamsType("initialized")) void {}

    pub fn onResponse(_: *Server, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}

    pub fn @"$/cancelRequest"(_: *Server, _: std.mem.Allocator, _: lsp.ParamsType("$/cancelRequest")) void {}

    pub fn @"workspace/didChangeWorkspaceFolders"(
        _: *Server,
        _: std.mem.Allocator,
        _: lsp.ParamsType("workspace/didChangeWorkspaceFolders"),
    ) void {}

    pub fn shutdown(server: *Server, _: std.mem.Allocator, _: lsp.ParamsType("shutdown")) lsp.ResultType("shutdown") {
        server.shutdown_requested = true;
        return null;
    }

    pub fn exit(_: *Server, _: std.mem.Allocator, _: lsp.ParamsType("exit")) void {}

    pub fn @"textDocument/didOpen"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didOpen"),
    ) !void {
        try server.documents.open(
            params.textDocument.uri,
            params.textDocument.version,
            params.textDocument.text,
        );
        try server.ensureCompiler(arena, params.textDocument.uri);
        try server.syncCompilerOverlay(params.textDocument.uri);
        try server.publishDiagnostics(arena, params.textDocument.uri);
    }

    pub fn @"textDocument/didChange"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didChange"),
    ) !void {
        try server.documents.change(
            params.textDocument.uri,
            params.textDocument.version,
            params.contentChanges,
        );
        if (server.compiler == null and server.compiler_restart_available) {
            server.compiler_restart_available = false;
            server.compiler_start_attempted = false;
            try server.ensureCompiler(arena, params.textDocument.uri);
        }
        try server.syncCompilerOverlay(params.textDocument.uri);
        try server.publishDiagnostics(arena, params.textDocument.uri);
    }

    pub fn @"textDocument/didClose"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didClose"),
    ) !void {
        if (server.compiler) |*compiler| {
            compiler.removeOverlay(params.textDocument.uri) catch |err| server.recordCompilerFailure(err);
        }
        if (server.compiler_root_uri) |root_uri| {
            if (std.mem.eql(u8, root_uri, params.textDocument.uri)) {
                server.allocator.free(root_uri);
                server.compiler_root_uri = null;
            }
        }
        _ = server.documents.close(params.textDocument.uri);
        try server.transport.writeNotification(
            server.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = params.textDocument.uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        );
    }

    pub fn @"textDocument/didSave"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didSave"),
    ) !void {
        if (server.compiler) |*compiler| compiler.deinit();
        server.compiler = null;
        if (server.compiler_root_uri) |uri| server.allocator.free(uri);
        server.compiler_root_uri = null;
        server.compiler_start_attempted = false;
        server.compiler_restart_available = true;
        try server.ensureCompiler(arena, params.textDocument.uri);
        try server.syncCompilerOverlay(params.textDocument.uri);
        try server.publishDiagnostics(arena, params.textDocument.uri);
    }

    pub fn @"textDocument/completion"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/completion"),
    ) !lsp.ResultType("textDocument/completion") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        var completions: std.ArrayList(lsp.types.completion.Item) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const byte_offset = document.byteOffset(params.position);
        if (formatStringAt(document.source, byte_offset)) {
            const placeholders = [_]struct { label: []const u8, detail: []const u8 }{
                .{ .label = "{s}", .detail = "string or byte slice" },
                .{ .label = "{d}", .detail = "decimal integer" },
                .{ .label = "{x}", .detail = "hexadecimal integer" },
                .{ .label = "{c}", .detail = "character" },
                .{ .label = "{any}", .detail = "default formatting" },
                .{ .label = "{!}", .detail = "error union" },
                .{ .label = "{?}", .detail = "optional" },
            };
            for (placeholders) |placeholder| try completions.append(arena, .{
                .label = placeholder.label,
                .kind = .Snippet,
                .detail = placeholder.detail,
            });
            return .{ .completion_items = try completions.toOwnedSlice(arena) };
        }
        if (importStringPrefix(document.source, byte_offset)) |prefix| {
            return .{ .completion_items = try server.importPathCompletions(arena, document, prefix) };
        }
        if (memberReceiver(document.source, byte_offset)) |receiver| {
            const syntax_members = try server.syntaxMembers(arena, document, receiver);
            for (syntax_members) |member| {
                try seen.put(arena, member.name, {});
                try completions.append(arena, .{
                    .label = member.name,
                    .kind = member.kind,
                    .detail = member.detail,
                });
            }
            if (syntax_members.len != 0) {
                return .{ .completion_items = try completions.toOwnedSlice(arena) };
            }
            if (try server.compilerTypeMembers(arena, document, receiver)) |member_names| {
                for (member_names) |name| {
                    if (!isIdentifier(name) or seen.contains(name)) continue;
                    try seen.put(arena, name, {});
                    try completions.append(arena, .{
                        .label = name,
                        .kind = .Field,
                        .detail = "compiler-resolved member",
                    });
                }
            }
            return .{ .completion_items = try completions.toOwnedSlice(arena) };
        }
        for (document.declarations) |declaration| {
            if (seen.contains(declaration.name)) continue;
            try seen.put(arena, declaration.name, {});
            try completions.append(arena, .{
                .label = declaration.name,
                .kind = completionKind(declaration.kind),
                .detail = declarationKindName(declaration.kind),
            });
        }
        const compiler_declarations = if (server.compiler) |*compiler|
            compiler.workspaceDeclarations(arena) catch |err| declarations: {
                server.recordCompilerFailure(err);
                break :declarations &.{};
            }
        else
            &.{};
        for (compiler_declarations) |fully_qualified_name| {
            if (completions.items.len == 4096) break;
            if (!isRelatedCompilerDeclaration(document, fully_qualified_name)) continue;
            const name = declarationBaseName(fully_qualified_name);
            if (!isIdentifier(name) or seen.contains(name)) continue;
            try seen.put(arena, name, {});
            try completions.append(arena, .{
                .label = name,
                .kind = .Variable,
                .detail = fully_qualified_name,
            });
        }
        return .{ .completion_items = try completions.toOwnedSlice(arena) };
    }

    pub fn @"textDocument/hover"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/hover"),
    ) !lsp.ResultType("textDocument/hover") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const token = document.tokenAt(document.byteOffset(params.position)) orelse return null;
        const spelling = document.source[token.loc.start..token.loc.end];
        const description = if (try language_hover.describe(arena, spelling, token.tag)) |language| hover.Content{
            .declaration = language.syntax,
            .type_summary = language.category,
            .documentation = language.summary,
            .reference = .{
                .label = "Zig language reference",
                .url = language.reference,
            },
        } else if (token.tag == .identifier)
            try server.hoverDescription(arena, document, token.loc) orelse return null
        else
            return null;
        return .{
            .contents = .{ .markup_content = .{
                .kind = .markdown,
                .value = try hover.default_markdown_renderer.render(arena, description),
            } },
            .range = document.range(token.loc),
        };
    }

    pub fn @"textDocument/definition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/definition"),
    ) !lsp.ResultType("textDocument/definition") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const byte_offset = document.byteOffset(params.position);
        if (try server.importedFileDefinition(arena, document, byte_offset)) |location| {
            return .{ .definition = .{ .location = location } };
        }
        const identifier_span = document.identifierAt(byte_offset) orelse return null;
        if (identifier_span.start > 0 and document.source[identifier_span.start - 1] == '.') {
            if (try server.importExpressionMemberDefinition(arena, document, identifier_span)) |location| {
                return .{ .definition = .{ .location = location } };
            }
        }
        if (memberReceiver(document.source, identifier_span.start)) |receiver| {
            if (try server.importedDefinition(arena, document, receiver, document.source[identifier_span.start..identifier_span.end])) |location| {
                return .{ .definition = .{ .location = location } };
            }
        }
        if (try server.aliasTargetDefinition(arena, document, identifier_span)) |location| {
            return .{ .definition = .{ .location = location } };
        }
        if (try server.importAliasDefinition(
            arena,
            document,
            document.source[identifier_span.start..identifier_span.end],
        )) |location| {
            return .{ .definition = .{ .location = location } };
        }
        const declaration = declarationAtPosition(document, params.position) orelse return null;
        return .{ .definition = .{ .location = .{
            .uri = document.uri,
            .range = document.range(declaration.span),
        } } };
    }

    pub fn @"textDocument/signatureHelp"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/signatureHelp"),
    ) !lsp.ResultType("textDocument/signatureHelp") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const call = callAt(document.source, document.byteOffset(params.position)) orelse return null;
        const label = functionSignature(document.source, call.name) orelse return null;
        const signatures = try arena.alloc(lsp.types.SignatureHelp.Signature, 1);
        signatures[0] = .{ .label = label };
        return .{
            .signatures = signatures,
            .activeSignature = 0,
            .activeParameter = call.active_parameter,
        };
    }

    pub fn @"textDocument/references"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/references"),
    ) !lsp.ResultType("textDocument/references") {
        const origin = server.documents.getConst(params.textDocument.uri) orelse return null;
        const identifier_span = origin.identifierAt(origin.byteOffset(params.position)) orelse return null;
        const name = origin.source[identifier_span.start..identifier_span.end];
        if (try origin.scopedIdentifierSpans(arena, identifier_span.start)) |spans| {
            const locations = try arena.alloc(lsp.types.Location, spans.len);
            var location_count: usize = 0;
            for (spans) |span| {
                if (!params.context.includeDeclaration and std.meta.eql(span, spans[0])) continue;
                locations[location_count] = .{ .uri = origin.uri, .range = origin.range(span) };
                location_count += 1;
            }
            return locations[0..location_count];
        }
        var locations: std.ArrayList(lsp.types.Location) = .empty;
        var iterator = server.documents.documents.valueIterator();
        while (iterator.next()) |document| {
            const spans = try document.identifierSpans(arena, name);
            for (spans) |span| {
                if (!params.context.includeDeclaration) {
                    if (document.declarationNamed(name)) |declaration| {
                        if (std.meta.eql(span, declaration.span)) continue;
                    }
                }
                try locations.append(arena, .{ .uri = document.uri, .range = document.range(span) });
            }
        }
        return try locations.toOwnedSlice(arena);
    }

    pub fn @"textDocument/documentSymbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/documentSymbol"),
    ) !lsp.ResultType("textDocument/documentSymbol") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const symbols = try arena.alloc(lsp.types.DocumentSymbol, document.declarations.len);
        for (document.declarations, symbols) |declaration, *symbol| {
            const range = document.range(declaration.span);
            symbol.* = .{
                .name = declaration.name,
                .kind = symbolKind(declaration.kind),
                .range = range,
                .selectionRange = range,
            };
        }
        return .{ .document_symbols = symbols };
    }

    pub fn @"workspace/symbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/symbol"),
    ) !lsp.ResultType("workspace/symbol") {
        var symbols: std.ArrayList(lsp.types.SymbolInformation) = .empty;
        var iterator = server.documents.documents.valueIterator();
        while (iterator.next()) |document| {
            for (document.declarations) |declaration| {
                if (params.query.len != 0 and std.mem.indexOf(u8, declaration.name, params.query) == null) continue;
                try symbols.append(arena, .{
                    .name = declaration.name,
                    .kind = symbolKind(declaration.kind),
                    .location = .{
                        .uri = document.uri,
                        .range = document.range(declaration.span),
                    },
                });
            }
        }
        return .{ .symbol_informations = try symbols.toOwnedSlice(arena) };
    }

    pub fn @"textDocument/semanticTokens/full"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/semanticTokens/full"),
    ) !lsp.ResultType("textDocument/semanticTokens/full") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        return .{ .data = try semanticTokens(document, arena, null) };
    }

    pub fn @"textDocument/semanticTokens/range"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/semanticTokens/range"),
    ) !lsp.ResultType("textDocument/semanticTokens/range") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        return .{ .data = try semanticTokens(document, arena, params.range) };
    }

    pub fn @"textDocument/inlayHint"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/inlayHint"),
    ) !lsp.ResultType("textDocument/inlayHint") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        return try typeInlayHints(document, arena, params.range);
    }

    pub fn @"textDocument/codeLens"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/codeLens"),
    ) !lsp.ResultType("textDocument/codeLens") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        var lenses: std.ArrayList(lsp.types.code_lens.Response) = .empty;
        for (document.declarations) |declaration| {
            if (declaration.kind != .constant) continue;
            const shape = try server.resolvedShapeForName(arena, document, declaration.name) orelse continue;
            const arguments = try arena.alloc(std.json.Value, 2);
            arguments[0] = .{ .string = document.uri };
            arguments[1] = .{ .string = declaration.name };
            try lenses.append(arena, .{
                .range = document.range(declaration.span),
                .command = .{
                    .title = try std.fmt.allocPrint(
                        arena,
                        "resolved {s}: {d} {s}",
                        .{
                            resolvedShapeKindName(shape.kind),
                            shape.fields.len,
                            if (shape.fields.len == 1) "member" else "members",
                        },
                    ),
                    .tooltip = "Show the compiler-resolved comptime type",
                    .command = "zig-analyzer.peekResolvedType",
                    .arguments = arguments,
                },
            });
        }
        return try lenses.toOwnedSlice(arena);
    }

    pub fn @"workspace/executeCommand"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/executeCommand"),
    ) !lsp.ResultType("workspace/executeCommand") {
        if (!std.mem.eql(u8, params.command, "zig-analyzer.peekResolvedType")) return error.InvalidParams;
        const arguments = params.arguments orelse return error.InvalidParams;
        if (arguments.len != 2) return error.InvalidParams;
        const uri = switch (arguments[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const type_name = switch (arguments[1]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const document = server.documents.getConst(uri) orelse return error.InvalidParams;
        const shape = try server.resolvedShapeForName(arena, document, type_name) orelse return null;
        return .{ .string = try renderResolvedShape(arena, type_name, shape) };
    }

    pub fn @"textDocument/prepareCallHierarchy"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/prepareCallHierarchy"),
    ) !lsp.ResultType("textDocument/prepareCallHierarchy") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const identifier = document.identifierAt(document.byteOffset(params.position)) orelse return null;
        const name = document.source[identifier.start..identifier.end];
        const location = server.functionNamed(name) orelse return null;
        const items = try arena.alloc(lsp.types.call_hierarchy.Item, 1);
        items[0] = callHierarchyItem(location.document, location.declaration);
        return items;
    }

    pub fn @"callHierarchy/incomingCalls"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("callHierarchy/incomingCalls"),
    ) !lsp.ResultType("callHierarchy/incomingCalls") {
        var calls: std.ArrayList(lsp.types.call_hierarchy.IncomingCall) = .empty;
        var iterator = server.documents.documents.valueIterator();
        while (iterator.next()) |document| {
            const tokens = try tokenize(arena, document.source);
            for (tokens, 0..) |token, index| {
                if (token.tag != .identifier or !std.mem.eql(u8, document.source[token.loc.start..token.loc.end], params.item.name) or
                    index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren or
                    index > 0 and (tokens[index - 1].tag == .keyword_fn or tokens[index - 1].tag == .period)) continue;
                const caller = functionContainingToken(document, tokens, index) orelse continue;
                const ranges = try arena.alloc(lsp.types.Range, 1);
                ranges[0] = document.range(token.loc);
                try calls.append(arena, .{
                    .from = callHierarchyItem(document, caller),
                    .fromRanges = ranges,
                });
            }
        }
        return try calls.toOwnedSlice(arena);
    }

    pub fn @"callHierarchy/outgoingCalls"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("callHierarchy/outgoingCalls"),
    ) !lsp.ResultType("callHierarchy/outgoingCalls") {
        const document = server.documents.getConst(params.item.uri) orelse return null;
        const declaration = document.declarationNamed(params.item.name) orelse return null;
        if (declaration.kind != .function) return null;
        const tokens = try tokenize(arena, document.source);
        const body = functionBodyTokenBounds(tokens, declaration) orelse return null;
        var calls: std.ArrayList(lsp.types.call_hierarchy.OutgoingCall) = .empty;
        for (tokens[body.opening + 1 .. body.closing], body.opening + 1..) |token, index| {
            if (token.tag != .identifier or index + 1 >= body.closing or tokens[index + 1].tag != .l_paren or
                index > 0 and tokens[index - 1].tag == .period) continue;
            const callee_name = document.source[token.loc.start..token.loc.end];
            const callee = server.functionNamed(callee_name) orelse continue;
            const ranges = try arena.alloc(lsp.types.Range, 1);
            ranges[0] = document.range(token.loc);
            try calls.append(arena, .{
                .to = callHierarchyItem(callee.document, callee.declaration),
                .fromRanges = ranges,
            });
        }
        return try calls.toOwnedSlice(arena);
    }

    pub fn @"textDocument/rename"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/rename"),
    ) !lsp.ResultType("textDocument/rename") {
        if (!isIdentifier(params.newName)) return error.InvalidParams;
        const origin = server.documents.getConst(params.textDocument.uri) orelse return null;
        const identifier_span = origin.identifierAt(origin.byteOffset(params.position)) orelse return null;
        return try server.renameWorkspaceEdit(arena, origin, identifier_span, params.newName);
    }

    fn renameWorkspaceEdit(
        server: *Server,
        arena: std.mem.Allocator,
        origin: *const Document,
        identifier_span: std.zig.Token.Loc,
        new_name: []const u8,
    ) !?lsp.types.WorkspaceEdit {
        if (!isIdentifier(new_name)) return error.InvalidParams;
        const name = origin.source[identifier_span.start..identifier_span.end];
        if (origin.declarationNamed(new_name) != null) return error.RequestFailed;
        if (try origin.scopedIdentifierSpans(arena, identifier_span.start)) |spans| {
            const reflected_spans = if (try isContainerField(arena, origin.source, identifier_span))
                try reflectionStringSpans(arena, origin.source, name)
            else
                &.{};
            const edits = try arena.alloc(lsp.types.TextEdit, spans.len + reflected_spans.len);
            for (spans, edits[0..spans.len]) |span, *edit| {
                edit.* = .{ .range = origin.range(span), .newText = new_name };
            }
            for (reflected_spans, edits[spans.len..]) |span, *edit| {
                edit.* = .{ .range = origin.range(span), .newText = new_name };
            }
            var scoped_changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
            try scoped_changes.map.put(arena, origin.uri, edits);
            return .{ .changes = scoped_changes };
        }
        if (origin.declarationNamed(name) == null) return null;
        var declaration_count: usize = 0;
        var declaration_iterator = server.documents.documents.valueIterator();
        while (declaration_iterator.next()) |document| {
            if (document.declarationNamed(name) != null) declaration_count += 1;
        }
        if (declaration_count != 1) return error.RequestFailed;

        var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
        var iterator = server.documents.documents.valueIterator();
        while (iterator.next()) |document| {
            const spans = try document.identifierSpans(arena, name);
            if (spans.len == 0) continue;
            const edits = try arena.alloc(lsp.types.TextEdit, spans.len);
            for (spans, edits) |span, *edit| {
                edit.* = .{ .range = document.range(span), .newText = new_name };
            }
            try changes.map.put(arena, document.uri, edits);
        }
        return .{ .changes = changes };
    }

    pub fn @"textDocument/codeAction"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/codeAction"),
    ) !lsp.ResultType("textDocument/codeAction") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        var lint_configuration = try server.loadConfiguration(arena);
        if (action_lsp.isRequested(params.context.only, .@"source.organizeImports")) {
            lint_configuration.levels[@intFromEnum(analysis.Rule.unsorted_imports)] = .warning;
        }
        const document_findings = try server.documentFindings(arena, document, lint_configuration);
        const requested_span = std.zig.Token.Loc{
            .start = document.byteOffset(params.range.start),
            .end = document.byteOffset(params.range.end),
        };
        var actions: std.ArrayList(lsp.types.CodeAction.Result) = .empty;
        var fix_all_edits: std.ArrayList(analysis.Edit) = .empty;

        for (document_findings) |finding| {
            for (finding.fixes) |fix| {
                if (fix.fix_all) try fix_all_edits.appendSlice(arena, fix.edits);
                const kind = action_lsp.kind(fix.kind);
                if (!action_lsp.isRequested(params.context.only, kind)) continue;
                if (fix.kind != .organize_imports and fix.kind != .fix_all and
                    !spansOverlap(requested_span, finding.span)) continue;
                const diagnostics = try arena.alloc(lsp.types.Diagnostic, 1);
                diagnostics[0] = try findingDiagnostic(arena, document, finding);
                try actions.append(arena, .{ .code_action = .{
                    .title = fix.title,
                    .kind = kind,
                    .diagnostics = if (fix.kind == .organize_imports) null else diagnostics,
                    .isPreferred = fix.preferred,
                    .edit = try action_lsp.documentEdit(arena, document, fix.edits),
                } });
            }
            if (finding.rule == .unresolved_call and spansOverlap(requested_span, finding.span) and
                action_lsp.isRequested(params.context.only, .@"refactor.rewrite"))
            {
                if (try generateFunctionEdit(arena, document.source, finding.span)) |generated| {
                    try actions.append(arena, .{ .code_action = .{
                        .title = try std.fmt.allocPrint(
                            arena,
                            "Generate function '{s}'",
                            .{document.source[finding.span.start..finding.span.end]},
                        ),
                        .kind = .@"refactor.rewrite",
                        .edit = try action_lsp.documentEdit(arena, document, &.{generated}),
                    } });
                }
            }
            if ((finding.rule == .non_idiomatic_name or finding.rule == .underscore_private_name or
                finding.rule == .redundant_qualified_name) and spansOverlap(requested_span, finding.span) and
                action_lsp.isRequested(params.context.only, .@"refactor.rewrite"))
            {
                if (try suggestedStyleName(arena, document.source, finding.span, finding.rule)) |new_name| {
                    if (server.renameWorkspaceEdit(arena, document, finding.span, new_name)) |maybe_edit| {
                        if (maybe_edit) |edit| {
                            try actions.append(arena, .{ .code_action = .{
                                .title = try std.fmt.allocPrint(
                                    arena,
                                    "Rename '{s}' to '{s}'",
                                    .{ document.source[finding.span.start..finding.span.end], new_name },
                                ),
                                .kind = .@"refactor.rewrite",
                                .isPreferred = false,
                                .edit = edit,
                            } });
                        }
                    } else |err| switch (err) {
                        error.RequestFailed => {},
                        else => return err,
                    }
                }
            }
            if (spansOverlap(requested_span, finding.span) and action_lsp.isRequested(params.context.only, .quickfix)) {
                switch (finding.rule) {
                    .unreleased_allocation => if (try allocationCleanupEdit(arena, document.source, finding.span)) |cleanup| {
                        try actions.append(arena, .{ .code_action = .{
                            .title = cleanup.title,
                            .kind = .quickfix,
                            .isPreferred = false,
                            .edit = try action_lsp.documentEdit(arena, document, &.{cleanup.edit}),
                        } });
                    },
                    .cleanup_after_fallible_operation => if (try moveCleanupAfterAcquisition(arena, document.source, finding.span)) |cleanup| {
                        try actions.append(arena, .{ .code_action = .{
                            .title = "Move cleanup directly after acquisition",
                            .kind = .quickfix,
                            .isPreferred = true,
                            .edit = try action_lsp.documentEdit(arena, document, cleanup),
                        } });
                    },
                    else => {},
                }
            }
        }

        const resolved_shapes = try server.compilerTypeShapes(arena, document);
        const native_actions = try zig_actions.actions(arena, document.source, requested_span, resolved_shapes);
        for (native_actions) |native_action| {
            const kind = action_lsp.kind(native_action.kind);
            if (!action_lsp.isRequested(params.context.only, kind)) continue;
            try actions.append(arena, .{ .code_action = .{
                .title = native_action.title,
                .kind = kind,
                .isPreferred = native_action.preferred,
                .edit = try action_lsp.documentEdit(arena, document, native_action.edits),
            } });
        }

        var open_documents: std.ArrayList(project_actions.OpenDocument) = .empty;
        var document_iterator = server.documents.documents.valueIterator();
        while (document_iterator.next()) |open_document| {
            try open_documents.append(arena, .{ .uri = open_document.uri, .source = open_document.source });
        }
        const workspace_actions = try project_actions.actions(
            arena,
            document.uri,
            document.source,
            requested_span,
            open_documents.items,
        );
        for (workspace_actions) |workspace_action| {
            const kind = action_lsp.kind(workspace_action.kind);
            if (!action_lsp.isRequested(params.context.only, kind)) continue;
            if (workspace_action.created_file != null and
                (!server.workspace_document_changes or !server.workspace_create_file)) continue;
            try actions.append(arena, .{ .code_action = .{
                .title = workspace_action.title,
                .kind = kind,
                .isPreferred = false,
                .edit = try action_lsp.projectEdit(arena, &server.documents, workspace_action),
            } });
        }

        if (action_lsp.isRequested(params.context.only, .@"refactor.extract")) {
            if (try extractExpressionEdits(arena, document, requested_span)) |extraction| {
                try actions.append(arena, .{ .code_action = .{
                    .title = try std.fmt.allocPrint(arena, "Extract into const '{s}'", .{extraction.name}),
                    .kind = .@"refactor.extract",
                    .isPreferred = true,
                    .edit = try action_lsp.documentEdit(arena, document, &.{ extraction.declaration, extraction.replacement }),
                } });
            }
        }

        if (action_lsp.isRequested(params.context.only, .@"source.fixAll")) {
            const safe_edits = try nonOverlappingEdits(arena, fix_all_edits.items);
            if (safe_edits.len != 0) {
                try actions.append(arena, .{ .code_action = .{
                    .title = "Fix all safe zig-analyzer findings",
                    .kind = .@"source.fixAll",
                    .edit = try action_lsp.documentEdit(arena, document, safe_edits),
                } });
            }
        }
        return try actions.toOwnedSlice(arena);
    }

    pub fn @"textDocument/formatting"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/formatting"),
    ) !lsp.ResultType("textDocument/formatting") {
        const document = server.documents.getConst(params.textDocument.uri) orelse return null;
        const formatted = try formatSource(server.io, arena, document.source);
        if (std.mem.eql(u8, formatted, document.source)) return &.{};
        const edits = try arena.alloc(lsp.types.TextEdit, 1);
        edits[0] = .{
            .range = document.range(.{ .start = 0, .end = document.source.len }),
            .newText = formatted,
        };
        return edits;
    }

    fn publishDiagnostics(server: *Server, arena: std.mem.Allocator, uri: []const u8) !void {
        const document = server.documents.getConst(uri) orelse return error.DocumentNotOpen;
        var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;
        try diagnostics.appendSlice(arena, try syntaxDiagnostics(document, arena));
        const lint_configuration = try server.loadConfiguration(arena);
        if (lint_configuration.warning) |warning| {
            try diagnostics.append(arena, .{
                .range = document.range(.{ .start = 0, .end = @min(document.source.len, 1) }),
                .severity = .Warning,
                .code = .{ .string = "invalid-configuration" },
                .source = "zig-analyzer configuration",
                .message = warning,
            });
        }
        if (try analysis.suppressionWarning(arena, document.source)) |warning| {
            try diagnostics.append(arena, .{
                .range = document.range(.{ .start = 0, .end = @min(document.source.len, 1) }),
                .severity = .Warning,
                .code = .{ .string = "invalid-configuration" },
                .source = "zig-analyzer configuration",
                .message = warning,
            });
        }
        const document_findings = try server.documentFindings(arena, document, lint_configuration);
        for (document_findings) |finding| try diagnostics.append(arena, try findingDiagnostic(arena, document, finding));
        if (server.compilerAnalysisCurrent(document)) {
            if (server.compiler) |*compiler| {
                var bundle = compiler.diagnostics(arena) catch |err| {
                    server.recordCompilerFailure(err);
                    const diagnostic_count = deduplicateAndSortDiagnostics(diagnostics.items);
                    return server.publishDiagnosticSlice(arena, document, diagnostics.items[0..diagnostic_count]);
                };
                defer bundle.deinit(arena);
                try diagnostics.appendSlice(arena, try compilerDiagnostics(document, bundle, arena));
            }
        }
        const diagnostic_count = deduplicateAndSortDiagnostics(diagnostics.items);
        try server.publishDiagnosticSlice(arena, document, diagnostics.items[0..diagnostic_count]);
    }

    fn loadConfiguration(server: *Server, allocator: std.mem.Allocator) !analysis.Configuration {
        const source = std.Io.Dir.cwd().readFileAlloc(
            server.io,
            "zig-analyzer.json",
            allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return analysis.Configuration.defaults(),
            else => {
                var lint_configuration = analysis.Configuration.defaults();
                lint_configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "could not read zig-analyzer.json: {t}",
                    .{err},
                );
                return lint_configuration;
            },
        };
        return try analysis.parseConfiguration(allocator, source);
    }

    fn publishDiagnosticSlice(
        server: *Server,
        arena: std.mem.Allocator,
        document: *const Document,
        diagnostics: []const lsp.types.Diagnostic,
    ) !void {
        try server.transport.writeNotification(
            server.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{
                .uri = document.uri,
                .version = document.version,
                .diagnostics = diagnostics,
            },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn ensureCompiler(server: *Server, allocator: std.mem.Allocator, uri: []const u8) !void {
        if (server.compiler != null or server.compiler_start_attempted) return;
        server.compiler_start_attempted = true;
        if (server.documents.getConst(uri) == null) return;
        if (!try pathExists(server.io, backend_bootstrap.backend_binary)) return;
        const document_path = try filePathFromUri(allocator, uri) orelse return;
        if (!try pathExists(server.io, document_path)) return;
        const root_source_path = try compile_units.rootSourceForDocument(server.io, allocator, document_path);
        server.compiler = compiler_session.Session.start(
            server.io,
            server.allocator,
            server.environ,
            root_source_path,
        ) catch |err| {
            std.log.err("compiler backend failed to start for '{s}': {t}", .{ root_source_path, err });
            return;
        };
    }

    fn syncCompilerOverlay(server: *Server, uri: []const u8) !void {
        const document = server.documents.getConst(uri) orelse return;
        const compiler = if (server.compiler) |*active| active else return;
        _ = compiler.replaceOverlay(uri, document.version, document.source) catch |err| switch (err) {
            error.SemanticsUnavailable => {
                if (server.compiler_root_uri) |previous_uri| {
                    if (std.mem.eql(u8, previous_uri, uri)) {
                        server.allocator.free(previous_uri);
                        server.compiler_root_uri = null;
                    }
                }
                return;
            },
            else => {
                server.recordCompilerFailure(err);
                return;
            },
        };
        if (server.compiler_root_uri) |previous_uri| server.allocator.free(previous_uri);
        server.compiler_root_uri = try server.allocator.dupe(u8, uri);
        server.compiler_root_version = document.version;
    }

    fn recordCompilerFailure(server: *Server, err: anyerror) void {
        std.log.err("compiler backend request failed: {t}; syntax service remains active", .{err});
        if (server.compiler) |*compiler| compiler.deinit();
        server.compiler = null;
        if (server.compiler_root_uri) |uri| server.allocator.free(uri);
        server.compiler_root_uri = null;
    }

    fn compilerAnalysisCurrent(server: *const Server, document: *const Document) bool {
        const root_uri = server.compiler_root_uri orelse return false;
        return std.mem.eql(u8, root_uri, document.uri) and server.compiler_root_version == document.version;
    }

    fn syntaxMembers(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
    ) ![]const SyntaxMember {
        if (try server.moduleView(allocator, document, receiver)) |view| return view.members;
        const receiver_name = std.mem.lastIndexOfScalar(u8, receiver, '.') orelse 0;
        const name = if (receiver_name == 0) receiver else receiver[receiver_name + 1 ..];
        const type_name = try declaredTypeName(allocator, document.source, name);
        return try structMembers(allocator, document.source, type_name orelse return &.{});
    }

    fn importedDefinition(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
        name: []const u8,
    ) !?lsp.types.Location {
        const view = try server.moduleView(allocator, document, receiver) orelse return null;
        for (view.members) |member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            return .{
                .uri = try std.fmt.allocPrint(allocator, "file://{s}", .{view.path}),
                .range = lsp.offsets.locToRange(view.source, member.span, .@"utf-16"),
            };
        }
        return null;
    }

    fn importedFileDefinition(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        byte_offset: usize,
    ) !?lsp.types.Location {
        const import_path = try importPathAt(allocator, document.source, byte_offset) orelse return null;
        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        const path = try server.importedNeighborPath(allocator, document_path, import_path) orelse return null;
        const source = try server.importedSource(allocator, path) orelse return null;
        return try sourceStartLocation(allocator, source);
    }

    fn importAliasDefinition(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        alias: []const u8,
    ) !?lsp.types.Location {
        const import_path = try importName(allocator, document.source, alias) orelse return null;
        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        const path = try server.importedNeighborPath(allocator, document_path, import_path) orelse return null;
        const source = try server.importedSource(allocator, path) orelse return null;
        return try sourceStartLocation(allocator, source);
    }

    fn aliasTargetDefinition(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        identifier_span: std.zig.Token.Loc,
    ) !?lsp.types.Location {
        const binding_spans = try document.scopedIdentifierSpans(allocator, identifier_span.start) orelse return null;
        if (binding_spans.len == 0 or std.meta.eql(binding_spans[0], identifier_span)) return null;
        const tokens = try tokenize(allocator, document.source);
        const binding_index = for (tokens, 0..) |token, index| {
            if (std.meta.eql(token.loc, binding_spans[0])) break index;
        } else return null;
        if (binding_index == 0 or tokens[binding_index - 1].tag != .keyword_const) return null;

        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        var file = ImportedSource{
            .path = document_path,
            .source = document.source,
            .tokens = tokens,
        };
        var container = TokenRange{ .start = 0, .end = tokens.len };
        var pending: std.ArrayList([]const u8) = .empty;
        const initial_target = try constantTarget(
            allocator,
            document.source,
            tokens,
            binding_index,
        ) orelse return null;
        switch (initial_target) {
            .container => return null,
            .alias_path => |path_text| {
                const segments = try dottedPathSegments(allocator, path_text) orelse return null;
                try pending.appendSlice(allocator, segments);
            },
            .imported_file => |imported| {
                const path = try server.importedNeighborPath(allocator, file.path, imported.file) orelse return null;
                file = try server.importedSource(allocator, path) orelse return null;
                container = .{ .start = 0, .end = file.tokens.len };
                if (imported.members.len == 0) return try sourceStartLocation(allocator, file);
                try pending.appendSlice(allocator, imported.members);
            },
        }

        var last_location: ?lsp.types.Location = null;
        var hops: usize = 0;
        while (pending.items.len != 0) : (hops += 1) {
            if (hops == 32) return last_location;
            const target_name = pending.orderedRemove(0);
            const declaration = containerDeclarationNamed(
                file.source,
                file.tokens,
                container,
                target_name,
            ) orelse return last_location;
            last_location = try sourceLocation(allocator, file, file.tokens[declaration.name_index].loc);
            const descent = switch (declaration.kind) {
                .field => return last_location,
                .function => if (pending.items.len == 0)
                    return last_location
                else
                    typeFunctionResult(file.source, file.tokens, declaration.name_index) orelse return last_location,
                .constant => try constantTarget(
                    allocator,
                    file.source,
                    file.tokens,
                    declaration.name_index,
                ) orelse return last_location,
            };
            switch (descent) {
                .container => |range| {
                    if (pending.items.len == 0) return last_location;
                    container = range;
                },
                .alias_path => |path_text| {
                    const segments = try dottedPathSegments(allocator, path_text) orelse return last_location;
                    try pending.insertSlice(allocator, 0, segments);
                    container = .{ .start = 0, .end = file.tokens.len };
                },
                .imported_file => |imported| {
                    try pending.insertSlice(allocator, 0, imported.members);
                    const path = try server.importedNeighborPath(allocator, file.path, imported.file) orelse return last_location;
                    file = try server.importedSource(allocator, path) orelse return last_location;
                    container = .{ .start = 0, .end = file.tokens.len };
                    if (pending.items.len == 0) return try sourceStartLocation(allocator, file);
                },
            }
        }
        return last_location;
    }

    fn importExpressionMemberDefinition(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        identifier_span: std.zig.Token.Loc,
    ) !?lsp.types.Location {
        const tokens = try tokenize(allocator, document.source);
        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        for (tokens, 0..) |token, import_index| {
            if (token.tag != .builtin or import_index + 5 >= tokens.len or
                !std.mem.eql(u8, document.source[token.loc.start..token.loc.end], "@import") or
                tokens[import_index + 1].tag != .l_paren or
                tokens[import_index + 2].tag != .string_literal or
                tokens[import_index + 3].tag != .r_paren)
            {
                continue;
            }
            var preceding_members: std.ArrayList([]const u8) = .empty;
            var member_index = import_index + 4;
            while (member_index + 1 < tokens.len and
                tokens[member_index].tag == .period and
                tokens[member_index + 1].tag == .identifier) : (member_index += 2)
            {
                const member_token = tokens[member_index + 1];
                if (std.meta.eql(member_token.loc, identifier_span)) {
                    const literal = document.source[tokens[import_index + 2].loc.start..tokens[import_index + 2].loc.end];
                    if (literal.len < 2) return null;
                    const path = try server.importedNeighborPath(
                        allocator,
                        document_path,
                        literal[1 .. literal.len - 1],
                    ) orelse return null;
                    const imported = try server.importedSource(allocator, path) orelse return null;
                    var site = ResolvedTypeSite{
                        .file = imported,
                        .container = .{ .start = 0, .end = imported.tokens.len },
                    };
                    if (preceding_members.items.len != 0) {
                        var pending: std.ArrayList([]const u8) = .empty;
                        try pending.appendSlice(allocator, preceding_members.items);
                        site = try server.descendPendingSegments(allocator, imported, &pending) orelse return null;
                    }
                    const member_name = document.source[member_token.loc.start..member_token.loc.end];
                    const declaration = containerDeclarationNamed(
                        site.file.source,
                        site.file.tokens,
                        site.container,
                        member_name,
                    ) orelse return null;
                    return try sourceLocation(
                        allocator,
                        site.file,
                        site.file.tokens[declaration.name_index].loc,
                    );
                }
                try preceding_members.append(
                    allocator,
                    document.source[member_token.loc.start..member_token.loc.end],
                );
            }
        }
        return null;
    }

    fn hoverDescription(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        identifier_span: std.zig.Token.Loc,
    ) !?hover.Content {
        const name = document.source[identifier_span.start..identifier_span.end];
        if (try server.resolvedShapeForName(allocator, document, name)) |shape| {
            if (try server.importDeclarationHover(allocator, document, identifier_span, name)) |origin| {
                if (shape.fields.len == 0) return .{
                    .declaration = origin.declaration,
                    .type_summary = "compiler-resolved comptime type",
                    .documentation = origin.documentation,
                };
                return .{
                    .declaration = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{
                        origin.declaration,
                        try renderResolvedShape(allocator, name, shape),
                    }),
                    .type_summary = "compiler-resolved comptime type",
                    .documentation = origin.documentation,
                };
            }
            return .{
                .declaration = try renderResolvedShape(allocator, name, shape),
                .type_summary = "compiler-resolved comptime type",
            };
        }
        if (try server.standardLibraryMemberHover(allocator, document, identifier_span.start, name)) |description| {
            return description;
        }
        if (try server.memberChainHover(allocator, document, identifier_span, name)) |description| {
            return description;
        }
        if (memberReceiver(document.source, identifier_span.start)) |receiver| {
            if (try server.moduleView(allocator, document, receiver)) |view| {
                for (view.members) |member| {
                    if (!std.mem.eql(u8, member.name, name)) continue;
                    return try describeBinding(allocator, view.source, member.span);
                }
            }
            const receiver_separator = std.mem.lastIndexOfScalar(u8, receiver, '.') orelse 0;
            const receiver_name = if (receiver_separator == 0) receiver else receiver[receiver_separator + 1 ..];
            const type_name = try declaredTypeName(allocator, document.source, receiver_name);
            if (type_name) |resolved_type| {
                const members = try structMembers(allocator, document.source, resolved_type);
                for (members) |member| {
                    if (!std.mem.eql(u8, member.name, name)) continue;
                    return try describeBinding(allocator, document.source, member.span);
                }
            }
            if (try server.inferredMemberHover(allocator, document, identifier_span, name)) |description| {
                return description;
            }
            if (std.mem.eql(u8, name, "len")) {
                return .{ .declaration = "len: usize", .type_summary = "usize" };
            }
            if (try describeTypedMemberNamed(allocator, document.source, name)) |description| return description;
            if (server.compiler_root_uri) |root_uri| {
                if (std.mem.eql(u8, root_uri, document.uri) and !server.compilerAnalysisCurrent(document)) return null;
            }
            if (try server.compilerTypeMembers(allocator, document, receiver)) |member_names| {
                for (member_names) |member_name| {
                    if (!std.mem.eql(u8, member_name, name)) continue;
                    if (document.declarationNamed(name)) |declaration| {
                        return try describeBinding(allocator, document.source, declaration.span);
                    }
                    return try describeTypedMemberNamed(allocator, document.source, name);
                }
                return null;
            }
        }
        if (try document.scopedIdentifierSpans(allocator, identifier_span.start)) |spans| {
            if (spans.len != 0) {
                if (try describeBinding(allocator, document.source, spans[0])) |binding| {
                    var description = binding;
                    if (description.type_summary == null) {
                        description.type_summary = try syntax_types.inferredBindingType(
                            allocator,
                            document.source,
                            spans[0],
                        );
                    }
                    return description;
                }
            }
        }
        if (document.declarationNamed(name)) |declaration| {
            return try describeBinding(allocator, document.source, declaration.span);
        }
        if (try describeTypedMemberNamed(allocator, document.source, name)) |description| return description;
        return try describeEnumTagNamed(allocator, document.source, name);
    }

    fn inferredMemberHover(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        member_span: std.zig.Token.Loc,
        member_name: []const u8,
    ) !?hover.Content {
        const receiver_span = receiverIdentifierSpan(document.source, member_span.start) orelse return null;
        const receiver_bindings = try document.scopedIdentifierSpans(allocator, receiver_span.start) orelse return null;
        if (receiver_bindings.len == 0) return null;
        const inferred_type = try bindingTypeExpression(allocator, document, receiver_bindings[0]) orelse return null;
        if (try server.importedTypeMemberHover(allocator, document, inferred_type, member_name)) |description| {
            return description;
        }
        const type_name = namedTypeExpression(inferred_type) orelse return null;
        if (std.mem.indexOfScalar(u8, type_name, '.')) |separator| {
            const import_alias = type_name[0..separator];
            if (try server.moduleView(allocator, document, import_alias)) |view| {
                const field_span = try syntax_types.memberSpan(
                    allocator,
                    view.source,
                    type_name[separator + 1 ..],
                    member_name,
                ) orelse return null;
                return try describeBinding(allocator, view.source, field_span);
            }
        }
        const field_span = try syntax_types.memberSpan(
            allocator,
            document.source,
            type_name,
            member_name,
        ) orelse return null;
        return try describeBinding(allocator, document.source, field_span);
    }

    fn standardLibraryMemberHover(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        identifier_start: usize,
        name: []const u8,
    ) !?hover.Content {
        const import_prefix = "@import(\"std\").";
        const prefix_start = std.mem.lastIndexOf(u8, document.source[0..identifier_start], import_prefix) orelse return null;
        const module_expression = document.source[prefix_start + import_prefix.len .. identifier_start];
        if (module_expression.len != 0 and module_expression[module_expression.len - 1] != '.') return null;
        const module_name = if (module_expression.len == 0) "" else module_expression[0 .. module_expression.len - 1];
        if (module_name.len != 0 and !isDottedIdentifier(module_name)) return null;
        const path = if (module_name.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/std/std.zig", .{try server.zigLibDirectory()})
        else path: {
            const relative_path = try std.mem.replaceOwned(u8, allocator, module_name, ".", std.fs.path.sep_str);
            break :path try std.fmt.allocPrint(allocator, "{s}/std/{s}.zig", .{
                try server.zigLibDirectory(),
                relative_path,
            });
        };
        const source = std.Io.Dir.cwd().readFileAlloc(
            server.io,
            path,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const members = try publicModuleMembers(allocator, source);
        for (members) |member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            return try describeBinding(allocator, source, member.span);
        }
        return null;
    }

    fn importDeclarationHover(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        identifier_span: std.zig.Token.Loc,
        name: []const u8,
    ) !?hover.Content {
        if (document.declarationNamed(name)) |declaration| {
            if (try describeBinding(allocator, document.source, declaration.span)) |description| {
                if (std.mem.indexOf(u8, description.declaration, "@import") != null) return description;
            }
        }
        const receiver = memberReceiver(document.source, identifier_span.start) orelse return null;
        const view = try server.moduleView(allocator, document, receiver) orelse return null;
        for (view.members) |member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            const description = try describeBinding(allocator, view.source, member.span) orelse return null;
            if (std.mem.indexOf(u8, description.declaration, "@import") == null) return null;
            return description;
        }
        return null;
    }

    fn importedTypeMemberHover(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        type_expression: []const u8,
        member_name: []const u8,
    ) !?hover.Content {
        const site = try server.resolveImportedTypeSite(allocator, document, type_expression) orelse return null;
        return try siteMemberDescription(allocator, site, member_name);
    }

    fn resolveImportedTypeSite(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        type_expression: []const u8,
    ) !?ResolvedTypeSite {
        const segments = try dottedPathSegments(allocator, bareTypeExpression(type_expression)) orelse return null;
        if (segments.len < 2) return null;
        const initial_path = try server.modulePath(allocator, document, segments[0]) orelse return null;
        const file = try server.importedSource(allocator, initial_path) orelse return null;
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments[1..]);
        return try server.descendPendingSegments(allocator, file, &pending);
    }

    fn resolveDocumentSite(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        expression: []const u8,
    ) !?ResolvedTypeSite {
        const segments = try dottedPathSegments(allocator, bareTypeExpression(expression)) orelse return null;
        if (segments.len == 0) return null;
        const path = try filePathFromUri(allocator, document.uri) orelse return null;
        const file = ImportedSource{
            .path = path,
            .source = document.source,
            .tokens = try tokenize(allocator, document.source),
        };
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments);
        return try server.descendPendingSegments(allocator, file, &pending);
    }

    fn resolveTypeSiteWithin(
        server: *Server,
        allocator: std.mem.Allocator,
        file: ImportedSource,
        type_expression: []const u8,
    ) !?ResolvedTypeSite {
        const segments = try dottedPathSegments(allocator, bareTypeExpression(type_expression)) orelse return null;
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.appendSlice(allocator, segments);
        return try server.descendPendingSegments(allocator, file, &pending);
    }

    fn descendPendingSegments(
        server: *Server,
        allocator: std.mem.Allocator,
        start_file: ImportedSource,
        pending: *std.ArrayList([]const u8),
    ) !?ResolvedTypeSite {
        var file = start_file;
        var container = TokenRange{ .start = 0, .end = file.tokens.len };
        var hops: usize = 0;
        while (pending.items.len != 0) : (hops += 1) {
            if (hops == 32) return null;
            const target_name = pending.orderedRemove(0);
            const declaration = containerDeclarationNamed(file.source, file.tokens, container, target_name) orelse return null;
            const descent = switch (declaration.kind) {
                .field => return null,
                .function => typeFunctionResult(file.source, file.tokens, declaration.name_index) orelse return null,
                .constant => try constantTarget(allocator, file.source, file.tokens, declaration.name_index) orelse return null,
            };
            switch (descent) {
                .container => |range| container = range,
                .alias_path => |path_text| {
                    const alias_segments = try dottedPathSegments(allocator, path_text) orelse return null;
                    try pending.insertSlice(allocator, 0, alias_segments);
                    container = .{ .start = 0, .end = file.tokens.len };
                },
                .imported_file => |imported| {
                    try pending.insertSlice(allocator, 0, imported.members);
                    const path = try server.importedNeighborPath(allocator, file.path, imported.file) orelse return null;
                    file = try server.importedSource(allocator, path) orelse return null;
                    container = .{ .start = 0, .end = file.tokens.len };
                },
            }
        }
        return .{ .file = file, .container = container };
    }

    fn memberChainHover(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        member_span: std.zig.Token.Loc,
        member_name: []const u8,
    ) !?hover.Content {
        const receiver = qualifiedCallReceiver(document.source, member_span.start) orelse return null;
        const links = try dottedPathSegments(allocator, receiver.expression) orelse return null;
        if (links.len == 0) return null;
        if (try importName(allocator, document.source, links[0]) != null) {
            // The receiver spells a constructed type, as in `std.ArrayList(u8).empty`.
            return try server.importedTypeMemberHover(allocator, document, receiver.expression, member_name);
        }
        // The receiver is a value chain, as in `arena.allocator().dupe`; follow
        // each link's declared result type to the container that owns the member.
        const bindings = try document.scopedIdentifierSpans(allocator, receiver.start) orelse return null;
        if (bindings.len == 0) return null;
        const base_type = try bindingTypeExpression(allocator, document, bindings[0]) orelse return null;
        var site = try server.resolveImportedTypeSite(allocator, document, base_type) orelse return null;
        for (links[1..]) |link| {
            const declaration = containerDeclarationNamed(site.file.source, site.file.tokens, site.container, link) orelse return null;
            const result_type = switch (declaration.kind) {
                .function => functionReturnTypeText(site.file.source, site.file.tokens, declaration.name_index),
                .field, .constant => typed: {
                    const binding = try describeBinding(
                        allocator,
                        site.file.source,
                        site.file.tokens[declaration.name_index].loc,
                    ) orelse break :typed null;
                    break :typed binding.type_summary;
                },
            } orelse return null;
            site = try server.resolveTypeSiteWithin(allocator, site.file, result_type) orelse return null;
        }
        return try siteMemberDescription(allocator, site, member_name);
    }

    fn bindingTypeExpression(
        allocator: std.mem.Allocator,
        document: *const Document,
        binding_span: std.zig.Token.Loc,
    ) !?[]const u8 {
        if (try syntax_types.inferredBindingType(allocator, document.source, binding_span)) |inferred| return inferred;
        if (try syntax_types.initializerTypeExpression(allocator, document.source, binding_span)) |constructed| return constructed;
        const binding = try describeBinding(allocator, document.source, binding_span) orelse return null;
        return binding.type_summary;
    }

    fn importedSource(server: *Server, allocator: std.mem.Allocator, path: []const u8) !?ImportedSource {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            server.io,
            path,
            allocator,
            .limited(16 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const source = try allocator.dupeZ(u8, bytes);
        return .{ .path = path, .source = source, .tokens = try tokenize(allocator, source) };
    }

    fn importedNeighborPath(
        server: *Server,
        allocator: std.mem.Allocator,
        current_path: []const u8,
        import_string: []const u8,
    ) !?[]const u8 {
        if (std.mem.eql(u8, import_string, "std")) {
            return try std.fmt.allocPrint(allocator, "{s}/std/std.zig", .{try server.zigLibDirectory()});
        }
        if (!std.mem.endsWith(u8, import_string, ".zig")) {
            return try compile_units.namedModuleSourceForDocument(
                server.io,
                allocator,
                current_path,
                import_string,
            );
        }
        const directory = std.fs.path.dirname(current_path) orelse return null;
        return try std.fs.path.resolve(allocator, &.{ directory, import_string });
    }

    fn compilerTypeMembers(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
    ) !?[]const []const u8 {
        const compiler = if (server.compiler) |*active| active else return null;
        const separator = std.mem.lastIndexOfScalar(u8, receiver, '.') orelse 0;
        const receiver_name = if (separator == 0) receiver else receiver[separator + 1 ..];
        const type_name = try declaredTypeName(allocator, document.source, receiver_name) orelse receiver_name;
        const declarations = compiler.workspaceDeclarations(allocator) catch |err| {
            server.recordCompilerFailure(err);
            return null;
        };
        const qualified_type_name = for (declarations) |declaration_name| {
            if (declaration_name.len <= type_name.len or !std.mem.endsWith(u8, declaration_name, type_name)) continue;
            if (declaration_name[declaration_name.len - type_name.len - 1] == '.') break declaration_name;
        } else type_name;
        return compiler.typeMembers(allocator, qualified_type_name) catch |err| switch (err) {
            error.SemanticsUnavailable => null,
            else => {
                server.recordCompilerFailure(err);
                return null;
            },
        };
    }

    fn functionNamed(server: *Server, name: []const u8) ?FunctionLocation {
        var selected: ?FunctionLocation = null;
        var iterator = server.documents.documents.valueIterator();
        while (iterator.next()) |document| {
            const declaration = document.declarationNamed(name) orelse continue;
            if (declaration.kind != .function) continue;
            if (selected != null) return null;
            selected = .{ .document = document, .declaration = declaration };
        }
        return selected;
    }

    fn resolvedShapeForName(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        type_name: []const u8,
    ) !?analysis.ResolvedShape {
        if (!server.compilerAnalysisCurrent(document)) return null;
        const compiler = if (server.compiler) |*active| active else return null;
        const declarations = compiler.workspaceDeclarations(allocator) catch |err| {
            server.recordCompilerFailure(err);
            return null;
        };
        const qualified_name = for (declarations) |declaration| {
            if (std.mem.eql(u8, declaration, type_name)) break declaration;
            if (declaration.len <= type_name.len or !std.mem.endsWith(u8, declaration, type_name)) continue;
            if (declaration[declaration.len - type_name.len - 1] == '.') break declaration;
        } else return null;
        const shape = compiler.typeShape(allocator, qualified_name) catch |err| switch (err) {
            error.SemanticsUnavailable => return null,
            else => {
                server.recordCompilerFailure(err);
                return null;
            },
        };
        return .{
            .type_name = type_name,
            .kind = switch (shape.kind) {
                .enumeration => .enumeration,
                .tagged_union => .tagged_union,
                .structure => .structure,
                _ => return null,
            },
            .fields = shape.fields,
        };
    }

    fn documentFindings(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        lint_configuration: analysis.Configuration,
    ) ![]analysis.Finding {
        const resolved_shapes = try server.compilerTypeShapes(allocator, document);
        var document_findings: std.ArrayList(analysis.Finding) = .empty;
        try document_findings.appendSlice(
            allocator,
            try analysis.findingsWithShapes(allocator, document.source, lint_configuration, resolved_shapes),
        );
        try document_findings.appendSlice(
            allocator,
            try server.moduleMemberFindings(allocator, document, lint_configuration),
        );
        if (try analysis.fileNameFinding(allocator, document.source, document.uri, lint_configuration)) |finding| {
            try document_findings.append(allocator, finding);
        }
        return try document_findings.toOwnedSlice(allocator);
    }

    fn moduleMemberFindings(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        configuration: analysis.Configuration,
    ) ![]const analysis.Finding {
        const level = configuration.level(.unresolved_member);
        if (level == .off) return &.{};
        const tokens = try tokenize(allocator, document.source);
        var candidate_receivers: std.StringHashMapUnmanaged(void) = .empty;
        for (document.declarations) |declaration| {
            if (declaration.brace_depth != 0 or declaration.kind != .constant) continue;
            try candidate_receivers.put(allocator, declaration.name, {});
        }
        var resolved_views: std.StringHashMapUnmanaged(?ModuleView) = .empty;
        var findings: std.ArrayList(analysis.Finding) = .empty;
        for (tokens, 0..) |member_token, member_index| {
            if (member_token.tag != .identifier or member_index < 2 or
                tokens[member_index - 1].tag != .period or tokens[member_index - 2].tag != .identifier) continue;
            if (member_index >= 3 and tokens[member_index - 3].tag == .period) continue;
            const receiver = document.source[tokens[member_index - 2].loc.start..tokens[member_index - 2].loc.end];
            if (!candidate_receivers.contains(receiver)) continue;
            const view_entry = try resolved_views.getOrPut(allocator, receiver);
            if (!view_entry.found_existing) {
                view_entry.value_ptr.* = try server.moduleView(allocator, document, receiver);
            }
            const view = view_entry.value_ptr.* orelse continue;
            const member_name = document.source[member_token.loc.start..member_token.loc.end];
            var exists = false;
            for (view.members) |member| {
                if (!std.mem.eql(u8, member.name, member_name)) continue;
                exists = true;
                break;
            }
            if (exists or analysis.isSuppressed(document.source, .unresolved_member, member_token.loc.start)) continue;
            try findings.append(allocator, .{
                .rule = .unresolved_member,
                .level = level,
                .span = member_token.loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "module '{s}' has no public member named '{s}'",
                    .{ receiver, member_name },
                ),
            });
        }
        return try findings.toOwnedSlice(allocator);
    }

    fn compilerTypeShapes(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
    ) ![]const analysis.ResolvedShape {
        if (!server.compilerAnalysisCurrent(document)) return &.{};
        const compiler = if (server.compiler) |*active| active else return &.{};
        const declarations = compiler.workspaceDeclarations(allocator) catch |err| {
            server.recordCompilerFailure(err);
            return &.{};
        };
        const tokens = try tokenize(allocator, document.source);
        var candidate_names: std.StringHashMapUnmanaged(void) = .empty;
        var shapes: std.ArrayList(analysis.ResolvedShape) = .empty;
        for (tokens, 0..) |token, index| {
            if (token.tag != .identifier) continue;
            var follows_colon = index > 0 and tokens[index - 1].tag == .colon;
            if (!follows_colon and index > 1 and tokens[index - 1].tag == .period) {
                var type_start = index - 1;
                while (type_start > 1 and tokens[type_start - 1].tag == .identifier and
                    tokens[type_start - 2].tag == .period)
                {
                    type_start -= 2;
                }
                follows_colon = type_start > 1 and tokens[type_start - 1].tag == .identifier and
                    tokens[type_start - 2].tag == .colon;
            }
            const opens_initializer = index + 1 < tokens.len and tokens[index + 1].tag == .l_brace;
            const reflected_type = index >= 2 and tokens[index - 1].tag == .l_paren and
                tokens[index - 2].tag == .builtin and
                (std.mem.eql(u8, document.source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "@hasField") or
                    std.mem.eql(u8, document.source[tokens[index - 2].loc.start..tokens[index - 2].loc.end], "@hasDecl"));
            if (!follows_colon and !opens_initializer and !reflected_type) continue;
            const type_name = document.source[token.loc.start..token.loc.end];
            if (candidate_names.contains(type_name)) continue;
            try candidate_names.put(allocator, type_name, {});
            const qualified_name = for (declarations) |declaration| {
                if (std.mem.eql(u8, declaration, type_name)) break declaration;
                if (declaration.len <= type_name.len or !std.mem.endsWith(u8, declaration, type_name)) continue;
                if (declaration[declaration.len - type_name.len - 1] == '.') break declaration;
            } else continue;
            const shape = compiler.typeShape(allocator, qualified_name) catch |err| switch (err) {
                error.SemanticsUnavailable => continue,
                else => {
                    server.recordCompilerFailure(err);
                    return try shapes.toOwnedSlice(allocator);
                },
            };
            try shapes.append(allocator, .{
                .type_name = type_name,
                .kind = switch (shape.kind) {
                    .enumeration => .enumeration,
                    .tagged_union => .tagged_union,
                    .structure => .structure,
                    _ => continue,
                },
                .fields = shape.fields,
            });
        }
        return try shapes.toOwnedSlice(allocator);
    }

    fn moduleView(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
    ) !?ModuleView {
        const site = try server.resolveDocumentSite(allocator, document, receiver) orelse return null;
        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        return .{
            .path = site.file.path,
            .source = site.file.source,
            .members = try siteMembers(
                allocator,
                site,
                std.mem.eql(u8, document_path, site.file.path),
            ),
        };
    }

    fn modulePath(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
    ) !?[]const u8 {
        const separator = std.mem.indexOfScalar(u8, receiver, '.');
        const alias = if (separator) |index| receiver[0..index] else receiver;
        const import_name = (try importName(allocator, document.source, alias)) orelse return null;
        if (std.mem.eql(u8, import_name, "std")) {
            const module_name = if (separator) |index| receiver[index + 1 ..] else {
                return try std.fmt.allocPrint(allocator, "{s}/std/std.zig", .{try server.zigLibDirectory()});
            };
            if (!isDottedIdentifier(module_name)) return null;
            const relative_path = try std.mem.replaceOwned(u8, allocator, module_name, ".", std.fs.path.sep_str);
            return try std.fmt.allocPrint(allocator, "{s}/std/{s}.zig", .{
                try server.zigLibDirectory(),
                relative_path,
            });
        }
        if (separator != null or std.fs.path.isAbsolute(import_name)) return null;
        const document_path = try filePathFromUri(allocator, document.uri) orelse return null;
        const directory = std.fs.path.dirname(document_path) orelse return null;
        return try std.fs.path.resolve(allocator, &.{ directory, import_name });
    }

    fn importPathCompletions(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        prefix: []const u8,
    ) ![]const lsp.types.completion.Item {
        var completions: std.ArrayList(lsp.types.completion.Item) = .empty;
        if (std.mem.indexOfScalar(u8, prefix, '/') == null) {
            for ([_][]const u8{ "std", "builtin", "root" }) |name| {
                if (!std.mem.startsWith(u8, name, prefix)) continue;
                try completions.append(allocator, .{ .label = name, .kind = .Module, .detail = "Zig module" });
            }
        }
        const document_path = try filePathFromUri(allocator, document.uri) orelse return try completions.toOwnedSlice(allocator);
        const document_directory = std.fs.path.dirname(document_path) orelse return try completions.toOwnedSlice(allocator);
        const prefix_directory = std.fs.path.dirname(prefix) orelse "";
        if (std.fs.path.isAbsolute(prefix_directory)) return try completions.toOwnedSlice(allocator);
        const directory_path = try std.fs.path.join(allocator, &.{ document_directory, prefix_directory });
        var directory = std.Io.Dir.openDirAbsolute(server.io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return try completions.toOwnedSlice(allocator),
            else => return err,
        };
        defer directory.close(server.io);
        var iterator = directory.iterateAssumeFirstIteration();
        const basename_prefix = std.fs.path.basename(prefix);
        while (try iterator.next(server.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, basename_prefix)) continue;
            if (entry.kind != .directory and (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig"))) continue;
            try completions.append(allocator, .{
                .label = if (entry.kind == .directory)
                    try std.fmt.allocPrint(allocator, "{s}/", .{entry.name})
                else
                    try allocator.dupe(u8, entry.name),
                .kind = if (entry.kind == .directory) .Folder else .File,
                .detail = if (entry.kind == .directory) "directory" else "Zig source file",
            });
        }
        return try completions.toOwnedSlice(allocator);
    }

    fn zigLibDirectory(server: *Server) ![]const u8 {
        if (server.zig_lib_directory) |directory| return directory;
        const zig_binary = if (try pathExists(server.io, backend_bootstrap.backend_binary))
            backend_bootstrap.backend_binary
        else
            "zig";
        const result = try std.process.run(server.allocator, server.io, .{
            .argv = &.{ zig_binary, "env" },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer server.allocator.free(result.stdout);
        defer server.allocator.free(result.stderr);
        const succeeded = switch (result.term) {
            .exited => |exit_code| exit_code == 0,
            else => false,
        };
        if (!succeeded) {
            std.log.err("'{s} env' failed: {s}", .{ zig_binary, result.stderr });
            return error.ZigEnvironmentUnavailable;
        }
        const prefix = ".lib_dir = \"";
        const start = std.mem.indexOf(u8, result.stdout, prefix) orelse return error.ZigEnvironmentMalformed;
        const value_start = start + prefix.len;
        const value_end = std.mem.indexOfScalarPos(u8, result.stdout, value_start, '"') orelse {
            return error.ZigEnvironmentMalformed;
        };
        server.zig_lib_directory = try server.allocator.dupe(u8, result.stdout[value_start..value_end]);
        return server.zig_lib_directory.?;
    }
};

const SyntaxMember = struct {
    name: []const u8,
    kind: lsp.types.completion.Item.Kind,
    detail: []const u8,
    span: std.zig.Token.Loc,
};

const ModuleView = struct {
    path: []const u8,
    source: []const u8,
    members: []const SyntaxMember,
};

const FunctionLocation = struct {
    document: *const Document,
    declaration: Declaration,
};

const ImportedSource = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
};

const TokenRange = struct {
    start: usize,
    end: usize,
};

const ContainerDeclaration = struct {
    name_index: usize,
    kind: enum { constant, function, field },
};

const ResolvedTypeSite = struct {
    file: ImportedSource,
    container: TokenRange,
};

const QualifiedReceiver = struct {
    expression: []const u8,
    start: usize,
};

fn bareTypeExpression(type_expression: []const u8) []const u8 {
    var bare = std.mem.trim(u8, type_expression, " \t\r\n");
    while (bare.len != 0 and (bare[0] == '*' or bare[0] == '?')) {
        bare = bare[1..];
        if (std.mem.startsWith(u8, bare, "const ")) bare = bare["const ".len..];
    }
    return bare;
}

fn siteMemberDescription(
    allocator: std.mem.Allocator,
    site: ResolvedTypeSite,
    member_name: []const u8,
) !?hover.Content {
    const declaration = containerDeclarationNamed(
        site.file.source,
        site.file.tokens,
        site.container,
        member_name,
    ) orelse return null;
    return try describeBinding(allocator, site.file.source, site.file.tokens[declaration.name_index].loc);
}

fn siteMembers(
    allocator: std.mem.Allocator,
    site: ResolvedTypeSite,
    include_private: bool,
) ![]SyntaxMember {
    var members: std.ArrayList(SyntaxMember) = .empty;
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    var public_pending = false;
    for (site.file.tokens[site.container.start..site.container.end], site.container.start..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .keyword_pub => if (brace_depth == 0 and parenthesis_depth == 0) {
                public_pending = true;
            },
            .keyword_fn, .keyword_const, .keyword_var => {
                if (brace_depth != 0 or parenthesis_depth != 0 or
                    (!include_private and !public_pending) or index + 1 >= site.container.end) continue;
                const name_token = site.file.tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = site.file.source[name_token.loc.start..name_token.loc.end],
                    .kind = switch (token.tag) {
                        .keyword_fn => .Function,
                        .keyword_const => .Constant,
                        .keyword_var => .Variable,
                        else => unreachable,
                    },
                    .detail = switch (token.tag) {
                        .keyword_fn => if (public_pending) "pub fn" else "fn",
                        .keyword_const => if (public_pending) "pub const" else "const",
                        .keyword_var => if (public_pending) "pub var" else "var",
                        else => unreachable,
                    },
                    .span = name_token.loc,
                });
                public_pending = false;
            },
            .identifier => {
                if (brace_depth != 0 or parenthesis_depth != 0) continue;
                const next_tag = if (index + 1 < site.container.end)
                    site.file.tokens[index + 1].tag
                else
                    null;
                const starts_tag = index == site.container.start or
                    site.file.tokens[index - 1].tag == .comma;
                const is_field_or_tag = next_tag == .colon or
                    (starts_tag and (next_tag == null or next_tag == .comma or next_tag == .equal));
                if (!is_field_or_tag) continue;
                try members.append(allocator, .{
                    .name = site.file.source[token.loc.start..token.loc.end],
                    .kind = .Field,
                    .detail = "field",
                    .span = token.loc,
                });
            },
            .semicolon => if (brace_depth == 0 and parenthesis_depth == 0) {
                public_pending = false;
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

fn sourceStartLocation(allocator: std.mem.Allocator, source: ImportedSource) !lsp.types.Location {
    return sourceLocation(allocator, source, .{ .start = 0, .end = 0 });
}

fn sourceLocation(
    allocator: std.mem.Allocator,
    source: ImportedSource,
    span: std.zig.Token.Loc,
) !lsp.types.Location {
    return .{
        .uri = try std.fmt.allocPrint(allocator, "file://{s}", .{source.path}),
        .range = lsp.offsets.locToRange(source.source, span, .@"utf-16"),
    };
}

fn qualifiedCallReceiver(source: []const u8, member_start: usize) ?QualifiedReceiver {
    if (member_start == 0 or source[member_start - 1] != '.') return null;
    var index = member_start - 1;
    var saw_call = false;
    while (index > 0) {
        if (source[index - 1] == ')') {
            saw_call = true;
            var depth: usize = 0;
            while (index > 0) : (index -= 1) {
                if (source[index - 1] == ')') depth += 1;
                if (source[index - 1] == '(') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (index == 0) return null;
            index -= 1;
        }
        const identifier_end = index;
        while (index > 0 and (std.ascii.isAlphanumeric(source[index - 1]) or source[index - 1] == '_')) : (index -= 1) {}
        if (index == identifier_end) return null;
        if (index == 0 or source[index - 1] != '.') break;
        index -= 1;
    }
    if (!saw_call) return null;
    if (!std.ascii.isAlphabetic(source[index]) and source[index] != '_') return null;
    return .{ .expression = source[index .. member_start - 1], .start = index };
}

fn functionReturnTypeText(
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    name_index: usize,
) ?[]const u8 {
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingSyntaxToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
        tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start == tokens.len) return null;
    const return_type = std.mem.trim(u8, source[tokens[parameters_end].loc.end..tokens[body_start].loc.start], " \t\r\n");
    if (return_type.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, return_type, '!')) |error_union| {
        return std.mem.trim(u8, return_type[error_union + 1 ..], " \t\r\n");
    }
    return return_type;
}

const DeclarationDescent = union(enum) {
    container: TokenRange,
    alias_path: []const u8,
    imported_file: struct {
        file: []const u8,
        members: []const []const u8,
    },
};

fn dottedPathSegments(allocator: std.mem.Allocator, type_expression: []const u8) !?[]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, type_expression, " \t\r\n");
    while (true) {
        const boundary = std.mem.indexOfAny(u8, rest, ".(") orelse rest.len;
        if (boundary == 0) return null;
        const segment = rest[0..boundary];
        if (!isDottedIdentifier(segment)) return null;
        try segments.append(allocator, segment);
        if (boundary == rest.len) return try segments.toOwnedSlice(allocator);
        if (rest[boundary] == '.') {
            rest = rest[boundary + 1 ..];
            continue;
        }
        var depth: usize = 0;
        var index = boundary;
        while (index < rest.len) : (index += 1) {
            if (rest[index] == '(') depth += 1;
            if (rest[index] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (index == rest.len) return null;
        if (index + 1 == rest.len) return try segments.toOwnedSlice(allocator);
        if (rest[index + 1] != '.') return null;
        rest = rest[index + 2 ..];
    }
}

fn containerDeclarationNamed(
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    container: TokenRange,
    name: []const u8,
) ?ContainerDeclaration {
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    for (tokens[container.start..container.end], container.start..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .identifier => {
                if (brace_depth != 0 or parenthesis_depth != 0) continue;
                if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
                if (index > container.start) switch (tokens[index - 1].tag) {
                    .keyword_const, .keyword_var => return .{ .name_index = index, .kind = .constant },
                    .keyword_fn => return .{ .name_index = index, .kind = .function },
                    else => {},
                };
                if (index + 1 < container.end and tokens[index + 1].tag == .colon) {
                    return .{ .name_index = index, .kind = .field };
                }
            },
            else => {},
        }
    }
    return null;
}

fn containerLiteralRange(tokens: []const std.zig.Token, keyword_index: usize) ?TokenRange {
    var brace = keyword_index + 1;
    while (brace < tokens.len and tokens[brace].tag != .l_brace and tokens[brace].tag != .semicolon) : (brace += 1) {}
    if (brace == tokens.len or tokens[brace].tag != .l_brace) return null;
    const closing = matchingSyntaxToken(tokens, brace, .l_brace, .r_brace) orelse return null;
    return .{ .start = brace + 1, .end = closing };
}

fn pathEndIndex(tokens: []const std.zig.Token, start: usize, limit: usize) ?usize {
    if (start >= limit or tokens[start].tag != .identifier) return null;
    var last = start;
    var cursor = start + 1;
    while (cursor < limit) {
        switch (tokens[cursor].tag) {
            .period => {
                if (cursor + 1 >= limit or tokens[cursor + 1].tag != .identifier) return null;
                last = cursor + 1;
                cursor += 2;
            },
            .l_paren => {
                const closing = matchingSyntaxToken(tokens, cursor, .l_paren, .r_paren) orelse return null;
                last = closing;
                cursor = closing + 1;
            },
            .semicolon => return last,
            else => return null,
        }
    }
    return null;
}

fn constantTarget(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    name_index: usize,
) !?DeclarationDescent {
    var equal_index = name_index + 1;
    var depth: usize = 0;
    while (equal_index < tokens.len) : (equal_index += 1) {
        switch (tokens[equal_index].tag) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => depth -|= 1,
            .equal => if (depth == 0) break,
            .semicolon => return null,
            else => {},
        }
    }
    if (equal_index + 1 >= tokens.len) return null;
    var value_index = equal_index + 1;
    while (value_index < tokens.len and
        (tokens[value_index].tag == .keyword_extern or tokens[value_index].tag == .keyword_packed)) : (value_index += 1)
    {}
    switch (tokens[value_index].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
            const range = containerLiteralRange(tokens, value_index) orelse return null;
            return .{ .container = range };
        },
        else => {},
    }
    if (tokens[value_index].tag == .builtin and
        std.mem.eql(u8, source[tokens[value_index].loc.start..tokens[value_index].loc.end], "@import"))
    {
        if (value_index + 3 >= tokens.len or tokens[value_index + 1].tag != .l_paren or
            tokens[value_index + 2].tag != .string_literal or tokens[value_index + 3].tag != .r_paren) return null;
        const literal = source[tokens[value_index + 2].loc.start..tokens[value_index + 2].loc.end];
        if (literal.len < 2) return null;
        const cursor = value_index + 4;
        if (cursor < tokens.len and tokens[cursor].tag == .period) {
            const last = pathEndIndex(tokens, cursor + 1, tokens.len) orelse return null;
            var tail: std.ArrayList([]const u8) = .empty;
            var member_index = cursor + 1;
            while (member_index <= last) : (member_index += 2) {
                if (tokens[member_index].tag != .identifier) return null;
                try tail.append(allocator, source[tokens[member_index].loc.start..tokens[member_index].loc.end]);
            }
            return .{ .imported_file = .{
                .file = literal[1 .. literal.len - 1],
                .members = try tail.toOwnedSlice(allocator),
            } };
        }
        return .{ .imported_file = .{ .file = literal[1 .. literal.len - 1], .members = &.{} } };
    }
    const last = pathEndIndex(tokens, value_index, tokens.len) orelse return null;
    return .{ .alias_path = source[tokens[value_index].loc.start..tokens[last].loc.end] };
}

fn typeFunctionResult(
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    name_index: usize,
) ?DeclarationDescent {
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingSyntaxToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
        tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start == tokens.len or tokens[body_start].tag != .l_brace) return null;
    const return_type = std.mem.trim(u8, source[tokens[parameters_end].loc.end..tokens[body_start].loc.start], " \t\r\n");
    if (!std.mem.eql(u8, return_type, "type")) return null;
    const body_end = matchingSyntaxToken(tokens, body_start, .l_brace, .r_brace) orelse return null;
    var index = body_start + 1;
    while (index < body_end) : (index += 1) {
        if (tokens[index].tag != .keyword_return) continue;
        var value_index = index + 1;
        while (value_index < body_end and
            (tokens[value_index].tag == .keyword_extern or tokens[value_index].tag == .keyword_packed)) : (value_index += 1)
        {}
        switch (tokens[value_index].tag) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                const range = containerLiteralRange(tokens, value_index) orelse return null;
                return .{ .container = range };
            },
            else => {},
        }
    }
    index = body_start + 1;
    while (index < body_end) : (index += 1) {
        if (tokens[index].tag != .keyword_return) continue;
        if (pathEndIndex(tokens, index + 1, body_end)) |last| {
            return .{ .alias_path = source[tokens[index + 1].loc.start..tokens[last].loc.end] };
        }
    }
    return null;
}

const FunctionBodyTokenBounds = struct {
    opening: usize,
    closing: usize,
};

fn callHierarchyItem(document: *const Document, declaration: Declaration) lsp.types.call_hierarchy.Item {
    return .{
        .name = declaration.name,
        .kind = .Function,
        .detail = functionSignature(document.source, declaration.name),
        .uri = document.uri,
        .range = document.range(declaration.span),
        .selectionRange = document.range(declaration.span),
    };
}

fn functionBodyTokenBounds(tokens: []const std.zig.Token, declaration: Declaration) ?FunctionBodyTokenBounds {
    const name_index = for (tokens, 0..) |token, index| {
        if (std.meta.eql(token.loc, declaration.span)) break index;
    } else return null;
    if (name_index == 0 or tokens[name_index - 1].tag != .keyword_fn or name_index + 1 >= tokens.len or
        tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = matchingSyntaxToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return null;
    var opening = parameters_end + 1;
    while (opening < tokens.len and tokens[opening].tag != .l_brace and tokens[opening].tag != .semicolon) : (opening += 1) {}
    if (opening >= tokens.len or tokens[opening].tag != .l_brace) return null;
    return .{
        .opening = opening,
        .closing = matchingSyntaxToken(tokens, opening, .l_brace, .r_brace) orelse return null,
    };
}

fn functionContainingToken(
    document: *const Document,
    tokens: []const std.zig.Token,
    token_index: usize,
) ?Declaration {
    for (document.declarations) |declaration| {
        if (declaration.kind != .function) continue;
        const body = functionBodyTokenBounds(tokens, declaration) orelse continue;
        if (token_index > body.opening and token_index < body.closing) return declaration;
    }
    return null;
}

fn resolvedShapeKindName(kind: analysis.ResolvedShape.Kind) []const u8 {
    return switch (kind) {
        .enumeration => "enum",
        .tagged_union => "tagged union",
        .structure => "struct",
    };
}

fn renderResolvedShape(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    shape: analysis.ResolvedShape,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("const {s} = {s} {{\n", .{
        type_name,
        switch (shape.kind) {
            .enumeration => "enum",
            .tagged_union => "union(enum)",
            .structure => "struct",
        },
    });
    for (shape.fields) |field| {
        switch (shape.kind) {
            .enumeration => try writer.writer.print("    {s},\n", .{field}),
            .tagged_union, .structure => try writer.writer.print("    {s}: <compiler-resolved>,\n", .{field}),
        }
    }
    try writer.writer.writeAll("};");
    return try writer.toOwnedSlice();
}

fn describeBinding(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    binding_span: std.zig.Token.Loc,
) !?hover.Content {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const binding_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and std.meta.eql(token.loc, binding_span)) break index;
    } else return null;

    if (binding_index > 0 and tokens[binding_index - 1].tag == .keyword_fn) {
        return try describeFunctionBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index > 0 and
        (tokens[binding_index - 1].tag == .keyword_const or tokens[binding_index - 1].tag == .keyword_var))
    {
        return try describeVariableBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index + 1 < tokens.len and tokens[binding_index + 1].tag == .colon) {
        return try describeTypedBinding(allocator, source_bytes, tokens, binding_index);
    }
    if (binding_index > 0 and binding_index + 1 < tokens.len and
        tokens[binding_index - 1].tag == .pipe and tokens[binding_index + 1].tag == .pipe)
    {
        return try describeCaptureBinding(allocator, source_bytes, tokens, binding_index);
    }
    return null;
}

fn describeCaptureBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !?hover.Content {
    var iterable_index = binding_index - 1;
    while (iterable_index > 0 and tokens[iterable_index].tag != .r_paren) : (iterable_index -= 1) {}
    if (tokens[iterable_index].tag != .r_paren or iterable_index == 0) return null;
    iterable_index -= 1;
    if (tokens[iterable_index].tag != .identifier) return null;
    const iterable_name = source[tokens[iterable_index].loc.start..tokens[iterable_index].loc.end];
    const iterable_type = typedBindingTypeNamed(source, tokens, iterable_name) orelse return null;
    const element_type = if (std.mem.startsWith(u8, iterable_type, "[]const "))
        iterable_type["[]const ".len..]
    else if (std.mem.startsWith(u8, iterable_type, "[]"))
        iterable_type[2..]
    else
        return null;
    const name = source[tokens[binding_index].loc.start..tokens[binding_index].loc.end];
    return .{
        .declaration = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, element_type }),
        .type_summary = element_type,
    };
}

fn describeTypedMemberNamed(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    name: []const u8,
) !?hover.Content {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 1 >= tokens.len or tokens[index + 1].tag != .colon) continue;
        if (!std.mem.eql(u8, source_bytes[token.loc.start..token.loc.end], name)) continue;
        return try describeTypedBinding(allocator, source_bytes, tokens, index);
    }
    return null;
}

fn describeEnumTagNamed(
    allocator: std.mem.Allocator,
    source_bytes: []const u8,
    name: []const u8,
) !?hover.Content {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !std.mem.eql(u8, source_bytes[token.loc.start..token.loc.end], name)) continue;
        const opening_brace = enclosingSyntaxToken(tokens, index, .l_brace, .r_brace) orelse continue;
        if (opening_brace == 0 or tokens[opening_brace - 1].tag != .keyword_enum) continue;
        if (opening_brace < 3 or tokens[opening_brace - 2].tag != .equal or tokens[opening_brace - 3].tag != .identifier) continue;
        const enum_name = source_bytes[tokens[opening_brace - 3].loc.start..tokens[opening_brace - 3].loc.end];
        return .{
            .declaration = try std.fmt.allocPrint(allocator, ".{s}", .{name}),
            .type_summary = enum_name,
        };
    }
    return null;
}

fn enclosingSyntaxToken(
    tokens: []const std.zig.Token,
    index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == closing_tag) {
            depth += 1;
        } else if (tokens[cursor].tag == opening_tag) {
            if (depth == 0) return cursor;
            depth -= 1;
        }
    }
    return null;
}

fn typedBindingTypeNamed(
    source: []const u8,
    tokens: []const std.zig.Token,
    name: []const u8,
) ?[]const u8 {
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 2 >= tokens.len or tokens[index + 1].tag != .colon) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
        var end_index = index + 2;
        var bracket_depth: usize = 0;
        while (end_index < tokens.len) : (end_index += 1) {
            switch (tokens[end_index].tag) {
                .l_bracket => bracket_depth += 1,
                .r_bracket => bracket_depth -|= 1,
                .comma, .r_paren, .equal => if (bracket_depth == 0) break,
                else => {},
            }
        }
        if (end_index == index + 2) return null;
        return std.mem.trim(
            u8,
            source[tokens[index + 1].loc.end..tokens[end_index - 1].loc.end],
            " \t\r\n",
        );
    }
    return null;
}

fn describeFunctionBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !hover.Content {
    const function_index = binding_index - 1;
    var opening_parenthesis = binding_index + 1;
    while (opening_parenthesis < tokens.len and tokens[opening_parenthesis].tag != .l_paren) : (opening_parenthesis += 1) {}
    if (opening_parenthesis == tokens.len) return error.MalformedFunctionDeclaration;
    const closing_parenthesis = matchingSyntaxToken(tokens, opening_parenthesis, .l_paren, .r_paren) orelse {
        return error.MalformedFunctionDeclaration;
    };
    var body_index = closing_parenthesis + 1;
    while (body_index < tokens.len and tokens[body_index].tag != .l_brace and tokens[body_index].tag != .semicolon) : (body_index += 1) {}
    if (body_index == tokens.len) return error.MalformedFunctionDeclaration;
    const declaration_end = tokens[body_index - 1].loc.end;
    const declaration = std.mem.trim(u8, source[tokens[function_index].loc.start..declaration_end], " \t\r\n");

    var summary: std.Io.Writer.Allocating = .init(allocator);
    defer summary.deinit();
    try summary.writer.writeAll("fn (");
    var segment_start = opening_parenthesis + 1;
    var nested_parentheses: usize = 0;
    var first_parameter = true;
    var index = segment_start;
    while (index <= closing_parenthesis) : (index += 1) {
        const at_end = index == closing_parenthesis;
        if (!at_end) {
            if (tokens[index].tag == .l_paren) nested_parentheses += 1;
            if (tokens[index].tag == .r_paren) nested_parentheses -|= 1;
        }
        if (!at_end and (tokens[index].tag != .comma or nested_parentheses != 0)) continue;
        if (segment_start < index) {
            const colon_index = for (tokens[segment_start..index], segment_start..) |token, parameter_index| {
                if (token.tag == .colon) break parameter_index;
            } else null;
            if (colon_index) |colon| {
                if (!first_parameter) try summary.writer.writeAll(", ");
                if (tokens[segment_start].tag == .keyword_comptime) try summary.writer.writeAll("comptime ");
                const parameter_type = std.mem.trim(
                    u8,
                    source[tokens[colon].loc.end..tokens[index - 1].loc.end],
                    " \t\r\n",
                );
                try summary.writer.writeAll(parameter_type);
                first_parameter = false;
            }
        }
        segment_start = index + 1;
    }
    try summary.writer.writeAll(") ");
    const return_type = std.mem.trim(
        u8,
        source[tokens[closing_parenthesis].loc.end..tokens[body_index].loc.start],
        " \t\r\n",
    );
    try summary.writer.writeAll(if (return_type.len == 0) "void" else return_type);
    return .{
        .declaration = declaration,
        .type_summary = try summary.toOwnedSlice(),
        .documentation = try documentationBefore(allocator, source, tokens[function_index].loc.start),
    };
}

fn describeVariableBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !hover.Content {
    const declaration_index = binding_index - 1;
    var end_index = binding_index + 1;
    while (end_index < tokens.len and tokens[end_index].tag != .semicolon) : (end_index += 1) {}
    if (end_index == tokens.len) return error.MalformedVariableDeclaration;
    const declaration = std.mem.trim(
        u8,
        source[tokens[declaration_index].loc.start..tokens[end_index - 1].loc.end],
        " \t\r\n",
    );
    var colon_index: ?usize = null;
    var equal_index: ?usize = null;
    for (tokens[binding_index + 1 .. end_index], binding_index + 1..) |token, index| {
        if (token.tag == .colon and colon_index == null) colon_index = index;
        if (token.tag == .equal) {
            equal_index = index;
            break;
        }
    }
    const explicit_type = if (colon_index) |colon|
        std.mem.trim(
            u8,
            source[tokens[colon].loc.end..tokens[(equal_index orelse end_index) - 1].loc.end],
            " \t\r\n",
        )
    else
        null;
    const value_token = if (equal_index) |equal|
        if (equal + 2 == end_index) tokens[equal + 1] else null
    else
        null;
    const inferred_type = if (explicit_type) |type_name|
        type_name
    else if (value_token) |token|
        inferredLiteralType(source[token.loc.start..token.loc.end], token.tag)
    else
        null;
    const type_summary = if (inferred_type) |type_name| summary: {
        if (value_token) |token| {
            const value = source[token.loc.start..token.loc.end];
            if (value.len <= 64) break :summary try std.fmt.allocPrint(allocator, "{s} = {s}", .{ type_name, value });
        }
        break :summary type_name;
    } else null;
    return .{
        .declaration = declaration,
        .type_summary = type_summary,
        .documentation = try documentationBefore(allocator, source, tokens[declaration_index].loc.start),
    };
}

fn describeTypedBinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_index: usize,
) !hover.Content {
    const colon_index = binding_index + 1;
    var end_index = colon_index + 1;
    var bracket_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    while (end_index < tokens.len) : (end_index += 1) {
        switch (tokens[end_index].tag) {
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => {
                if (bracket_depth == 0 and parenthesis_depth == 0) break;
                parenthesis_depth -|= 1;
            },
            .comma, .equal, .semicolon, .r_brace => if (bracket_depth == 0 and parenthesis_depth == 0) break,
            else => {},
        }
    }
    if (end_index == colon_index + 1) return error.MalformedTypedBinding;
    const type_name = std.mem.trim(
        u8,
        source[tokens[colon_index].loc.end..tokens[end_index - 1].loc.end],
        " \t\r\n",
    );
    return .{
        .declaration = source[tokens[binding_index].loc.start..tokens[end_index - 1].loc.end],
        .type_summary = type_name,
        .documentation = try documentationBefore(allocator, source, tokens[binding_index].loc.start),
    };
}

fn inferredLiteralType(source: []const u8, tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (tag) {
        .number_literal => if (std.mem.indexOfScalar(u8, source, '.') == null) "comptime_int" else "comptime_float",
        .string_literal => "string",
        .char_literal => "comptime_int",
        .identifier => if (std.mem.eql(u8, source, "true") or std.mem.eql(u8, source, "false")) "bool" else null,
        else => null,
    };
}

fn documentationBefore(
    allocator: std.mem.Allocator,
    source: []const u8,
    declaration_start: usize,
) !?[]const u8 {
    const declaration_line_start = std.mem.lastIndexOfScalar(u8, source[0..declaration_start], '\n') orelse 0;
    var block_start = if (declaration_line_start == 0) 0 else declaration_line_start;
    var cursor = block_start;
    var found = false;
    while (cursor > 0) {
        const previous_end = cursor - 1;
        const previous_start = (std.mem.lastIndexOfScalar(u8, source[0..previous_end], '\n') orelse 0) +
            @intFromBool(std.mem.lastIndexOfScalar(u8, source[0..previous_end], '\n') != null);
        const line = std.mem.trim(u8, source[previous_start..previous_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "///")) break;
        found = true;
        block_start = previous_start;
        cursor = previous_start;
    }
    if (!found) return null;

    var documentation: std.Io.Writer.Allocating = .init(allocator);
    defer documentation.deinit();
    var lines = std.mem.splitScalar(u8, source[block_start..declaration_line_start], '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "///")) continue;
        if (!first) try documentation.writer.writeByte('\n');
        try documentation.writer.writeAll(std.mem.trimStart(u8, line[3..], " "));
        first = false;
    }
    return try documentation.toOwnedSlice();
}

fn formatStringAt(source: [:0]const u8, byte_offset: usize) bool {
    var previous: [2]std.zig.Token = undefined;
    var previous_count: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .string_literal and byte_offset > token.loc.start and byte_offset < token.loc.end) {
            if (previous_count < 2 or previous[1].tag != .l_paren or previous[0].tag != .identifier) return false;
            const callee = source[previous[0].loc.start..previous[0].loc.end];
            return std.mem.eql(u8, callee, "print") or std.mem.eql(u8, callee, "format") or
                std.mem.eql(u8, callee, "allocPrint") or std.mem.eql(u8, callee, "bufPrint");
        }
        if (previous_count < previous.len) {
            previous[previous_count] = token;
            previous_count += 1;
        } else {
            previous[0] = previous[1];
            previous[1] = token;
        }
    }
}

fn importStringPrefix(source: [:0]const u8, byte_offset: usize) ?[]const u8 {
    var previous: [3]std.zig.Token = undefined;
    var previous_count: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return null;
        if (token.tag == .string_literal and byte_offset > token.loc.start and byte_offset <= token.loc.end) {
            if (previous_count < 2 or previous[previous_count - 1].tag != .l_paren or
                previous[previous_count - 2].tag != .builtin or
                !std.mem.eql(u8, source[previous[previous_count - 2].loc.start..previous[previous_count - 2].loc.end], "@import")) return null;
            return source[token.loc.start + 1 .. @min(byte_offset, token.loc.end - 1)];
        }
        if (previous_count < previous.len) {
            previous[previous_count] = token;
            previous_count += 1;
        } else {
            previous[0] = previous[1];
            previous[1] = previous[2];
            previous[2] = token;
        }
    }
}

fn importPathAt(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    byte_offset: usize,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or index + 3 >= tokens.len or
            !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import") or
            tokens[index + 1].tag != .l_paren or
            tokens[index + 2].tag != .string_literal or
            tokens[index + 3].tag != .r_paren)
        {
            continue;
        }
        if (byte_offset < token.loc.start or byte_offset > tokens[index + 3].loc.end) continue;
        const literal = source[tokens[index + 2].loc.start..tokens[index + 2].loc.end];
        if (literal.len < 2) return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

fn memberReceiver(source: []const u8, byte_offset: usize) ?[]const u8 {
    if (byte_offset == 0 or byte_offset > source.len or source[byte_offset - 1] != '.') return null;
    var start = byte_offset - 1;
    while (start > 0) {
        const byte = source[start - 1];
        if (!isIdentifierByte(byte) and byte != '.') break;
        start -= 1;
    }
    const receiver = source[start .. byte_offset - 1];
    if (!isDottedIdentifier(receiver)) return null;
    return receiver;
}

fn receiverIdentifierSpan(source: []const u8, member_start: usize) ?std.zig.Token.Loc {
    if (member_start < 2 or member_start > source.len or source[member_start - 1] != '.') return null;
    const end = member_start - 1;
    var start = end;
    while (start > 0 and isIdentifierByte(source[start - 1])) start -= 1;
    if (start == end or !isIdentifier(source[start..end])) return null;
    return .{ .start = start, .end = end };
}

fn namedTypeExpression(type_expression: []const u8) ?[]const u8 {
    var type_name = std.mem.trim(u8, type_expression, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, type_name, '!')) |error_separator| {
        type_name = std.mem.trimStart(u8, type_name[error_separator + 1 ..], " \t\r\n");
    }
    while (type_name.len != 0 and type_name[0] == '?') type_name = type_name[1..];
    return if (isDottedIdentifier(type_name)) type_name else null;
}

fn isDottedIdentifier(source: []const u8) bool {
    if (source.len == 0 or source[0] == '.' or source[source.len - 1] == '.') return false;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index != source.len and source[index] != '.') continue;
        if (!isIdentifier(source[segment_start..index])) return false;
        segment_start = index + 1;
    }
    return true;
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    return try tokens.toOwnedSlice(allocator);
}

fn matchingSyntaxToken(
    tokens: []const std.zig.Token,
    opening_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn matchingOpeningSyntaxToken(
    tokens: []const std.zig.Token,
    closing_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = closing_index + 1;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == closing_tag) depth += 1;
        if (tokens[cursor].tag != opening_tag) continue;
        depth -= 1;
        if (depth == 0) return cursor;
    }
    return null;
}

fn importName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    alias: []const u8,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 7 >= tokens.len) continue;
        const alias_token = tokens[index + 1];
        const equal_token = tokens[index + 2];
        const import_token = tokens[index + 3];
        const opening_parenthesis = tokens[index + 4];
        const path_token = tokens[index + 5];
        if (alias_token.tag != .identifier or equal_token.tag != .equal or
            import_token.tag != .builtin or opening_parenthesis.tag != .l_paren or
            path_token.tag != .string_literal or tokens[index + 6].tag != .r_paren or
            tokens[index + 7].tag != .semicolon)
        {
            continue;
        }
        if (!std.mem.eql(u8, source[alias_token.loc.start..alias_token.loc.end], alias)) continue;
        if (!std.mem.eql(u8, source[import_token.loc.start..import_token.loc.end], "@import")) continue;
        const literal = source[path_token.loc.start..path_token.loc.end];
        if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
        return literal[1 .. literal.len - 1];
    }
    return null;
}

fn declaredTypeName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    binding_name: []const u8,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 2 >= tokens.len) continue;
        if (tokens[index + 1].tag != .colon or tokens[index + 2].tag != .identifier) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], binding_name)) continue;
        const type_token = tokens[index + 2];
        return source[type_token.loc.start..type_token.loc.end];
    }
    return null;
}

fn structMembers(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    type_name: []const u8,
) ![]SyntaxMember {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const opening_index = for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= tokens.len) continue;
        if (tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            tokens[index + 3].tag != .keyword_struct or tokens[index + 4].tag != .l_brace)
        {
            continue;
        }
        const name_token = tokens[index + 1];
        if (std.mem.eql(u8, source[name_token.loc.start..name_token.loc.end], type_name)) break index + 4;
    } else return &.{};

    var members: std.ArrayList(SyntaxMember) = .empty;
    errdefer members.deinit(allocator);
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            },
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .keyword_fn => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 1 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = .Method,
                    .detail = "fn",
                    .span = name_token.loc,
                });
            },
            .keyword_const, .keyword_var => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 2 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                if (tokens[index + 2].tag != .equal and tokens[index + 2].tag != .colon) continue;
                try members.append(allocator, .{
                    .name = source[name_token.loc.start..name_token.loc.end],
                    .kind = if (token.tag == .keyword_const) .Constant else .Variable,
                    .detail = if (token.tag == .keyword_const) "const" else "var",
                    .span = name_token.loc,
                });
            },
            .identifier => {
                if (brace_depth != 1 or parenthesis_depth != 0 or index + 1 >= tokens.len) continue;
                if (tokens[index + 1].tag != .colon) continue;
                try members.append(allocator, .{
                    .name = source[token.loc.start..token.loc.end],
                    .kind = .Field,
                    .detail = "field",
                    .span = token.loc,
                });
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

fn publicModuleMembers(allocator: std.mem.Allocator, source_bytes: []const u8) ![]SyntaxMember {
    const source = try allocator.allocSentinel(u8, source_bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, source_bytes);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);

    var members: std.ArrayList(SyntaxMember) = .empty;
    errdefer members.deinit(allocator);
    var brace_depth: usize = 0;
    var public_pending = false;
    for (tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .keyword_pub => if (brace_depth == 0) {
                public_pending = true;
            },
            .keyword_fn, .keyword_const, .keyword_var => {
                if (brace_depth != 0 or !public_pending or index + 1 >= tokens.len) continue;
                const name_token = tokens[index + 1];
                if (name_token.tag != .identifier) continue;
                try members.append(allocator, .{
                    .name = try allocator.dupe(u8, source[name_token.loc.start..name_token.loc.end]),
                    .kind = switch (token.tag) {
                        .keyword_fn => .Function,
                        .keyword_const => .Constant,
                        .keyword_var => .Variable,
                        else => unreachable,
                    },
                    .detail = switch (token.tag) {
                        .keyword_fn => "pub fn",
                        .keyword_const => "pub const",
                        .keyword_var => "pub var",
                        else => unreachable,
                    },
                    .span = name_token.loc,
                });
                public_pending = false;
            },
            .semicolon => if (brace_depth == 0) {
                public_pending = false;
            },
            else => {},
        }
    }
    return try members.toOwnedSlice(allocator);
}

fn findingDiagnostic(
    allocator: std.mem.Allocator,
    document: *const Document,
    finding: analysis.Finding,
) !lsp.types.Diagnostic {
    const related: ?[]const lsp.types.Diagnostic.RelatedInformation = if (finding.related.len == 0) null else related: {
        const information = try allocator.alloc(lsp.types.Diagnostic.RelatedInformation, finding.related.len);
        for (finding.related, information) |finding_related, *diagnostic_related| {
            diagnostic_related.* = .{
                .location = .{ .uri = document.uri, .range = document.range(finding_related.span) },
                .message = finding_related.message,
            };
        }
        break :related information;
    };
    return .{
        .range = document.range(finding.span),
        .severity = levelSeverity(finding.level),
        .code = .{ .string = finding.rule.code() },
        .codeDescription = if (ruleDocumentationUri(finding.rule)) |uri| .{ .href = uri } else null,
        .source = "zig-analyzer",
        .message = finding.message,
        .relatedInformation = related,
    };
}

fn ruleDocumentationUri(rule: analysis.Rule) ?[]const u8 {
    return switch (rule) {
        .non_idiomatic_name, .non_idiomatic_file_name => "https://ziglang.org/documentation/master/#Names",
        .vague_type_name => "https://ziglang.org/documentation/master/#Avoid-Redundancy-in-Names",
        .redundant_qualified_name => "https://ziglang.org/documentation/master/#Avoid-Redundant-Names-in-Fully-Qualified-Namespaces",
        .underscore_private_name => "https://ziglang.org/documentation/master/#Refrain-from-Underscore-Prefixes",
        .doc_comment_style, .public_declaration_docs => "https://ziglang.org/documentation/master/#Doc-Comment-Guidance",
        .prefer_optional_capture => "https://ziglang.org/documentation/master/#if-with-Optionals",
        .prefer_try, .discarded_error, .unsafe_catch_unreachable, .lost_error_context => "https://ziglang.org/documentation/master/#Errors",
        .missing_switch_prong, .non_exhaustive_switch_else, .non_exhaustive_error_switch => "https://ziglang.org/documentation/master/#Exhaustive-Switching",
        .redundant_comptime, .redundant_inline, .unknown_comptime_member, .constant_comptime_condition => "https://ziglang.org/documentation/master/#comptime",
        else => null,
    };
}

fn levelSeverity(level: analysis.Level) lsp.types.Diagnostic.Severity {
    return switch (level) {
        .off, .hint => .Hint,
        .information => .Information,
        .warning => .Warning,
        .@"error" => .Error,
    };
}

fn spansOverlap(left: std.zig.Token.Loc, right: std.zig.Token.Loc) bool {
    if (left.start == left.end) return right.start <= left.start and left.start <= right.end;
    return left.start < right.end and right.start < left.end;
}

fn nonOverlappingEdits(allocator: std.mem.Allocator, edits: []const analysis.Edit) ![]const analysis.Edit {
    if (edits.len == 0) return &.{};
    const sorted = try allocator.dupe(analysis.Edit, edits);
    std.mem.sort(analysis.Edit, sorted, {}, struct {
        fn lessThan(_: void, left: analysis.Edit, right: analysis.Edit) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return left.span.end < right.span.end;
        }
    }.lessThan);
    var accepted: std.ArrayList(analysis.Edit) = .empty;
    for (sorted) |edit| {
        if (accepted.items.len != 0) {
            const previous = accepted.items[accepted.items.len - 1];
            if (edit.span.start < previous.span.end) continue;
            if (std.meta.eql(edit.span, previous.span) and std.mem.eql(u8, edit.replacement, previous.replacement)) continue;
        }
        try accepted.append(allocator, edit);
    }
    return try accepted.toOwnedSlice(allocator);
}

const CleanupAction = struct {
    title: []const u8,
    edit: analysis.Edit,
};

fn allocationCleanupEdit(
    allocator: std.mem.Allocator,
    source: []const u8,
    binding_span: std.zig.Token.Loc,
) !?CleanupAction {
    const statement_start = (std.mem.lastIndexOfScalar(u8, source[0..binding_span.start], '\n') orelse 0) +
        @intFromBool(std.mem.lastIndexOfScalar(u8, source[0..binding_span.start], '\n') != null);
    const relative_end = std.mem.indexOfScalar(u8, source[binding_span.end..], ';') orelse return null;
    const statement_end = binding_span.end + relative_end + 1;
    const statement = source[statement_start..statement_end];
    const equal = std.mem.indexOfScalar(u8, statement, '=') orelse return null;
    const allocation_methods = [_][]const u8{ ".alloc(", ".allocSentinel(", ".alignedAlloc(", ".dupe(", ".dupeZ(", ".realloc(", ".create(" };
    const method_offset, const release = for (allocation_methods) |method| {
        if (std.mem.indexOf(u8, statement[equal + 1 ..], method)) |offset| {
            break .{ equal + 1 + offset, if (std.mem.eql(u8, method, ".create(")) "destroy" else "free" };
        }
    } else return null;
    var receiver = std.mem.trim(u8, statement[equal + 1 .. method_offset], " \t\r\n");
    if (std.mem.startsWith(u8, receiver, "try ")) receiver = std.mem.trimStart(u8, receiver[4..], " \t");
    if (receiver.len == 0) return null;
    for (receiver) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '.') return null;
    }
    const binding_name = source[binding_span.start..binding_span.end];
    const indentation_end = for (source[statement_start..], statement_start..) |character, offset| {
        if (character != ' ' and character != '\t') break offset;
    } else statement_start;
    const indentation = source[statement_start..indentation_end];
    return .{
        .title = try std.fmt.allocPrint(allocator, "Insert defer {s}.{s}({s})", .{ receiver, release, binding_name }),
        .edit = .{
            .span = .{ .start = statement_end, .end = statement_end },
            .replacement = try std.fmt.allocPrint(allocator, "\n{s}defer {s}.{s}({s});", .{ indentation, receiver, release, binding_name }),
        },
    };
}

fn moveCleanupAfterAcquisition(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    binding_span: std.zig.Token.Loc,
) !?[]const analysis.Edit {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var binding_index: ?usize = null;
    for (tokens, 0..) |token, index| if (std.meta.eql(token.loc, binding_span)) {
        binding_index = index;
        break;
    };
    const declaration_name_index = binding_index orelse return null;
    const binding_name = source[binding_span.start..binding_span.end];
    var allocation_end = declaration_name_index;
    while (allocation_end < tokens.len and tokens[allocation_end].tag != .semicolon) : (allocation_end += 1) {}
    if (allocation_end >= tokens.len) return null;
    var defer_index = allocation_end + 1;
    const defer_end = while (defer_index < tokens.len) {
        while (defer_index < tokens.len and tokens[defer_index].tag != .keyword_defer) : (defer_index += 1) {}
        if (defer_index >= tokens.len) return null;
        var candidate_end = defer_index;
        var contains_binding = false;
        var contains_release = false;
        while (candidate_end < tokens.len and tokens[candidate_end].tag != .semicolon) : (candidate_end += 1) {
            if (tokens[candidate_end].tag == .identifier and
                std.mem.eql(u8, source[tokens[candidate_end].loc.start..tokens[candidate_end].loc.end], binding_name))
            {
                contains_binding = true;
            }
            if (tokens[candidate_end].tag != .identifier) continue;
            const method = source[tokens[candidate_end].loc.start..tokens[candidate_end].loc.end];
            const cleanup_methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };
            for (cleanup_methods) |cleanup_method| {
                if (std.mem.eql(u8, method, cleanup_method)) contains_release = true;
            }
        }
        if (candidate_end >= tokens.len) return null;
        if (contains_binding and contains_release) break candidate_end;
        defer_index = candidate_end + 1;
    } else return null;

    const cleanup_line_start = (std.mem.lastIndexOfScalar(u8, source[0..tokens[defer_index].loc.start], '\n') orelse 0) +
        @intFromBool(std.mem.lastIndexOfScalar(u8, source[0..tokens[defer_index].loc.start], '\n') != null);
    const cleanup_prefix = source[cleanup_line_start..tokens[defer_index].loc.start];
    if (std.mem.trim(u8, cleanup_prefix, " \t\r").len != 0) return null;
    const cleanup_statement_end = tokens[defer_end].loc.end;
    const cleanup_line_end = if (std.mem.indexOfScalar(u8, source[cleanup_statement_end..], '\n')) |relative|
        cleanup_statement_end + relative + 1
    else
        source.len;
    if (std.mem.trim(u8, source[cleanup_statement_end..cleanup_line_end], " \t\r\n").len != 0) return null;

    const cleanup_line = std.mem.trimEnd(u8, source[cleanup_line_start..cleanup_line_end], "\r\n");
    const edits = try allocator.alloc(analysis.Edit, 2);
    edits[0] = .{
        .span = .{ .start = tokens[allocation_end].loc.end, .end = tokens[allocation_end].loc.end },
        .replacement = try std.fmt.allocPrint(allocator, "\n{s}", .{cleanup_line}),
    };
    edits[1] = .{
        .span = .{ .start = cleanup_line_start, .end = cleanup_line_end },
        .replacement = "",
    };
    return edits;
}

fn generateFunctionEdit(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name_span: std.zig.Token.Loc,
) !?analysis.Edit {
    if (try insideContainerAt(allocator, source, name_span.start)) return null;
    var opening = name_span.end;
    while (opening < source.len and std.ascii.isWhitespace(source[opening])) : (opening += 1) {}
    if (opening >= source.len or source[opening] != '(') return null;
    const closing = matchingByte(source, opening, '(', ')') orelse return null;
    const statement_start = (std.mem.lastIndexOfScalar(u8, source[0..name_span.start], ';') orelse
        std.mem.lastIndexOfScalar(u8, source[0..name_span.start], '{') orelse 0) + 1;
    const prefix = source[statement_start..name_span.start];
    const equal = std.mem.lastIndexOfScalar(u8, prefix, '=') orelse return null;
    const colon = std.mem.lastIndexOfScalar(u8, prefix[0..equal], ':') orelse return null;
    const return_type = std.mem.trim(u8, prefix[colon + 1 .. equal], " \t\r\n");
    if (return_type.len == 0) return null;
    const function_name = source[name_span.start..name_span.end];
    const arguments_source = source[opening + 1 .. closing];
    if (std.mem.indexOfAny(u8, arguments_source, "([{") != null) return null;
    var parameter_names: std.ArrayList([]const u8) = .empty;
    var parameter_types: std.ArrayList([]const u8) = .empty;
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    var arguments = std.mem.splitScalar(u8, arguments_source, ',');
    while (arguments.next()) |raw_argument| {
        const argument = std.mem.trim(u8, raw_argument, " \t\r\n");
        if (argument.len == 0) continue;
        const parameter_index = parameter_names.items.len + 1;
        const parameter_name = if (isIdentifier(argument) and !seen_names.contains(argument))
            argument
        else
            try std.fmt.allocPrint(allocator, "arg{d}", .{parameter_index});
        try seen_names.put(allocator, parameter_name, {});
        try parameter_names.append(allocator, parameter_name);
        try parameter_types.append(
            allocator,
            if (isIdentifier(argument)) (try declaredTypeName(allocator, source, argument)) orelse "anytype" else "anytype",
        );
    }
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("\nfn {s}(", .{function_name});
    for (parameter_names.items, parameter_types.items, 0..) |parameter_name, parameter_type, parameter_index| {
        if (parameter_index != 0) try writer.writer.writeAll(", ");
        try writer.writer.print("{s}: {s}", .{ parameter_name, parameter_type });
    }
    try writer.writer.print(") {s} {{\n", .{return_type});
    for (parameter_names.items) |parameter_name| {
        try writer.writer.print("    _ = {s};\n", .{parameter_name});
    }
    try writer.writer.writeAll("    @panic(\"TODO\");\n}\n");
    return .{
        .span = .{ .start = source.len, .end = source.len },
        .replacement = try writer.toOwnedSlice(),
    };
}

fn insideContainerAt(allocator: std.mem.Allocator, source: [:0]const u8, offset: usize) !bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof or token.loc.start >= offset) break;
        try tokens.append(allocator, token);
    }
    var brace_kinds: std.ArrayList(bool) = .empty;
    var container_depth: usize = 0;
    for (tokens.items, 0..) |token, index| switch (token.tag) {
        .l_brace => {
            var cursor = index;
            var is_container = false;
            while (cursor > 0 and index - cursor < 8) {
                cursor -= 1;
                switch (tokens.items[cursor].tag) {
                    .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                        is_container = true;
                        break;
                    },
                    .semicolon, .l_brace, .r_brace => break,
                    else => {},
                }
            }
            try brace_kinds.append(allocator, is_container);
            container_depth += @intFromBool(is_container);
        },
        .r_brace => if (brace_kinds.pop()) |was_container| {
            container_depth -= @intFromBool(was_container);
        },
        else => {},
    };
    return container_depth != 0;
}

fn matchingByte(source: []const u8, opening: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    for (source[opening..], opening..) |character, offset| {
        if (character == open) depth += 1;
        if (character != close) continue;
        depth -= 1;
        if (depth == 0) return offset;
    }
    return null;
}

const Extraction = struct {
    name: []const u8,
    declaration: analysis.Edit,
    replacement: analysis.Edit,
};

fn extractExpressionEdits(
    allocator: std.mem.Allocator,
    document: *const Document,
    selection: std.zig.Token.Loc,
) !?Extraction {
    if (selection.start == selection.end) return null;
    var exact_node = false;
    for (1..document.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const first = document.tree.firstToken(node);
        const last = document.tree.lastToken(node);
        const start = document.tree.tokenStart(first);
        const end = document.tree.tokenStart(last) + document.tree.tokenSlice(last).len;
        if (selection.start == start and selection.end == end) {
            exact_node = true;
            break;
        }
    }
    if (!exact_node) return null;
    const line_start = (std.mem.lastIndexOfScalar(u8, document.source[0..selection.start], '\n') orelse 0) +
        @intFromBool(std.mem.lastIndexOfScalar(u8, document.source[0..selection.start], '\n') != null);
    var indentation_end = line_start;
    while (indentation_end < document.source.len and
        (document.source[indentation_end] == ' ' or document.source[indentation_end] == '\t')) : (indentation_end += 1)
    {}
    const indentation = document.source[line_start..indentation_end];
    var suffix: usize = 1;
    var name: []const u8 = "value";
    while (identifierOccurs(document.source, name)) : (suffix += 1) {
        name = try std.fmt.allocPrint(allocator, "value{d}", .{suffix + 1});
    }
    return .{
        .name = name,
        .declaration = .{
            .span = .{ .start = line_start, .end = line_start },
            .replacement = try std.fmt.allocPrint(
                allocator,
                "{s}const {s} = {s};\n",
                .{ indentation, name, document.source[selection.start..selection.end] },
            ),
        },
        .replacement = .{ .span = selection, .replacement = name },
    };
}

fn identifierOccurs(source: [:0]const u8, name: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .identifier and std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) return true;
    }
}

fn isContainerField(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    span: std.zig.Token.Loc,
) !bool {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const index = for (tokens, 0..) |token, token_index| {
        if (std.meta.eql(token.loc, span)) break token_index;
    } else return false;
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .colon) return false;
    var cursor = index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        if (cursor == 0) return false;
        const container_token = tokens[cursor - 1];
        if (container_token.tag == .keyword_struct or
            container_token.tag == .keyword_enum or
            container_token.tag == .keyword_union) return true;
        if (container_token.tag != .r_paren) return false;
        const parameters_start = matchingOpeningSyntaxToken(tokens, cursor - 1, .l_paren, .r_paren) orelse return false;
        return parameters_start > 0 and tokens[parameters_start - 1].tag == .keyword_union;
    }
    return false;
}

fn reflectionStringSpans(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
) ![]const std.zig.Token.Loc {
    const tokens = try tokenize(allocator, source);
    var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or
            (!std.mem.eql(u8, source[token.loc.start..token.loc.end], "@field") and
                !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@hasField") and
                !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@hasDecl"))) continue;
        if (index + 5 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        const closing = matchingSyntaxToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        var comma = index + 2;
        while (comma < closing and tokens[comma].tag != .comma) : (comma += 1) {}
        if (comma + 1 >= closing or tokens[comma + 1].tag != .string_literal) continue;
        const literal = source[tokens[comma + 1].loc.start..tokens[comma + 1].loc.end];
        if (literal.len < 2 or !std.mem.eql(u8, literal[1 .. literal.len - 1], name)) continue;
        try spans.append(allocator, .{
            .start = tokens[comma + 1].loc.start + 1,
            .end = tokens[comma + 1].loc.end - 1,
        });
    }
    return try spans.toOwnedSlice(allocator);
}

fn suggestedStyleName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
    rule: analysis.Rule,
) !?[]const u8 {
    const name = source[declaration_span.start..declaration_span.end];
    return switch (rule) {
        .non_idiomatic_name => try suggestedDeclarationName(allocator, source, declaration_span),
        .underscore_private_name => if (name.len > 1) try allocator.dupe(u8, name[1..]) else null,
        .redundant_qualified_name => try redundantQualifiedSuggestion(allocator, source, declaration_span),
        else => null,
    };
}

fn redundantQualifiedSuggestion(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    const declaration_index = for (tokens, 0..) |token, index| {
        if (std.meta.eql(token.loc, declaration_span)) break index;
    } else return null;
    var cursor = declaration_index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        if (cursor < 4 or tokens[cursor - 1].tag != .keyword_struct or tokens[cursor - 2].tag != .equal or
            tokens[cursor - 3].tag != .identifier or tokens[cursor - 4].tag != .keyword_const) return null;
        const namespace_name = source[tokens[cursor - 3].loc.start..tokens[cursor - 3].loc.end];
        const declaration_name = source[declaration_span.start..declaration_span.end];
        if (declaration_name.len <= namespace_name.len) return null;
        return try allocator.dupe(u8, declaration_name[namespace_name.len..]);
    }
    return null;
}

fn suggestedDeclarationName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
) !?[]const u8 {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    const index = for (tokens.items, 0..) |token, token_index| {
        if (std.meta.eql(token.loc, declaration_span)) break token_index;
    } else return null;
    if (index == 0) return null;
    const name = source[declaration_span.start..declaration_span.end];
    const convention: enum { camel, title, snake } = convention: {
        switch (tokens.items[index - 1].tag) {
            .keyword_fn => {
                if (index + 1 < tokens.items.len and tokens.items[index + 1].tag == .l_paren) {
                    const parameters_end = matchingSyntaxToken(tokens.items, index + 1, .l_paren, .r_paren) orelse break :convention .camel;
                    if (parameters_end + 1 < tokens.items.len and
                        std.mem.eql(u8, source[tokens.items[parameters_end + 1].loc.start..tokens.items[parameters_end + 1].loc.end], "type"))
                    {
                        break :convention .title;
                    }
                }
                break :convention .camel;
            },
            .keyword_const => {
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .builtin and tokens.items[index + 3].tag == .l_paren)
                {
                    const builtin_name = source[tokens.items[index + 2].loc.start..tokens.items[index + 2].loc.end];
                    const type_builtins = [_][]const u8{
                        "@TypeOf", "@Type", "@Int", "@Enum", "@Union", "@Struct", "@Pointer", "@Array", "@Vector", "@Fn", "@Tuple",
                    };
                    for (type_builtins) |type_builtin| {
                        if (std.mem.eql(u8, builtin_name, type_builtin)) break :convention .title;
                    }
                    if (std.mem.eql(u8, builtin_name, "@typeInfo")) {
                        var cursor = index + 3;
                        while (cursor < tokens.items.len and tokens.items[cursor].tag != .semicolon) : (cursor += 1) {
                            if (tokens.items[cursor].tag != .identifier or cursor == 0 or tokens.items[cursor - 1].tag != .period) continue;
                            const field_name = source[tokens.items[cursor].loc.start..tokens.items[cursor].loc.end];
                            const type_fields = [_][]const u8{ "child", "payload", "error_set", "return_type", "tag_type" };
                            for (type_fields) |type_field| {
                                if (std.mem.eql(u8, field_name, type_field)) break :convention .title;
                            }
                        }
                    }
                }
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    (tokens.items[index + 2].tag == .keyword_extern or tokens.items[index + 2].tag == .keyword_packed) and
                    switch (tokens.items[index + 3].tag) {
                        .keyword_struct, .keyword_union => true,
                        else => false,
                    }) break :convention .title;
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .keyword_struct and tokens.items[index + 3].tag == .l_brace)
                {
                    const closing = matchingSyntaxToken(tokens.items, index + 3, .l_brace, .r_brace) orelse break :convention .title;
                    var has_field = false;
                    for (tokens.items[index + 4 .. closing], index + 4..) |candidate, candidate_index| {
                        if (candidate.tag == .identifier and candidate_index + 1 < closing and
                            tokens.items[candidate_index + 1].tag == .colon)
                        {
                            has_field = true;
                            break;
                        }
                    }
                    break :convention if (has_field) .title else .snake;
                }
                if (index + 2 < tokens.items.len and tokens.items[index + 1].tag == .equal and switch (tokens.items[index + 2].tag) {
                    .keyword_union, .keyword_enum, .keyword_opaque => true,
                    else => false,
                }) break :convention .title;
                if (index + 2 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .identifier)
                {
                    const target_name = source[tokens.items[index + 2].loc.start..tokens.items[index + 2].loc.end];
                    for (tokens.items, 0..) |candidate, candidate_index| {
                        if (candidate.tag != .identifier or candidate_index == 0 or candidate_index + 2 >= tokens.items.len or
                            tokens.items[candidate_index - 1].tag != .keyword_const or
                            !std.mem.eql(u8, source[candidate.loc.start..candidate.loc.end], target_name) or
                            tokens.items[candidate_index + 1].tag != .equal) continue;
                        if (switch (tokens.items[candidate_index + 2].tag) {
                            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => true,
                            else => false,
                        }) break :convention .title;
                    }
                }
                break :convention .snake;
            },
            .keyword_var => break :convention .snake,
            else => return null,
        }
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    switch (convention) {
        .camel => {
            var words = std.mem.splitScalar(u8, name, '_');
            var word_index: usize = 0;
            while (words.next()) |word| {
                if (word.len == 0) continue;
                if (word_index == 0) {
                    try writer.writer.writeAll(word);
                } else {
                    try writer.writer.writeByte(std.ascii.toUpper(word[0]));
                    try writer.writer.writeAll(word[1..]);
                }
                word_index += 1;
            }
        },
        .title => {
            var capitalize = true;
            for (name) |character| {
                if (character == '_') {
                    capitalize = true;
                    continue;
                }
                try writer.writer.writeByte(if (capitalize) std.ascii.toUpper(character) else character);
                capitalize = false;
            }
        },
        .snake => for (name, 0..) |character, character_index| {
            if (std.ascii.isUpper(character)) {
                if (character_index != 0) try writer.writer.writeByte('_');
                try writer.writer.writeByte(std.ascii.toLower(character));
            } else {
                try writer.writer.writeByte(character);
            }
        },
    }
    const suggestion = try writer.toOwnedSlice();
    if (suggestion.len == 0 or std.mem.eql(u8, suggestion, name) or !isIdentifier(suggestion)) return null;
    return suggestion;
}

fn deduplicateAndSortDiagnostics(diagnostics: []lsp.types.Diagnostic) usize {
    std.mem.sort(lsp.types.Diagnostic, diagnostics, {}, struct {
        fn lessThan(_: void, left: lsp.types.Diagnostic, right: lsp.types.Diagnostic) bool {
            if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
            if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
            return std.mem.lessThan(u8, left.message, right.message);
        }
    }.lessThan);
    if (diagnostics.len < 2) return diagnostics.len;
    var write_index: usize = 1;
    for (diagnostics[1..]) |diagnostic| {
        const previous = diagnostics[write_index - 1];
        if (std.meta.eql(previous.range, diagnostic.range) and std.mem.eql(u8, previous.message, diagnostic.message)) {
            if (previous.relatedInformation == null and diagnostic.relatedInformation != null) {
                diagnostics[write_index - 1] = diagnostic;
            }
            continue;
        }
        diagnostics[write_index] = diagnostic;
        write_index += 1;
    }
    return write_index;
}

fn syntaxDiagnostics(document: *const Document, allocator: std.mem.Allocator) ![]lsp.types.Diagnostic {
    const diagnostics = try allocator.alloc(lsp.types.Diagnostic, document.tree.errors.len);
    for (document.tree.errors, diagnostics) |parse_error, *diagnostic| {
        var message: std.Io.Writer.Allocating = .init(allocator);
        defer message.deinit();
        try document.tree.renderError(parse_error, &message.writer);
        const token_index = parse_error.token + @intFromBool(parse_error.token_is_prev);
        const start = document.tree.tokenStart(token_index);
        const end = start + document.tree.tokenSlice(token_index).len;
        diagnostic.* = .{
            .range = document.range(.{ .start = start, .end = end }),
            .severity = if (parse_error.is_note) .Information else .Error,
            .code = .{ .string = "syntax-error" },
            .source = "zig-analyzer parser",
            .message = try message.toOwnedSlice(),
        };
    }
    return diagnostics;
}

pub fn compilerDiagnostics(
    document: *const Document,
    bundle: std.zig.ErrorBundle,
    allocator: std.mem.Allocator,
) ![]lsp.types.Diagnostic {
    if (bundle.errorMessageCount() == 0) return &.{};
    const document_path = try filePathFromUri(allocator, document.uri) orelse return &.{};
    defer allocator.free(document_path);
    const absolute_document_path = try std.fs.path.resolve(allocator, &.{document_path});
    defer allocator.free(absolute_document_path);
    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;
    for (bundle.getMessages()) |message_index| {
        const error_message = bundle.getErrorMessage(message_index);
        if (error_message.src_loc == .none) continue;
        const source_location = bundle.getSourceLocation(error_message.src_loc);
        const source_path = bundle.nullTerminatedString(source_location.src_path);
        if (!try sourcePathMatchesDocument(allocator, source_path, absolute_document_path)) continue;

        const line_start = lineStartOffset(document.source, source_location.line) orelse continue;
        const before_main = source_location.span_main -| source_location.span_start;
        const start_column = source_location.column -| before_main;
        const span_length = @max(source_location.span_end -| source_location.span_start, 1);
        const start = @min(line_start + start_column, document.source.len);
        const end = @min(start + span_length, document.source.len);
        var related: std.ArrayList(lsp.types.Diagnostic.RelatedInformation) = .empty;
        for (bundle.getNotes(message_index)) |note_index| {
            const note = bundle.getErrorMessage(note_index);
            if (note.src_loc == .none) continue;
            const note_location = bundle.getSourceLocation(note.src_loc);
            const note_path = bundle.nullTerminatedString(note_location.src_path);
            const note_range, const note_uri = if (try sourcePathMatchesDocument(allocator, note_path, absolute_document_path)) same: {
                const note_line_start = lineStartOffset(document.source, note_location.line) orelse continue;
                const note_before_main = note_location.span_main -| note_location.span_start;
                const note_start_column = note_location.column -| note_before_main;
                const note_start = @min(note_line_start + note_start_column, document.source.len);
                const note_end = @min(note_start + @max(note_location.span_end -| note_location.span_start, 1), document.source.len);
                break :same .{
                    document.range(.{ .start = note_start, .end = note_end }),
                    try allocator.dupe(u8, document.uri),
                };
            } else .{
                lsp.types.Range{
                    .start = .{ .line = note_location.line, .character = note_location.column },
                    .end = .{ .line = note_location.line, .character = note_location.column + 1 },
                },
                try std.fmt.allocPrint(allocator, "file://{s}", .{note_path}),
            };
            try related.append(allocator, .{
                .location = .{ .uri = note_uri, .range = note_range },
                .message = try allocator.dupe(u8, bundle.nullTerminatedString(note.msg)),
            });
        }
        try diagnostics.append(allocator, .{
            .range = document.range(.{ .start = start, .end = end }),
            .severity = .Error,
            .code = .{ .string = "compiler-error" },
            .source = "zig compiler",
            .message = try allocator.dupe(u8, bundle.nullTerminatedString(error_message.msg)),
            .relatedInformation = if (related.items.len == 0) null else try related.toOwnedSlice(allocator),
        });
    }
    return try diagnostics.toOwnedSlice(allocator);
}

fn sourcePathMatchesDocument(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    absolute_document_path: []const u8,
) !bool {
    if (!std.fs.path.isAbsolute(source_path)) {
        if (!std.mem.endsWith(u8, absolute_document_path, source_path)) return false;
        const prefix_length = absolute_document_path.len - source_path.len;
        return prefix_length == 0 or std.fs.path.isSep(absolute_document_path[prefix_length - 1]);
    }
    const absolute_source_path = try std.fs.path.resolve(allocator, &.{source_path});
    defer allocator.free(absolute_source_path);
    return std.mem.eql(u8, absolute_document_path, absolute_source_path);
}

fn lineStartOffset(source: []const u8, target_line: u32) ?usize {
    var line: u32 = 0;
    var offset: usize = 0;
    while (line < target_line) {
        const newline = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return null;
        offset = newline + 1;
        line += 1;
    }
    return offset;
}

fn declarationAtPosition(document: *const Document, position: lsp.types.Position) ?Declaration {
    const identifier_span = document.identifierAt(document.byteOffset(position)) orelse return null;
    return document.declarationNamed(document.source[identifier_span.start..identifier_span.end]);
}

fn declarationKindName(kind: Declaration.Kind) []const u8 {
    return switch (kind) {
        .constant => "const",
        .variable => "var",
        .function => "fn",
    };
}

fn completionKind(kind: Declaration.Kind) lsp.types.completion.Item.Kind {
    return switch (kind) {
        .constant => .Constant,
        .variable => .Variable,
        .function => .Function,
    };
}

fn symbolKind(kind: Declaration.Kind) lsp.types.SymbolKind {
    return switch (kind) {
        .constant => .Constant,
        .variable => .Variable,
        .function => .Function,
    };
}

const semantic_token_types: []const []const u8 = &.{
    "variable",
    "function",
    "keyword",
    "comment",
    "string",
    "number",
    "macro",
};
const semantic_token_modifiers: []const []const u8 = &.{ "declaration", "readonly", "static" };

fn semanticTokens(
    document: *const Document,
    allocator: std.mem.Allocator,
    requested_range: ?lsp.types.Range,
) ![]u32 {
    var encoded: std.ArrayList(u32) = .empty;
    var previous_line: u32 = 0;
    var previous_character: u32 = 0;
    var tokenizer = std.zig.Tokenizer.init(document.source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const token_type = semanticTokenType(document, token) orelse continue;
        const range = document.range(token.loc);
        if (range.start.line != range.end.line) continue;
        if (requested_range) |limit| {
            if (range.end.line < limit.start.line or range.start.line > limit.end.line) continue;
            if (range.end.line == limit.start.line and range.end.character < limit.start.character) continue;
            if (range.start.line == limit.end.line and range.start.character > limit.end.character) continue;
        }
        const delta_line = range.start.line - previous_line;
        const delta_character = if (delta_line == 0)
            range.start.character - previous_character
        else
            range.start.character;
        try encoded.appendSlice(allocator, &.{
            delta_line,
            delta_character,
            range.end.character - range.start.character,
            token_type,
            semanticTokenModifiers(document, token),
        });
        previous_line = range.start.line;
        previous_character = range.start.character;
    }
    return try encoded.toOwnedSlice(allocator);
}

fn typeInlayHints(
    document: *const Document,
    allocator: std.mem.Allocator,
    requested_range: lsp.types.Range,
) ![]const lsp.types.InlayHint {
    var hints: std.ArrayList(lsp.types.InlayHint) = .empty;
    var tokenizer = std.zig.Tokenizer.init(document.source);
    while (true) {
        const declaration_token = tokenizer.next();
        if (declaration_token.tag == .eof) break;
        if (declaration_token.tag != .keyword_const and declaration_token.tag != .keyword_var) continue;
        const name_token = tokenizer.next();
        if (name_token.tag != .identifier) continue;
        if (tokenizer.next().tag != .equal) continue;
        const value_token = tokenizer.next();
        const label = inferredTypeLabel(document.source[value_token.loc.start..value_token.loc.end], value_token.tag) orelse continue;
        const position = document.range(name_token.loc).end;
        if (position.line < requested_range.start.line or position.line > requested_range.end.line) continue;
        if (position.line == requested_range.start.line and position.character < requested_range.start.character) continue;
        if (position.line == requested_range.end.line and position.character > requested_range.end.character) continue;
        try hints.append(allocator, .{
            .position = position,
            .label = .{ .string = label },
            .kind = .Type,
            .paddingLeft = true,
        });
    }
    const tokens = try tokenize(allocator, document.source);
    defer allocator.free(tokens);
    for (tokens, 0..) |token, enum_index| {
        if (token.tag != .keyword_enum) continue;
        var opening = enum_index + 1;
        if (opening < tokens.len and tokens[opening].tag == .l_paren) {
            opening = (matchingSyntaxToken(tokens, opening, .l_paren, .r_paren) orelse continue) + 1;
        }
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = matchingSyntaxToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        var next_value: i128 = 0;
        var value_known = true;
        var cursor = opening + 1;
        while (cursor < closing) : (cursor += 1) {
            if (tokens[cursor].tag != .identifier or cursor > opening + 1 and switch (tokens[cursor - 1].tag) {
                .comma, .doc_comment, .container_doc_comment => false,
                else => true,
            }) continue;
            if (std.mem.eql(u8, document.source[tokens[cursor].loc.start..tokens[cursor].loc.end], "_")) continue;
            if (cursor + 1 < closing and tokens[cursor + 1].tag == .equal) {
                if (cursor + 2 < closing and tokens[cursor + 2].tag == .number_literal) {
                    next_value = std.fmt.parseInt(i128, document.source[tokens[cursor + 2].loc.start..tokens[cursor + 2].loc.end], 0) catch {
                        value_known = false;
                        continue;
                    };
                    next_value += 1;
                    value_known = true;
                } else value_known = false;
                continue;
            }
            if (!value_known) continue;
            const position = document.range(tokens[cursor].loc).end;
            if (!positionInRange(position, requested_range)) continue;
            try hints.append(allocator, .{
                .position = position,
                .label = .{ .string = try std.fmt.allocPrint(allocator, " = {d}", .{next_value}) },
                .kind = .Type,
                .paddingLeft = true,
            });
            next_value += 1;
        }
    }
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= tokens.len or tokens[fn_index + 1].tag != .identifier or
            tokens[fn_index + 2].tag != .l_paren) continue;
        const function_name = document.source[tokens[fn_index + 1].loc.start..tokens[fn_index + 1].loc.end];
        const parameters_end = matchingSyntaxToken(tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        var ordinal: usize = 0;
        var parameter_cursor = fn_index + 3;
        var nested_depth: usize = 0;
        while (parameter_cursor < parameters_end) : (parameter_cursor += 1) {
            switch (tokens[parameter_cursor].tag) {
                .l_paren, .l_brace, .l_bracket => nested_depth += 1,
                .r_paren, .r_brace, .r_bracket => nested_depth -|= 1,
                .comma => if (nested_depth == 0) {
                    ordinal += 1;
                },
                .keyword_comptime => {
                    if (nested_depth != 0 or parameter_cursor + 1 >= parameters_end or
                        tokens[parameter_cursor + 1].tag != .identifier) continue;
                    const parameter_name = document.source[tokens[parameter_cursor + 1].loc.start..tokens[parameter_cursor + 1].loc.end];
                    for (tokens, 0..) |call_token, call_index| {
                        if (call_token.tag != .identifier or !std.mem.eql(u8, document.source[call_token.loc.start..call_token.loc.end], function_name) or
                            call_index + 1 >= tokens.len or tokens[call_index + 1].tag != .l_paren or
                            call_index > 0 and tokens[call_index - 1].tag == .keyword_fn) continue;
                        const argument_index = callArgumentToken(tokens, call_index + 1, ordinal) orelse continue;
                        const position = document.range(tokens[argument_index].loc).start;
                        if (!positionInRange(position, requested_range)) continue;
                        try hints.append(allocator, .{
                            .position = position,
                            .label = .{ .string = try std.fmt.allocPrint(allocator, "{s}:", .{parameter_name}) },
                            .kind = .Parameter,
                            .paddingRight = true,
                        });
                    }
                },
                else => {},
            }
        }
    }
    return try hints.toOwnedSlice(allocator);
}

fn callArgumentToken(tokens: []const std.zig.Token, opening: usize, requested_ordinal: usize) ?usize {
    const closing = matchingSyntaxToken(tokens, opening, .l_paren, .r_paren) orelse return null;
    var ordinal: usize = 0;
    var nested_depth: usize = 0;
    var cursor = opening + 1;
    while (cursor < closing) : (cursor += 1) {
        if (ordinal == requested_ordinal and nested_depth == 0 and tokens[cursor].tag != .comma) return cursor;
        switch (tokens[cursor].tag) {
            .l_paren, .l_brace, .l_bracket => nested_depth += 1,
            .r_paren, .r_brace, .r_bracket => nested_depth -|= 1,
            .comma => if (nested_depth == 0) {
                ordinal += 1;
            },
            else => {},
        }
    }
    return null;
}

fn positionInRange(position: lsp.types.Position, range: lsp.types.Range) bool {
    if (position.line < range.start.line or position.line > range.end.line) return false;
    if (position.line == range.start.line and position.character < range.start.character) return false;
    if (position.line == range.end.line and position.character > range.end.character) return false;
    return true;
}

fn inferredTypeLabel(source: []const u8, tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (tag) {
        .number_literal => ": comptime_int",
        .string_literal, .multiline_string_literal_line => ": []const u8",
        .char_literal => ": u8",
        .identifier => if (std.mem.eql(u8, source, "true") or std.mem.eql(u8, source, "false")) ": bool" else null,
        else => null,
    };
}

fn semanticTokenType(document: *const Document, token: std.zig.Token) ?u32 {
    if (token.tag == .identifier) {
        if (document.declarationNamed(document.source[token.loc.start..token.loc.end])) |declaration| {
            return if (declaration.kind == .function) 1 else 0;
        }
        return 0;
    }
    if (token.tag == .builtin) return 6;
    if (token.tag == .doc_comment or token.tag == .container_doc_comment) return 3;
    if (token.tag == .string_literal or token.tag == .multiline_string_literal_line or token.tag == .char_literal) return 4;
    if (token.tag == .number_literal) return 5;
    if (std.mem.startsWith(u8, @tagName(token.tag), "keyword_")) return 2;
    return null;
}

fn semanticTokenModifiers(document: *const Document, token: std.zig.Token) u32 {
    var modifiers: u32 = @intFromBool(isDeclarationSpan(document, token.loc));
    if (token.tag != .identifier) return modifiers;
    const declaration = document.declarationNamed(document.source[token.loc.start..token.loc.end]) orelse return modifiers;
    if (!std.meta.eql(declaration.span, token.loc) or declaration.kind != .constant) return modifiers;
    modifiers |= 1 << 1;
    const line_end = std.mem.indexOfScalarPos(u8, document.source, token.loc.end, '\n') orelse document.source.len;
    const declaration_tail = std.mem.trim(u8, document.source[token.loc.end..line_end], " \t\r");
    const equal = std.mem.indexOfScalar(u8, declaration_tail, '=') orelse return modifiers;
    const initializer = std.mem.trim(u8, declaration_tail[equal + 1 ..], " \t\r");
    if (initializer.len != 0 and (std.ascii.isDigit(initializer[0]) or initializer[0] == '\'' or initializer[0] == '"' or
        std.mem.startsWith(u8, initializer, "true") or std.mem.startsWith(u8, initializer, "false")))
    {
        modifiers |= 1 << 2;
    }
    return modifiers;
}

fn isDeclarationSpan(document: *const Document, span: std.zig.Token.Loc) bool {
    for (document.declarations) |declaration| {
        if (std.meta.eql(declaration.span, span)) return true;
    }
    return false;
}

fn declarationBaseName(fully_qualified_name: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, fully_qualified_name, '.') orelse return fully_qualified_name;
    return fully_qualified_name[separator + 1 ..];
}

fn isRelatedCompilerDeclaration(document: *const Document, fully_qualified_name: []const u8) bool {
    for (document.declarations) |declaration| {
        if (declaration.brace_depth != 0 or declaration.name.len < 3) continue;
        if (std.mem.eql(u8, declaration.name, "std")) continue;
        if (std.mem.indexOf(u8, fully_qualified_name, declaration.name) != null) return true;
    }
    return false;
}

const CallContext = struct {
    name: []const u8,
    active_parameter: u32,
};

fn callAt(source: []const u8, byte_offset: usize) ?CallContext {
    if (byte_offset > source.len) return null;
    var nesting: u32 = 0;
    var cursor = byte_offset;
    while (cursor > 0) {
        cursor -= 1;
        switch (source[cursor]) {
            ')' => nesting += 1,
            '(' => {
                if (nesting != 0) {
                    nesting -= 1;
                    continue;
                }
                var name_end = cursor;
                while (name_end > 0 and std.ascii.isWhitespace(source[name_end - 1])) name_end -= 1;
                var name_start = name_end;
                while (name_start > 0 and isIdentifierByte(source[name_start - 1])) name_start -= 1;
                if (name_start == name_end) return null;
                var active_parameter: u32 = 0;
                var argument_nesting: u32 = 0;
                for (source[cursor + 1 .. byte_offset]) |byte| switch (byte) {
                    '(', '[', '{' => argument_nesting += 1,
                    ')', ']', '}' => argument_nesting -|= 1,
                    ',' => if (argument_nesting == 0) {
                        active_parameter += 1;
                    },
                    else => {},
                };
                return .{ .name = source[name_start..name_end], .active_parameter = active_parameter };
            },
            else => {},
        }
    }
    return null;
}

fn functionSignature(source: [:0]const u8, name: []const u8) ?[]const u8 {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const function_token = tokenizer.next();
        if (function_token.tag == .eof) return null;
        if (function_token.tag != .keyword_fn) continue;
        const name_token = tokenizer.next();
        if (name_token.tag != .identifier) continue;
        if (!std.mem.eql(u8, source[name_token.loc.start..name_token.loc.end], name)) continue;
        var nesting: u32 = 0;
        var found_parameters = false;
        while (true) {
            const token = tokenizer.next();
            switch (token.tag) {
                .l_paren => {
                    nesting += 1;
                    found_parameters = true;
                },
                .r_paren => {
                    nesting -|= 1;
                    if (found_parameters and nesting == 0) {
                        return source[function_token.loc.start..token.loc.end];
                    }
                },
                .eof => return null,
                else => {},
            }
        }
    }
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    var source_buffer: [256:0]u8 = undefined;
    if (name.len > source_buffer.len) return false;
    @memcpy(source_buffer[0..name.len], name);
    source_buffer[name.len] = 0;
    var tokenizer = std.zig.Tokenizer.init(source_buffer[0..name.len :0]);
    const identifier = tokenizer.next();
    return identifier.tag == .identifier and identifier.loc.end == name.len and tokenizer.next().tag == .eof;
}

fn formatSource(io: std.Io, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const zig_binary = if (try pathExists(io, backend_bootstrap.backend_binary))
        backend_bootstrap.backend_binary
    else
        "zig";
    var child = try std.process.spawn(io, .{
        .argv = &.{ zig_binary, "fmt", "--stdin" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, source);
    child.stdin.?.close(io);
    child.stdin = null;

    var stdout_reader = child.stdout.?.readerStreaming(io, &.{});
    const formatted = try stdout_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(formatted);
    var stderr_reader = child.stderr.?.readerStreaming(io, &.{});
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(stderr);

    const term = try child.wait(io);
    const succeeded = switch (term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
    if (!succeeded) {
        std.log.err("Zig formatter failed: {s}", .{stderr});
        return error.FormattingFailed;
    }
    return formatted;
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn filePathFromUri(allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const encoded_path = uri[prefix.len..];
    const buffer = try allocator.alloc(u8, encoded_path.len);
    return std.Uri.percentDecodeBackwards(buffer, encoded_path);
}

test "syntax diagnostics describe malformed source" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const broken =");
    defer document.deinit();
    const diagnostics = try syntaxDiagnostics(&document, std.testing.allocator);
    defer {
        for (diagnostics) |diagnostic| std.testing.allocator.free(diagnostic.message);
        std.testing.allocator.free(diagnostics);
    }
    try std.testing.expect(diagnostics.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "expected") != null);
}

test "hover descriptions cover fields and loop captures" {
    const source = "const Entry = struct { value: u32 }; fn run(values: []const u32) void { for (values) |value| { _ = value; } }";
    const field = (try describeTypedMemberNamed(std.testing.allocator, source, "value")).?;
    try std.testing.expectEqualStrings("value: u32", field.declaration);
    try std.testing.expectEqualStrings("u32", field.type_summary.?);

    const source_z = try std.testing.allocator.dupeZ(u8, source);
    defer std.testing.allocator.free(source_z);
    const tokens = try tokenize(std.testing.allocator, source_z);
    defer std.testing.allocator.free(tokens);
    const capture_index = for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and token.loc.start > 80 and
            std.mem.eql(u8, source[token.loc.start..token.loc.end], "value")) break index;
    } else unreachable;
    const capture = (try describeCaptureBinding(std.testing.allocator, source, tokens, capture_index)).?;
    defer std.testing.allocator.free(capture.declaration);
    try std.testing.expectEqualStrings("value: u32", capture.declaration);
    try std.testing.expectEqualStrings("u32", capture.type_summary.?);

    const enum_tag = (try describeEnumTagNamed(
        std.testing.allocator,
        "const Stage = enum { buffered, traced };",
        "buffered",
    )).?;
    defer std.testing.allocator.free(enum_tag.declaration);
    try std.testing.expectEqualStrings(".buffered", enum_tag.declaration);
    try std.testing.expectEqualStrings("Stage", enum_tag.type_summary.?);
}

test "rename names must be Zig identifiers" {
    try std.testing.expect(isIdentifier("generated_value"));
    try std.testing.expect(!isIdentifier("generated-value"));
    try std.testing.expect(!isIdentifier(""));
}

test "formatting returns the Zig formatter result" {
    const formatted = try formatSource(std.testing.io, std.testing.allocator, "const answer=42;\n");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("const answer = 42;\n", formatted);
}

test "LSP formatting delegates to zig fmt without applying lint fixes" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///format.zig","languageId":"zig","version":1,"text":"fn run(enabled:bool)void{var value=if(enabled)true else false;_=value;}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///format.zig"},"options":{"tabSize":4,"insertSpaces":true}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "var value = if (enabled) true else false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "const value") == null);
}

test "late allocation cleanup action moves the existing defer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: anytype) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 16);\n" ++
        "    try initialize(buffer);\n" ++
        "    defer finishOtherWork(buffer);\n" ++
        "    defer allocator.free(buffer);\n" ++
        "}\n";
    const binding_start = std.mem.indexOf(u8, source, "buffer =") orelse unreachable;
    const edits = (try moveCleanupAfterAcquisition(arena_state.allocator(), source, .{
        .start = binding_start,
        .end = binding_start + "buffer".len,
    })).?;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expect(std.mem.indexOf(u8, edits[0].replacement, "defer allocator.free(buffer);") != null);
    try std.testing.expectEqualStrings("", edits[1].replacement);
    try std.testing.expect(std.mem.indexOf(u8, source[edits[1].span.start..edits[1].span.end], "finishOtherWork") == null);
}

test "late resource cleanup action moves close after acquisition" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 =
        "fn run(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    try validate();\n" ++
        "    defer file.close();\n" ++
        "}\n";
    const binding_start = std.mem.indexOf(u8, source, "file =") orelse unreachable;
    const edits = (try moveCleanupAfterAcquisition(arena_state.allocator(), source, .{
        .start = binding_start,
        .end = binding_start + "file".len,
    })).?;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expect(std.mem.indexOf(u8, edits[0].replacement, "defer file.close();") != null);
    try std.testing.expectEqualStrings("", edits[1].replacement);
}

test "semantic tokens encode keywords declarations and numbers" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const answer = 42;\n",
    );
    defer document.deinit();
    const encoded = try semanticTokens(&document, std.testing.allocator, null);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u32, &.{
        0, 0, 5, 2, 0,
        0, 6, 6, 0, 7,
        0, 9, 2, 5, 0,
    }, encoded);
}

test "signature help finds the active argument" {
    const source: [:0]const u8 = "fn add(left: u32, right: u32) u32 { return left + right; }\nconst sum = add(1, 2);\n";
    const second_argument = std.mem.indexOf(u8, source, "2);").? + 1;
    const call = callAt(source, second_argument).?;
    try std.testing.expectEqualStrings("add", call.name);
    try std.testing.expectEqual(@as(u32, 1), call.active_parameter);
    try std.testing.expectEqualStrings("fn add(left: u32, right: u32)", functionSignature(source, call.name).?);
}

test "inlay hints report obvious literal types" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const answer = 42;\nconst enabled = true;\n",
    );
    defer document.deinit();
    const hints = try typeInlayHints(&document, std.testing.allocator, .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 1, .character = 21 },
    });
    defer std.testing.allocator.free(hints);
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqualStrings(": comptime_int", hints[0].label.string);
    try std.testing.expectEqualStrings(": bool", hints[1].label.string);
}

test "enum inlay hints expose implicit integer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.open(
        arena.allocator(),
        "file:///fixture.zig",
        1,
        "const Mode = enum { idle, busy = 4, done };\n",
    );
    defer document.deinit();
    const hints = try typeInlayHints(&document, arena.allocator(), .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 45 },
    });
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqualStrings(" = 0", hints[0].label.string);
    try std.testing.expectEqualStrings(" = 5", hints[1].label.string);
}

test "comptime calls show parameter-name hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var document = try Document.open(
        arena.allocator(),
        "file:///fixture.zig",
        1,
        "fn Matrix(comptime Element: type, comptime size: usize) type { return [size]Element; }\nconst M = Matrix(u32, 3);\n",
    );
    defer document.deinit();
    const hints = try typeInlayHints(&document, arena.allocator(), .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 25 },
    });
    try std.testing.expectEqual(@as(usize, 2), hints.len);
    try std.testing.expectEqualStrings("Element:", hints[0].label.string);
    try std.testing.expectEqualStrings("size:", hints[1].label.string);
}

test "format and import string contexts are recognized precisely" {
    const format_source: [:0]const u8 = "std.debug.print(\"value {}\", .{42});\n";
    const format_offset = std.mem.indexOf(u8, format_source, "{}") orelse unreachable;
    try std.testing.expect(formatStringAt(format_source, format_offset + 1));
    try std.testing.expect(!formatStringAt(format_source, format_source.len));

    const import_source: [:0]const u8 = "const module = @import(\"dir/mod\");\n";
    const import_offset = std.mem.indexOf(u8, import_source, "dir/mod") orelse unreachable;
    try std.testing.expectEqualStrings("dir/mo", importStringPrefix(import_source, import_offset + "dir/mo".len).?);
}

test "reflection string spans participate in field rename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32 };\n" ++
        "fn inspect(state: State) void { _ = @field(state, \"value\"); _ = @hasField(State, \"value\"); }\n";
    const spans = try reflectionStringSpans(arena.allocator(), source, "value");
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    for (spans) |span| try std.testing.expectEqualStrings("value", source[span.start..span.end]);
}

test "field rename classification excludes typed locals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32 };\n" ++
        "const Event = union(enum) { ready: u32 };\n" ++
        "fn inspect() void { var local: u32 = 1; _ = local; }\n";
    const struct_field_start = std.mem.indexOf(u8, source, "value: u32") orelse unreachable;
    const union_field_start = std.mem.indexOf(u8, source, "ready: u32") orelse unreachable;
    const local_start = std.mem.indexOf(u8, source, "local: u32") orelse unreachable;

    try std.testing.expect(try isContainerField(arena.allocator(), source, .{
        .start = struct_field_start,
        .end = struct_field_start + "value".len,
    }));
    try std.testing.expect(try isContainerField(arena.allocator(), source, .{
        .start = union_field_start,
        .end = union_field_start + "ready".len,
    }));
    try std.testing.expect(!try isContainerField(arena.allocator(), source, .{
        .start = local_start,
        .end = local_start + "local".len,
    }));
}

test "style rename preserves type-producing declaration semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const inferred_type = @TypeOf(1);\n" ++
        "const reflected_type = @typeInfo(@TypeOf(make)).@\"fn\".return_type.?;\n" ++
        "const external_state = extern struct { value: u32 };\n";
    const inferred_start = std.mem.indexOf(u8, source, "inferred_type") orelse unreachable;
    const reflected_start = std.mem.indexOf(u8, source, "reflected_type") orelse unreachable;
    const external_start = std.mem.indexOf(u8, source, "external_state") orelse unreachable;

    const inferred_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = inferred_start,
        .end = inferred_start + "inferred_type".len,
    })).?;
    const external_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = external_start,
        .end = external_start + "external_state".len,
    })).?;
    const reflected_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = reflected_start,
        .end = reflected_start + "reflected_type".len,
    })).?;
    try std.testing.expectEqualStrings("InferredType", inferred_name);
    try std.testing.expectEqualStrings("ReflectedType", reflected_name);
    try std.testing.expectEqualStrings("ExternalState", external_name);
}

test "fix-all edits keep same-position insertions in input order and drop overlaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const survivors = try nonOverlappingEdits(arena, &.{
        .{ .span = .{ .start = 5, .end = 9 }, .replacement = "replacement" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "first insertion" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "first insertion" },
        .{ .span = .{ .start = 3, .end = 3 }, .replacement = "second insertion" },
        .{ .span = .{ .start = 7, .end = 12 }, .replacement = "overlaps the replacement" },
    });

    try std.testing.expectEqual(@as(usize, 3), survivors.len);
    try std.testing.expectEqualStrings("first insertion", survivors[0].replacement);
    try std.testing.expectEqualStrings("second insertion", survivors[1].replacement);
    try std.testing.expectEqualStrings("replacement", survivors[2].replacement);
}

test "member resolution finds explicit struct fields" {
    const source: [:0]const u8 =
        "const Profile = struct { display_name: []const u8, login_count: u32 };\n" ++
        "fn show(profile: Profile) []const u8 { return profile.display_name; }\n";
    const receiver_offset = std.mem.indexOf(u8, source, "profile.").? + "profile.".len;
    try std.testing.expectEqualStrings("profile", memberReceiver(source, receiver_offset).?);
    const type_name = (try declaredTypeName(std.testing.allocator, source, "profile")).?;
    try std.testing.expectEqualStrings("Profile", type_name);
    const members = try structMembers(std.testing.allocator, source, type_name);
    defer std.testing.allocator.free(members);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("display_name", members[0].name);
    try std.testing.expectEqualStrings("login_count", members[1].name);
}

test "module resolution returns only public declarations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        "pub const default_limit: u32 = 42;\n" ++
        "const private_limit: u32 = 7;\n" ++
        "pub fn clampToLimit(value: u32) u32 { return value; }\n";
    const members = try publicModuleMembers(arena_state.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("default_limit", members[0].name);
    try std.testing.expectEqualStrings("clampToLimit", members[1].name);
}

test "module diagnostics report only missing public members" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const catalog = @import(\"catalog.zig\");\n" ++
        "fn result() u32 { _ = catalog.default_limit; return catalog.missingLimit; }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();
    try server.documents.open("file://examples/zls/imports/main.zig", 1, source);
    const document = server.documents.getConst("file://examples/zls/imports/main.zig").?;
    const found = try server.documentFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("missingLimit", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "module diagnostics resolve nested imported aliases once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const Message = @import(\"catalog.zig\").MessagePool.Message;\n" ++
        "fn use(_: *Message.Ping, _: *Message.Missing) void {}\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();
    try server.documents.open("file://examples/zls/imports/nested.zig", 1, source);
    const document = server.documents.getConst("file://examples/zls/imports/nested.zig").?;

    const view = (try server.moduleView(arena, document, "Message")).?;
    var ping_member_count: usize = 0;
    for (view.members) |member| {
        if (std.mem.eql(u8, member.name, "Ping")) ping_member_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ping_member_count);

    const found = try server.documentFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("Missing", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "module diagnostics respect same-file visibility and nested receivers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const namespace = struct { const log = struct { fn scoped() void {} }; };\n" ++
        "const log = struct {};\n" ++
        "const Status = enum { normal };\n" ++
        "const Private = struct { fn run() void {} const Nested = u8; };\n" ++
        "fn use() void { namespace.log.scoped(); _ = Status.normal; Private.run(); _ = Private.Nested; Private.missing(); }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();
    try server.documents.open("file:///same_file_visibility.zig", 1, source);
    const document = server.documents.getConst("file:///same_file_visibility.zig").?;

    const found = try server.moduleMemberFindings(arena, document, analysis.Configuration.defaults());
    var missing_member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        missing_member_count += 1;
        try std.testing.expectEqualStrings("missing", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_member_count);
}

test "definition follows a constant alias into an imported declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source: [:0]const u8 =
        "const catalog = @import(\"catalog.zig\");\n" ++
        "const Alias = catalog.MessagePool;\n" ++
        "fn use() void { _ = Alias; }\n";
    const incoming = [_][]const u8{};
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();
    try server.documents.open("file://examples/zls/imports/alias.zig", 1, source);
    const document = server.documents.getConst("file://examples/zls/imports/alias.zig").?;
    const usage_start = std.mem.lastIndexOf(u8, source, "Alias").?;
    const identifier_span = document.identifierAt(usage_start).?;

    const location = (try server.aliasTargetDefinition(arena, document, identifier_span)).?;
    try std.testing.expect(std.mem.endsWith(u8, location.uri, "/examples/zls/imports/catalog.zig"));
    try std.testing.expectEqual(@as(u32, 2), location.range.start.line);
    try std.testing.expectEqual(@as(u32, 10), location.range.start.character);
}

test "import resolution identifies aliases" {
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const catalog = @import(\"catalog.zig\");\n";
    try std.testing.expectEqualStrings("std", (try importName(std.testing.allocator, source, "std")).?);
    try std.testing.expectEqualStrings("catalog.zig", (try importName(std.testing.allocator, source, "catalog")).?);
}

test "LSP member completion and rename respect syntax context" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///comparison.zig","languageId":"zig","version":1,"text":"const Profile = struct { display_name: []const u8, login_count: u32 };\nfn show(profile: Profile) []const u8 { return profile.display_name; }\nfn increment(value: u32) u32 { return value + 1; }\nfn describe(value: []const u8) []const u8 { return value; }\nconst std = @import(\"std\");\nfn namesMatch(left: []const u8, right: []const u8) bool { return std.mem.eql(u8, left, right); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comparison.zig"},"position":{"line":1,"character":54}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///comparison.zig"},"position":{"line":5,"character":73}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///comparison.zig"},"position":{"line":2,"character":15},"newName":"number"}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///comparison.zig"},"position":{"line":1,"character":55}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///comparison.zig"},"position":{"line":5,"character":74}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 8), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "display_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "login_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "\"eql\"") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, transport.output(4), "\"newText\":\"number\""));
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "```zig\\ndisplay_name: []const u8\\n```\\n```zig\\n([]const u8)\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "fn eql(comptime T: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "Returns true if and only if") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(7), "\"result\":null") != null);
}

test "LSP import completion and definition resolve another file" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig","languageId":"zig","version":1,"text":"const catalog = @import(\"catalog.zig\");\nfn result() u32 { return catalog.clampToLimit(100); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig"},"position":{"line":1,"character":33}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig"},"position":{"line":1,"character":36}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig"},"position":{"line":1,"character":36}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "default_limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "clampToLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "catalog.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "fn clampToLimit(value: u32) u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "\"result\":null") != null);
}

test "LSP resolves import paths and nested imported definitions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig","languageId":"zig","version":1,"text":"const Message = @import(\"catalog.zig\").MessagePool.Message;\nfn use(_: *Message.Ping) void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig"},"position":{"line":1,"character":19}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig"},"position":{"line":0,"character":26}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig"},"position":{"line":0,"character":40}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig"},"position":{"line":0,"character":52}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/definition","params":{"textDocument":{"uri":"file://examples/zls/imports/nested.zig"},"position":{"line":1,"character":20}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 8), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "unresolved-member") == null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "\"Ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "catalog.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "\"line\":0,\"character\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "\"line\":2,\"character\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "\"line\":3,\"character\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "\"line\":4,\"character\":18") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(7), "\"result\":null") != null);
}

test "LSP hover describes parameters locals functions and bounded constants" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///hover.zig","languageId":"zig","version":1,"text":"/// Maximum number of attempts made by the example.\nconst retry_limit: u8 = 3;\n\n/// Adds an incoming sample to an accumulated value.\nfn addSample(accumulated: u32, incoming: u32) u32 {\n    return accumulated + incoming;\n}\n\nfn compute(incoming: u32) u32 {\n    const doubled: u32 = incoming * 2;\n    return addSample(doubled, incoming) + retry_limit;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":9,"character":26}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":22}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":12}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///hover.zig"},"position":{"line":10,"character":43}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "\"kind\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "```zig\\nincoming: u32\\n```\\n```zig\\n(u32)\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "```zig\\nconst doubled: u32 = incoming * 2\\n```\\n```zig\\n(u32)\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "```zig\\nfn addSample(accumulated: u32, incoming: u32) u32\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "Adds an incoming sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "```zig\\nconst retry_limit: u8 = 3\\n```\\n```zig\\n(u8 = 3)\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "Maximum number of attempts") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "\"result\":null") != null);
}

test "LSP hover documents Zig keywords primitive types and values" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///language.zig","languageId":"zig","version":1,"text":"const count: u8 = 1;\nvar enabled: bool = true;\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":0,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":0,"character":13}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":13}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///language.zig"},"position":{"line":1,"character":21}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    server.compiler_restart_available = false;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 8), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "```zig\\nconst\\n```\\n```zig\\n(keyword)\\n```") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "cannot be reassigned") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "#Keyword-Reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "An unsigned integer type with 8 bits") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "mutable binding") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "boolean type") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "primitive value") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "#Primitive-Values") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(7), "\"result\":null") != null);
}

test "LSP hover documents builtins operators literals and semicolons" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tokens.zig","languageId":"zig","version":1,"text":"const value = @as(u8, 1 + 2);\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":15}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":22}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":24}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tokens.zig"},"position":{"line":0,"character":28}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    server.compiler_restart_available = false;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "@as(comptime T: type, expression: anytype) T") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "builtin function") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "#@as") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "integer literal") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "(operator)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "Terminates a declaration") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "#Grammar") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "\"result\":null") != null);
}

test "LSP hover follows inferred returns through imported type aliases" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig","languageId":"zig","version":1,"text":"const types = @import(\"hover_types.zig\");\nfn make() types.Headers.View { return .{ .slice = \"zig\" }; }\nfn inspect() usize { const view = make(); return view.slice.len; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig"},"position":{"line":2,"character":50}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/hover_main.zig"},"position":{"line":2,"character":55}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "const view = make()") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "types.Headers.View") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "slice: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "Headers decoded from the used message body") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "\"result\":null") != null);
}

test "LSP hover resolves constructed types through imports and type functions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://fixtures/member_main.zig","languageId":"zig","version":1,"text":"const registry = @import(\"store_registry.zig\");\nfn run() void {\n    var store = registry.Store.init(8);\n    store.close();\n    var queue = registry.Queue(u8).empty;\n    queue.push(1);\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/member_main.zig"},"position":{"line":3,"character":11}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://fixtures/member_main.zig"},"position":{"line":5,"character":11}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "fn close(self: *Store) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Releases every resource owned by the store.") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "fn push(self: *@This(), entry: T) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "Appends one entry to the queue tail.") != null);
}

test "LSP publishes memory ownership warnings" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///memory.zig","languageId":"zig","version":1,"text":"fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); _ = buffer; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///memory.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":104}},"context":{"diagnostics":[],"only":["quickfix"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "unreleased-allocation") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "no visible free") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "\"severity\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Insert defer allocator.free(buffer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "\"isPreferred\":false") != null);
}

test "LSP publishes unresolved calls before the document is saved" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///unsaved.zig","languageId":"zig","version":1,"text":"fn compute() u32 { return 1; }\ncomptime { _ = compute(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///unsaved.zig","version":2},"contentChanges":[{"text":"fn compte() u32 { return 1; }\ncomptime { _ = compute(); }\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "unresolved-call") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "unresolved function 'compute'") != null);
}

test "LSP publishes unresolved type references after an unsaved rename" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///unsaved_type.zig","languageId":"zig","version":1,"text":"const pool = @import(\"pool\");\nconst Message = pool.Message;\nfn use(message: *Message.Prepare) void { _ = message; }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///unsaved_type.zig","version":2},"contentChanges":[{"text":"const pool = @import(\"pool\");\nconst Mssage = pool.Message;\nfn use(message: *Message.Prepare) void { _ = message; }\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "\"diagnostics\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "unresolved-identifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "unresolved identifier 'Message'") != null);
}

test "LSP advertises and returns complete filtered code actions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"textDocument":{"codeAction":{"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor.extract","refactor.rewrite","source.organizeImports","source.fixAll"]}}}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///actions.zig","languageId":"zig","version":1,"text":"const Mode = enum { fast, safe };\nfn run(mode: Mode, input: u32) void {\n    var value = 1;\n    _ = value;\n    const generated: u32 = missing(input, 42);\n    _ = generated;\n    switch (mode) { .fast => {} }\n    _ = if (value == 1) true else false;\n    defer { cleanup(); }\n    if (value == 1) {} else {}\n}\nfn cleanup() void {}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///actions.zig"},"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":17}},"context":{"diagnostics":[],"only":["quickfix"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///actions.zig"},"range":{"start":{"line":6,"character":4},"end":{"line":6,"character":35}},"context":{"diagnostics":[],"only":["quickfix"]}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///actions.zig"},"range":{"start":{"line":4,"character":27},"end":{"line":4,"character":34}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///actions.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":11,"character":20}},"context":{"diagnostics":[],"only":["source.fixAll"]}}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "source.organizeImports") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "resolveProvider\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "codeLensProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "zig-analyzer.peekResolvedType") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "callHierarchyProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "missing-switch-prong") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "never-mutated-var") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Change 'value' to const") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "\"newText\":\"const\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "Fill missing switch prongs") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), ".safe => @panic") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "Generate function 'missing'") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "fn missing(input: u32, arg2: anytype) u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "Fix all safe zig-analyzer findings") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "Fill missing switch prongs") == null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "\"newText\":\"const\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "value == 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "cleanup();") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "\"newText\":\"\"") != null);
}

test "LSP returns Zig error recovery actions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///recovery.zig","languageId":"zig","version":1,"text":"fn load() error{Missing}!u8 { return 1; }\nfn run() !void { _ = load(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///recovery.zig"},"range":{"start":{"line":1,"character":21},"end":{"line":1,"character":25}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Propagate the error with try") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Handle the error with catch") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Handle every error with a switch") != null);
}

test "LSP returns build repair and c import extraction workspace actions" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{"workspace":{"workspaceEdit":{"documentChanges":true,"resourceOperations":["create"]}}}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/build.zig","languageId":"zig","version":1,"text":"const std = @import(\"std\"); pub fn build(b: *std.Build) void { const exe = b.addExecutable(.{ .name = \"app\" }); _ = exe.root_module; }"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/src/main.zig","languageId":"zig","version":1,"text":"const feature = @import(\"feature\"); const c = @cImport({ @cInclude(\"x.h\"); });"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///project/src/feature.zig","languageId":"zig","version":1,"text":"const c = @cImport({ @cInclude(\"x.h\"); });"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///project/src/main.zig"},"range":{"start":{"line":0,"character":24},"end":{"line":0,"character":33}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///project/src/main.zig"},"range":{"start":{"line":0,"character":46},"end":{"line":0,"character":54}},"context":{"diagnostics":[],"only":["refactor.rewrite"]}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 7), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "Add module 'feature' to build.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "root_module.addImport") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "Extract repeated @cImport") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "documentChanges") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "c_imports.zig") != null);
}

test "LSP call hierarchy connects callers and callees" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///calls.zig","languageId":"zig","version":1,"text":"fn callee() void {}\nfn caller() void { callee(); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"file:///calls.zig"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"caller","kind":12,"uri":"file:///calls.zig","range":{"start":{"line":1,"character":3},"end":{"line":1,"character":9}},"selectionRange":{"start":{"line":1,"character":3},"end":{"line":1,"character":9}}}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"callee","kind":12,"uri":"file:///calls.zig","range":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}},"selectionRange":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}}}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "\"name\":\"callee\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "\"name\":\"callee\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "\"name\":\"caller\"") != null);
}

test "LSP extracts an exact UTF-16 expression selection" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///extract.zig","languageId":"zig","version":1,"text":"fn compute() u32 {\n    const label = \"😀\";\n    _ = label;\n    return 20 + 22;\n}\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///extract.zig"},"range":{"start":{"line":3,"character":11},"end":{"line":3,"character":18}},"context":{"diagnostics":[],"only":["refactor.extract"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Extract into const 'value'") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "const value = 20 + 22;") != null);
}

test "LSP organizes imports when the style lint is disabled" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///imports.zig","languageId":"zig","version":1,"text":"// package\nconst package = @import(\"package\");\n// standard\nconst std = @import(\"std\");\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///imports.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":3,"character":27}},"context":{"diagnostics":[],"only":["source.organizeImports"]}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "Organize imports") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "source.organizeImports") != null);
    const standard_comment = std.mem.indexOf(u8, transport.output(2), "// standard").?;
    const package_comment = std.mem.indexOf(u8, transport.output(2), "// package").?;
    try std.testing.expect(standard_comment < package_comment);
}

test "LSP diagnostics map positions past astral-plane characters in UTF-16" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///astral.zig","languageId":"zig","version":1,"text":"const s = \"😀\"; const broken ="}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 3), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "syntax-error") != null);
    // The error sits at the end of the line: 32 bytes but 30 UTF-16 units.
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "\"character\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "\"character\":32") == null);
}

test "LSP keeps answering after an edit deletes the import behind a member access" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig","languageId":"zig","version":1,"text":"const catalog = @import(\"catalog.zig\");\nfn result() u32 { return catalog.clampToLimit(100); }\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig","version":2},"contentChanges":[{"text":"fn result() u32 { return catalog.clampToLimit(100); }\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig"},"position":{"line":0,"character":35}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file://examples/zls/imports/main.zig"},"position":{"line":0,"character":33}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    server.compiler_restart_available = false;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 6), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "\"result\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "\"result\":[]") != null);
}

test "LSP discards an out-of-order document version instead of clobbering newer text" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///rapid.zig","languageId":"zig","version":1,"text":"const first = 1;\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///rapid.zig","version":3},"contentChanges":[{"text":"const third = 3;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///rapid.zig","version":2},"contentChanges":[{"text":"const second = 2;\n"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///rapid.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    server.compiler_start_attempted = true;
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    // The stale version publishes nothing: open, newer change, symbols, shutdown.
    try std.testing.expectEqual(@as(usize, 5), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "third") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "second") == null);
}

test "LSP survives a save notification for a document that was never opened" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///ghost.zig"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///alive.zig","languageId":"zig","version":1,"text":"const answer = 42;\n"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///alive.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    defer server.deinit();

    try lsp.basic_server.run(std.testing.io, std.testing.allocator, &transport.transport, &server, null);

    try std.testing.expectEqual(@as(usize, 4), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "answer") != null);
}

test "LSP session covers lifecycle synchronization and broad features" {
    const incoming = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":99}}
        ,
        \\{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[],"removed":[]}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///fixture.zig","languageId":"zig","version":1,"text":"const answer = 42;\n"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///fixture.zig","version":2},"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":0}},"text":"const broken ="}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///fixture.zig"},"position":{"line":0,"character":6}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///fixture.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"workspace/symbol","params":{"query":"ans"}}
        ,
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///fixture.zig"}}}
        ,
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///fixture.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":18}}}}
        ,
        \\{"jsonrpc":"2.0","id":8,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///fixture.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":1,"character":14}}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    };
    var transport = TestTransport.init(&incoming);
    var server = Server.init(std.testing.io, std.testing.allocator, .empty, &transport.transport);
    defer server.deinit();

    try lsp.basic_server.run(
        std.testing.io,
        std.testing.allocator,
        &transport.transport,
        &server,
        null,
    );

    try std.testing.expectEqual(@as(usize, 10), transport.output_count);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(0), "zig-analyzer") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(1), "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(2), "expected") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(3), "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(4), "broken") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(5), "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(6), "\"data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(7), "\"data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(8), "comptime_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output(9), "\"result\":null") != null);
}

const TestTransport = struct {
    transport: lsp.Transport,
    incoming: []const []const u8,
    incoming_index: usize = 0,
    output_buffers: [16][65536]u8 = undefined,
    output_lengths: [16]usize = @splat(0),
    output_count: usize = 0,

    fn init(incoming: []const []const u8) TestTransport {
        return .{
            .transport = .{ .vtable = &.{
                .readJsonMessage = readJsonMessage,
                .writeJsonMessage = writeJsonMessage,
            } },
            .incoming = incoming,
        };
    }

    fn output(transport: *const TestTransport, index: usize) []const u8 {
        return transport.output_buffers[index][0..transport.output_lengths[index]];
    }

    fn readJsonMessage(
        transport: *lsp.Transport,
        _: std.Io,
        allocator: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        const test_transport: *TestTransport = @fieldParentPtr("transport", transport);
        if (test_transport.incoming_index == test_transport.incoming.len) return error.EndOfStream;
        const message = test_transport.incoming[test_transport.incoming_index];
        test_transport.incoming_index += 1;
        return try allocator.dupe(u8, message);
    }

    fn writeJsonMessage(
        transport: *lsp.Transport,
        _: std.Io,
        message: []const u8,
    ) lsp.Transport.WriteError!void {
        const test_transport: *TestTransport = @fieldParentPtr("transport", transport);
        std.debug.assert(test_transport.output_count < test_transport.output_buffers.len);
        std.debug.assert(message.len <= test_transport.output_buffers[0].len);
        const index = test_transport.output_count;
        @memcpy(test_transport.output_buffers[index][0..message.len], message);
        test_transport.output_lengths[index] = message.len;
        test_transport.output_count += 1;
    }
};
