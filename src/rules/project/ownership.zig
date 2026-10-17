//! The cross-file ownership engine. It summarizes every file once, then runs
//! the checks that need a callee's summary from another file: the
//! file-local lifecycle engines re-run with summaries, and the owned-field
//! cleanup proofs.
const std = @import("std");
const allocation_lifecycle = @import("../lifecycle/allocation_lifecycle.zig");
const project = @import("../project.zig");
const summaries = @import("../summaries.zig");
const types = @import("../types.zig");
const owned_fields = @import("owned_fields.zig");
const run_module = @import("run.zig");
const summary_checks = @import("summary_checks.zig");

/// Rules only this engine reports.
pub const rules = owned_fields.rules;

/// Rules a file-local engine owns and this engine re-runs with cross-file
/// summaries, adding findings that need a callee in another file.
pub const refines = [_]types.Rule{
    .missing_errdefer,
    .discarded_read_count,
    .discarded_write_count,
    .invalidated_element_pointer,
    .invalidated_container_view,
    .iterator_invalidated_during_loop,
    .local_storage_escape,
    .returning_released_value,
    .unflushed_writer,
} ++ allocation_lifecycle.rules;

const summary_rules = refines ++ rules;

pub fn run(project_run: run_module.ProjectRun) !void {
    if (!project_run.configuration.anyEnabled(&summary_rules)) return;
    const sources = try project_run.allocator.alloc(summaries.Source, project_run.files.len);
    for (project_run.files, sources, 0..) |file, *source, file_index| source.* = .{
        .file_index = file_index,
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens,
    };
    const summary_index = try summaries.build(project_run.allocator, sources, project_run.configuration);
    try owned_fields.findIncompleteOwnedFieldCleanup(project_run, summary_index);
    try summary_checks.findDeferredOwnedEscapes(project_run, summary_index);
    // Files are checked on several threads, each into a list of its own that
    // is joined in file order, so the findings are the same as in one thread.
    const per_file = try project_run.allocator.alloc(std.ArrayList(run_module.Finding), project_run.files.len);
    @memset(per_file, .empty);
    defer for (per_file) |*found| found.deinit(project_run.results);
    try run_module.forEachIndex(project_run, project_run.files.len, FileChecks{
        .run = project_run,
        .summary_index = summary_index,
        .per_file = per_file,
    }, FileChecks.check);
    for (per_file) |found| try project_run.findings.appendSlice(project_run.results, found.items);
}

const FileChecks = struct {
    run: run_module.ProjectRun,
    summary_index: summaries.Index,
    per_file: []std.ArrayList(run_module.Finding),

    fn check(checks: FileChecks, file_index: usize) !void {
        // The file's syntax and scratch are released when its checks end, so
        // only the files in flight hold a tree; findings are copied out.
        var file_arena: std.heap.ArenaAllocator = .init(checks.run.backing);
        defer file_arena.deinit();
        var file_run = checks.run;
        file_run.allocator = file_arena.allocator();
        file_run.findings = &checks.per_file[file_index];
        defer checks.run.syntaxes[file_index] = null;
        try summary_checks.checkFile(file_run, file_index, checks.summary_index);
    }
};

const borrowing_files = [_]project.SourceFile{
    .{ .path = "src/inspect.zig", .source = "pub fn inspect(bytes: []u8) void { _ = bytes.len; }" },
    .{ .path = "src/main.zig", .source = "const inspection = @import(\"inspect.zig\");" ++
        "fn run(allocator: std.mem.Allocator) !void { const bytes = try allocator.alloc(u8, 4); inspection.inspect(bytes); }" },
};

const owned_field_files = [_]project.SourceFile{.{
    .path = "src/record.zig",
    .source = "const Record = struct { title: []u8, payload: []u8, allocator: std.mem.Allocator, " ++
        "fn deinit(self: Record) void { self.allocator.free(self.title); } };" ++
        "fn make(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
        "fn makeRecord(allocator: std.mem.Allocator) !Record {" ++
        "const title = try make(allocator, \"title\"); const payload = try make(allocator, \"payload\");" ++
        "return .{ .title = title, .payload = payload, .allocator = allocator }; }",
}};

fn alone(rule: types.Rule) types.Configuration {
    var configuration = types.Configuration.defaults();
    @memset(&configuration.levels, .off);
    configuration.levels[@backingInt(rule)] = .warning;
    return configuration;
}

fn expectOnly(found: []const run_module.Finding, rule: types.Rule, file_index: usize) !void {
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(rule, found[0].finding.rule);
    try std.testing.expectEqual(file_index, found[0].file_index);
}

test "a refined rule or an owned-field rule alone starts the engine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // A file-local engine re-run with the summary of a callee in another file.
    try expectOnly(
        try project.findings(allocator, &borrowing_files, alone(.unreleased_allocation)),
        .unreleased_allocation,
        1,
    );
    // A proof only this engine makes.
    try expectOnly(
        try project.findings(allocator, &owned_field_files, alone(.incomplete_owned_field_cleanup)),
        .incomplete_owned_field_cleanup,
        0,
    );
    // With neither enabled, the engine reports nothing.
    var configuration = types.Configuration.defaults();
    for (summary_rules) |rule| configuration.levels[@backingInt(rule)] = .off;
    for ([_][]const project.SourceFile{ &borrowing_files, &owned_field_files }) |files| {
        for (try project.findings(allocator, files, configuration)) |finding| {
            for (summary_rules) |rule| try std.testing.expect(finding.finding.rule != rule);
        }
    }
}

test "per-file checks on several threads find what one thread finds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Callers in other files of one borrowing helper, and owned-field proofs.
    var files: std.ArrayList(project.SourceFile) = .empty;
    try files.append(allocator, borrowing_files[0]);
    for (0..12) |index| {
        try files.append(allocator, .{ .path = try allocator.print("src/caller{d}.zig", .{index}), .source = borrowing_files[1].source });
        try files.append(allocator, .{ .path = try allocator.print("src/record{d}.zig", .{index}), .source = owned_field_files[0].source });
    }
    const configuration = types.Configuration.defaults();
    const sequential = try project.findings(allocator, files.items, configuration);
    // The testing allocator also proves the per-file lists are released.
    const concurrent = try project.findingsConcurrently(std.testing.io, std.testing.allocator, files.items, configuration, .{}, null);
    defer project.freeFindings(std.testing.allocator, concurrent);
    var leaks: usize = 0;
    var owned_fields_found: usize = 0;
    for (sequential) |finding| switch (finding.finding.rule) {
        .unreleased_allocation => leaks += 1,
        .incomplete_owned_field_cleanup => owned_fields_found += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 12), leaks);
    try std.testing.expectEqual(@as(usize, 12), owned_fields_found);
    try std.testing.expectEqual(sequential.len, concurrent.len);
    for (sequential, concurrent) |one, several| {
        try std.testing.expectEqual(one.file_index, several.file_index);
        try std.testing.expectEqual(one.finding.rule, several.finding.rule);
        try std.testing.expectEqual(one.finding.span, several.finding.span);
        try std.testing.expectEqualStrings(one.finding.message, several.finding.message);
    }
}
