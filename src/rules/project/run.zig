//! Context shared by every whole-project rule: the parsed files, the
//! configuration, compiler facts, and the sink findings go to. It mirrors
//! `context.RuleRun` for rules that read several files at once.
const std = @import("std");
const context = @import("../context.zig");
const generated_source = @import("../generated_source.zig");
const types = @import("../types.zig");

/// One source of the project as the caller supplies it.
pub const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
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
/// which naming and import conventions do not apply to.
pub const File = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    generated: bool,
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
    files: []const File,
    configuration: types.Configuration,
    compiler_facts: CompilerFacts,
    findings: *std.ArrayList(Finding),
    /// Syntax per file, built on first use by `syntax`.
    syntaxes: []?context.Syntax,
    /// Lets per-file passes run on several threads; null runs them in order.
    io: ?std.Io = null,

    pub fn level(run: ProjectRun, rule: types.Rule) types.Level {
        return run.configuration.level(rule);
    }

    /// Records the finding unless its rule is off.
    pub fn report(run: ProjectRun, found: Report) !void {
        try run.emit(found.file_index, .{
            .rule = found.rule,
            .level = run.level(found.rule),
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
    for (found) |entry| {
        allocator.free(entry.finding.message);
        for (entry.finding.related) |related| allocator.free(related.message);
        allocator.free(entry.finding.related);
        for (entry.finding.fixes) |fix| {
            allocator.free(fix.title);
            for (fix.edits) |edit| allocator.free(edit.replacement);
            allocator.free(fix.edits);
        }
        allocator.free(entry.finding.fixes);
    }
    allocator.free(found);
}
