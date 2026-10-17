//! Functions that allocate through an allocator outside an initialization path.
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const File = run_module.File;
const types = @import("../types.zig");
const project = @import("../project.zig");
const support = @import("../test_support.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const topLevelComma = tokens_util.topLevelComma;

pub const rules = [_]types.Rule{.allocation_after_init};

pub fn find(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.allocation_after_init) == .off) return;
    const allocation_methods = [_][]const u8{ "alloc", "allocWithOptions", "create", "dupe", "realloc" };
    for (run.files, 0..) |file, file_index| {
        if (file.generated or run.levelFor(file_index, .allocation_after_init) == .off) continue;
        // A test, and a private helper only tests call, allocates its fixtures
        // where it needs them.
        var test_only: ?syntax_scope.TestOnlyBodies = null;
        defer if (test_only) |*bodies| bodies.deinit(run.allocator);
        var test_end: usize = 0;
        for (file.tokens, 0..) |token, fn_index| {
            if (fn_index < test_end) continue;
            if (token.tag == .keyword_test) {
                test_end = tokens_util.testBlockEnd(file.tokens, fn_index) orelse continue;
                continue;
            }
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const function_name = tokenText(file.source, file.tokens[fn_index + 1]);
            if (isInitializationName(function_name)) continue;
            const scopes = try run.scopes(file_index);
            const parameters_end = scopes.matchingToken(fn_index + 2) orelse continue;
            const opening = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const closing = scopes.matchingToken(opening) orelse continue;
            var index = opening + 1;
            while (index < closing) : (index += 1) {
                const body_token = file.tokens[index];
                if (body_token.tag == .keyword_fn and index + 2 < closing and
                    file.tokens[index + 1].tag == .identifier and file.tokens[index + 2].tag == .l_paren)
                {
                    const nested_parameters_end = scopes.matchingToken(index + 2) orelse continue;
                    const nested_opening = syntax_scope.functionBodyAfterParameters(file.tokens, nested_parameters_end) orelse continue;
                    const nested_closing = scopes.matchingToken(nested_opening) orelse continue;
                    if (nested_closing < closing) index = nested_closing;
                    continue;
                }
                if (body_token.tag != .identifier or index < 2 or file.tokens[index - 1].tag != .period or file.tokens[index - 2].tag != .identifier) continue;
                var is_allocation = false;
                for (allocation_methods) |method| {
                    if (tokenIs(file.source, body_token, method)) is_allocation = true;
                }
                if (!is_allocation) continue;
                const receiver = tokenText(file.source, file.tokens[index - 2]);
                if (std.mem.find(u8, receiver, "alloc") == null and !bindingHasAllocatorType(file, fn_index, opening, receiver)) continue;
                if (test_only == null) test_only = try syntax_scope.testOnlyBodies(run.allocator, file.source, file.tokens);
                if (test_only.?.contains(opening)) break;
                try run.report(.{
                    .file_index = file_index,
                    .rule = .allocation_after_init,
                    .span = body_token.loc,
                    .message = try run.allocator.print("function '{s}' allocates through '{s}' outside a recognized initialization path", .{ function_name, receiver }),
                });
            }
        }
    }
}

fn bindingHasAllocatorType(file: File, start: usize, end: usize, name: []const u8) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, name) or index + 6 >= end or file.tokens[index + 1].tag != .colon) continue;
        const type_end = topLevelComma(file.tokens, index + 2, end) orelse end;
        if (std.mem.find(u8, file.source[file.tokens[index + 2].loc.start..file.tokens[type_end - 1].loc.end], "Allocator") != null) return true;
    }
    return false;
}

/// `init*` and `create*` set a value up; `main` sets the program up before
/// its work begins.
fn isInitializationName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "init") or std.mem.startsWith(u8, name, "create") or
        std.mem.eql(u8, name, "main");
}

test "main, tests and non-production files may allocate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.allocation_after_init}, .information);
    const grow = "fn grow(gpa: std.mem.Allocator) ![]u8 { return gpa.alloc(u8, 1); }";
    const files = [_]project.SourceFile{
        .{ .path = "src/main.zig", .source =
        \\pub fn main(gpa: std.mem.Allocator) !void {
        \\    gpa.free(try gpa.alloc(u8, 1));
        \\}
        \\test "fixture" {
        \\    const Fixture = struct {
        \\        fn build(gpa: std.mem.Allocator) ![]u8 { return gpa.alloc(u8, 4); }
        \\    };
        \\    std.testing.allocator.free(try Fixture.build(std.testing.allocator));
        \\    std.testing.allocator.free(try scenario(std.testing.allocator));
        \\}
        \\fn scenario(gpa: std.mem.Allocator) ![]u8 { return gpa.alloc(u8, 2); }
        \\fn grow(gpa: std.mem.Allocator) ![]u8 { return gpa.alloc(u8, 1); }
        },
        .{ .path = "src/lsm/forest_fuzz.zig", .source = grow },
        .{ .path = "src/testing/fixtures.zig", .source = grow },
        .{ .path = "tools/generate.zig", .source = grow },
        .{ .path = "build.zig", .source = grow },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);
    var allocations: usize = 0;
    for (found) |finding| if (finding.finding.rule == .allocation_after_init) {
        allocations += 1;
        try std.testing.expectEqual(@as(usize, 0), finding.file_index);
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "function 'grow'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), allocations);
}

test "allocation policy attributes nested function work only to the nested function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.allocation_after_init}, .information);
    const files = [_]project.SourceFile{.{
        .path = "src/factory.zig",
        .source = "fn Factory() type { return struct { fn work(allocator: std.mem.Allocator) !void { _ = try allocator.alloc(u8, 1); } }; }",
    }};
    const found = try project.findings(arena.allocator(), &files, configuration);
    var allocations: usize = 0;
    for (found) |finding| if (finding.finding.rule == .allocation_after_init) {
        allocations += 1;
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "function 'work'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), allocations);
}
