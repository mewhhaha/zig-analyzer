//! Diagnostics as the editor sees them. A document's diagnostics are two
//! layers: the lint layer (syntax errors, configuration warnings, rule
//! findings), computed from the document text and any compiler facts already
//! known, and the compiler layer (compile errors), produced by the compiler
//! backend for exactly one document version. The `Publisher` is the only code
//! that writes `publishDiagnostics`: it merges the layers that belong to the
//! same document version, so a lint-only republish keeps the compiler errors of
//! that version and a compiler result for an outdated version is dropped.
const std = @import("std");

const lsp = @import("lsp");

const analysis = @import("../analysis.zig");
const build_graph = @import("../compiler/build_graph.zig");
const project_config = @import("../project/config.zig");
const imported_deprecations = @import("../project/imported_deprecations.zig");
const module_sites = @import("../project/module_sites.zig");
const document_module = @import("../syntax/document.zig");
const uri_module = @import("../uri.zig");

const Document = document_module.Document;
const Diagnostic = lsp.types.Diagnostic;

pub fn findingDiagnostic(
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
        .codeDescription = .{ .href = analysis.ruleDocumentationUrl(finding.rule) },
        .source = "zig-analyzer",
        .message = .{ .string = finding.message },
        .relatedInformation = related,
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

pub fn syntaxDiagnostics(document: *const Document, allocator: std.mem.Allocator) ![]lsp.types.Diagnostic {
    const diagnostics = try allocator.alloc(lsp.types.Diagnostic, document.tree.errors.len);
    var initialized: usize = 0;
    errdefer {
        for (diagnostics[0..initialized]) |diagnostic| allocator.free(diagnostic.message.string);
        allocator.free(diagnostics);
    }
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
            .message = .{ .string = try message.toOwnedSlice() },
        };
        initialized += 1;
    }
    return diagnostics;
}

/// The compiler's errors in `document` as editor diagnostics. An error saying
/// that an import of a module in `unavailable` does not resolve is expected,
/// since the analyzer chose not to produce that module; it becomes an
/// information diagnostic naming the step that generates the module, not an
/// error.
pub fn compilerDiagnostics(
    document: *const Document,
    bundle: std.zig.ErrorBundle,
    allocator: std.mem.Allocator,
    unavailable: []const build_graph.UnavailableImport,
) ![]lsp.types.Diagnostic {
    if (bundle.errorMessageCount() == 0) return &.{};
    const document_path = try uri_module.toPath(allocator, document.uri) orelse return &.{};
    defer allocator.free(document_path);
    const absolute_document_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{document_path});
    defer allocator.free(absolute_document_path);
    var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| {
            allocator.free(diagnostic.message.string);
            if (diagnostic.relatedInformation) |related_information| {
                for (related_information) |information| {
                    allocator.free(information.location.uri);
                    allocator.free(information.message);
                }
                allocator.free(related_information);
            }
        }
        diagnostics.deinit(allocator);
    }
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
        if (unavailableImport(bundle.nullTerminatedString(error_message.msg), unavailable)) |missing| {
            const notice = try allocator.print(
                "module '{s}' is not available: step '{s}' {s}; analysis continues without it",
                .{ missing.import_name, missing.step, missing.reason },
            );
            errdefer allocator.free(notice);
            try diagnostics.append(allocator, .{
                .range = document.range(.{ .start = start, .end = end }),
                .severity = .Information,
                .code = .{ .string = "module-unavailable" },
                .source = "zig-analyzer",
                .message = .{ .string = notice },
            });
            continue;
        }
        var related: std.ArrayList(lsp.types.Diagnostic.RelatedInformation) = .empty;
        errdefer {
            for (related.items) |information| {
                allocator.free(information.location.uri);
                allocator.free(information.message);
            }
            related.deinit(allocator);
        }
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
                try uri_module.fromPath(allocator, note_path),
            };
            errdefer allocator.free(note_uri);
            const note_message = try allocator.dupe(u8, bundle.nullTerminatedString(note.msg));
            errdefer allocator.free(note_message);
            try related.append(allocator, .{
                .location = .{ .uri = note_uri, .range = note_range },
                .message = note_message,
            });
        }
        const diagnostic_message = try allocator.dupe(u8, bundle.nullTerminatedString(error_message.msg));
        errdefer allocator.free(diagnostic_message);
        const related_information = if (related.items.len == 0) null else try related.toOwnedSlice(allocator);
        errdefer if (related_information) |information_items| {
            for (information_items) |information| {
                allocator.free(information.location.uri);
                allocator.free(information.message);
            }
            allocator.free(information_items);
        };
        try diagnostics.append(allocator, .{
            .range = document.range(.{ .start = start, .end = end }),
            .severity = .Error,
            .code = .{ .string = "compiler-error" },
            .source = "zig compiler",
            .message = .{ .string = diagnostic_message },
            .relatedInformation = related_information,
        });
    }
    return try diagnostics.toOwnedSlice(allocator);
}

/// The unavailable import the compiler error `message` ("no module named 'x'
/// available within module 'y'") is about, if it is one.
fn unavailableImport(message: []const u8, unavailable: []const build_graph.UnavailableImport) ?build_graph.UnavailableImport {
    const prefix = "no module named '";
    if (!std.mem.startsWith(u8, message, prefix)) return null;
    const rest = message[prefix.len..];
    const quote = std.mem.findScalar(u8, rest, '\'') orelse return null;
    if (!std.mem.startsWith(u8, rest[quote..], "' available within module")) return null;
    for (unavailable) |entry| {
        if (std.mem.eql(u8, entry.import_name, rest[0..quote])) return entry;
    }
    return null;
}

fn sourcePathMatchesDocument(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    absolute_document_path: []const u8,
) !bool {
    if (!std.Io.Dir.path.isAbsolute(source_path)) {
        if (!std.mem.endsWith(u8, absolute_document_path, source_path)) return false;
        const prefix_length = absolute_document_path.len - source_path.len;
        return prefix_length == 0 or std.Io.Dir.path.isSep(absolute_document_path[prefix_length - 1]);
    }
    const absolute_source_path = try std.Io.Dir.path.resolveAlloc(allocator, &.{source_path});
    defer allocator.free(absolute_source_path);
    return std.mem.eql(u8, absolute_document_path, absolute_source_path);
}

fn lineStartOffset(source: []const u8, target_line: u32) ?usize {
    var line: u32 = 0;
    var offset: usize = 0;
    while (line < target_line) {
        const newline = std.mem.findScalarPos(u8, source, offset, '\n') orelse return null;
        offset = newline + 1;
        line += 1;
    }
    return offset;
}

fn deduplicateAndSortDiagnostics(diagnostics: []lsp.types.Diagnostic) usize {
    std.mem.sort(lsp.types.Diagnostic, diagnostics, {}, struct {
        fn lessThan(_: void, left: lsp.types.Diagnostic, right: lsp.types.Diagnostic) bool {
            if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
            if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
            return std.mem.lessThan(u8, left.message.string, right.message.string);
        }
    }.lessThan);
    if (diagnostics.len < 2) return diagnostics.len;
    var write_index: usize = 1;
    for (diagnostics[1..]) |diagnostic| {
        const previous = diagnostics[write_index - 1];
        if (std.meta.eql(previous.range, diagnostic.range) and std.mem.eql(u8, previous.message.string, diagnostic.message.string)) {
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

/// The files each open document's deprecation findings looked at, so a change to
/// one of them refreshes the documents that import it.
pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        storage: std.heap.ArenaAllocator,
        paths: []const []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Dependencies {
        return .{ .allocator = allocator };
    }

    pub fn deinit(dependencies: *Dependencies) void {
        var entries = dependencies.entries.iterator();
        while (entries.next()) |entry| {
            entry.value_ptr.storage.deinit();
            dependencies.allocator.free(entry.key_ptr.*);
        }
        dependencies.entries.deinit(dependencies.allocator);
        dependencies.* = undefined;
    }

    pub fn store(dependencies: *Dependencies, uri: []const u8, paths: []const []const u8) !void {
        var storage = std.heap.ArenaAllocator.init(dependencies.allocator);
        errdefer storage.deinit();
        const copies = try storage.allocator().alloc([]const u8, paths.len);
        for (paths, copies) |path, *copy| copy.* = try storage.allocator().dupe(u8, path);
        const entry: Entry = .{ .storage = storage, .paths = copies };
        if (dependencies.entries.getPtr(uri)) |previous| {
            previous.storage.deinit();
            previous.* = entry;
        } else {
            const key = try dependencies.allocator.dupe(u8, uri);
            errdefer dependencies.allocator.free(key);
            try dependencies.entries.put(dependencies.allocator, key, entry);
        }
    }

    pub fn remove(dependencies: *Dependencies, uri: []const u8) void {
        const removed = dependencies.entries.fetchRemove(uri) orelse return;
        dependencies.allocator.free(removed.key);
        var storage = removed.value.storage;
        storage.deinit();
    }

    /// URIs of the documents, other than `changed_uri`, that looked at the file
    /// at `path`. The caller owns the slice and its strings.
    pub fn dependents(
        dependencies: *const Dependencies,
        allocator: std.mem.Allocator,
        changed_uri: []const u8,
        path: []const u8,
    ) ![]const []const u8 {
        var affected: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (affected.items) |uri| allocator.free(uri);
            affected.deinit(allocator);
        }
        var entries = dependencies.entries.iterator();
        while (entries.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, changed_uri)) continue;
            for (entry.value_ptr.paths) |dependency| {
                if (!std.mem.eql(u8, dependency, path)) continue;
                try affected.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
                break;
            }
        }
        return try affected.toOwnedSlice(allocator);
    }
};

/// Computes the lint layer of a document. Cheap to copy; it only names the
/// shared services it reads, so both the foreground and the compiler backend
/// use it.
pub const Linter = struct {
    io: std.Io,
    transport: *lsp.Transport,
    configurations: *project_config.Store,

    /// The lint configuration for `document`: the nearest `zig-analyzer.json`
    /// above its file with the per-path relaxations the CLI applies too. A
    /// broken configuration file is reported to the user once.
    pub fn configuration(linter: Linter, arena: std.mem.Allocator, document: *const Document) !analysis.Configuration {
        const path = try uri_module.toPath(arena, document.uri) orelse return analysis.Configuration.defaults();
        const resolved = try linter.configurations.forFile(path);
        if (resolved.new_warning) |warning| try linter.showWarning(arena, warning);
        return resolved.configuration;
    }

    /// Tells the user something about their project, in an editor message.
    pub fn showWarning(linter: Linter, arena: std.mem.Allocator, message: []const u8) !void {
        try linter.showMessage(arena, .Warning, message);
    }

    pub fn showMessage(linter: Linter, arena: std.mem.Allocator, kind: lsp.types.window.MessageType, message: []const u8) !void {
        try linter.transport.writeNotification(
            linter.io,
            arena,
            "window/showMessage",
            lsp.types.window.ShowMessageParams,
            .{ .type = kind, .message = message },
            .{ .emit_null_optional_fields = false },
        );
    }

    /// Writes to the editor's server log without interrupting the user.
    pub fn logMessage(linter: Linter, arena: std.mem.Allocator, message: []const u8) !void {
        try linter.transport.writeNotification(
            linter.io,
            arena,
            "window/logMessage",
            lsp.types.window.LogMessageParams,
            .{ .type = .Info, .message = message },
            .{ .emit_null_optional_fields = false },
        );
    }

    /// Every rule finding for `document`. `shapes` are the compiler-resolved
    /// type shapes known for it (empty without a compiler); `documents` are the
    /// open buffers imports resolve against; `dependencies`, when given,
    /// records which files the deprecation findings read.
    pub fn findings(
        linter: Linter,
        allocator: std.mem.Allocator,
        documents: *const document_module.Store,
        document: *const Document,
        lint_configuration: analysis.Configuration,
        shapes: []const analysis.ResolvedShape,
        dependencies: ?*Dependencies,
    ) ![]analysis.Finding {
        const origin = try module_sites.File.ofDocument(allocator, document);
        const modules: []const analysis.ModuleMembers = if (origin == null or lint_configuration.level(.unresolved_member) == .off)
            &.{}
        else
            try (module_sites.Resolver{ .io = linter.io }).fileModules(allocator, origin.?);
        var document_findings: std.ArrayList(analysis.Finding) = .empty;
        errdefer document_findings.deinit(allocator);
        try document_findings.appendSlice(
            allocator,
            try analysis.findingsWith(
                allocator,
                document.source,
                lint_configuration,
                .{
                    .tokens = document.tokens,
                    .tree = &document.tree,
                    .scopes = &document.scopes,
                    .resolved_shapes = shapes,
                    .module_members = modules,
                },
            ),
        );
        try linter.appendImportedDeprecations(allocator, documents, document, lint_configuration, &document_findings, dependencies);
        if (try analysis.fileNameFinding(allocator, &document.tree, document.uri, lint_configuration)) |finding| {
            try document_findings.append(allocator, finding);
        }
        return try document_findings.toOwnedSlice(allocator);
    }

    /// The lint layer: syntax errors, a malformed-suppression warning and the
    /// rule findings, as LSP diagnostics.
    pub fn diagnostics(
        linter: Linter,
        arena: std.mem.Allocator,
        documents: *const document_module.Store,
        document: *const Document,
        shapes: []const analysis.ResolvedShape,
        dependencies: ?*Dependencies,
    ) ![]Diagnostic {
        var layer: std.ArrayList(Diagnostic) = .empty;
        try layer.appendSlice(arena, try syntaxDiagnostics(document, arena));
        const lint_configuration = try linter.configuration(arena, document);
        if (try analysis.suppressionWarning(arena, document.source)) |warning| {
            try layer.append(arena, .{
                .range = document.range(.{ .start = 0, .end = @min(document.source.len, 1) }),
                .severity = .Warning,
                .code = .{ .string = "invalid-configuration" },
                .source = "zig-analyzer configuration",
                .message = .{ .string = warning },
            });
        }
        const document_findings = try linter.findings(arena, documents, document, lint_configuration, shapes, dependencies);
        for (document_findings) |finding| try layer.append(arena, try findingDiagnostic(arena, document, finding));
        return try layer.toOwnedSlice(arena);
    }

    fn appendImportedDeprecations(
        linter: Linter,
        allocator: std.mem.Allocator,
        documents: *const document_module.Store,
        document: *const Document,
        lint_configuration: analysis.Configuration,
        findings_list: *std.ArrayList(analysis.Finding),
        dependencies: ?*Dependencies,
    ) !void {
        if (lint_configuration.level(.deprecated_declaration) == .off) return;
        const path = try uri_module.toPath(allocator, document.uri) orelse return;
        defer allocator.free(path);
        var imported: imported_deprecations.ImportedDeprecations = undefined;
        imported.init(linter.io, allocator);
        defer imported.deinit();
        // Open buffers take precedence over disk, including unsaved dependencies.
        var open_documents = documents.documents.valueIterator();
        while (open_documents.next()) |open_document| {
            const open_path = try uri_module.toPath(allocator, open_document.uri) orelse continue;
            defer allocator.free(open_path);
            try imported.addSource(.{ .path = open_path, .source = open_document.source, .tokens = open_document.tokens });
        }
        try imported.check(.{ .path = path, .source = document.source, .tokens = document.tokens }, lint_configuration, findings_list);
        const dependency_paths = try imported.dependencyPaths(allocator);
        defer allocator.free(dependency_paths);
        if (dependencies) |recorded| try recorded.store(document.uri, dependency_paths);
    }
};

/// Writes `publishDiagnostics` for every document, merging the layers of one
/// document version. All writers go through here, under one lock.
pub const Publisher = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    /// What is currently known about one document. `version` is the newest
    /// version the foreground has published; layers always describe it.
    const Entry = struct {
        version: i32,
        lint: Layer,
        compiler: ?Layer = null,
        /// The diagnostics last written, to skip identical republishes.
        published: Layer,

        fn deinit(state: *Entry) void {
            state.lint.deinit();
            if (state.compiler) |*layer| layer.deinit();
            state.published.deinit();
        }
    };

    const Layer = struct {
        arena: std.heap.ArenaAllocator,
        diagnostics: []const Diagnostic,

        fn copy(allocator: std.mem.Allocator, diagnostics: []const Diagnostic) !Layer {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            errdefer arena.deinit();
            // The diagnostics live in `arena`, which `deinit` releases.
            // zig-analyzer: disable-next-line incomplete-owned-field-cleanup
            return .{ .diagnostics = try copyDiagnostics(arena.allocator(), diagnostics), .arena = arena };
        }

        fn deinit(layer: *Layer) void {
            layer.arena.deinit();
            layer.* = undefined;
        }
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, transport: *lsp.Transport) Publisher {
        return .{ .io = io, .allocator = allocator, .transport = transport };
    }

    pub fn deinit(publisher: *Publisher) void {
        var entries = publisher.entries.iterator();
        while (entries.next()) |known| {
            publisher.allocator.free(known.key_ptr.*);
            known.value_ptr.deinit();
        }
        publisher.entries.deinit(publisher.allocator);
        publisher.* = undefined;
    }

    /// Foreground: the lint layer of `version` of `uri`. Publishes it together
    /// with the compiler layer of the same version, if there is one. A newer
    /// version retires the older compiler layer; an older version is ignored.
    pub fn publishLint(
        publisher: *Publisher,
        uri: []const u8,
        version: i32,
        lint: []const Diagnostic,
    ) !void {
        publisher.mutex.lockUncancelable(publisher.io);
        defer publisher.mutex.unlock(publisher.io);
        const tracked = try publisher.track(uri, version) orelse return;
        var layer = try Layer.copy(publisher.allocator, lint);
        errdefer layer.deinit();
        tracked.lint.deinit();
        tracked.lint = layer;
        try publisher.write(uri, tracked, false);
    }

    /// Compiler backend: the compiler layer of `version` of `uri`, with the
    /// lint layer recomputed from the compiler's facts. Dropped when the
    /// foreground has moved on to another version or closed the document, and
    /// not republished when it changes nothing.
    pub fn publishCompiled(
        publisher: *Publisher,
        uri: []const u8,
        version: i32,
        lint: []const Diagnostic,
        compiler: []const Diagnostic,
    ) !void {
        publisher.mutex.lockUncancelable(publisher.io);
        defer publisher.mutex.unlock(publisher.io);
        const known = publisher.entries.getPtr(uri) orelse return;
        if (known.version != version) return;
        var lint_layer = try Layer.copy(publisher.allocator, lint);
        errdefer lint_layer.deinit();
        var compiler_layer = try Layer.copy(publisher.allocator, compiler);
        errdefer compiler_layer.deinit();
        known.lint.deinit();
        known.lint = lint_layer;
        if (known.compiler) |*previous| previous.deinit();
        known.compiler = compiler_layer;
        try publisher.write(uri, known, true);
    }

    /// The document was closed: forget it and clear its diagnostics.
    pub fn close(publisher: *Publisher, uri: []const u8, arena: std.mem.Allocator) !void {
        publisher.mutex.lockUncancelable(publisher.io);
        defer publisher.mutex.unlock(publisher.io);
        if (publisher.entries.fetchRemove(uri)) |removed| {
            publisher.allocator.free(removed.key);
            var state = removed.value;
            state.deinit();
        }
        try publisher.transport.writeNotification(
            publisher.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        );
    }

    /// The entry for `uri` at `version`, created or advanced as needed; null
    /// when `version` is older than the one already published.
    fn track(publisher: *Publisher, uri: []const u8, version: i32) !?*Entry {
        if (publisher.entries.getPtr(uri)) |known| {
            if (version < known.version) return null;
            if (version > known.version) {
                known.version = version;
                if (known.compiler) |*stale| stale.deinit();
                known.compiler = null;
            }
            return known;
        }
        const key = try publisher.allocator.dupe(u8, uri);
        errdefer publisher.allocator.free(key);
        var empty = try Layer.copy(publisher.allocator, &.{});
        errdefer empty.deinit();
        var published = try Layer.copy(publisher.allocator, &.{});
        errdefer published.deinit();
        try publisher.entries.put(publisher.allocator, key, .{ .version = version, .lint = empty, .published = published });
        return publisher.entries.getPtr(uri).?;
    }

    fn write(publisher: *Publisher, uri: []const u8, state: *Entry, skip_identical: bool) !void {
        var scratch: std.heap.ArenaAllocator = .init(publisher.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var merged: std.ArrayList(Diagnostic) = .empty;
        try merged.appendSlice(arena, state.lint.diagnostics);
        if (state.compiler) |compiler_layer| try merged.appendSlice(arena, compiler_layer.diagnostics);
        const count = deduplicateAndSortDiagnostics(merged.items);
        const diagnostics = merged.items[0..count];
        if (skip_identical and sameDiagnostics(state.published.diagnostics, diagnostics)) return;
        const published = try Layer.copy(publisher.allocator, diagnostics);
        state.published.deinit();
        state.published = published;
        try publisher.transport.writeNotification(
            publisher.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .version = state.version, .diagnostics = diagnostics },
            .{ .emit_null_optional_fields = false },
        );
    }
};

fn sameDiagnostics(left: []const Diagnostic, right: []const Diagnostic) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.meta.eql(a.range, b.range) or a.severity != b.severity or !std.mem.eql(u8, a.message.string, b.message.string)) return false;
        const left_code: []const u8 = if (a.code) |code| code.string else "";
        const right_code: []const u8 = if (b.code) |code| code.string else "";
        if (!std.mem.eql(u8, left_code, right_code)) return false;
        if ((a.relatedInformation == null) != (b.relatedInformation == null)) return false;
    }
    return true;
}

fn copyDiagnostics(allocator: std.mem.Allocator, diagnostics: []const Diagnostic) ![]Diagnostic {
    const copies = try allocator.alloc(Diagnostic, diagnostics.len);
    for (diagnostics, copies) |diagnostic, *copy| {
        copy.* = .{
            .range = diagnostic.range,
            .severity = diagnostic.severity,
            .code = if (diagnostic.code) |code| .{ .string = try allocator.dupe(u8, code.string) } else null,
            .codeDescription = if (diagnostic.codeDescription) |description| .{ .href = try allocator.dupe(u8, description.href) } else null,
            .source = if (diagnostic.source) |source| try allocator.dupe(u8, source) else null,
            .message = .{ .string = try allocator.dupe(u8, diagnostic.message.string) },
        };
        if (diagnostic.relatedInformation) |related| {
            const related_copies = try allocator.alloc(Diagnostic.RelatedInformation, related.len);
            for (related, related_copies) |information, *related_copy| related_copy.* = .{
                .location = .{ .uri = try allocator.dupe(u8, information.location.uri), .range = information.location.range },
                .message = try allocator.dupe(u8, information.message),
            };
            copy.relatedInformation = related_copies;
        }
    }
    return copies;
}

test "syntax diagnostics describe malformed source" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const broken =");
    defer document.deinit();
    const diagnostics = try syntaxDiagnostics(&document, std.testing.allocator);
    defer {
        for (diagnostics) |diagnostic| std.testing.allocator.free(diagnostic.message.string);
        std.testing.allocator.free(diagnostics);
    }
    try std.testing.expect(diagnostics.len > 0);
    try std.testing.expect(std.mem.find(u8, diagnostics[0].message.string, "expected") != null);
}

test "a lint-only republish keeps the compiler layer of the same version" {
    var transport = TestSink.init();
    var publisher = Publisher.init(std.testing.io, std.testing.allocator, &transport.transport);
    defer publisher.deinit();
    const lint = [_]Diagnostic{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .message = .{ .string = "lint finding" } }};
    const compile_error = [_]Diagnostic{.{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 1 } }, .message = .{ .string = "compile error" } }};

    try publisher.publishLint("file:///a.zig", 1, &lint);
    try publisher.publishCompiled("file:///a.zig", 1, &lint, &compile_error);
    try publisher.publishLint("file:///a.zig", 1, &lint);

    try std.testing.expectEqual(@as(usize, 3), transport.count);
    try std.testing.expect(std.mem.find(u8, transport.output(0), "compile error") == null);
    try std.testing.expect(std.mem.find(u8, transport.output(1), "compile error") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "compile error") != null);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "lint finding") != null);
}

test "compiler results for an outdated or closed document are dropped" {
    var transport = TestSink.init();
    var publisher = Publisher.init(std.testing.io, std.testing.allocator, &transport.transport);
    defer publisher.deinit();
    const compile_error = [_]Diagnostic{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .message = .{ .string = "compile error" } }};

    try publisher.publishCompiled("file:///a.zig", 1, &.{}, &compile_error);
    try std.testing.expectEqual(@as(usize, 0), transport.count);
    try publisher.publishLint("file:///a.zig", 2, &.{});
    try publisher.publishCompiled("file:///a.zig", 1, &.{}, &compile_error);
    try std.testing.expectEqual(@as(usize, 1), transport.count);
    try publisher.publishCompiled("file:///a.zig", 2, &.{}, &compile_error);
    try std.testing.expectEqual(@as(usize, 2), transport.count);
    // The newer version retires the compiler layer: its errors no longer apply.
    try publisher.publishLint("file:///a.zig", 3, &.{});
    try std.testing.expectEqual(@as(usize, 3), transport.count);
    try std.testing.expect(std.mem.find(u8, transport.output(2), "compile error") == null);
    try publisher.close("file:///a.zig", std.testing.allocator);
    try publisher.publishCompiled("file:///a.zig", 3, &.{}, &compile_error);
    try std.testing.expectEqual(@as(usize, 4), transport.count);
}

test "an unchanged compiler result is not republished" {
    var transport = TestSink.init();
    var publisher = Publisher.init(std.testing.io, std.testing.allocator, &transport.transport);
    defer publisher.deinit();
    try publisher.publishLint("file:///a.zig", 1, &.{});
    try publisher.publishCompiled("file:///a.zig", 1, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), transport.count);
}

/// Test support: a transport that records what is written to it, without a
/// protocol peer. Writers are serialized by the `Publisher`.
pub const TestSink = struct {
    transport: lsp.Transport,
    buffers: [16][4096]u8 = undefined,
    lengths: [16]usize = @splat(0),
    count: usize = 0,

    pub fn init() TestSink {
        return .{ .transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } } };
    }

    pub fn output(sink: *const TestSink, index: usize) []const u8 {
        return sink.buffers[index][0..sink.lengths[index]];
    }

    fn read(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn write(transport: *lsp.Transport, _: std.Io, message: []const u8) lsp.Transport.WriteError!void {
        const sink: *TestSink = @fieldParentPtr("transport", transport);
        @memcpy(sink.buffers[sink.count][0..message.len], message);
        sink.lengths[sink.count] = message.len;
        sink.count += 1;
    }
};
