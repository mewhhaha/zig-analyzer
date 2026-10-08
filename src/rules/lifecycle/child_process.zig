//! Child-process cleanup: pipes closed twice and children never waited on.
const std = @import("std");
const statementStart = @import("../../syntax/tokens.zig").statementStart;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{ .child_pipe_double_close, .unwaited_child_process };

pub fn run(context: RuleRun) !void {
    try findChildPipeDoubleClose(context);
    try findUnwaitedChildProcesses(context);
}

fn findChildPipeDoubleClose(context: RuleRun) !void {
    const level = context.level(.child_pipe_double_close);
    if (level == .off) return;
    for (context.tokens, 0..) |token, close_index| {
        if (token.tag != .identifier or !context.tokenIs(close_index, "close") or close_index < 6 or
            context.tokens[close_index - 1].tag != .period) continue;
        const child_name = childPipeReceiver(context, close_index) orelse continue;
        if (!bindingIsProcessChild(context, child_name, close_index)) continue;
        const scope_end = context.enclosingScopeEnd(close_index) orelse continue;
        const wait_index = pathMethod(context, child_name, "wait", close_index + 1, scope_end) orelse continue;
        if (pipeClearedBeforeWait(context, child_name, close_index + 1, wait_index)) continue;
        try context.emit(.{
            .rule = .child_pipe_double_close,
            .level = level,
            .span = context.tokens[close_index].loc,
            .message = try context.allocator.print(
                "manually closing '{s}' pipe before {s}.wait can make wait close the same descriptor again",
                .{ child_name, child_name },
            ),
        });
    }
}

fn findUnwaitedChildProcesses(context: RuleRun) !void {
    const level = context.level(.unwaited_child_process);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (directProcessSpawnInRange(context, declaration_index + 2, declaration_end) == null) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const declaration_scope = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const child_name = context.tokenText(declaration_index + 1);
        if (pathMethodInScope(context, child_name, "wait", declaration_scope, declaration_end + 1, scope_end) != null or
            pathMethodInScope(context, child_name, "kill", declaration_scope, declaration_end + 1, scope_end) != null or
            childTerminatedInEveryConditionalBranch(context, child_name, declaration_scope, declaration_end + 1, scope_end) or
            childOwnershipEscapes(context, child_name, declaration_scope, declaration_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .unwaited_child_process,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "spawned child '{s}' reaches the end of the scope without wait, kill, or ownership transfer",
                .{child_name},
            ),
        });
    }

    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        const spawn_index = processSpawnInRange(context, equal_index + 1, statement_end) orelse continue;
        const scope_end = context.enclosingScopeEnd(equal_index) orelse continue;
        const scope = context.enclosingOpeningBrace(equal_index) orelse continue;
        if (scopeTerminatesProcess(context, scope, statement_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .unwaited_child_process,
            .level = level,
            .span = context.tokens[spawn_index].loc,
            .message = "discarding the spawned child prevents the caller from waiting for process termination",
        });
    }
}

fn bindingIsProcessChild(context: RuleRun, child_name: []const u8, before: usize) bool {
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = context.functionRange(function_index) orelse continue;
        if (before <= function.body_start or before >= function.body_end) continue;
        if (context.parameterNamesTypePath(
            child_name,
            &.{ "process", "Child" },
            function.parameters_start,
            function.parameters_end,
        )) return true;
        if (parameterNamed(context, child_name, function.parameters_start, function.parameters_end)) return false;
    }
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!context.tokenIs(index, child_name) or index == 0 or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var) or
            index + 1 >= before or context.tokens[index + 1].tag != .equal) continue;
        const declaration_end = context.statementEnd(index - 1) orelse continue;
        if (declaration_end > before) continue;
        if (context.enclosingOpeningBrace(index)) |opening| {
            const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
            if (before >= closing) continue;
        }
        if (rangeNamesProcessChild(context, index + 2, declaration_end)) return true;
    }
    return false;
}

fn childPipeReceiver(context: RuleRun, close_index: usize) ?[]const u8 {
    const start = close_index -| 10;
    for (context.tokens[start..close_index], start..) |token, child_index| {
        if (token.tag != .identifier or child_index + 3 >= close_index or
            context.tokens[child_index + 1].tag != .period or
            (!context.tokenIs(child_index + 2, "stdin") and !context.tokenIs(child_index + 2, "stdout") and
                !context.tokenIs(child_index + 2, "stderr"))) continue;
        return context.tokenText(child_index);
    }
    return null;
}

fn pathMethod(context: RuleRun, receiver: []const u8, method: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.tokenIs(index, receiver) and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, method) and context.tokens[index + 3].tag == .l_paren) return index + 2;
    }
    return null;
}

fn pipeClearedBeforeWait(context: RuleRun, child_name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokenIs(index, child_name) and context.tokens[index + 1].tag == .period and
            (context.tokenIs(index + 2, "stdin") or context.tokenIs(index + 2, "stdout") or context.tokenIs(index + 2, "stderr")) and
            context.tokens[index + 3].tag == .equal and context.tokenIs(index + 4, "null")) return true;
    }
    return false;
}

fn childOwnershipEscapes(
    context: RuleRun,
    child_name: []const u8,
    declaration_scope: usize,
    start: usize,
    end: usize,
) bool {
    if (childIdTransferredToWatcher(context, child_name, start, end)) return true;
    if (childPassedToThreadSpawn(context, child_name, start, end)) return true;
    for (context.tokens[start..end], start..) |token, index| {
        if (!context.tokenIs(index, child_name)) continue;
        if (context.enclosingOpeningBrace(index) != declaration_scope) continue;
        if (index > start and context.tokens[index - 1].tag == .keyword_return) return true;
        if (index > start and context.tokens[index - 1].tag == .equal and
            (index < 2 or !context.tokenIs(index - 2, "_")) and
            index + 1 < end and context.tokens[index + 1].tag != .period) return true;
        if (index > start and context.tokens[index - 1].tag == .ampersand) return true;
        if (token.tag == .identifier and index + 1 < end and
            (context.tokens[index + 1].tag == .comma or context.tokens[index + 1].tag == .r_paren)) return true;
    }
    return false;
}

fn childTerminatedInEveryConditionalBranch(
    context: RuleRun,
    child_name: []const u8,
    scope: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, if_index| {
        if (token.tag != .keyword_if or context.enclosingOpeningBrace(if_index) != scope) continue;
        var then_start = if_index + 1;
        while (then_start < end and context.tokens[then_start].tag != .l_brace) : (then_start += 1) {}
        if (then_start == end) continue;
        const then_end = context.matchingToken(then_start, .l_brace, .r_brace) orelse continue;
        if (then_end + 2 >= end or context.tokens[then_end + 1].tag != .keyword_else or
            context.tokens[then_end + 2].tag != .l_brace) continue;
        const else_start = then_end + 2;
        const else_end = context.matchingToken(else_start, .l_brace, .r_brace) orelse continue;
        const then_terminates = pathMethodInScope(context, child_name, "wait", then_start, then_start + 1, then_end) != null or
            pathMethodInScope(context, child_name, "kill", then_start, then_start + 1, then_end) != null;
        const else_terminates = pathMethodInScope(context, child_name, "wait", else_start, else_start + 1, else_end) != null or
            pathMethodInScope(context, child_name, "kill", else_start, else_start + 1, else_end) != null;
        if (then_terminates and else_terminates) return true;
    }
    return false;
}

fn directProcessSpawnInRange(context: RuleRun, start: usize, end: usize) ?usize {
    var value_start = start;
    while (value_start < end and context.tokens[value_start].tag != .equal) : (value_start += 1) {}
    if (value_start == end) return null;
    value_start += 1;
    while (value_start < end) : (value_start += 1) switch (context.tokens[value_start].tag) {
        .keyword_try, .keyword_nosuspend => {},
        else => break,
    };
    if (value_start + 4 >= end or !context.tokenIs(value_start, "std") or
        context.tokens[value_start + 1].tag != .period or !context.tokenIs(value_start + 2, "process") or
        context.tokens[value_start + 3].tag != .period or !context.tokenIs(value_start + 4, "spawn")) return null;
    return value_start + 4;
}

fn pathMethodInScope(
    context: RuleRun,
    receiver: []const u8,
    method: []const u8,
    scope: usize,
    start: usize,
    end: usize,
) ?usize {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (context.enclosingOpeningBrace(index) == scope and context.tokenIs(index, receiver) and
            context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, method) and
            context.tokens[index + 3].tag == .l_paren) return index + 2;
    }
    return null;
}

fn processSpawnInRange(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokenIs(index, "std") and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, "process") and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "spawn")) return index + 4;
    }
    return null;
}

fn scopeTerminatesProcess(context: RuleRun, scope: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or context.enclosingOpeningBrace(index) != scope or
            index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        if (context.tokens[statementStart(context.tokens, index)].tag == .keyword_if) continue;
        if (context.tokenIs(index, "RtlExitUserProcess") or context.tokenIs(index, "exitProcess")) return true;
        if (!context.tokenIs(index, "exit") or index < 2 or context.tokens[index - 1].tag != .period or
            context.tokens[index - 2].tag != .identifier) continue;
        if (context.tokenIs(index - 2, "process") or context.tokenIs(index - 2, "posix")) return true;
    }
    return false;
}

fn parameterNamed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start + 1 .. end], start + 1..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .colon) return true;
    }
    return false;
}

fn rangeNamesProcessChild(context: RuleRun, start: usize, end: usize) bool {
    var saw_process = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "process")) saw_process = true;
        if (saw_process and (context.tokenIs(index, "Child") or context.tokenIs(index, "spawn"))) return true;
        if (context.tokenIs(index, "Child") and childAliasIsStandard(context)) return true;
    }
    return false;
}

fn childIdTransferredToWatcher(context: RuleRun, child_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, child_index| {
        if (token.tag != .identifier or !context.tokenIs(child_index, child_name) or child_index + 2 >= end or
            context.tokens[child_index + 1].tag != .period or !context.tokenIs(child_index + 2, "id")) continue;
        const statement_start = statementStart(context.tokens, child_index);
        if (context.tokens[statement_start].tag != .keyword_const and context.tokens[statement_start].tag != .keyword_var) continue;
        const watcher = context.tokenText(statement_start + 1);
        const statement_end = context.statementEnd(statement_start) orelse continue;
        var calls_init = false;
        for (context.tokens[statement_start..statement_end], statement_start..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "init") and index > 0 and
                context.tokens[index - 1].tag == .period) calls_init = true;
        }
        if (calls_init and pathMethod(context, watcher, "wait", statement_end + 1, end) != null) return true;
    }
    return false;
}

fn childPassedToThreadSpawn(context: RuleRun, child_name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "spawn") or index < 2 or
            context.tokens[index - 1].tag != .period or !context.tokenIs(index - 2, "Thread") or
            index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[index + 2 .. @min(call_end, end)], index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier and context.tokenIs(argument_index, child_name) and
                (argument_index == 0 or context.tokens[argument_index - 1].tag != .period)) return true;
        }
    }
    return false;
}

fn childAliasIsStandard(context: RuleRun) bool {
    var index: usize = 0;
    while (index + 7 < context.tokens.len) : (index += 1) {
        if (context.tokens[index].tag != .keyword_const or !context.tokenIs(index + 1, "Child") or
            context.tokens[index + 2].tag != .equal or !context.tokenIs(index + 3, "std") or
            context.tokens[index + 4].tag != .period or !context.tokenIs(index + 5, "process") or
            context.tokens[index + 6].tag != .period or !context.tokenIs(index + 7, "Child")) continue;
        return true;
    }
    return false;
}

test "closing a typed child pipe before waiting reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn childRun(io: std.Io, child: *std.process.Child) !void { child.stdout.?.close(io); try child.wait(io); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.child_pipe_double_close});
}

test "closing a child pipe through an aliased type reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Child = std.process.Child; fn childRun() !void { var child = Child.init(args, a); child.stdin.?.close(); _ = try child.wait(); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.child_pipe_double_close});
}

test "clearing a manually closed child pipe transfers the closed state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Child = std.process.Child; fn childRun() !void { var child = Child.init(args, a); child.stdin.?.close(); child.stdin = null; _ = try child.wait(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "child bindings do not lend process provenance across functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn standard(args: anytype, allocator: anytype) void { " ++
        "var child = std.process.Child.init(args, allocator); _ = &child; } " ++
        "fn custom(child: *CustomChild) !void { child.stdout.?.close(); _ = try child.wait(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "spawned children retain their terminal cleanup contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(io: std.Io) !void { _ = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); }" ++
        "fn bound(io: std.Io) !void { var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); _ = child; }" ++
        "fn clean(io: std.Io) !void { var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); _ = try child.wait(io); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{ .unwaited_child_process, .unwaited_child_process });
}

test "conditional waits do not prove child cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(io: std.Io, should_wait: bool) !void { " ++
        "var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); " ++
        "if (should_wait) { _ = try child.wait(io); } }" ++
        "fn nested(io: std.Io, should_wait: bool, nested_wait: bool) !void { " ++
        "var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); " ++
        "if (should_wait) { if (nested_wait) { _ = try child.wait(io); } } else { _ = try child.wait(io); } }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(types.Rule.unwaited_child_process, findings[0].rule);
    try std.testing.expectEqual(types.Rule.unwaited_child_process, findings[1].rule);
}

test "every conditional branch can wait for the child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(io: std.Io, inherit: bool) !void { " ++
        "var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); " ++
        "if (inherit) { _ = try child.wait(io); } else { read(child.stderr); _ = try child.wait(io); } }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .unwaited_child_process);
}

test "thread reapers process watchers and process replacement transfer children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn reaper(io: std.Io) !void { var child = try std.process.spawn(io, .{});" ++
        "const thread = try std.Thread.spawn(.{}, reap, .{ io, child }); thread.detach(); }" ++
        "fn watcher(io: std.Io) !void { const child = try std.process.spawn(io, .{});" ++
        "var process = try Watcher.init(child.id.?); defer process.deinit(); process.wait(); }" ++
        "fn restart(io: std.Io) noreturn { _ = std.process.spawn(io, .{}) catch unreachable; std.process.exit(0); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .unwaited_child_process);
}

test "unrelated and conditional exit calls do not replace child cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn unrelated(io: std.Io) !void { _ = try std.process.spawn(io, .{}); logger.exit(); }" ++
        "fn conditional(io: std.Io, stop: bool) !void { _ = try std.process.spawn(io, .{});" ++
        "if (stop) std.process.exit(1); continueWork(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var unwaited_count: usize = 0;
    for (findings) |finding| if (finding.rule == .unwaited_child_process) {
        unwaited_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), unwaited_count);
}

test "nested process spawns do not make scalar initializers into children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn digest(io: std.Io) !Hash { const result = blk: { var child = try std.process.spawn(io, .{});" ++
        "defer child.kill(io); break :blk hash(child.id); }; use(result); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
