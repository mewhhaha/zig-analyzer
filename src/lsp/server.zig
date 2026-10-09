//! The language server: the `Server` struct the LSP runtime dispatches to.
//! Lifecycle, document synchronization and diagnostics publishing live here;
//! every feature request is one line forwarding to its module.
const std = @import("std");
const build_options = @import("build_options");
const lsp = @import("lsp");

comptime {
    @setEvalBranchQuota(50_000);
}

const analysis = @import("../analysis.zig");
const code_actions = @import("code_actions.zig");
const compiler_backend = @import("compiler_backend.zig");
const completion = @import("completion.zig");
const diagnostics = @import("diagnostics.zig");
const document_module = @import("../syntax/document.zig");
const hover = @import("hover.zig");
const navigation = @import("navigation.zig");
const presentation = @import("presentation.zig");
const project_config = @import("../project/config.zig");
const rename = @import("rename.zig");
const services_module = @import("services.zig");
const source_store = @import("../project/source_store.zig");
const uri_module = @import("../uri.zig");

const Document = document_module.Document;
const Services = services_module.Services;

pub fn runBasicServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    server: *Server,
    log_fn: anytype,
) !void {
    @setEvalBranchQuota(50_000);
    return lsp.basic_server.run(io, allocator, transport, server, log_fn);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio = lsp.Transport.Stdio.init(&read_buffer, .stdin(), .stdout());
    var thread_safe_transport = lsp.ThreadSafeTransport(.{
        .thread_safe_read = false,
        .thread_safe_write = true,
    }).init(&stdio.transport);
    var server: Server = undefined;
    try server.init(io, allocator, environ, &thread_safe_transport.transport, .{});
    defer server.deinit();
    try runBasicServer(io, allocator, &thread_safe_transport.transport, &server, std.log.err);
    if (!server.shutdown_requested) return error.ExitWithoutShutdown;
}

pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    documents: document_module.Store,
    /// Lint configuration and project roots; shared lookups are cached here.
    project_config: project_config.Store,
    /// The only writer of `publishDiagnostics`.
    publisher: diagnostics.Publisher,
    /// Deprecation findings' file dependencies per open document.
    dependencies: diagnostics.Dependencies,
    /// Dependencies of open documents, parsed once for every lint run.
    sources: source_store.Store,
    /// The compiler worker: queued, never waited on by requests.
    backend: compiler_backend.CompilerBackend,
    shutdown_requested: bool = false,

    pub const Options = struct {
        compiler: compiler_backend.Options = .{},

        /// No compiler is ever started: syntax and lint services only.
        pub const syntax_only: Options = .{ .compiler = .{ .enabled = false } };
    };

    /// Pinned: the backend's worker holds pointers into the server, so
    /// initialize in place and do not move.
    pub fn init(
        server: *Server,
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        transport: *lsp.Transport,
        options: Options,
    ) !void {
        server.* = .{
            .io = io,
            .allocator = allocator,
            .transport = transport,
            .documents = .init(allocator),
            .project_config = .init(io, allocator),
            .publisher = .init(io, allocator, transport),
            .dependencies = .init(allocator),
            .sources = .init(allocator),
            .backend = undefined,
        };
        errdefer server.deinit();
        try server.backend.init(io, allocator, environ, options.compiler, server.linter(), &server.publisher);
    }

    pub fn deinit(server: *Server) void {
        server.backend.deinit();
        server.publisher.deinit();
        server.dependencies.deinit();
        server.sources.deinit();
        server.project_config.deinit();
        server.documents.deinit();
        server.* = undefined;
    }

    pub fn linter(server: *Server) diagnostics.Linter {
        return .{ .io = server.io, .transport = server.transport, .configurations = &server.project_config, .sources = &server.sources };
    }
    /// What feature requests read; see `services.zig`.
    pub fn services(server: *Server) Services {
        return .{
            .io = server.io,
            .documents = &server.documents,
            .backend = &server.backend,
            .linter = server.linter(),
            .dependencies = &server.dependencies,
        };
    }

    pub fn initialize(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("initialize"),
    ) !lsp.ResultType("initialize") {
        if (params.workspaceFolders) |folders| {
            for (folders) |folder| try server.addWorkspaceFolder(arena, folder.uri);
        } else if (params.rootUri) |root_uri| {
            try server.addWorkspaceFolder(arena, root_uri);
        } else if (params.rootPath) |root_path| {
            try server.addWorkspaceRoot(root_path);
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
                .typeDefinitionProvider = .{ .bool = true },
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
                        .tokenTypes = presentation.semantic_token_types,
                        .tokenModifiers = presentation.semantic_token_modifiers,
                    },
                    .range = .{ .bool = true },
                    .full = .{ .bool = true },
                } },
                .inlayHintProvider = .{ .inlay_hint_options = .{ .resolveProvider = false } },
                .executeCommandProvider = .{ .commands = &.{ "zig-analyzer.peekResolvedType", "zig-analyzer.typeAtPosition" } },
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
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/didChangeWorkspaceFolders"),
    ) !void {
        for (params.event.removed) |folder| {
            const path = try uri_module.toPath(arena, folder.uri) orelse continue;
            server.project_config.removeWorkspaceRoot(path);
        }
        for (params.event.added) |folder| try server.addWorkspaceFolder(arena, folder.uri);
    }

    pub fn @"workspace/didChangeWatchedFiles"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/didChangeWatchedFiles"),
    ) !void {
        for (params.changes) |change| {
            if (!isProjectConfigurationUri(change.uri)) continue;
            try server.projectConfigurationChanged(arena);
            return;
        }
    }

    fn addWorkspaceFolder(server: *Server, arena: std.mem.Allocator, folder_uri: []const u8) !void {
        const path = try uri_module.toPath(arena, folder_uri) orelse return;
        try server.addWorkspaceRoot(path);
    }

    fn addWorkspaceRoot(server: *Server, path: []const u8) !void {
        try server.project_config.addWorkspaceRoot(path);
    }

    /// A `zig-analyzer.json` changed: drop cached configuration and refresh
    /// every open document's diagnostics.
    pub fn projectConfigurationChanged(server: *Server, arena: std.mem.Allocator) !void {
        server.project_config.invalidate();
        var uris: std.ArrayList([]const u8) = .empty;
        var documents = server.documents.documents.valueIterator();
        while (documents.next()) |document| try uris.append(arena, document.uri);
        for (uris.items) |uri| try server.publishDiagnostics(arena, uri);
    }

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
        try server.publishDeprecationDependents(arena, params.textDocument.uri);
        try server.publishDiagnostics(arena, params.textDocument.uri);
        try server.backend.documentChanged(server.documents.getConst(params.textDocument.uri).?, .edited);
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
        try server.publishDeprecationDependents(arena, params.textDocument.uri);
        try server.publishDiagnostics(arena, params.textDocument.uri);
        try server.backend.documentChanged(server.documents.getConst(params.textDocument.uri).?, .edited);
    }

    pub fn @"textDocument/didClose"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didClose"),
    ) !void {
        try server.backend.documentClosed(params.textDocument.uri);
        _ = server.documents.close(params.textDocument.uri);
        server.dependencies.remove(params.textDocument.uri);
        try server.publishDeprecationDependents(arena, params.textDocument.uri);
        try server.publisher.close(params.textDocument.uri, arena);
    }

    pub fn @"textDocument/didSave"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/didSave"),
    ) !void {
        if (isProjectConfigurationUri(params.textDocument.uri)) try server.projectConfigurationChanged(arena);
        try server.publishDeprecationDependents(arena, params.textDocument.uri);
        const document = try server.analysisDocumentAfterSave(arena, params.textDocument.uri) orelse return;
        const build_configuration_changed = std.mem.endsWith(u8, params.textDocument.uri, "/build.zig") or
            std.mem.endsWith(u8, params.textDocument.uri, "/build.zig.zon");
        try server.backend.documentChanged(document, if (build_configuration_changed) .build_changed else .saved);
    }

    pub fn @"textDocument/completion"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/completion"),
    ) !lsp.ResultType("textDocument/completion") {
        return completion.completion(server.services(), arena, params);
    }

    pub fn @"textDocument/hover"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/hover"),
    ) !lsp.ResultType("textDocument/hover") {
        return hover.hover(server.services(), arena, params);
    }

    pub fn @"textDocument/definition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/definition"),
    ) !lsp.ResultType("textDocument/definition") {
        return navigation.definition(server.services(), arena, params);
    }

    pub fn @"textDocument/typeDefinition"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/typeDefinition"),
    ) !lsp.ResultType("textDocument/typeDefinition") {
        return navigation.typeDefinition(server.services(), arena, params);
    }

    pub fn @"textDocument/references"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/references"),
    ) !lsp.ResultType("textDocument/references") {
        return navigation.references(server.services(), arena, params);
    }

    pub fn @"textDocument/signatureHelp"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/signatureHelp"),
    ) !lsp.ResultType("textDocument/signatureHelp") {
        return presentation.signatureHelp(server.services(), arena, params);
    }

    pub fn @"textDocument/documentSymbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/documentSymbol"),
    ) !lsp.ResultType("textDocument/documentSymbol") {
        return presentation.documentSymbol(server.services(), arena, params);
    }

    pub fn @"workspace/symbol"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/symbol"),
    ) !lsp.ResultType("workspace/symbol") {
        return presentation.workspaceSymbol(server.services(), arena, params);
    }

    pub fn @"textDocument/semanticTokens/full"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/semanticTokens/full"),
    ) !lsp.ResultType("textDocument/semanticTokens/full") {
        return presentation.semanticTokensFull(server.services(), arena, params);
    }

    pub fn @"textDocument/semanticTokens/range"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/semanticTokens/range"),
    ) !lsp.ResultType("textDocument/semanticTokens/range") {
        return presentation.semanticTokensRange(server.services(), arena, params);
    }

    pub fn @"textDocument/inlayHint"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/inlayHint"),
    ) !lsp.ResultType("textDocument/inlayHint") {
        return presentation.inlayHint(server.services(), arena, params);
    }

    pub fn @"textDocument/codeLens"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/codeLens"),
    ) !lsp.ResultType("textDocument/codeLens") {
        return presentation.codeLens(server.services(), arena, params);
    }

    pub fn @"workspace/executeCommand"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("workspace/executeCommand"),
    ) !lsp.ResultType("workspace/executeCommand") {
        return hover.executeCommand(server.services(), arena, params);
    }

    pub fn @"textDocument/prepareCallHierarchy"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/prepareCallHierarchy"),
    ) !lsp.ResultType("textDocument/prepareCallHierarchy") {
        return presentation.prepareCallHierarchy(server.services(), arena, params);
    }

    pub fn @"callHierarchy/incomingCalls"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("callHierarchy/incomingCalls"),
    ) !lsp.ResultType("callHierarchy/incomingCalls") {
        return presentation.incomingCalls(server.services(), arena, params);
    }

    pub fn @"callHierarchy/outgoingCalls"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("callHierarchy/outgoingCalls"),
    ) !lsp.ResultType("callHierarchy/outgoingCalls") {
        return presentation.outgoingCalls(server.services(), arena, params);
    }

    pub fn @"textDocument/rename"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/rename"),
    ) !lsp.ResultType("textDocument/rename") {
        return rename.rename(server.services(), arena, params);
    }

    pub fn @"textDocument/codeAction"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/codeAction"),
    ) !lsp.ResultType("textDocument/codeAction") {
        return code_actions.codeAction(server.services(), arena, params);
    }

    pub fn @"textDocument/formatting"(
        server: *Server,
        arena: std.mem.Allocator,
        params: lsp.ParamsType("textDocument/formatting"),
    ) !lsp.ResultType("textDocument/formatting") {
        return presentation.formatting(server.services(), arena, params);
    }

    /// Every rule finding for `document` under `lint_configuration`, using the
    /// compiler facts already known for it.
    pub fn documentFindings(
        server: *Server,
        allocator: std.mem.Allocator,
        document: *const Document,
        lint_configuration: analysis.Configuration,
    ) ![]analysis.Finding {
        const shapes = try server.backend.knownShapes(allocator, document.uri);
        return server.linter().findings(allocator, &server.documents, document, lint_configuration, shapes, &server.dependencies);
    }

    /// Computes the lint layer of the open document `uri` and publishes it
    /// together with the compiler layer of the same version, if there is one.
    pub fn publishDiagnostics(server: *Server, arena: std.mem.Allocator, uri: []const u8) !void {
        const document = server.documents.getConst(uri) orelse return error.DocumentNotOpen;
        const shapes = try server.backend.knownShapes(arena, uri);
        const lint = try server.linter().diagnostics(arena, &server.documents, document, shapes, &server.dependencies);
        try server.publisher.publishLint(uri, document.version, lint);
    }

    /// The open document a save of `saved_uri` should be analyzed through: the
    /// document itself, or for `build.zig` / `build.zig.zon` the compile root
    /// below its directory (else any open source file there).
    pub fn analysisDocumentAfterSave(server: *Server, arena: std.mem.Allocator, saved_uri: []const u8) !?*const Document {
        if (!std.mem.endsWith(u8, saved_uri, "/build.zig") and
            !std.mem.endsWith(u8, saved_uri, "/build.zig.zon")) return server.documents.getConst(saved_uri);
        const directory_end = (std.mem.findScalarLast(u8, saved_uri, '/') orelse return null) + 1;
        const directory_uri = saved_uri[0..directory_end];
        if (try server.backend.compileRoot(arena)) |root_uri| {
            if (std.mem.startsWith(u8, root_uri, directory_uri)) {
                if (server.documents.getConst(root_uri)) |document| return document;
            }
        }
        var documents = server.documents.documents.valueIterator();
        while (documents.next()) |document| {
            if (std.mem.startsWith(u8, document.uri, directory_uri) and
                !std.mem.endsWith(u8, document.uri, "/build.zig") and
                !std.mem.endsWith(u8, document.uri, "/build.zig.zon")) return document;
        }
        return null;
    }

    /// Refreshes the diagnostics of every document whose deprecation findings
    /// read the file that changed.
    fn publishDeprecationDependents(server: *Server, allocator: std.mem.Allocator, changed_uri: []const u8) !void {
        const path = try uri_module.toPath(allocator, changed_uri) orelse return;
        defer allocator.free(path);
        const affected = try server.dependencies.dependents(allocator, changed_uri, path);
        defer {
            for (affected) |uri| allocator.free(uri);
            allocator.free(affected);
        }
        // Publishing recomputes and replaces dependency records; the list above
        // is already a copy, so that cannot invalidate it.
        for (affected) |uri| if (server.documents.getConst(uri) != null) try server.publishDiagnostics(allocator, uri);
    }
};

fn isProjectConfigurationUri(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, "/" ++ project_config.file_name);
}
