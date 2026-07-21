const std = @import("std");
const syntax_scope = @import("../syntax_scope.zig");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const FunctionRange = struct {
    parameters_start: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

pub fn run(context: RuleRun) !void {
    try findPointerOnlyFrees(context);
    try findNullablePointerLengths(context);
    try findDiscardedResources(context);
    try findChildPipeDoubleClose(context);
    try findUnwaitedChildProcesses(context);
    try findOverflowBeforeClamp(context);
    try findUncheckedRangeEnds(context);
    try findUncheckedDeclaredRangeEnds(context);
}

fn findPointerOnlyFrees(context: RuleRun) !void {
    const level = context.level(.pointer_only_free);
    if (level == .off) return;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        const pointer_name = manyPointerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const slice = sliceFromPointer(context, pointer_name, function.body_start + 1, function.body_end) orelse continue;
        if (hasLengthParameter(context, function.parameters_start, function.parameters_end) and
            sliceHasNamedBound(context, slice.bracket_start + 1, slice.bracket_end)) continue;
        const free_index = freeOfBinding(context, slice.binding, function.body_start + 1, function.body_end) orelse continue;
        try context.emit(.{
            .rule = .pointer_only_free,
            .level = level,
            .span = context.tokens[free_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "freeing slice '{s}' reconstructed from pointer '{s}' without its allocation length can pass the allocator the wrong layout",
                .{ slice.binding, pointer_name },
            ),
        });
    }
}

fn findNullablePointerLengths(context: RuleRun) !void {
    const level = context.level(.nullable_pointer_length);
    if (level == .off) return;
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        const pointer_name = nullableManyPointerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const length_name = integerParameter(context, function.parameters_start, function.parameters_end) orelse continue;
        const allocation = allocationWithLength(context, length_name, function.body_start + 1, function.body_end) orelse continue;
        const branch = optionalPointerBranch(context, pointer_name, allocation.declaration_end + 1, function.body_end) orelse continue;
        if (!rangeCopiesName(context, branch.capture, branch.body_start + 1, branch.end)) continue;
        if (!rangeReturns(context, allocation.binding, branch.end + 1, function.body_end)) continue;
        try context.emit(.{
            .rule = .nullable_pointer_length,
            .level = level,
            .span = context.tokens[branch.start].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "nullable pointer '{s}' may be null while length '{s}' is positive, returning uninitialized allocation '{s}'",
                .{ pointer_name, length_name, allocation.binding },
            ),
        });
    }
}

fn findDiscardedResources(context: RuleRun) !void {
    const level = context.level(.discarded_resource);
    if (level == .off) return;
    const acquisitions = [_][]const u8{
        "open",
        "openat",
        "socket",
        "dup",
        "dup2",
        "eventfd",
        "inotify_init1",
        "openFile",
        "createFile",
        "openFileAbsolute",
        "createFileAbsolute",
        "openDir",
        "openDirAbsolute",
    };
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, call_index| {
            if (candidate.tag != .identifier or call_index + 1 >= statement_end or
                context.tokens[call_index + 1].tag != .l_paren) continue;
            for (acquisitions) |acquisition| {
                if (!context.tokenIs(call_index, acquisition)) continue;
                const is_directory_method = std.mem.eql(u8, acquisition, "openFile") or
                    std.mem.eql(u8, acquisition, "createFile") or
                    std.mem.eql(u8, acquisition, "openFileAbsolute") or
                    std.mem.eql(u8, acquisition, "createFileAbsolute") or
                    std.mem.eql(u8, acquisition, "openDir") or
                    std.mem.eql(u8, acquisition, "openDirAbsolute");
                if (is_directory_method and !ioDirectoryCall(context, call_index)) continue;
                if (!is_directory_method and !posixAcquisitionCall(context, call_index)) continue;
                try context.emit(.{
                    .rule = .discarded_resource,
                    .level = level,
                    .span = candidate.loc,
                    .message = try std.fmt.allocPrint(
                        context.allocator,
                        "discarded {s} result is an owned OS resource that must be closed",
                        .{acquisition},
                    ),
                });
                break;
            }
        }
    }
}

fn posixAcquisitionCall(context: RuleRun, call_index: usize) bool {
    if (call_index >= 2 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "posix")) return true;
    return call_index >= 6 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "linux") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "os") and context.tokens[call_index - 5].tag == .period and
        context.tokenIs(call_index - 6, "std");
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
            .message = try std.fmt.allocPrint(
                context.allocator,
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

fn processSpawnInRange(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokenIs(index, "std") and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, "process") and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "spawn")) return index + 4;
    }
    return null;
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

fn statementStart(tokens: []const std.zig.Token, index: usize) usize {
    var cursor = index;
    while (cursor > 0) : (cursor -= 1) switch (tokens[cursor - 1].tag) {
        .semicolon, .l_brace, .r_brace => break,
        else => {},
    };
    return cursor;
}

fn ioDirectoryCall(context: RuleRun, call_index: usize) bool {
    if (call_index >= 4 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "fs") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "std")) return true;
    if (call_index >= 6 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "Dir") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "Io") and context.tokens[call_index - 5].tag == .period and
        context.tokenIs(call_index - 6, "std")) return true;
    if (call_index < 2 or context.tokens[call_index - 1].tag != .period or
        context.tokens[call_index - 2].tag != .identifier) return false;
    const receiver = context.tokenText(call_index - 2);
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        if (call_index <= function.body_start or call_index >= function.body_end) continue;
        if (parameterNamesTypePath(context, receiver, &.{ "Io", "Dir" }, function.parameters_start, function.parameters_end) or
            parameterNamesTypePath(context, receiver, &.{ "fs", "Dir" }, function.parameters_start, function.parameters_end)) return true;
    }
    return false;
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
            .message = try std.fmt.allocPrint(
                context.allocator,
                "manually closing '{s}' pipe before {s}.wait can make wait close the same descriptor again",
                .{ child_name, child_name },
            ),
        });
    }
}

fn bindingIsProcessChild(context: RuleRun, child_name: []const u8, before: usize) bool {
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = functionRange(context, function_index) orelse continue;
        if (before <= function.body_start or before >= function.body_end) continue;
        if (parameterNamesTypePath(
            context,
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

fn parameterNamed(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start + 1 .. end], start + 1..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .colon) return true;
    }
    return false;
}

fn parameterNamesTypePath(
    context: RuleRun,
    parameter_name: []const u8,
    type_path: []const []const u8,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or !context.tokenIs(name_index, parameter_name) or
            name_index + 1 >= end or context.tokens[name_index + 1].tag != .colon) continue;
        var segment_end = name_index + 2;
        while (segment_end < end and context.tokens[segment_end].tag != .comma) : (segment_end += 1) {}
        var matched: usize = 0;
        for (context.tokens[name_index + 2 .. segment_end], name_index + 2..) |type_token, index| {
            if (type_token.tag != .identifier or matched >= type_path.len or !context.tokenIs(index, type_path[matched])) continue;
            matched += 1;
        }
        return matched == type_path.len;
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

fn pipeClearedBeforeWait(context: RuleRun, child_name: []const u8, start: usize, end: usize) bool {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (context.tokenIs(index, child_name) and context.tokens[index + 1].tag == .period and
            (context.tokenIs(index + 2, "stdin") or context.tokenIs(index + 2, "stdout") or context.tokenIs(index + 2, "stderr")) and
            context.tokens[index + 3].tag == .equal and context.tokenIs(index + 4, "null")) return true;
    }
    return false;
}

fn functionRange(context: RuleRun, function_index: usize) ?FunctionRange {
    var parameters_start = function_index + 1;
    while (parameters_start < context.tokens.len and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
    if (parameters_start >= context.tokens.len) return null;
    const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse return null;
    var body_start = parameters_end + 1;
    while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
        context.tokens[body_start].tag != .semicolon) : (body_start += 1)
    {}
    if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) return null;
    const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
    return .{ .parameters_start = parameters_start, .parameters_end = parameters_end, .body_start = body_start, .body_end = body_end };
}

fn manyPointerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or name_index + 3 >= end or context.tokens[name_index + 1].tag != .colon) continue;
        var index = name_index + 2;
        if (context.tokens[index].tag == .question_mark) index += 1;
        if (index + 1 < end and context.tokens[index].tag == .l_bracket and
            context.tokens[index + 1].tag == .asterisk) return context.tokenText(name_index);
    }
    return null;
}

fn nullableManyPointerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag == .identifier and name_index + 4 < end and context.tokens[name_index + 1].tag == .colon and
            context.tokens[name_index + 2].tag == .question_mark and context.tokens[name_index + 3].tag == .l_bracket and
            context.tokens[name_index + 4].tag == .asterisk) return context.tokenText(name_index);
    }
    return null;
}

fn hasLengthParameter(context: RuleRun, start: usize, end: usize) bool {
    return integerParameter(context, start, end) != null;
}

fn integerParameter(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
        if (token.tag != .identifier or name_index + 2 >= end or context.tokens[name_index + 1].tag != .colon or
            context.tokens[name_index + 2].tag != .identifier) continue;
        const type_name = context.tokenText(name_index + 2);
        if (std.mem.eql(u8, type_name, "usize") or std.mem.eql(u8, type_name, "u32") or
            std.mem.eql(u8, type_name, "u64")) return context.tokenText(name_index);
    }
    return null;
}

const ReconstructedSlice = struct {
    binding: []const u8,
    bracket_start: usize,
    bracket_end: usize,
};

fn sliceFromPointer(context: RuleRun, pointer_name: []const u8, start: usize, end: usize) ?ReconstructedSlice {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        if (statement_end > end) continue;
        var index = declaration_index + 2;
        while (index + 1 < statement_end) : (index += 1) {
            if (context.tokenIs(index, pointer_name) and context.tokens[index + 1].tag == .l_bracket) {
                const bracket_end = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
                return .{
                    .binding = context.tokenText(declaration_index + 1),
                    .bracket_start = index + 1,
                    .bracket_end = bracket_end,
                };
            }
        }
    }
    return null;
}

fn sliceHasNamedBound(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| if (token.tag == .identifier) return true;
    return false;
}

fn freeOfBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "free") or
            method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. @min(call_end, end)], method_index + 2..) |argument, index| {
            if (argument.tag == .identifier and context.tokenIs(index, binding)) return method_index;
        }
    }
    return null;
}

const Allocation = struct { binding: []const u8, declaration_end: usize };

fn allocationWithLength(context: RuleRun, length_name: []const u8, start: usize, end: usize) ?Allocation {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!rangeCalls(context, "alloc", declaration_index + 2, declaration_end) or
            !rangeContainsName(context, length_name, declaration_index + 2, declaration_end)) continue;
        return .{ .binding = context.tokenText(declaration_index + 1), .declaration_end = declaration_end };
    }
    return null;
}

const TokenRange = struct { start: usize, end: usize };

const OptionalBranch = struct {
    start: usize,
    body_start: usize,
    end: usize,
    capture: []const u8,
};

fn optionalPointerBranch(context: RuleRun, pointer_name: []const u8, start: usize, end: usize) ?OptionalBranch {
    for (context.tokens[start..end], start..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= end or context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end + 4 >= end or !rangeContainsName(context, pointer_name, if_index + 2, condition_end) or
            context.tokens[condition_end + 1].tag != .pipe or context.tokens[condition_end + 2].tag != .identifier or
            context.tokens[condition_end + 3].tag != .pipe or context.tokens[condition_end + 4].tag != .l_brace) continue;
        const body_start = condition_end + 4;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        return .{
            .start = if_index,
            .body_start = body_start,
            .end = body_end,
            .capture = context.tokenText(condition_end + 2),
        };
    }
    return null;
}

fn rangeCalls(context: RuleRun, method: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, method) and index + 1 < end and
            context.tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn rangeCopiesName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, copy_index| {
        if ((token.tag != .builtin or !context.tokenIs(copy_index, "@memcpy")) and
            (token.tag != .identifier or !context.tokenIs(copy_index, "copyForwards"))) continue;
        const statement_end = context.statementEnd(copy_index) orelse continue;
        if (statement_end <= end and rangeContainsName(context, name, copy_index + 1, statement_end)) return true;
    }
    return false;
}

fn rangeContainsName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

fn rangeReturns(context: RuleRun, binding: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return and index + 1 < end and context.tokenIs(index + 1, binding)) return true;
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

fn findOverflowBeforeClamp(context: RuleRun) !void {
    const level = context.level(.overflow_before_clamp);
    if (level == .off) return;

    for (context.tokens, 0..) |token, clamp_index| {
        if (token.tag != .builtin or (!context.tokenIs(clamp_index, "@min") and
            !context.tokenIs(clamp_index, "@max")) or clamp_index + 1 >= context.tokens.len or
            context.tokens[clamp_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(clamp_index + 1, .l_paren, .r_paren) orelse continue;
        const comma = topLevelComma(context, clamp_index + 2, closing) orelse continue;
        const arguments = [_]TokenRange{
            .{ .start = clamp_index + 2, .end = comma },
            .{ .start = comma + 1, .end = closing },
        };
        for (arguments) |argument| {
            const operator_tag: std.zig.Token.Tag = if (context.tokenIs(clamp_index, "@min")) .plus else .minus;
            const operator_index = arithmeticInRange(context, operator_tag, argument.start, argument.end) orelse continue;
            if (!integerExpression(context, argument.start, operator_index) or
                !integerExpression(context, operator_index + 1, argument.end) or
                !runtimeExpression(context, argument.start, operator_index) or
                !runtimeExpression(context, operator_index + 1, argument.end)) continue;
            if (bitSizeMinusLeadingZeros(context, argument.start, argument.end, operator_index)) continue;
            if (boundedUnsignedDifferenceInSignedType(context, argument.start, argument.end, operator_index)) continue;
            if (arithmeticHasVisibleGuard(context, operator_index, argument.start, argument.end, clamp_index)) continue;

            const operation = if (context.tokens[operator_index].tag == .plus) "addition" else "subtraction";
            const failure = if (context.tokens[operator_index].tag == .plus) "overflow" else "underflow";
            try context.emit(.{
                .rule = .overflow_before_clamp,
                .level = level,
                .span = context.tokens[operator_index].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "integer {s} is evaluated before {s} and can {s}; guard it or use checked or saturating arithmetic",
                    .{ operation, context.tokenText(clamp_index), failure },
                ),
            });
            break;
        }
    }
}

fn findUncheckedRangeEnds(context: RuleRun) !void {
    const level = context.level(.unchecked_range_end);
    if (level == .off) return;
    for (context.tokens, 0..) |token, operator_index| {
        if (token.tag != .plus or additionIsInsideClamp(context, operator_index)) continue;
        const statement_start = statementStart(context.tokens, operator_index);
        const statement_end = context.statementEnd(operator_index) orelse continue;
        const left_start = additionOperandStart(context.tokens, operator_index, statement_start);
        const right_end = additionOperandEnd(context.tokens, operator_index + 1, statement_end);
        if (right_end >= statement_end) continue;
        const comparison = isComparison(context.tokens[right_end].tag);
        const slice_end = additionIsSliceEnd(context, left_start, right_end);
        if (!comparison and !slice_end) continue;
        if (left_start == operator_index or operator_index + 1 == right_end or
            !runtimeExpression(context, left_start, operator_index) or
            !unsignedIntegerExpression(context, left_start, operator_index) or
            !unsignedIntegerExpression(context, operator_index + 1, right_end)) continue;
        const runtime_length = runtimeExpression(context, operator_index + 1, right_end) and
            (rangeNamesLength(context, left_start, right_end) or
                extentComparedWithSameDimension(context, operator_index + 1, right_end, statement_end));
        const constant_lookahead = riskyConstantLookahead(context, left_start, operator_index, right_end) and
            (slice_end or rangeNamesLength(context, right_end + 1, statement_end));
        if (!runtime_length and !constant_lookahead) continue;
        if (rangeContainsCall(context.tokens, left_start, operator_index) or
            leftOperandEndsWithCall(context.tokens, operator_index) or
            leftOperandComesFromSearchMatch(context, left_start, operator_index, operator_index + 1, right_end) or
            narrowedOperandsCannotOverflowUsize(context, left_start, operator_index, right_end)) continue;
        if (runtime_length and rightOperandBoundedByRemaining(
            context,
            left_start,
            operator_index,
            right_end,
        )) continue;
        if (runtime_length and arithmeticHasVisibleGuard(
            context,
            operator_index,
            left_start,
            right_end,
            statement_start,
        )) continue;
        if (constant_lookahead and constantLookaheadHasVisibleGuard(
            context,
            left_start,
            operator_index,
            statement_start,
        )) continue;
        try context.emit(.{
            .rule = .unchecked_range_end,
            .level = level,
            .span = context.tokens[operator_index].loc,
            .message = try context.allocator.dupe(
                u8,
                "range end uses unchecked runtime addition before bounds validation; validate with subtraction or checked arithmetic",
            ),
        });
    }
}

fn findUncheckedDeclaredRangeEnds(context: RuleRun) !void {
    const level = context.level(.unchecked_range_end);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or context.tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = context.statementEnd(declaration_index) orelse continue;
        const equal_index = findTag(context.tokens, .equal, declaration_index + 2, statement_end) orelse continue;
        if (rangeContainsComparison(context.tokens, equal_index + 1, statement_end)) continue;
        const operator_index = singleArithmeticInRange(context, .plus, equal_index + 1, statement_end) orelse continue;
        const left_start = additionOperandStart(context.tokens, operator_index, equal_index + 1);
        const right_end = additionOperandEnd(context.tokens, operator_index + 1, statement_end);
        if (right_end != statement_end or !runtimeExpression(context, left_start, operator_index) or
            !runtimeExpression(context, operator_index + 1, right_end) or
            !unsignedIntegerExpression(context, left_start, operator_index) or
            !unsignedIntegerExpression(context, operator_index + 1, right_end) or
            !rangeRepresentsLength(context, operator_index + 1, right_end, operator_index)) continue;
        if (rightOperandBoundedByRemaining(context, left_start, operator_index, right_end) or
            leftOperandComesFromSearchMatch(context, left_start, operator_index, operator_index + 1, right_end) or
            arithmeticHasVisibleGuard(context, operator_index, left_start, right_end, declaration_index)) continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const function_body = functionBodyContaining(context, declaration_index) orelse continue;
        if (!bindingFeedsBoundedRange(context, binding, function_body, statement_end + 1, scope_end, 0)) continue;
        try context.emit(.{
            .rule = .unchecked_range_end,
            .level = level,
            .span = context.tokens[operator_index].loc,
            .message = try context.allocator.dupe(
                u8,
                "range end uses unchecked runtime addition before bounds validation; validate with subtraction or checked arithmetic",
            ),
        });
    }
}

fn rangeRepresentsLength(context: RuleRun, start: usize, end: usize, before: usize) bool {
    if (rangeNamesLength(context, start, end)) return true;
    const name = runtimeName(context, start, end) orelse return false;
    const body_start = functionBodyContaining(context, before) orelse return false;
    for (context.tokens[body_start + 1 .. before], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= before or
            !context.tokenIs(declaration_index + 1, name)) continue;
        if (functionBodyContaining(context, declaration_index) != body_start) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |candidate, index| {
            if (candidate.tag == .identifier and context.tokenIs(index, "readInt")) return true;
        }
    }
    return false;
}

fn bindingFeedsBoundedRange(
    context: RuleRun,
    binding: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
    depth: usize,
) bool {
    if (depth == 3) return false;
    var statement_start = start;
    while (statement_start < end) {
        const statement_end = context.statementEnd(statement_start) orelse return false;
        const bounded_end = @min(statement_end, end);
        if (rangeContainsNameInFunction(context, binding, function_body, statement_start, bounded_end)) {
            if ((rangeContainsComparison(context.tokens, statement_start, bounded_end) and
                rangeNamesLength(context, statement_start, bounded_end)) or
                rangeUsesBindingAsSliceEnd(context, binding, function_body, statement_start, bounded_end)) return true;
            if (context.tokens[statement_start].tag == .keyword_const or context.tokens[statement_start].tag == .keyword_var) {
                const equal_index = findTag(context.tokens, .equal, statement_start + 2, bounded_end) orelse {
                    statement_start = statement_end + 1;
                    continue;
                };
                if (arithmeticInRange(context, .plus, equal_index + 1, bounded_end) != null and
                    rangeRepresentsLength(context, equal_index + 1, bounded_end, statement_start))
                {
                    const next_binding = context.tokenText(statement_start + 1);
                    if (bindingFeedsBoundedRange(context, next_binding, function_body, statement_end + 1, end, depth + 1)) return true;
                }
            }
        }
        statement_start = statement_end + 1;
    }
    return false;
}

fn rangeContainsNameInFunction(
    context: RuleRun,
    name: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and
            functionBodyContaining(context, index) == function_body) return true;
    }
    return false;
}

fn rangeUsesBindingAsSliceEnd(
    context: RuleRun,
    binding: []const u8,
    function_body: usize,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, range_index| {
        if (token.tag != .ellipsis2) continue;
        for (context.tokens[range_index + 1 .. end], range_index + 1..) |candidate, index| {
            if (candidate.tag == .r_bracket) break;
            if (candidate.tag == .identifier and context.tokenIs(index, binding) and
                functionBodyContaining(context, index) == function_body) return true;
        }
    }
    return false;
}

fn rangeContainsComparison(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (isComparison(token.tag)) return true;
    return false;
}

fn rangeContainsCall(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if ((tokens[index].tag == .identifier or tokens[index].tag == .builtin) and
            tokens[index + 1].tag == .l_paren) return true;
    }
    return false;
}

fn leftOperandEndsWithCall(tokens: []const std.zig.Token, operator_index: usize) bool {
    if (operator_index == 0 or tokens[operator_index - 1].tag != .r_paren) return false;
    var depth: usize = 0;
    var index = operator_index - 1;
    while (index > 0) {
        switch (tokens[index].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                depth -|= 1;
                if (depth == 0) return index > 0 and
                    (tokens[index - 1].tag == .identifier or tokens[index - 1].tag == .builtin);
            },
            else => {},
        }
        index -= 1;
    }
    return false;
}

fn leftOperandComesFromSearchMatch(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_start: usize,
    right_end: usize,
) bool {
    const offset_name = runtimeName(context, left_start, operator_index) orelse return false;
    const needle_name = lengthReceiverName(context, right_start, right_end) orelse return false;
    const body_start = functionBodyContaining(context, operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, call_index| {
        if (token.tag != .identifier or
            (!context.tokenIs(call_index, "indexOf") and !context.tokenIs(call_index, "indexOfPos")) or
            call_index + 1 >= operator_index or context.tokens[call_index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        if (!rangeContainsName(context, needle_name, call_index + 2, call_end)) continue;
        const capture_end = @min(call_end + 8, operator_index);
        for (context.tokens[call_end + 1 .. capture_end], call_end + 1..) |candidate, capture_index| {
            if (candidate.tag == .pipe and capture_index + 1 < capture_end and
                context.tokenIs(capture_index + 1, offset_name)) return true;
        }
    }
    return false;
}

fn lengthReceiverName(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var index = start;
    while (index + 2 < end) : (index += 1) {
        if (context.tokens[index].tag == .identifier and context.tokens[index + 1].tag == .period and
            context.tokenIs(index + 2, "len")) return context.tokenText(index);
    }
    return null;
}

fn singleArithmeticInRange(
    context: RuleRun,
    tag: std.zig.Token.Tag,
    start: usize,
    end: usize,
) ?usize {
    var selected: ?usize = null;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => if (token.tag == tag and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                if (selected != null) return null;
                selected = index;
            },
        }
    }
    return selected;
}

fn findTag(tokens: []const std.zig.Token, tag: std.zig.Token.Tag, start: usize, end: usize) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn isComparison(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        .bang_equal,
        => true,
        else => false,
    };
}

fn additionOperandStart(tokens: []const std.zig.Token, operator_index: usize, minimum: usize) usize {
    var start = operator_index;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    while (start > minimum) {
        const previous = tokens[start - 1].tag;
        switch (previous) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => if (parenthesis_depth != 0) {
                parenthesis_depth -= 1;
                start -= 1;
                continue;
            },
            .r_bracket => bracket_depth += 1,
            .l_bracket => if (bracket_depth != 0) {
                bracket_depth -= 1;
                start -= 1;
                continue;
            },
            .r_brace => brace_depth += 1,
            .l_brace => if (brace_depth != 0) {
                brace_depth -= 1;
                start -= 1;
                continue;
            },
            else => {},
        }
        if (parenthesis_depth != 0 or bracket_depth != 0 or brace_depth != 0) {
            start -= 1;
            continue;
        }
        const boundary = switch (previous) {
            .l_paren,
            .comma,
            .semicolon,
            .equal,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .slash_equal,
            .percent_equal,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            .equal_equal,
            .bang_equal,
            .keyword_and,
            .keyword_or,
            .l_bracket,
            .ellipsis2,
            => true,
            else => false,
        };
        if (boundary) break;
        start -= 1;
    }
    return start;
}

fn additionOperandEnd(tokens: []const std.zig.Token, start: usize, maximum: usize) usize {
    var end = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    while (end < maximum) : (end += 1) {
        switch (tokens[end].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => if (parenthesis_depth != 0) {
                parenthesis_depth -= 1;
                continue;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => if (bracket_depth != 0) {
                bracket_depth -= 1;
                continue;
            },
            .l_brace => brace_depth += 1,
            .r_brace => if (brace_depth != 0) {
                brace_depth -= 1;
                continue;
            },
            else => {},
        }
        if (parenthesis_depth != 0 or bracket_depth != 0 or brace_depth != 0) continue;
        switch (tokens[end].tag) {
            .r_paren,
            .comma,
            .semicolon,
            .angle_bracket_left,
            .angle_bracket_left_equal,
            .angle_bracket_right,
            .angle_bracket_right_equal,
            .equal_equal,
            .bang_equal,
            .keyword_and,
            .keyword_or,
            .r_bracket,
            => return end,
            else => {},
        }
    }
    return end;
}

fn rangeNamesLength(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "len", "length", "count", "size" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

fn extentComparedWithSameDimension(
    context: RuleRun,
    start: usize,
    comparison_index: usize,
    statement_end: usize,
) bool {
    const extent = runtimeName(context, start, comparison_index) orelse return false;
    if (!std.mem.eql(u8, extent, "width") and !std.mem.eql(u8, extent, "height")) return false;
    return rangeContainsName(context, extent, comparison_index + 1, statement_end);
}

fn rightOperandBoundedByRemaining(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, right_end) orelse return false;
    const body_start = functionBodyContaining(context, operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= operator_index or
            !context.tokenIs(declaration_index + 1, right_name)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= operator_index or
            !rangeContainsTag(context.tokens, .minus, declaration_index + 2, declaration_end) or
            !rangeContainsName(context, left_name, declaration_index + 2, declaration_end) or
            !rangeNamesLength(context, declaration_index + 2, declaration_end)) continue;
        return true;
    }
    return false;
}

fn narrowedOperandsCannotOverflowUsize(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const receiver = lengthReceiverName(context, operator_index + 1, right_end) orelse return false;
    const left_bits = unsignedOriginBits(context, left_name, operator_index, 0) orelse return false;
    const body_start = functionBodyContaining(context, operator_index) orelse return false;
    for (context.tokens[body_start + 1 .. operator_index], body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 4 >= operator_index or
            context.tokens[declaration_index + 1].tag != .identifier or
            context.tokens[declaration_index + 2].tag != .colon or
            context.tokens[declaration_index + 3].tag != .identifier) continue;
        const right_bits = unsignedTypeBits(context.tokenText(declaration_index + 3)) orelse continue;
        if (@max(left_bits, right_bits) + 1 > @bitSizeOf(usize)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= operator_index) continue;
        var saw_cast = false;
        var saw_receiver = false;
        var saw_length = false;
        for (context.tokens[declaration_index + 4 .. declaration_end], declaration_index + 4..) |candidate, index| {
            if (candidate.tag == .builtin and context.tokenIs(index, "@intCast")) saw_cast = true;
            if (candidate.tag == .identifier and context.tokenIs(index, receiver)) saw_receiver = true;
            if (candidate.tag == .identifier and context.tokenIs(index, "len")) saw_length = true;
        }
        if (saw_cast and saw_receiver and saw_length) return true;
    }
    return false;
}

fn additionIsSliceEnd(context: RuleRun, left_start: usize, right_end: usize) bool {
    if (context.tokens[right_end].tag != .r_bracket or left_start == 0) return false;
    return context.tokens[left_start - 1].tag == .ellipsis2;
}

fn riskyConstantLookahead(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    right_end: usize,
) bool {
    if (!rangeHasCursorName(context, left_start, operator_index) or operator_index + 2 != right_end or
        context.tokens[operator_index + 1].tag != .number_literal) return false;
    const literal = context.tokenText(operator_index + 1);
    const lookahead = std.fmt.parseInt(usize, literal, 0) catch return false;
    return lookahead >= 4;
}

fn rangeHasCursorName(context: RuleRun, start: usize, end: usize) bool {
    const names = [_][]const u8{ "cursor", "offset" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        const identifier = context.tokenText(index);
        for (names) |name| {
            if (std.mem.eql(u8, identifier, name) or
                (identifier.len > name.len and identifier[identifier.len - name.len - 1] == '_' and
                    std.mem.endsWith(u8, identifier, name))) return true;
        }
    }
    return false;
}

fn constantLookaheadHasVisibleGuard(
    context: RuleRun,
    left_start: usize,
    operator_index: usize,
    use_index: usize,
) bool {
    const cursor_name = runtimeName(context, left_start, operator_index) orelse return false;
    const literal = context.tokenText(operator_index + 1);
    const body_start = functionBodyContaining(context, use_index) orelse return false;
    const scope = context.enclosingOpeningBrace(use_index) orelse return false;
    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, guard_index| {
        if (token.tag != .keyword_if or context.enclosingOpeningBrace(guard_index) != scope or
            guard_index + 1 >= use_index or context.tokens[guard_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= use_index or !rangeContainsName(context, cursor_name, guard_index + 2, condition_end) or
            !rangeContainsLiteral(context, literal, guard_index + 2, condition_end) or
            !rangeNamesLength(context, guard_index + 2, condition_end) or
            !rangeContainsTag(context.tokens, .minus, guard_index + 2, condition_end)) continue;
        const guard_end = @min(context.statementEnd(guard_index) orelse use_index, use_index);
        if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
    }
    return false;
}

fn rangeContainsLiteral(context: RuleRun, literal: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal and std.mem.eql(u8, context.tokenText(index), literal)) return true;
    }
    return false;
}

fn rangeContainsTag(tokens: []const std.zig.Token, tag: std.zig.Token.Tag, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == tag) return true;
    return false;
}

fn additionIsInsideClamp(context: RuleRun, operator_index: usize) bool {
    var cursor = operator_index;
    while (cursor > 1) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
        if (context.tokens[cursor].tag != .l_paren or context.tokens[cursor - 1].tag != .builtin or
            (!context.tokenIs(cursor - 1, "@min") and !context.tokenIs(cursor - 1, "@max"))) continue;
        const closing = context.matchingToken(cursor, .l_paren, .r_paren) orelse return false;
        return operator_index < closing;
    }
    return false;
}

fn boundedUnsignedDifferenceInSignedType(context: RuleRun, start: usize, end: usize, operator_index: usize) bool {
    if (context.tokens[operator_index].tag != .minus) return false;
    const left_name = runtimeName(context, start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, end) orelse return false;
    const left_bits = unsignedOriginBits(context, left_name, operator_index, 0) orelse return false;
    const right_bits = unsignedOriginBits(context, right_name, operator_index, 0) orelse return false;
    const signed_bits = signedOperationBits(context, left_name, start, end, operator_index) orelse return false;
    return @max(left_bits, right_bits) < signed_bits;
}

fn unsignedOriginBits(context: RuleRun, name: []const u8, before: usize, depth: usize) ?usize {
    if (depth == 3) return null;
    const function_start = enclosingFunctionDeclaration(context, before) orelse 0;
    var index = before;
    while (index > function_start) {
        index -= 1;
        if (!context.tokenIs(index, name)) continue;
        if (index + 2 < before and context.tokens[index + 1].tag == .colon) {
            if (unsignedTypeBits(context.tokenText(index + 2))) |bits| return bits;
            if (signedTypeBits(context.tokenText(index + 2)) == null) continue;
            const declaration_end = context.statementEnd(statementStart(context.tokens, index)) orelse continue;
            var source_name: ?[]const u8 = null;
            for (context.tokens[index + 3 .. declaration_end], index + 3..) |token, value_index| {
                if (token.tag != .identifier or context.tokenIs(value_index, "intCast") or
                    context.tokenIs(value_index, "intFromFloat")) continue;
                if (context.tokens[value_index - 1].tag == .period) continue;
                source_name = context.tokenText(value_index);
            }
            if (source_name) |source| return unsignedOriginBits(context, source, index, depth + 1);
        }
        if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or
            context.tokens[index - 1].tag == .keyword_var))
        {
            const declaration_end = context.statementEnd(index - 1) orelse continue;
            for (context.tokens[index + 1 .. declaration_end], index + 1..) |token, value_index| {
                if (token.tag == .identifier) if (unsignedTypeBits(context.tokenText(value_index))) |bits| return bits;
            }
        }
    }
    return null;
}

fn signedOperationBits(context: RuleRun, left_name: []const u8, start: usize, end: usize, before: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier) if (signedTypeBits(context.tokenText(index))) |bits| return bits;
    }
    const function_start = enclosingFunctionDeclaration(context, before) orelse 0;
    var index = before;
    while (index > function_start) {
        index -= 1;
        if (!context.tokenIs(index, left_name) or index + 2 >= before or context.tokens[index + 1].tag != .colon) continue;
        return signedTypeBits(context.tokenText(index + 2));
    }
    return null;
}

fn enclosingFunctionDeclaration(context: RuleRun, target: usize) ?usize {
    var selected: ?usize = null;
    for (context.tokens[0..target], 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        var body_start = function_index + 1;
        while (body_start < target and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start == target or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (target < body_end) selected = function_index;
    }
    return selected;
}

fn unsignedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'u') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch null;
}

fn signedTypeBits(name: []const u8) ?usize {
    if (name.len < 2 or name[0] != 'i') return null;
    return std.fmt.parseInt(usize, name[1..], 10) catch null;
}

fn bitSizeMinusLeadingZeros(context: RuleRun, start: usize, end: usize, operator_index: usize) bool {
    if (context.tokens[operator_index].tag != .minus) return false;
    var clz_name: ?[]const u8 = null;
    var index = operator_index + 1;
    while (index + 2 < end) : (index += 1) {
        if (context.tokens[index].tag != .builtin or !context.tokenIs(index, "@clz") or
            context.tokens[index + 1].tag != .l_paren or context.tokens[index + 2].tag != .identifier) continue;
        clz_name = context.tokenText(index + 2);
        break;
    }
    const name = clz_name orelse return false;
    index = start;
    while (index + 4 < operator_index) : (index += 1) {
        if (context.tokens[index].tag != .builtin or !context.tokenIs(index, "@bitSizeOf") or
            context.tokens[index + 1].tag != .l_paren or context.tokens[index + 2].tag != .builtin or
            !context.tokenIs(index + 2, "@TypeOf") or context.tokens[index + 3].tag != .l_paren or
            !context.tokenIs(index + 4, name)) continue;
        return true;
    }
    return false;
}

fn arithmeticInRange(context: RuleRun, tag: std.zig.Token.Tag, start: usize, end: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var result: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => if (token.tag == tag and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                result = index;
            },
        }
    }
    return result;
}

fn integerExpression(context: RuleRun, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal) return true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "len") and index > start and context.tokens[index - 1].tag == .period) return true;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) {
            if (context.tokenIs(index - 2, "self") and selfFieldHasIntegerType(context, context.tokenText(index), index)) return true;
            continue;
        }
        if (integerTypedBinding(context, context.tokenText(index), index)) return true;
    }
    return false;
}

fn unsignedIntegerExpression(context: RuleRun, start: usize, end: usize) bool {
    if (start >= end) return false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .number_literal) return true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "len") and index > start and context.tokens[index - 1].tag == .period) return true;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) {
            if (fieldHasUnsignedType(context, context.tokenText(index))) return true;
            continue;
        }
        if (unsignedTypedBinding(context, context.tokenText(index), index)) return true;
    }
    return false;
}

fn unsignedTypedBinding(context: RuleRun, name: []const u8, before: usize) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    const function_start = functionStartForBody(context, function_body) orelse return false;
    var name_index = before;
    while (name_index > function_start) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name) or name_index + 1 >= before) continue;
        if (context.tokens[name_index + 1].tag == .colon) {
            return typeRangeIsUnsigned(context, name_index + 2, before);
        }
        if (context.tokens[name_index + 1].tag != .equal or name_index == 0 or
            (context.tokens[name_index - 1].tag != .keyword_const and
                context.tokens[name_index - 1].tag != .keyword_var)) continue;
        const declaration_end = context.statementEnd(name_index - 1) orelse continue;
        if (declaration_end >= before) continue;
        for (context.tokens[name_index + 2 .. declaration_end], name_index + 2..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, "readInt")) return true;
        }
        if (arithmeticInRange(context, .plus, name_index + 2, declaration_end)) |operator_index| {
            return unsignedIntegerExpression(context, name_index + 2, operator_index) and
                unsignedIntegerExpression(context, operator_index + 1, declaration_end);
        }
    }
    return false;
}

fn fieldHasUnsignedType(context: RuleRun, field_name: []const u8) bool {
    var found = false;
    for (context.tokens, 0..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or
            field_index + 2 >= context.tokens.len or context.tokens[field_index + 1].tag != .colon) continue;
        const unsigned = typeRangeIsUnsigned(context, field_index + 2, context.tokens.len);
        if (!unsigned) return false;
        found = true;
    }
    return found;
}

fn typeRangeIsUnsigned(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, type_index| {
        if (token.tag == .identifier) return unsignedIntegerTypeName(context.tokenText(type_index));
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
}

fn unsignedIntegerTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_ulong") or std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_ulonglong")) return true;
    if (name.len < 2 or name[0] != 'u') return false;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn runtimeExpression(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, "self") or context.tokenIs(index, "std") or context.tokenIs(index, "math")) continue;
        if (index >= start + 2 and context.tokens[index - 1].tag == .period) switch (context.tokens[index - 2].tag) {
            .string_literal, .char_literal, .number_literal => continue,
            else => {},
        };
        return true;
    }
    return false;
}

fn integerTypedBinding(context: RuleRun, name: []const u8, before: usize) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    const function_start = functionStartForBody(context, function_body) orelse return false;
    var name_index = before;
    while (name_index > function_start) {
        name_index -= 1;
        if (!context.tokenIs(name_index, name)) continue;
        if ((name_index > function_start and context.tokens[name_index - 1].tag == .pipe) or
            (name_index + 1 < before and context.tokens[name_index + 1].tag == .pipe)) return false;
        if (name_index + 1 < before and context.tokens[name_index + 1].tag == .colon) {
            return typeRangeIsInteger(context, name_index + 2, before);
        }
        if (name_index > function_start and
            (context.tokens[name_index - 1].tag == .keyword_const or context.tokens[name_index - 1].tag == .keyword_var) and
            name_index + 1 < before and context.tokens[name_index + 1].tag == .equal) return false;
    }
    return false;
}

fn selfFieldHasIntegerType(context: RuleRun, field_name: []const u8, before: usize) bool {
    const function_body = functionBodyContaining(context, before) orelse return false;
    const type_body = context.enclosingOpeningBrace(function_body) orelse return false;
    for (context.tokens[type_body + 1 .. function_body], type_body + 1..) |token, field_index| {
        if (token.tag != .identifier or !context.tokenIs(field_index, field_name) or
            field_index + 2 >= function_body or context.tokens[field_index + 1].tag != .colon or
            context.enclosingOpeningBrace(field_index) != type_body) continue;
        return typeRangeIsInteger(context, field_index + 2, function_body);
    }
    return false;
}

fn typeRangeIsInteger(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, type_index| {
        if (token.tag == .identifier and integerTypeName(context.tokenText(type_index))) return true;
        if (token.tag == .comma or token.tag == .equal or token.tag == .r_paren or token.tag == .semicolon) return false;
    }
    return false;
}

fn integerTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "c_int") or std.mem.eql(u8, name, "c_uint") or
        std.mem.eql(u8, name, "c_long") or std.mem.eql(u8, name, "c_ulong") or
        std.mem.eql(u8, name, "c_short") or std.mem.eql(u8, name, "c_ushort") or
        std.mem.eql(u8, name, "c_longlong") or std.mem.eql(u8, name, "c_ulonglong")) return true;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn arithmeticHasVisibleGuard(
    context: RuleRun,
    operator_index: usize,
    left_start: usize,
    right_end: usize,
    use_index: usize,
) bool {
    const left_name = runtimeName(context, left_start, operator_index) orelse return false;
    const right_name = runtimeName(context, operator_index + 1, right_end) orelse return false;
    const body_start = functionBodyContaining(context, use_index) orelse return false;
    const scope = context.enclosingOpeningBrace(use_index) orelse return false;
    const companion: std.zig.Token.Tag = if (context.tokens[operator_index].tag == .plus) .minus else .plus;

    if (inlineConditionalGuardsArithmetic(
        context,
        left_name,
        right_name,
        companion,
        left_start,
        operator_index,
    )) return true;

    for (context.tokens[body_start + 1 .. use_index], body_start + 1..) |token, guard_index| {
        if (context.enclosingOpeningBrace(guard_index) != scope) continue;
        if (token.tag == .keyword_if and guard_index + 1 < use_index and
            context.tokens[guard_index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end >= use_index or !guardConditionMatches(
                context,
                left_name,
                right_name,
                companion,
                guard_index + 2,
                condition_end,
            )) continue;
            const guard_end = @min(context.statementEnd(guard_index) orelse use_index, use_index);
            if (rangeTerminates(context, condition_end + 1, guard_end)) return true;
        }
        if (token.tag == .identifier and context.tokenIs(guard_index, "assert") and
            guard_index + 1 < use_index and context.tokens[guard_index + 1].tag == .l_paren)
        {
            const condition_end = context.matchingToken(guard_index + 1, .l_paren, .r_paren) orelse continue;
            if (condition_end < use_index and guardConditionMatches(
                context,
                left_name,
                right_name,
                companion,
                guard_index + 2,
                condition_end,
            )) return true;
        }
    }
    return false;
}

fn inlineConditionalGuardsArithmetic(
    context: RuleRun,
    left_name: []const u8,
    right_name: []const u8,
    companion: std.zig.Token.Tag,
    start: usize,
    operator_index: usize,
) bool {
    for (context.tokens[start..operator_index], start..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 1 >= operator_index or
            context.tokens[if_index + 1].tag != .l_paren) continue;
        const condition_end = context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse continue;
        if (condition_end >= operator_index or !guardConditionMatches(
            context,
            left_name,
            right_name,
            companion,
            if_index + 2,
            condition_end,
        )) continue;
        for (context.tokens[condition_end + 1 .. operator_index]) |branch_token| {
            if (branch_token.tag == .keyword_else) return true;
        }
    }
    return false;
}

fn runtimeName(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    var name: ?[]const u8 = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or context.tokenIs(index, "self") or context.tokenIs(index, "std") or
            context.tokenIs(index, "math")) continue;
        name = context.tokenText(index);
    }
    return name;
}

fn guardConditionMatches(
    context: RuleRun,
    left_name: []const u8,
    right_name: []const u8,
    companion: std.zig.Token.Tag,
    start: usize,
    end: usize,
) bool {
    var saw_left = false;
    var saw_right = false;
    var saw_companion = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == companion) saw_companion = true;
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, left_name)) saw_left = true;
        if (context.tokenIs(index, right_name)) saw_right = true;
    }
    return saw_left and saw_right and saw_companion;
}

fn rangeTerminates(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
        else => {},
    };
    return false;
}

fn functionBodyContaining(context: RuleRun, target_index: usize) ?usize {
    var selected: ?usize = null;
    for (context.tokens[0..target_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= target_index or
            context.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end) orelse continue;
        if (body_start >= target_index or context.tokens[body_start].tag != .l_brace) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (target_index < body_end) selected = body_start;
    }
    return selected;
}

fn functionStartForBody(context: RuleRun, body_start: usize) ?usize {
    var function_index = body_start;
    while (function_index > 0) {
        function_index -= 1;
        if (context.tokens[function_index].tag != .keyword_fn or function_index + 2 >= body_start or
            context.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        const candidate_body = syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end) orelse continue;
        if (candidate_body == body_start) return function_index;
    }
    return null;
}

fn topLevelComma(context: RuleRun, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) return index,
        else => {},
    };
    return null;
}

test "pointer-only frees and nullable pointer lengths preserve allocation contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn release(a: anytype, ptr: [*]u8) void { const bytes = ptr[0..16]; a.free(bytes); } " ++
        "fn copy(a: anytype, ptr: ?[*]const u8, len: usize) ![]u8 { const out = try a.alloc(u8, len); if (ptr) |p| { @memcpy(out, p[0..len]); } return out; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "unrelated integer parameters do not supply allocation lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn release(a: anytype, ptr: [*]u8, flags: u32) void { " ++
        "const bytes = ptr[0..16]; a.free(bytes); _ = flags; } " ++
        "fn releaseKnown(a: anytype, ptr: [*]u8, len: usize) void { " ++
        "const bytes = ptr[0..len]; a.free(bytes); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.pointer_only_free, findings[0].rule);
}

test "nullable pointer fallback copies initialize their allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(a: anytype, ptr: ?[*]const u8, fallback: []const u8, len: usize) ![]u8 { " ++
        "const out = try a.alloc(u8, len); if (ptr == null) { @memcpy(out, fallback[0..len]); } return out; }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "discarded descriptors and child pipe closes report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn openOne() !void { _ = try std.posix.openat(dir, name, flags, 0); } " ++
        "const Child = std.process.Child; fn childRun() !void { var child = Child.init(args, a); child.stdin.?.close(); _ = try child.wait(); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "custom open and socket methods do not imply OS resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(registry: *Registry) !void { _ = try registry.open(); _ = registry.socket(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "clearing a manually closed child pipe transfers the closed state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Child = std.process.Child; fn childRun() !void { var child = Child.init(args, a); child.stdin.?.close(); child.stdin = null; _ = try child.wait(); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "child bindings do not lend process provenance across functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn standard(args: anytype, allocator: anytype) void { " ++
        "var child = std.process.Child.init(args, allocator); _ = &child; } " ++
        "fn custom(child: *CustomChild) !void { child.stdout.?.close(); _ = try child.wait(); }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "discarded Io files and typed child parameters preserve resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn openOne(dir: std.Io.Dir, path: []const u8) !void { _ = try dir.openFile(path, .{}); } " ++
        "fn childRun(io: std.Io, child: *std.process.Child) !void { child.stdout.?.close(io); try child.wait(io); }";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(types.Rule.discarded_resource, findings[0].rule);
    try std.testing.expectEqual(types.Rule.child_pipe_double_close, findings[1].rule);
}

test "discarded absolute Io files preserve resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn openOne(io: std.Io) !void { _ = try std.Io.Dir.openFileAbsolute(io, \"/tmp/state\", .{});" ++
        "_ = try std.Io.Dir.createFileAbsolute(io, \"/tmp/output\", .{});" ++
        "_ = try std.fs.openDirAbsolute(\"/tmp\", .{}); }";
    const findings = try findingsFor(arena.allocator(), source);
    var discarded_count: usize = 0;
    for (findings) |finding| if (finding.rule == .discarded_resource) {
        discarded_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), discarded_count);
}

test "directories and spawned children retain their terminal cleanup contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(dir: std.Io.Dir, io: std.Io) !void { _ = try dir.openDir(io, \".\", .{});" ++
        "_ = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); }" ++
        "fn bound(io: std.Io) !void { var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); _ = child; }" ++
        "fn clean(io: std.Io) !void { var child = try std.process.spawn(io, .{ .argv = &.{\"true\"} }); _ = try child.wait(io); }";
    const found = try findingsFor(arena.allocator(), source);
    var discarded_count: usize = 0;
    var child_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .discarded_resource => discarded_count += 1,
        .unwaited_child_process => child_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), discarded_count);
    try std.testing.expectEqual(@as(usize, 2), child_count);
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
    const findings = try findingsFor(arena.allocator(), source);
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
    const findings = try findingsFor(arena.allocator(), source);
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
    const findings = try findingsFor(arena.allocator(), source);
    for (findings) |finding| try std.testing.expect(finding.rule != .unwaited_child_process);
}

test "unrelated and conditional exit calls do not replace child cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn unrelated(io: std.Io) !void { _ = try std.process.spawn(io, .{}); logger.exit(); }" ++
        "fn conditional(io: std.Io, stop: bool) !void { _ = try std.process.spawn(io, .{});" ++
        "if (stop) std.process.exit(1); continueWork(); }";
    const findings = try findingsFor(arena.allocator(), source);
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
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "checked addition is not made safe by a later minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Writer = struct { offset: usize, output: []u8, " ++
        "fn end(self: *Writer, amount: usize) usize { return @min(self.output.len, self.offset + amount); } }; " ++
        "fn second(limit: usize, offset: usize, amount: usize) usize { " ++
        "return @min(limit + 1, offset + amount); }";
    const found = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(types.Rule.overflow_before_clamp, found[0].rule);
    try std.testing.expectEqual(types.Rule.overflow_before_clamp, found[1].rule);
}

test "safe clamp arithmetic remains clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guarded(limit: usize, offset: usize, amount: usize) usize { " ++
        "if (amount > limit - offset) return limit; return @min(limit, offset + amount); } " ++
        "fn saturated(limit: usize, offset: usize, amount: usize) usize { return @min(limit, offset +| amount); } " ++
        "fn smallLookahead(limit: usize, offset: usize) usize { return @min(limit, offset + 8); } " ++
        "fn indexed(ranges: []Range, output_length: usize, range: Range) usize { " ++
        "return @max(ranges[output_length - 1].end, range.end); } " ++
        "const global_amount: usize = 1; fn inferred(limit: usize, offset: usize) usize { " ++
        "const global_amount = compute(); return @min(limit, offset + global_amount); } " ++
        "fn checked(limit: usize, offset: usize, amount: usize) !usize { " ++
        "const end = try std.math.add(usize, offset, amount); return @min(limit, end); }" ++
        "fn conditional(label: []const u8, maximum: usize) usize { " ++
        "return @max(0, if (maximum > label.len + 3) 0 else label.len + 3 - maximum); }" ++
        "fn bits(number: u64) usize { return @max(@bitSizeOf(@TypeOf(number)) - @clz(number), 3); }" ++
        "fn widened(height: u16, thickness: u16) i32 { const height_i: i32 = @intCast(height);" ++
        "return @max(0, height_i - @as(i32, thickness)); }";
    const found = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "unchecked range end addition before comparison reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Entry = struct { offset: usize, data: []const u8 };" ++
        "const Sprite = struct { width: usize };" ++
        "fn contains(total: usize, offset: usize, bytes: []const u8) bool {" ++
        "return offset + bytes.len <= total; }" ++
        "fn adjacent(entry: Entry, next: Entry) bool {" ++
        "return entry.offset + entry.data.len == next.offset; }" ++
        "fn decode(bytes: []const u8, cursor: usize, name_len: usize) bool {" ++
        "return cursor + 8 > bytes.len or cursor + name_len > bytes.len; }" ++
        "fn region(sprite: Sprite, x: usize, width: usize) bool {" ++
        "return x + width <= sprite.width; }" ++
        "fn take(bytes: []const u8, start: usize, length: usize) []const u8 {" ++
        "return bytes[start..start + length]; }" ++
        "fn assigned(bytes: []const u8, cursor: usize) bool {" ++
        "const name_len = std.mem.readInt(u32, bytes[0..4], .little);" ++
        "const content_len = std.mem.readInt(u32, bytes[4..8], .little);" ++
        "const name_end = cursor + name_len; const content_end = name_end + content_len;" ++
        "return content_end <= bytes.len; }";
    const found = try findingsFor(arena.allocator(), source);
    var range_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unchecked_range_end) range_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), range_count);
}

test "range checks inside functions with anonymous struct returns report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn contains(total: usize, offset: usize, bytes: []const u8) struct { ok: bool } {" ++
        "_ = total; const end = offset + bytes.len; return .{ .ok = end <= bytes.len }; }";
    const found = try findingsFor(arena.allocator(), source);
    var range_count: usize = 0;
    for (found) |finding| if (finding.rule == .unchecked_range_end) {
        range_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), range_count);
}

test "subtraction and checked range ends stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn contains(total: usize, offset: usize, bytes: []const u8) bool {" ++
        "if (offset > total) return false; return bytes.len <= total - offset; }" ++
        "fn checked(total: usize, offset: usize, length: usize) !bool {" ++
        "const end = try std.math.add(usize, offset, length); return end <= total; }" ++
        "fn header(bytes: []const u8, cursor: usize) bool {" ++
        "if (cursor > bytes.len - 8) return false; return cursor + 8 <= bytes.len; }" ++
        "fn signed(x: i32, width: i32, limit: i32) bool { return x + width <= limit; }" ++
        "fn floating(x: f64, width: f64, limit: f64) bool { return x + width <= limit; }" ++
        "fn narrowed(word: []const u8, col: u16, limit: usize) bool {" ++
        "const word_len: u16 = @intCast(word.len); _ = word_len; return col + word.len <= limit; }";
    const found = try findingsFor(arena.allocator(), source);
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

test "nested functions do not consume an outer declared range end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse(cursor: usize, amount: usize) usize { const Decoder = struct { fn read(bytes: []const u8) u32 {" ++
        "const amount = std.mem.readInt(u32, bytes[0..4], .little); return amount; } }; _ = Decoder;" ++
        "const end = cursor + amount; const Local = struct {" ++
        "fn take(bytes: []const u8, end: usize) []const u8 { return bytes[0..end]; } }; _ = Local; return end; }";
    const found = try findingsFor(arena.allocator(), source);
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

test "comparisons nested inside a later call are not range-end bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn measure(slice: []const u8, index: usize) u64 { var length: u64 = 0;" ++
        "length += slice.len - 2 + @intFromBool(index != 0); return length; }";
    const found = try findingsFor(arena.allocator(), source);
    for (found) |finding| try std.testing.expect(finding.rule != .unchecked_range_end);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
