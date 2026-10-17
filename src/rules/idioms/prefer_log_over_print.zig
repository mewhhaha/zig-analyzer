//! `std.debug.print` in library code that `std.log` should carry.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const functionBodyAfterParameters = @import("../../syntax/scope.zig").functionBodyAfterParameters;

pub const rules = [_]types.Rule{.prefer_log_over_print};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_log_over_print);
    if (level == .off) return;
    if (std.mem.find(u8, context.source, "pub fn build(") != null or
        std.mem.find(u8, context.source, "pub fn main(") != null) return;
    var graph: ?CallGraph = null;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "print") or index < 4 or
            !context.tokenIs(index - 4, "std") or !context.tokenIs(index - 2, "debug")) continue;
        if (context.scopes.insideTestBlock(index) or announcesExit(context, index)) continue;
        if (graph == null) graph = try CallGraph.init(context);
        if (graph.?.deliberate(context, index)) continue;
        const fixes = try context.singleFix(.{
            .title = "Use std.log.debug",
            .span = .{ .start = context.tokens[index - 4].loc.start, .end = token.loc.end },
            .replacement = "std.log.debug",
        });
        try context.emit(.{ .rule = .prefer_log_over_print, .level = level, .span = token.loc, .message = "std.debug.print is unconditional diagnostic output; use std.log so callers control level and scope", .fixes = fixes });
    }
}

/// Whether the print at `index` is the message of a process exit: the next
/// statement ends the program, so a log level must not filter it out.
fn announcesExit(context: RuleRun, index: usize) bool {
    const statement_end = context.statementEnd(index - 4) orelse return false;
    if (statement_end + 1 >= context.tokens.len) return false;
    return switch (context.tokens[statement_end + 1].tag) {
        .keyword_return, .keyword_break, .keyword_continue => false,
        else => context.statementDiverges(statement_end + 1),
    };
}

/// Where a token runs: in a test, in a named function of the file, or in
/// neither (a container-level initializer).
const Site = union(enum) { test_block, function: usize, outside };

/// The file's named functions and their calls, built once for a file with a
/// print to judge. A function writes its output on purpose when it shows so
/// itself (`writesOutput`) or when every call of it in the file comes from a
/// test or from such a function; a call cycle with no other caller counts as
/// purposeful, as a function with no caller does not.
const CallGraph = struct {
    /// The function whose body the `{` at a token index opens.
    by_body: std.AutoHashMapUnmanaged(usize, usize),
    /// Functions that print as a side effect someone else asked for.
    incidental: []bool,

    fn init(context: RuleRun) !CallGraph {
        const tokens = context.tokens;
        var functions: std.ArrayList(FunctionIdentity) = .empty;
        defer functions.deinit(context.allocator);
        var by_name: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
        defer by_name.deinit(context.allocator);
        var graph: CallGraph = .{ .by_body = .empty, .incidental = &.{} };
        for (tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= tokens.len or tokens[fn_index + 1].tag != .identifier or
                tokens[fn_index + 2].tag != .l_paren) continue;
            const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
            // The first brace may open an error set or struct of the return type.
            const opening = functionBodyAfterParameters(tokens, parameters_end) orelse continue;
            const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
            try graph.by_body.put(context.allocator, opening, functions.items.len);
            const named = try by_name.getOrPut(context.allocator, context.tokenText(fn_index + 1));
            if (!named.found_existing) named.value_ptr.* = .empty;
            try named.value_ptr.append(context.allocator, functions.items.len);
            try functions.append(context.allocator, .{
                .name = context.tokenText(fn_index + 1),
                .parameters_start = fn_index + 2,
                .parameters_end = parameters_end,
                .body_start = opening,
                .body_end = closing,
            });
        }
        const count = functions.items.len;
        const writes = try context.allocator.alloc(bool, count);
        for (functions.items, writes) |function, *purposeful| purposeful.* = writesOutput(context, function);
        // Calls are matched by name: a name declared twice gets the calls of
        // both.
        const callees = try context.allocator.alloc(std.ArrayList(usize), count);
        @memset(callees, .empty);
        const called = try context.allocator.alloc(bool, count);
        @memset(called, false);
        graph.incidental = try context.allocator.alloc(bool, count);
        @memset(graph.incidental, false);
        var pending: std.ArrayList(usize) = .empty;
        defer pending.deinit(context.allocator);
        for (tokens, 0..) |token, reference| {
            if (token.tag != .identifier or reference + 1 >= tokens.len or tokens[reference + 1].tag != .l_paren or
                (reference > 0 and tokens[reference - 1].tag == .keyword_fn)) continue;
            const targets = by_name.get(context.tokenText(reference)) orelse continue;
            const site = graph.siteOf(context, reference);
            for (targets.items) |target| {
                called[target] = true;
                switch (site) {
                    .test_block => {},
                    .function => |caller| try callees[caller].append(context.allocator, target),
                    .outside => if (!writes[target] and !graph.incidental[target]) {
                        graph.incidental[target] = true;
                        try pending.append(context.allocator, target);
                    },
                }
            }
        }
        for (called, writes, graph.incidental, 0..) |has_caller, purposeful, *incidental, function| {
            if (has_caller or purposeful or incidental.*) continue;
            incidental.* = true;
            try pending.append(context.allocator, function);
        }
        // What an incidental function calls is called incidentally too.
        while (pending.pop()) |function| {
            for (callees[function].items) |target| {
                if (writes[target] or graph.incidental[target]) continue;
                graph.incidental[target] = true;
                try pending.append(context.allocator, target);
            }
        }
        return graph;
    }

    fn siteOf(graph: *const CallGraph, context: RuleRun, index: usize) Site {
        if (context.scopes.insideTestBlock(index)) return .test_block;
        var brace = context.enclosingOpeningBrace(index);
        while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
            if (graph.by_body.get(opening)) |function| return .{ .function = function };
        }
        return .outside;
    }

    /// Whether the token at `index` writes output on purpose.
    fn deliberate(graph: *const CallGraph, context: RuleRun, index: usize) bool {
        return switch (graph.siteOf(context, index)) {
            .test_block => true,
            .function => |function| !graph.incidental[function],
            .outside => false,
        };
    }
};

/// What marks a function's stderr output as its purpose rather than
/// diagnostics: a printing name (`dump*`, `print*`, `debugPrint*`, `dbg`), a
/// `noreturn` result (a fatal-error helper), a benchmark step's signature, a
/// test helper's use of `std.testing` or `error.Test*`, or a command that
/// also opens stdout or stderr itself.
fn writesOutput(context: RuleRun, function: FunctionIdentity) bool {
    const name = function.name;
    for ([_][]const u8{ "dump", "print", "debugPrint", "debug_print" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    if (std.mem.eql(u8, name, "dbg")) return true;
    if (context.tokenIs(function.parameters_end + 1, "noreturn")) return true;
    for (context.tokens[function.parameters_start..function.body_end], function.parameters_start..) |token, index| {
        if (token.tag != .identifier) continue;
        const text = context.tokenText(index);
        if (index < function.body_start and std.mem.find(u8, text, "Benchmark") != null) return true;
        if (std.mem.eql(u8, text, "testing")) return true;
        // `error.TestExpectedEqual` or `error{TestExpectedEqual}`.
        if (std.mem.startsWith(u8, text, "Test") and index >= 2 and context.tokens[index - 2].tag == .keyword_error) return true;
        const opens_stream = std.mem.eql(u8, text, "stdout") or std.mem.eql(u8, text, "stderr") or
            std.mem.eql(u8, text, "getStdOut") or std.mem.eql(u8, text, "getStdErr");
        if (opens_stream and index + 1 < context.tokens.len and context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

const FunctionIdentity = struct {
    name: []const u8,
    parameters_start: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

test "command output from main is not replaced with logging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn main() void { std.debug.print(\"usage: tool\\n\", .{}); }\n";
    const configuration = support.only(&.{.prefer_log_over_print}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "debug output reachable only from tests remains test output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn printCase() void { std.debug.print(\"case\", .{}); }\n" ++
        "fn verifyCase() void { printCase(); }\n" ++
        "test \"case\" { verifyCase(); }\n";
    const configuration = support.only(&.{.prefer_log_over_print}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "dump helpers, test helpers, benchmarks, commands and fatal messages print on purpose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn dumpState(self: State) void { std.debug.print(\"{any}\", .{self}); }\n" ++
        "fn renderDiff(expected: []const u8) void { std.debug.print(\"{s}\", .{expected}); }\n" ++
        "pub fn expectText(expected: []const u8, actual: []const u8) error{TestExpectedEqual}!void {\n" ++
        "    if (std.mem.eql(u8, expected, actual)) return;\n" ++
        "    renderDiff(expected);\n" ++
        "    return error.TestExpectedEqual;\n" ++
        "}\n" ++
        "fn stepReport(ptr: *anyopaque) Benchmark.Error!void { std.debug.print(\"{*}\", .{ptr}); }\n" ++
        "pub fn listThemes(io: std.Io) !u8 {\n" ++
        "    var out = std.Io.File.stdout().writer(io, &.{});\n" ++
        "    std.debug.print(\"no themes\", .{});\n" ++
        "    try out.interface.flush();\n" ++
        "    return 0;\n" ++
        "}\n" ++
        "pub fn fatal(comptime format: []const u8, arguments: anytype) noreturn {\n" ++
        "    std.debug.print(format, arguments);\n" ++
        "    std.process.exit(1);\n" ++
        "}\n" ++
        "pub fn mode(choice: ?u8) u8 {\n" ++
        "    return choice orelse {\n" ++
        "        std.debug.print(\"choose a mode\", .{});\n" ++
        "        std.process.exit(1);\n" ++
        "    };\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_log_over_print}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "debug prints in library code report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void { std.debug.print(\"hello\", .{}); }\n" ++
        "pub fn load(path: []const u8) !void {\n" ++
        "    std.debug.print(\"loading {s}\", .{path});\n" ++
        "    return error.Missing;\n" ++
        "}\n" ++
        "fn trace(depth: u8) void {\n" ++
        "    std.debug.print(\"{d}\", .{depth});\n" ++
        "    if (depth > 0) trace(depth - 1);\n" ++
        "}\n" ++
        "pub fn walk() void { trace(3); }\n" ++
        "test walk { trace(1); }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_log_over_print}, .information));
    try support.expectRules(found, &.{ .prefer_log_over_print, .prefer_log_over_print, .prefer_log_over_print });
}
