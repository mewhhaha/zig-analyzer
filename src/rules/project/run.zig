//! Context shared by every whole-project rule: the parsed files, the
//! configuration, compiler facts, and the sink findings go to. It mirrors
//! `context.RuleRun` for rules that read several files at once.
const std = @import("std");
const syntax_scope = @import("../../syntax/scope.zig");
const tokenize = @import("../../syntax/tokens.zig").tokenize;
const configuration_module = @import("../configuration.zig");
const context = @import("../context.zig");
const generated_source = @import("../generated_source.zig");
const support = @import("../test_support.zig");
const types = @import("../types.zig");

/// One source of the project as the caller supplies it.
pub const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
    /// The path relative to the project root that per-path configuration
    /// judges, when `path` is relative to another directory.
    config_path: ?[]const u8 = null,
};

/// A type the compiler resolved, named by its compiler-qualified declaration.
pub const CompilerShape = types.ResolvedShape;

pub const CompilerUnitFacts = struct {
    root_path: []const u8,
    shapes: []const CompilerShape,
};

pub const CompilerFacts = struct {
    units: []const CompilerUnitFacts = &.{},
    roots_complete: bool = false,
};

/// A project file with its tokens ready; `generated` marks translate-c output,
/// which naming and import conventions do not apply to, and `tool_generated`
/// a file whose header says a tool wrote it, which keeps no style rules.
pub const File = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    generated: bool,
    tool_generated: bool = false,
    config_path: []const u8,
};

/// A finding and the index of the file it belongs to.
pub const Finding = struct {
    file_index: usize,
    finding: types.Finding,
};

/// A finding as a project rule states it; the level comes from the
/// configuration.
pub const Report = struct {
    file_index: usize,
    rule: types.Rule,
    span: std.zig.Token.Loc,
    message: []const u8,
    related: []const types.RelatedSpan = &.{},
    fixes: []const types.Fix = &.{},
};

pub const ProjectRun = struct {
    /// Scratch space owned by the entry point's arena; everything allocated
    /// here is released when the analysis ends, so rules never free it.
    allocator: std.mem.Allocator,
    /// Allocator the reported findings are copied to.
    results: std.mem.Allocator,
    /// The allocator `allocator` draws from, for scratch a per-file pass
    /// releases before the analysis ends; as thread-safe as `results`.
    backing: std.mem.Allocator,
    files: []const File,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
    findings: *std.ArrayList(Finding),
    /// Syntax per file, built on first use by `syntax`.
    syntaxes: []?context.Syntax,
    /// Scope index per file, built on first use by `scopes`; shared across
    /// threads and with other passes over the same files.
    file_scopes: *syntax_scope.LazyIndexes,
    /// Lets per-file passes run on several threads; null runs them in order.
    io: ?std.Io = null,

    pub fn level(run: ProjectRun, rule: types.Rule) types.Level {
        return run.configuration.level(rule);
    }

    /// The rule's level in one file, after the per-path relaxations and
    /// overrides the file-local rules see too (`configuration.forPath`).
    pub fn levelFor(run: ProjectRun, file_index: usize, rule: types.Rule) types.Level {
        const file = run.files[file_index];
        if (file.tool_generated and rule.tier() == .style) return .off;
        return configuration_module.forPath(run.configuration, file.config_path).level(rule);
    }

    /// Records the finding unless its rule is off in the file.
    pub fn report(run: ProjectRun, found: Report) !void {
        try run.emit(found.file_index, .{
            .rule = found.rule,
            .level = run.levelFor(found.file_index, found.rule),
            .span = found.span,
            .message = found.message,
            .related = found.related,
            .fixes = found.fixes,
        });
    }

    /// Records the finding unless its level is off, copying it to `results`.
    pub fn emit(run: ProjectRun, file_index: usize, finding: types.Finding) !void {
        if (finding.level == .off) return;
        try run.findings.append(run.results, .{ .file_index = file_index, .finding = try cloneFinding(run.results, finding) });
    }

    /// The tree and scope index of a file, parsed on first use.
    pub fn syntax(run: ProjectRun, file_index: usize) !*const context.Syntax {
        const slot = &run.syntaxes[file_index];
        if (slot.* == null) {
            const file = run.files[file_index];
            slot.* = try context.Syntax.init(run.allocator, file.source, file.tokens);
        }
        return &slot.*.?;
    }

    /// The scope index of a file, built on first use and kept until the
    /// analysis ends; unlike `syntax`, it parses nothing.
    pub fn scopes(run: ProjectRun, file_index: usize) !*const syntax_scope.Index {
        const file = run.files[file_index];
        return run.file_scopes.at(file_index, file.source, file.tokens);
    }

    /// A `RuleRun` over one file for the file-local passes project analysis
    /// re-runs with summaries; their findings land in `local`.
    pub fn ruleRun(run: ProjectRun, file_index: usize, local: *std.ArrayList(types.Finding)) !context.RuleRun {
        const shared = try run.syntax(file_index);
        return shared.ruleRun(run.allocator, run.configuration, local);
    }
};

pub fn newFile(source_file: SourceFile, tokens: []const std.zig.Token) File {
    return .{
        .path = source_file.path,
        .source = source_file.source,
        .tokens = tokens,
        .generated = generated_source.isTranslateCOutput(source_file.source),
        .tool_generated = generated_source.hasGeneratedHeader(source_file.source),
        .config_path = source_file.config_path orelse source_file.path,
    };
}

fn cloneFinding(allocator: std.mem.Allocator, finding: types.Finding) !types.Finding {
    const message = try allocator.dupe(u8, finding.message);
    errdefer allocator.free(message);
    const related = try cloneRelated(allocator, finding.related);
    errdefer allocator.free(related);
    return .{
        .rule = finding.rule,
        .level = finding.level,
        .span = finding.span,
        .message = message,
        .related = related,
        .fixes = try cloneFixes(allocator, finding.fixes),
    };
}

fn cloneRelated(allocator: std.mem.Allocator, related: []const types.RelatedSpan) ![]const types.RelatedSpan {
    const copies = try allocator.alloc(types.RelatedSpan, related.len);
    errdefer allocator.free(copies);
    for (related, copies) |source, *target| target.* = .{
        .span = source.span,
        .message = try allocator.dupe(u8, source.message),
    };
    return copies;
}

fn cloneFixes(allocator: std.mem.Allocator, fixes: []const types.Fix) ![]const types.Fix {
    const copies = try allocator.alloc(types.Fix, fixes.len);
    errdefer allocator.free(copies);
    for (fixes, copies) |source, *target| {
        target.* = source;
        target.title = try allocator.dupe(u8, source.title);
        target.edits = try cloneEdits(allocator, source.edits);
    }
    return copies;
}

fn cloneEdits(allocator: std.mem.Allocator, edits: []const types.Edit) ![]const types.Edit {
    const copies = try allocator.alloc(types.Edit, edits.len);
    errdefer allocator.free(copies);
    for (edits, copies) |source, *target| target.* = .{
        .span = source.span,
        .replacement = try allocator.dupe(u8, source.replacement),
    };
    return copies;
}

/// Workers a parallel pass uses at most.
const max_workers = 8;

/// Runs `body(context, index)` for every index below `count`. With `run.io`
/// the indices are shared by a few threads, so `body` may only touch state of
/// its own index (and read-only state); the first error stops the pass.
pub fn forEachIndex(
    run: ProjectRun,
    count: usize,
    payload: anytype,
    comptime body: fn (@TypeOf(payload), usize) anyerror!void,
) !void {
    const io = run.io orelse {
        for (0..count) |index| try body(payload, index);
        return;
    };
    const Pass = struct {
        payload: @TypeOf(payload),
        next: std.atomic.Value(usize) = .init(0),
        failure: ?anyerror = null,
        mutex: std.Io.Mutex = .init,

        fn work(pass: *@This(), pass_io: std.Io, total: usize) void {
            while (true) {
                const index = pass.next.fetchAdd(1, .monotonic);
                if (index >= total) return;
                body(pass.payload, index) catch |err| {
                    pass.mutex.lockUncancelable(pass_io);
                    defer pass.mutex.unlock(pass_io);
                    if (pass.failure == null) pass.failure = err;
                    pass.next.store(total, .monotonic);
                    return;
                };
            }
        }
    };
    var pass: Pass = .{ .payload = payload };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (1..@max(1, @min(max_workers, count / 4))) |_| group.concurrent(io, Pass.work, .{ &pass, io, count }) catch break;
    pass.work(io, count);
    try group.await(io);
    if (pass.failure) |failure| return failure;
}

/// Releases findings `ProjectRun` copied to `allocator`.
pub fn freeFindings(allocator: std.mem.Allocator, found: []const Finding) void {
    for (found) |entry| freeFinding(allocator, entry.finding);
    allocator.free(found);
}

/// Releases one finding `ProjectRun` copied to `allocator`.
pub fn freeFinding(allocator: std.mem.Allocator, finding: types.Finding) void {
    allocator.free(finding.message);
    for (finding.related) |related| allocator.free(related.message);
    allocator.free(finding.related);
    for (finding.fixes) |fix| {
        allocator.free(fix.title);
        for (fix.edits) |edit| allocator.free(edit.replacement);
        allocator.free(fix.edits);
    }
    allocator.free(finding.fixes);
}

fn testFile(allocator: std.mem.Allocator, source_file: SourceFile) !File {
    return newFile(source_file, try tokenize(allocator, source_file.source));
}

/// A run over `files` whose scratch is `scratch` and whose findings are
/// copied to `results`.
fn testRun(
    scratch: std.mem.Allocator,
    results: std.mem.Allocator,
    files: []const File,
    configuration: types.Configuration,
    found: *std.ArrayList(Finding),
    file_scopes: *syntax_scope.LazyIndexes,
) !ProjectRun {
    const syntaxes = try scratch.alloc(?context.Syntax, files.len);
    @memset(syntaxes, null);
    return .{
        .allocator = scratch,
        .results = results,
        .backing = results,
        .files = files,
        .configuration = configuration,
        .compiler_facts = .{},
        .findings = found,
        .syntaxes = syntaxes,
        .file_scopes = file_scopes,
    };
}

test "new files record whether a tool wrote them and the path configuration judges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plain = try testFile(allocator, .{ .path = "src/plain.zig", .source = "const answer = 42;" });
    try std.testing.expect(!plain.generated and !plain.tool_generated);
    try std.testing.expectEqualStrings("src/plain.zig", plain.config_path);
    try std.testing.expectEqual(std.zig.Token.Tag.eof, plain.tokens[plain.tokens.len - 1].tag);
    // Written out once, so this file does not itself read as translate-c output.
    var preamble: std.Io.Writer.Allocating = .init(allocator);
    for ([_]u8{ 16, 32, 64 }) |width| {
        try preamble.writer.print("pub const __builtin_bswap{d} = @import(\"std\").zig.c_builtins.__builtin_bswap{d};\n", .{ width, width });
    }
    const translated = try testFile(allocator, .{ .path = "src/c.zig", .source = try preamble.toOwnedSliceSentinel(0) });
    try std.testing.expect(translated.generated and !translated.tool_generated);
    const tool = try testFile(allocator, .{
        .path = "gen/tables.zig",
        .source = "// Code generated by tablegen. DO NOT EDIT.\nconst table = 1;",
        .config_path = "pkg/gen/tables.zig",
    });
    try std.testing.expect(!tool.generated and tool.tool_generated);
    try std.testing.expectEqualStrings("gen/tables.zig", tool.path);
    try std.testing.expectEqualStrings("pkg/gen/tables.zig", tool.config_path);
}

test "a file's level drops style rules in tool output and applies the overrides for its path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var configuration = support.only(&.{ .recursive_call, .unreleased_allocation }, .warning);
    configuration.overrides = &.{.{
        .paths = &.{"src/legacy/**"},
        .lints = .{ .rule_levels = &.{.{ .rule = .unreleased_allocation, .level = .information }} },
    }};
    const files = [_]File{
        try testFile(allocator, .{ .path = "src/main.zig", .source = "fn walk() void { walk(); }" }),
        try testFile(allocator, .{ .path = "src/tables.zig", .source = "// @generated\nfn walk() void { walk(); }" }),
        try testFile(allocator, .{ .path = "legacy/old.zig", .source = "fn walk() void { walk(); }", .config_path = "src/legacy/old.zig" }),
    };
    var found: std.ArrayList(Finding) = .empty;
    var file_scopes: syntax_scope.LazyIndexes = try .init(allocator, null, files.len);
    defer file_scopes.deinit();
    const run = try testRun(allocator, allocator, &files, configuration, &found, &file_scopes);
    try std.testing.expectEqual(types.Level.warning, run.level(.recursive_call));
    try std.testing.expectEqual(types.Level.warning, run.levelFor(0, .recursive_call));
    try std.testing.expectEqual(types.Level.off, run.levelFor(1, .recursive_call));
    try std.testing.expectEqual(types.Level.warning, run.levelFor(1, .unreleased_allocation));
    try std.testing.expectEqual(types.Level.warning, run.levelFor(2, .recursive_call));
    try std.testing.expectEqual(types.Level.information, run.levelFor(2, .unreleased_allocation));
    try std.testing.expectEqual(types.Level.warning, run.levelFor(0, .unreleased_allocation));
}

test "reports take their file's level and are copied out of scratch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const files = [_]File{
        try testFile(scratch, .{ .path = "src/main.zig", .source = "fn walk() void { walk(); }" }),
        try testFile(scratch, .{ .path = "src/tables.zig", .source = "// @generated\nfn walk() void { walk(); }" }),
    };
    var found: std.ArrayList(Finding) = .empty;
    defer found.deinit(std.testing.allocator);
    defer for (found.items) |entry| freeFinding(std.testing.allocator, entry.finding);
    var file_scopes: syntax_scope.LazyIndexes = try .init(scratch, null, files.len);
    defer file_scopes.deinit();
    const run = try testRun(scratch, std.testing.allocator, &files, support.only(&.{.recursive_call}, .information), &found, &file_scopes);
    const message = try scratch.dupe(u8, "recursive call");
    const title = try scratch.dupe(u8, "Use a loop");
    const replacement = try scratch.dupe(u8, "loop");
    const note = try scratch.dupe(u8, "declared here");
    const edits = [_]types.Edit{.{ .span = .{ .start = 17, .end = 21 }, .replacement = replacement }};
    const fixes = [_]types.Fix{.{ .title = title, .kind = .quickfix, .edits = &edits }};
    const related = [_]types.RelatedSpan{.{ .span = .{ .start = 3, .end = 7 }, .message = note }};
    for (0..files.len) |file_index| try run.report(.{
        .file_index = file_index,
        .rule = .recursive_call,
        .span = .{ .start = 17, .end = 21 },
        .message = message,
        .related = &related,
        .fixes = &fixes,
    });
    // The style rule is off in the generated file, so only the first is kept.
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    const kept = found.items[0];
    try std.testing.expectEqual(@as(usize, 0), kept.file_index);
    try std.testing.expectEqual(types.Level.information, kept.finding.level);
    for ([_][]u8{ message, title, replacement, note }) |text| @memset(text, 'x');
    try std.testing.expectEqualStrings("recursive call", kept.finding.message);
    try std.testing.expectEqualStrings("Use a loop", kept.finding.fixes[0].title);
    try std.testing.expectEqualStrings("loop", kept.finding.fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("declared here", kept.finding.related[0].message);
    try run.emit(0, .{ .rule = .recursive_call, .level = .off, .span = .{ .start = 0, .end = 0 }, .message = message });
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
}

test "a file's syntax and scope index are built once and shared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const files = [_]File{
        try testFile(allocator, .{ .path = "src/a.zig", .source = "fn a() void {}" }),
        try testFile(allocator, .{ .path = "src/b.zig", .source = "fn b(x: u8) u8 { return x; }" }),
    };
    var found: std.ArrayList(Finding) = .empty;
    var file_scopes: syntax_scope.LazyIndexes = try .init(allocator, null, files.len);
    defer file_scopes.deinit();
    const run = try testRun(allocator, allocator, &files, types.Configuration.defaults(), &found, &file_scopes);
    const syntax = try run.syntax(1);
    try std.testing.expectEqual(syntax, try run.syntax(1));
    try std.testing.expect(run.syntaxes[0] == null);
    const scopes = try run.scopes(1);
    try std.testing.expectEqual(scopes, try run.scopes(1));
    // The `x` that `return x` reads is the parameter.
    try std.testing.expect(scopes.findBindingNamed("x", files[1].tokens.len - 4) != null);
    var local: std.ArrayList(types.Finding) = .empty;
    const rule_run = try run.ruleRun(1, &local);
    try std.testing.expectEqual(files[1].tokens.ptr, rule_run.tokens.ptr);
    try std.testing.expectEqual(&local, rule_run.findings);
}

test "forEachIndex visits each index once on one thread or several and stops at the first error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var found: std.ArrayList(Finding) = .empty;
    var file_scopes: syntax_scope.LazyIndexes = try .init(allocator, null, 0);
    defer file_scopes.deinit();
    var run = try testRun(allocator, allocator, &.{}, types.Configuration.defaults(), &found, &file_scopes);
    const Visits = struct {
        counts: [64]std.atomic.Value(u32) = @splat(.init(0)),
        failing: ?usize = null,

        fn visit(visits: *@This(), index: usize) !void {
            if (visits.failing == index) return error.Stop;
            _ = visits.counts[index].fetchAdd(1, .monotonic);
        }
    };
    for ([_]?std.Io{ null, std.testing.io }) |io| {
        run.io = io;
        var visits: Visits = .{};
        try forEachIndex(run, visits.counts.len, &visits, Visits.visit);
        for (&visits.counts) |*count| try std.testing.expectEqual(@as(u32, 1), count.load(.monotonic));
        var failing: Visits = .{ .failing = 5 };
        try std.testing.expectError(error.Stop, forEachIndex(run, failing.counts.len, &failing, Visits.visit));
        try std.testing.expectEqual(@as(u32, 0), failing.counts[5].load(.monotonic));
    }
}
