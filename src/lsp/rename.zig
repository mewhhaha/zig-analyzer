//! Rename: the edits that change every occurrence of a name.
//!
//! A local (parameter, variable, capture) is renamed by lexical scoping alone.
//! A container member (a field, method, enum case, or top-level declaration)
//! is renamed by compiler identity when a compiler is available: every
//! occurrence of the spelling in the open documents and in the files of the
//! compile units that contain the document is asked of the compiler, and only
//! those that resolve to the declaration under the cursor are edited. If the
//! document belongs to several configured compile units, the same questions
//! are asked in each of them and a rename whose answers differ is refused,
//! because it would be right for one build configuration and wrong for another.
//!
//! Without a compiler, a document outside every unit, or a name the compiler
//! cannot resolve, rename falls back to syntax scoping unchanged. The mode
//! used is reported in the editor log either way.
//!
//! Waiting is bounded, since rename is user-initiated: up to `session_wait_ms`
//! for the compile in progress, and up to `unit_deadline_ms` for each other
//! compile unit, of which at most `max_probed_units` are started. Units that
//! analyze the document identically (same configuration of the modules that
//! contain it) are compared once. Occurrences in files that only other units
//! contain are resolved by the first unit that contains each.
const std = @import("std");

const lsp = @import("lsp");

const actions = @import("../actions/registry.zig");
const build_graph = @import("../compiler/build_graph.zig");
const compile_units = @import("../compiler/compile_units.zig");
const protocol = @import("../compiler/protocol.zig");
const compiler_session = @import("../compiler/session.zig");
const document_module = @import("../syntax/document.zig");
const symbol_query = @import("../syntax/symbol_query.zig");
const syntax_types = @import("../syntax/types.zig");
const uri_module = @import("../uri.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Services = services_module.Services;
const Session = compiler_session.Session;
const Symbol = compiler_session.Symbol;

/// Longest a rename waits for a compile already in progress.
pub const session_wait_ms = 5_000;
/// Longest a rename waits for each other compile unit to start and analyze.
pub const unit_deadline_ms = 30_000;
/// Most other compile units one rename starts a compiler for, to compare the
/// declaration across the units that contain the document and to resolve the
/// files only other units contain.
pub const max_probed_units = 16;
const max_candidate_files = 4096;
const max_file_bytes = 4 * 1024 * 1024;

/// How a rename found what to edit.
pub const Mode = enum { compiler, syntax };

pub const Report = struct {
    mode: Mode,
    /// For the editor log: what happened and why.
    message: []const u8,
};

const Result = union(enum) {
    edit: lsp.types.WorkspaceEdit,
    /// The cursor is not on a name this server renames.
    nothing,
    /// The rename is wrong or unsafe; the message says why.
    refused: []const u8,
};

const Planned = struct {
    result: Result,
    report: Report,
    /// Something the user should look at even though the rename went ahead.
    warning: ?[]const u8 = null,
};

pub fn rename(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/rename"),
) !lsp.ResultType("textDocument/rename") {
    if (!syntax_types.isIdentifier(params.newName)) return error.InvalidParams;
    const origin = services.documents.getConst(params.textDocument.uri) orelse return null;
    const offset = origin.byteOffset(params.position);
    const identifier = origin.identifierAt(offset);
    const site = try symbol_query.siteAt(arena, origin, offset);
    if (identifier == null and site == null) return null;

    const planned = try plan(services, arena, origin, identifier, site, params.newName);
    services.linter.logMessage(arena, planned.report.message) catch |err| {
        std.log.warn("could not log the rename report: {t}", .{err});
    };
    if (planned.warning) |warning| services.linter.showMessage(arena, .Warning, warning) catch |err| {
        std.log.warn("could not show the rename warning: {t}", .{err});
    };
    switch (planned.result) {
        .edit => |edit| return edit,
        .nothing => return null,
        .refused => |message| {
            services.linter.showMessage(arena, .Error, message) catch |err| {
                std.log.warn("could not show why the rename was refused: {t}", .{err});
            };
            return error.RequestFailed;
        },
    }
}

fn plan(
    services: Services,
    arena: std.mem.Allocator,
    origin: *const Document,
    identifier: ?std.zig.Token.Loc,
    site: ?symbol_query.Site,
    new_name: []const u8,
) !Planned {
    var reason: []const u8 = "the name is not a container member";
    if (site) |found| switch (found.role) {
        .local => reason = "the name is a local binding, which lexical scoping decides",
        .member => switch (try compilerPlan(services, arena, origin, found, new_name)) {
            .planned => |planned| return planned,
            .fallback => |why| reason = why,
        },
    } else reason = "the name is not one the compiler is asked about";
    const span = identifier orelse return .{
        .result = .nothing,
        .report = .{ .mode = .syntax, .message = "rename: nothing to rename here" },
    };
    const edit = try workspaceEdit(services, arena, origin, span, new_name);
    return .{
        .result = if (edit) |value| .{ .edit = value } else .nothing,
        .report = .{
            .mode = .syntax,
            .message = try arena.print("rename '{s}' to '{s}': syntax scoping ({s})", .{
                origin.source[span.start..span.end],
                new_name,
                reason,
            }),
        },
    };
}

/// The edit renaming the identifier at `identifier_span` of `origin` by syntax
/// scoping alone, or null when it is not a declaration this server can
/// rename. Fails with `RequestFailed` when the new name is taken or the
/// declaration is ambiguous.
pub fn workspaceEdit(
    services: Services,
    arena: std.mem.Allocator,
    origin: *const Document,
    identifier_span: std.zig.Token.Loc,
    new_name: []const u8,
) !?lsp.types.WorkspaceEdit {
    if (!syntax_types.isIdentifier(new_name)) return error.InvalidParams;
    const name = origin.source[identifier_span.start..identifier_span.end];
    if (origin.declarationNamed(new_name) != null) return error.RequestFailed;
    if (try origin.scopedIdentifierSpans(arena, identifier_span.start)) |spans| {
        const reflected_spans = if (try actions.naming.isContainerField(arena, origin.source, identifier_span))
            try actions.naming.reflectionStringSpans(arena, origin.source, name)
        else
            &.{};
        const edit_count = std.math.add(usize, spans.len, reflected_spans.len) catch |err| switch (err) {
            error.Overflow => return error.RequestFailed,
        };
        const edits = try arena.alloc(lsp.types.TextEdit, edit_count);
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
    var declaration_iterator = services.documents.documents.valueIterator();
    while (declaration_iterator.next()) |document| {
        if (document.declarationNamed(name) != null) declaration_count += 1;
    }
    if (declaration_count != 1) return error.RequestFailed;

    var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
    var iterator = services.documents.documents.valueIterator();
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

// ---- compiler identity ----------------------------------------------------

const Attempt = union(enum) {
    planned: Planned,
    /// The compiler cannot answer; why, for the log.
    fallback: []const u8,
};

/// A file that may hold occurrences, with the questions its member sites ask.
const Candidate = struct {
    document: *const Document,
    /// Sites the syntax can state a question for, and the questions.
    sites: []const symbol_query.Site,
    queries: []const symbol_query.Query,
    /// Sites the syntax cannot state a question for.
    unverifiable: []const symbol_query.Site,
};

/// The compiler's answers to the target question and every candidate's.
const Answers = struct {
    target: Symbol,
    /// Parallel to the candidates; null when the compiler does not contain the
    /// file.
    files: []const ?[]const Symbol,
};

fn compilerPlan(
    services: Services,
    arena: std.mem.Allocator,
    origin: *const Document,
    site: symbol_query.Site,
    new_name: []const u8,
) !Attempt {
    const backend = services.backend;
    const query = site.role.member orelse
        return .{ .fallback = "the syntax around the name does not say where it is declared" };
    const name = origin.source[site.span.start..site.span.end];
    const origin_path = (try uri_module.toPath(arena, origin.uri)) orelse
        return .{ .fallback = "the document is not a file" };

    const session = backend.acquireWithin(origin.uri, origin.version, session_wait_ms) orelse
        return .{ .fallback = "the compiler has not analyzed this version of the document" };
    var holding = true;
    defer if (holding) backend.release();
    const compile = backend.activeCompile();
    const active_launch: ?u64 = if (compile) |active| if (active.unit != null) active.launch else null else null;

    const graph = try buildGraphFor(services.io, arena, origin_path);
    defer if (graph) |known| known.release();
    const containing: []const *const build_graph.Unit = if (graph) |known|
        try known.unitsContaining(services.io, arena, origin_path)
    else
        &.{};
    const workspace = try workspaceRoot(services.io, arena, origin_path, containing.len != 0);
    const cache_root: []const u8 = if (compile) |active| try arena.dupe(u8, active.cache_root) else workspace;

    const first = firstPass(services, arena, session, origin, query, name, new_name, workspace, containing, graph) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            backend.fail(err, origin.uri);
            holding = false;
            return .{ .fallback = try arena.print("the compiler request failed ({t})", .{err}) };
        },
    };
    backend.release();
    holding = false;
    const primary = switch (first) {
        .answered => |answered| answered,
        .fallback => |why| return .{ .fallback = why },
        .refused => |message| return .{ .planned = .{
            .result = .{ .refused = message },
            .report = .{ .mode = .compiler, .message = message },
        } },
    };

    // Other compile units that contain the document must agree. Units that
    // analyze the file exactly as one already compared do (same configuration
    // of the modules containing it) add nothing.
    var others: std.ArrayList(*const build_graph.Unit) = .empty;
    var compared: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var probed: std.AutoHashMapUnmanaged(*const build_graph.Unit, void) = .empty;
    var active_label: []const u8 = "the analyzed file";
    if (graph) |known| {
        for (containing) |unit| {
            if (!try isActive(arena, unit, active_launch)) continue;
            try compared.put(arena, try known.analysisKey(services.io, arena, unit, origin_path), {});
            try probed.put(arena, unit, {});
            active_label = try unitLabel(arena, unit);
        }
        for (containing) |unit| {
            if (try isActive(arena, unit, active_launch)) continue;
            const key = try known.analysisKey(services.io, arena, unit, origin_path);
            if ((try compared.getOrPut(arena, key)).found_existing) continue;
            try others.append(arena, unit);
        }
    }
    if (others.items.len > max_probed_units) {
        const message = try arena.print(
            "Cannot rename '{s}': the file is analyzed {d} different ways by the compile units and at most {d} others can be compared.",
            .{ name, others.items.len + 1, max_probed_units },
        );
        return .{ .planned = .{ .result = .{ .refused = message }, .report = .{ .mode = .compiler, .message = message } } };
    }

    // Each answer set is merged into one per file: the first compile that
    // contains the file decides what it says.
    const candidates = primary.candidates;
    const merged = try arena.dupe(?[]const Symbol, primary.answers.files);
    var used: std.ArrayList([]const u8) = .empty;
    try used.append(arena, active_label);
    var unchecked: std.ArrayList([]const u8) = .empty;
    var probes: usize = 0;
    for (others.items) |unit| {
        probes += 1;
        try probed.put(arena, unit, {});
        const answers = probeUnit(services, arena, unit, cache_root, origin, query, candidates) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try unchecked.append(arena, try arena.print("{s} ({t})", .{ try unitLabel(arena, unit), err }));
                continue;
            },
        };
        if (try firstDifference(arena, candidates, primary.answers, answers, active_label, try unitLabel(arena, unit))) |difference| {
            const message = try arena.print(
                "Cannot rename '{s}': the declaration differs between compile units. {s}",
                .{ name, difference },
            );
            return .{ .planned = .{ .result = .{ .refused = message }, .report = .{ .mode = .compiler, .message = message } } };
        }
        merge(merged, answers.files);
        try used.append(arena, try unitLabel(arena, unit));
    }

    // Files the compiles so far do not contain (the roots of other units, say)
    // still hold occurrences: ask the first unit that contains each.
    if (graph) |known| {
        const given_up = try arena.alloc(bool, candidates.len);
        @memset(given_up, false);
        while (probes < max_probed_units) {
            const index = for (candidates, merged, given_up, 0..) |candidate, answers, gave_up, position| {
                if (answers == null and !gave_up and (candidate.sites.len != 0 or candidate.unverifiable.len != 0)) break position;
            } else break;
            given_up[index] = true;
            const path = (try uri_module.toPath(arena, candidates[index].document.uri)) orelse continue;
            const owners = try known.unitsContaining(services.io, arena, path);
            const unit = for (owners) |owner| {
                if (!probed.contains(owner)) break owner;
            } else continue;
            probes += 1;
            try probed.put(arena, unit, {});
            const answers = probeUnit(services, arena, unit, cache_root, origin, query, candidates) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try unchecked.append(arena, try arena.print("{s} ({t})", .{ try unitLabel(arena, unit), err }));
                    continue;
                },
            };
            merge(merged, answers.files);
            try used.append(arena, try unitLabel(arena, unit));
        }
    }
    return .{ .planned = try compose(arena, candidates, primary.answers.target, merged, name, new_name, used.items, unchecked.items) };
}

/// Whether `unit` is the compile unit the running compiler was started for.
/// Units can share a name and even a root source (one program built with
/// different options), so what decides is the arguments it lowers to.
fn isActive(arena: std.mem.Allocator, unit: *const build_graph.Unit, active_launch: ?u64) !bool {
    const wanted = active_launch orelse return false;
    return (try build_graph.lower(arena, unit)).fingerprint() == wanted;
}

/// A unit's name and root, which together say which of several units with the
/// same name is meant.
fn unitLabel(arena: std.mem.Allocator, unit: *const build_graph.Unit) ![]const u8 {
    const path = unit.root().source.path() orelse return unit.name;
    return arena.print("{s} ({s})", .{ unit.name, std.Io.Dir.path.basename(path) });
}

fn merge(merged: []?[]const Symbol, files: []const ?[]const Symbol) void {
    for (merged, files) |*answer, other| {
        if (answer.* == null) answer.* = other;
    }
}

const Primary = struct {
    candidates: []const Candidate,
    answers: Answers,
};

const FirstPass = union(enum) {
    answered: Primary,
    fallback: []const u8,
    refused: []const u8,
};

/// Resolves the declaration under the cursor in the running compile, checks the
/// new name is free, gathers every file that may hold occurrences, and asks
/// about all of them. Runs with the compiler session held.
fn firstPass(
    services: Services,
    arena: std.mem.Allocator,
    session: *Session,
    origin: *const Document,
    query: symbol_query.Query,
    name: []const u8,
    new_name: []const u8,
    workspace: []const u8,
    containing: []const *const build_graph.Unit,
    graph: ?*build_graph.BuildGraph,
) !FirstPass {
    const target = (session.resolveSymbols(arena, origin.uri, &.{query}) catch |err| switch (err) {
        error.SemanticsUnavailable => return .{ .fallback = "the document is not part of the running compile" },
        else => return err,
    })[0];
    if (target.status != .resolved) {
        return .{ .fallback = try arena.print("the compiler could not resolve the declaration ({t})", .{target.status}) };
    }
    const taken = (try session.resolveSymbols(arena, origin.uri, &.{try query.retargeted(arena, new_name)}))[0];
    if (taken.status == .resolved) {
        return .{ .refused = try arena.print("Cannot rename '{s}' to '{s}': '{s}' is already declared there.", .{ name, new_name, new_name }) };
    }
    const declaring_path = try compile_units.absolutePath(services.io, arena, target.file);
    if (!isEditable(declaring_path, workspace)) {
        return .{ .refused = try arena.print("Cannot rename '{s}': it is declared in {s}, outside the workspace.", .{ name, declaring_path }) };
    }
    const candidates = try gatherCandidates(services, arena, name, declaring_path, workspace, containing, graph);
    const files = try askAboutCandidates(session, arena, candidates);
    return .{ .answered = .{ .candidates = candidates, .answers = .{ .target = target, .files = files } } };
}

fn askAboutCandidates(session: *Session, arena: std.mem.Allocator, candidates: []const Candidate) ![]const ?[]const Symbol {
    const answers = try arena.alloc(?[]const Symbol, candidates.len);
    for (candidates, answers) |candidate, *answer| {
        if (candidate.queries.len == 0) {
            answer.* = &.{};
            continue;
        }
        answer.* = session.resolveSymbols(arena, candidate.document.uri, candidate.queries) catch |err| switch (err) {
            // The compile does not contain this file.
            error.SemanticsUnavailable => null,
            else => return err,
        };
    }
    return answers;
}

/// Starts a compiler for `unit`, shows it the open buffers, and asks it the
/// same questions as the running compile.
fn probeUnit(
    services: Services,
    arena: std.mem.Allocator,
    unit: *const build_graph.Unit,
    cache_root: []const u8,
    origin: *const Document,
    query: symbol_query.Query,
    candidates: []const Candidate,
) !Answers {
    const launch = try build_graph.lower(arena, unit);
    var session = try Session.startWithin(
        services.io,
        services.backend.allocator,
        services.backend.environ,
        launch,
        cache_root,
        unit_deadline_ms,
    );
    defer session.deinit();
    var staged = false;
    var documents = services.documents.documents.valueIterator();
    while (documents.next()) |document| {
        _ = session.stageOverlay(document.uri, document.version, document.source) catch |err| switch (err) {
            error.SemanticsUnavailable => continue,
            else => return err,
        };
        staged = true;
    }
    if (staged) try session.update();
    const target = if (session.resolveSymbols(arena, origin.uri, &.{query})) |answers| answers[0] else |err| switch (err) {
        // A unit that does not contain the document says nothing about it.
        error.SemanticsUnavailable => Symbol{ .status = .unresolved, .kind = .none, .file = "", .start = 0, .end = 0 },
        else => return err,
    };
    return .{ .target = target, .files = try askAboutCandidates(&session, arena, candidates) };
}

/// Describes the first place the two compiles disagree about the declaration
/// or an occurrence, or null when they agree everywhere both can answer.
fn firstDifference(
    arena: std.mem.Allocator,
    candidates: []const Candidate,
    first: Answers,
    second: Answers,
    first_unit: ?[]const u8,
    second_unit: []const u8,
) !?[]const u8 {
    const first_name = first_unit orelse "the analyzed file";
    if (conflict(first.target, second.target)) {
        return try arena.print("'{s}' resolves the declaration to {s}, but '{s}' to {s}.", .{
            first_name, describe(first.target), second_unit, describe(second.target),
        });
    }
    for (candidates, first.files, second.files) |candidate, maybe_first, maybe_second| {
        const first_symbols = maybe_first orelse continue;
        const second_symbols = maybe_second orelse continue;
        for (candidate.sites, first_symbols, second_symbols) |site, a, b| {
            if (!conflict(a, b)) continue;
            const start = candidate.document.range(site.span).start;
            return try arena.print("At {s}:{d}:{d}, '{s}' resolves to {s}, but '{s}' to {s}.", .{
                candidate.document.uri, start.line + 1, start.character + 1, first_name, describe(a), second_unit, describe(b),
            });
        }
    }
    return null;
}

/// Whether two answers prove the builds disagree: both resolved to different
/// declarations, or exactly one found the member missing. An answer that is
/// merely unavailable proves nothing.
fn conflict(a: Symbol, b: Symbol) bool {
    if (a.status == .resolved and b.status == .resolved) return !a.same(b);
    return (a.status == .resolved and b.status == .absent) or (a.status == .absent and b.status == .resolved);
}

fn describe(symbol: Symbol) []const u8 {
    return switch (symbol.status) {
        .resolved => symbol.file,
        .absent => "no such member",
        else => "an unresolved name",
    };
}

fn compose(
    arena: std.mem.Allocator,
    candidates: []const Candidate,
    target: Symbol,
    files: []const ?[]const Symbol,
    name: []const u8,
    new_name: []const u8,
    units: []const []const u8,
    unchecked: []const []const u8,
) !Planned {
    var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
    var renamed: usize = 0;
    var excluded: usize = 0;
    var unresolved: usize = 0;
    var unverifiable: usize = 0;
    var outside: usize = 0;
    var first_left_alone: ?[]const u8 = null;
    for (candidates, files) |candidate, maybe_symbols| {
        // A file no compile unit contains is not part of any build; its
        // occurrences are some other program's.
        const symbols = maybe_symbols orelse {
            outside += candidate.sites.len + candidate.unverifiable.len;
            continue;
        };
        unverifiable += candidate.unverifiable.len;
        for (candidate.unverifiable) |site| {
            if (first_left_alone == null) first_left_alone = try locate(arena, candidate.document, site.span);
        }
        var edits: std.ArrayList(lsp.types.TextEdit) = .empty;
        for (candidate.sites, symbols) |site, symbol| {
            if (symbol.same(target)) {
                try edits.append(arena, .{ .range = candidate.document.range(site.span), .newText = new_name });
                renamed += 1;
            } else if (symbol.status == .resolved or symbol.status == .absent) {
                excluded += 1;
            } else {
                unresolved += 1;
                if (first_left_alone == null) first_left_alone = try locate(arena, candidate.document, site.span);
            }
        }
        if (edits.items.len != 0) try changes.map.put(arena, candidate.document.uri, edits.items);
    }
    var listed: std.ArrayList(u8) = .empty;
    for (units, 0..) |unit, index| {
        if (index != 0) try listed.appendSlice(arena, ", ");
        try listed.appendSlice(arena, unit);
    }
    const message = try arena.print(
        "rename '{s}' to '{s}': compiler identity (units: {s}); {d} renamed, {d} left alone as other declarations, {d} not resolved, {d} not analyzable, {d} outside every compile",
        .{ name, new_name, listed.items, renamed, excluded, unresolved, unverifiable, outside },
    );
    var warning: std.ArrayList(u8) = .empty;
    if (unresolved + unverifiable != 0) {
        try warning.print(arena, "Renamed '{s}' by compiler identity, but {d} occurrence(s) could not be resolved and were left unchanged", .{ name, unresolved + unverifiable });
        if (first_left_alone) |where| try warning.print(arena, " (first: {s})", .{where});
        try warning.append(arena, '.');
    }
    if (unchecked.len != 0) {
        if (warning.items.len != 0) try warning.append(arena, ' ');
        try warning.appendSlice(arena, "Could not analyze compile units: ");
        for (unchecked, 0..) |entry, index| {
            if (index != 0) try warning.appendSlice(arena, ", ");
            try warning.appendSlice(arena, entry);
        }
        try warning.append(arena, '.');
    }
    return .{
        .result = .{ .edit = .{ .changes = changes } },
        .report = .{ .mode = .compiler, .message = message },
        .warning = if (warning.items.len != 0) warning.items else null,
    };
}

fn locate(arena: std.mem.Allocator, document: *const Document, span: std.zig.Token.Loc) ![]const u8 {
    const start = document.range(span).start;
    return arena.print("{s}:{d}:{d}", .{ document.uri, start.line + 1, start.character + 1 });
}

// ---- candidates -------------------------------------------------------------

/// Open documents, the files of the compile units, and the declaring file,
/// each with its member sites spelled `name`. Files without any are left out.
fn gatherCandidates(
    services: Services,
    arena: std.mem.Allocator,
    name: []const u8,
    declaring_path: []const u8,
    workspace: []const u8,
    containing: []const *const build_graph.Unit,
    graph: ?*build_graph.BuildGraph,
) ![]const Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var documents = services.documents.documents.valueIterator();
    while (documents.next()) |document| {
        if (try uri_module.toPath(arena, document.uri)) |path| {
            try seen.put(arena, path, {});
            if (!isEditable(path, workspace)) continue;
        }
        try addCandidate(arena, &candidates, document, name);
    }
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(arena, declaring_path);
    if (graph) |known| for (containing) |unit| {
        try paths.appendSlice(arena, try known.unitFiles(services.io, arena, unit));
    };
    var read: usize = 0;
    for (paths.items) |path| {
        if ((try seen.getOrPut(arena, path)).found_existing or !isEditable(path, workspace)) continue;
        if (read == max_candidate_files) break;
        read += 1;
        const bytes = std.Io.Dir.cwd().readFileAlloc(services.io, path, arena, .limited(max_file_bytes)) catch continue;
        if (std.mem.find(u8, bytes, name) == null) continue;
        const document = try arena.create(Document);
        document.* = try Document.open(arena, try uri_module.fromPath(arena, path), 0, bytes);
        try addCandidate(arena, &candidates, document, name);
    }
    return candidates.items;
}

fn addCandidate(arena: std.mem.Allocator, candidates: *std.ArrayList(Candidate), document: *const Document, name: []const u8) !void {
    const sites = try symbol_query.memberSites(arena, document, name);
    if (sites.len == 0) return;
    var queryable: std.ArrayList(symbol_query.Site) = .empty;
    var queries: std.ArrayList(symbol_query.Query) = .empty;
    var unverifiable: std.ArrayList(symbol_query.Site) = .empty;
    for (sites) |site| {
        if (site.role.member) |query| {
            try queryable.append(arena, site);
            try queries.append(arena, query);
        } else try unverifiable.append(arena, site);
    }
    try candidates.append(arena, .{
        .document = document,
        .sites = queryable.items,
        .queries = queries.items,
        .unverifiable = unverifiable.items,
    });
}

/// The directory a rename may edit below: the build root when a compile unit
/// contains the document, else the document's own directory.
fn workspaceRoot(io: std.Io, arena: std.mem.Allocator, document_path: []const u8, in_build: bool) ![]const u8 {
    if (in_build) {
        if (try compile_units.nearestBuildRoot(io, arena, document_path)) |root| return root;
    }
    return std.Io.Dir.path.dirname(document_path) orelse document_path;
}

/// Whether `path` is project source: inside the workspace and not a fetched
/// package or a build cache.
fn isEditable(path: []const u8, workspace: []const u8) bool {
    if (!std.mem.startsWith(u8, path, workspace)) return false;
    const workspace_ends_with_separator = workspace.len != 0 and workspace[workspace.len - 1] == '/';
    if (path.len != workspace.len and path[workspace.len] != '/' and !workspace_ends_with_separator) return false;
    const relative = path[workspace.len..];
    for ([_][]const u8{ "/zig-pkg/", "/.zig-cache/", "/.zig-analyzer/", "/zig-out/" }) |excluded| {
        if (std.mem.find(u8, relative, excluded) != null) return false;
    }
    return true;
}

fn buildGraphFor(io: std.Io, arena: std.mem.Allocator, document_path: []const u8) !?*build_graph.BuildGraph {
    const root = (try compile_units.nearestBuildRoot(io, arena, document_path)) orelse return null;
    return try compile_units.buildGraph(io, root, .cached);
}

const testing = std.testing;

fn testSymbol(status: protocol.SymbolStatus, file: []const u8, start: u32) Symbol {
    return .{ .status = status, .kind = .field, .file = file, .start = start, .end = start + 1 };
}

test "answers conflict only when they prove the builds disagree" {
    const a = testSymbol(.resolved, "a.zig", 4);
    try testing.expect(!conflict(a, testSymbol(.resolved, "a.zig", 4)));
    try testing.expect(conflict(a, testSymbol(.resolved, "a.zig", 9)));
    try testing.expect(conflict(a, testSymbol(.resolved, "b.zig", 4)));
    try testing.expect(conflict(a, testSymbol(.absent, "", 0)));
    try testing.expect(conflict(testSymbol(.absent, "", 0), a));
    try testing.expect(!conflict(a, testSymbol(.unresolved, "", 0)));
    try testing.expect(!conflict(testSymbol(.generic, "", 0), a));
    try testing.expect(!conflict(testSymbol(.absent, "", 0), testSymbol(.absent, "", 0)));
}

test "only project source is editable" {
    try testing.expect(isEditable("/project/src/main.zig", "/project"));
    try testing.expect(isEditable("/project/main.zig", "/project/"));
    try testing.expect(!isEditable("/projects/main.zig", "/project"));
    try testing.expect(!isEditable("/project/zig-pkg/dep/dep.zig", "/project"));
    try testing.expect(!isEditable("/project/.zig-cache/o/x.zig", "/project"));
    try testing.expect(!isEditable("/elsewhere/main.zig", "/project"));
}
