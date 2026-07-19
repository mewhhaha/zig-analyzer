const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;

pub fn run(context: RuleRun) !void {
    try findReturnedLocalSlices(context);
    try findReturnedLocalPointers(context);
    try findGloballyStoredLocalSlices(context);
    try findOutputParameterStoredLocalSlices(context);
    try findRetainedLocalPointers(context);
}

fn findReturnedLocalSlices(context: RuleRun) !void {
    const level = context.level(.returning_local_slice);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        // A 'comptime var' array is interned into the binary; slices of it are
        // valid after the function returns.
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        // A function with only comptime parameters is evaluated from values
        // known during compilation, so its local result storage is promoted.
        if (enclosingFunctionHasOnlyComptimeParameters(context, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declarationStoresArray(context, declaration_index, declaration_end)) continue;
        const function_scope = enclosingFunctionScope(context, declaration_index) orelse continue;
        const scope_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const binding_index = declaration_index + 1;
        const binding_name = context.tokenText(binding_index);

        var return_index = declaration_end + 1;
        while (return_index + 2 < scope_end) : (return_index += 1) {
            if (context.tokens[return_index].tag != .keyword_return or
                context.enclosingOpeningBrace(return_index) != function_scope) continue;
            const return_end = context.statementEnd(return_index) orelse continue;
            const direct_slice = context.tokenIs(return_index + 1, binding_name) and
                context.tokens[return_index + 2].tag == .l_bracket and
                sliceExpressionReturnsView(context, return_index + 2, return_end);
            const returned_alias = if (context.tokens[return_index + 1].tag == .identifier and
                return_index + 2 == return_end)
                aliasBorrowsLocalArray(
                    context,
                    context.tokenText(return_index + 1),
                    binding_name,
                    function_scope + 1,
                    return_index,
                )
            else
                false;
            if (!direct_slice and !returned_alias) continue;
            try context.emit(.{
                .rule = .returning_local_slice,
                .level = level,
                .span = context.tokens[return_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "returned slice '{s}' refers to a local array whose storage expires when this function returns",
                    .{binding_name},
                ),
            });
        }
    }
}

fn findReturnedLocalPointers(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const function_scope = enclosingFunctionScope(context, declaration_index) orelse continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        for (context.tokens[declaration_end + 1 .. function_end], declaration_end + 1..) |candidate, return_index| {
            if (candidate.tag != .keyword_return or context.enclosingOpeningBrace(return_index) != function_scope) continue;
            const return_end = context.statementEnd(return_index) orelse continue;
            const address_index = returnedAddressOfBinding(context, binding_name, return_index + 1, return_end) orelse continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[address_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "returned value stores a pointer to local binding '{s}', whose storage expires when the function returns",
                    .{binding_name},
                ),
            });
        }
    }
}

fn findGloballyStoredLocalSlices(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declarationStoresArray(context, declaration_index, declaration_end)) continue;
        const function_scope = enclosingFunctionScope(context, declaration_index) orelse continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const local_name = context.tokenText(declaration_index + 1);
        var index = declaration_end + 1;
        while (index + 3 < function_end) : (index += 1) {
            if (context.tokens[index].tag != .identifier or context.tokens[index + 1].tag != .equal or
                !context.tokenIs(index + 2, local_name) or context.tokens[index + 3].tag != .l_bracket) continue;
            if (index > 0) switch (context.tokens[index - 1].tag) {
                .semicolon, .l_brace, .r_brace => {},
                else => continue,
            };
            const slice_end = context.matchingToken(index + 3, .l_bracket, .r_bracket) orelse continue;
            if (!sliceExpressionReturnsView(context, index + 3, slice_end + 1)) continue;
            const destination = context.tokenText(index);
            if (!moduleBindingExists(context, destination) or
                localBindingExists(context, destination, function_scope + 1, index)) continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[index + 2].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "slice of local array '{s}' is stored in global binding '{s}' and outlives its backing storage",
                    .{ local_name, destination },
                ),
            });
        }
    }
}

fn findOutputParameterStoredLocalSlices(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declarationStoresArray(context, declaration_index, declaration_end)) continue;
        const function_scope = enclosingFunctionScope(context, declaration_index) orelse continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const local_name = context.tokenText(declaration_index + 1);
        var index = declaration_end + 1;
        while (index + 5 < function_end) : (index += 1) {
            if (context.tokens[index].tag != .identifier) continue;
            const equal_index = if (context.tokens[index + 1].tag == .period_asterisk and
                context.tokens[index + 2].tag == .equal)
                index + 2
            else if (index + 3 < function_end and context.tokens[index + 1].tag == .period and
                context.tokens[index + 2].tag == .asterisk and context.tokens[index + 3].tag == .equal)
                index + 3
            else
                continue;
            if (!context.tokenIs(equal_index + 1, local_name) or context.tokens[equal_index + 2].tag != .l_bracket) continue;
            const slice_end = context.matchingToken(equal_index + 2, .l_bracket, .r_bracket) orelse continue;
            if (!sliceExpressionReturnsView(context, equal_index + 2, slice_end + 1)) continue;
            const output_name = context.tokenText(index);
            if (!functionParameterExists(context, function_scope, output_name)) continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[equal_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "slice of local array '{s}' is stored through output parameter '{s}' and outlives its backing storage",
                    .{ local_name, output_name },
                ),
            });
        }
    }
}

fn findRetainedLocalPointers(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !insideFunctionOrTestBody(context.tokens, declaration_index)) continue;
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const function_scope = enclosingFunctionScope(context, declaration_index) orelse continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const local_name = context.tokenText(declaration_index + 1);
        for (context.tokens[declaration_end + 1 .. function_end], declaration_end + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or !retainingMethod(context, method_index) or
                method_index < 2 or context.tokens[method_index - 1].tag != .period or
                context.tokens[method_index + 1].tag != .l_paren) continue;
            const receiver_root = callReceiverRoot(context, method_index) orelse continue;
            const retained_outside_scope = functionParameterExists(context, function_scope, receiver_root) or
                (moduleBindingExists(context, receiver_root) and
                    !localBindingExists(context, receiver_root, function_scope + 1, method_index));
            if (!retained_outside_scope) continue;
            const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
            const address_index = addressOfBinding(context, local_name, method_index + 2, call_end) orelse continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[address_index + 1].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "pointer to local binding '{s}' is retained by {s} beyond the binding's lifetime",
                    .{ local_name, context.tokenText(method_index) },
                ),
            });
            break;
        }
    }
}

fn retainingMethod(context: RuleRun, method_index: usize) bool {
    const methods = [_][]const u8{ "append", "appendAssumeCapacity", "insert", "put" };
    for (methods) |method| if (context.tokenIs(method_index, method)) return true;
    return false;
}

fn callReceiverRoot(context: RuleRun, method_index: usize) ?[]const u8 {
    if (method_index < 2 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier) return null;
    var root_index = method_index - 2;
    while (root_index >= 2 and context.tokens[root_index - 1].tag == .period and
        context.tokens[root_index - 2].tag == .identifier) root_index -= 2;
    return context.tokenText(root_index);
}

fn addressOfBinding(context: RuleRun, name: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .ampersand and index + 1 < end and context.tokenIs(index + 1, name)) return index;
    }
    return null;
}

fn functionParameterExists(context: RuleRun, body_opening: usize, name: []const u8) bool {
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    } else return false;
    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    for (context.tokens[parameters_opening + 1 .. parameters_closing], parameters_opening + 1..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and
            index + 1 < parameters_closing and context.tokens[index + 1].tag == .colon) return true;
    }
    return false;
}

fn moduleBindingExists(context: RuleRun, name: []const u8) bool {
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 1 >= context.tokens.len or
            !context.tokenIs(declaration_index + 1, name)) continue;
        if (!insideFunctionOrTestBody(context.tokens, declaration_index)) return true;
    }
    return false;
}

fn localBindingExists(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag == .keyword_const or token.tag == .keyword_var) and declaration_index + 1 < end and
            context.tokenIs(declaration_index + 1, name)) return true;
    }
    return false;
}

fn sliceExpressionReturnsView(context: RuleRun, opening: usize, end: usize) bool {
    const closing = context.matchingToken(opening, .l_bracket, .r_bracket) orelse return false;
    return closing < end and containsRange(context.tokens, opening + 1, closing) and
        (closing + 1 >= end or context.tokens[closing + 1].tag != .period_asterisk);
}

fn aliasBorrowsLocalArray(
    context: RuleRun,
    alias: []const u8,
    local: []const u8,
    start: usize,
    end: usize,
) bool {
    for (context.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 2 >= end or !context.tokenIs(declaration_index + 1, alias)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declaration_end > end) continue;
        var index = declaration_index + 2;
        while (index + 1 < declaration_end) : (index += 1) {
            if (!context.tokenIs(index, local) or context.tokens[index + 1].tag != .l_bracket) continue;
            if (sliceExpressionReturnsView(context, index + 1, declaration_end)) return true;
        }
    }
    return false;
}

fn returnedAddressOfBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    if (start + 1 < end and context.tokens[start].tag == .ampersand and context.tokenIs(start + 1, binding)) return start;
    var saw_initializer = false;
    var parenthesis_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .l_brace) saw_initializer = true;
        if (token.tag == .l_paren) {
            if (!saw_initializer) return null;
            parenthesis_depth += 1;
        }
        if (token.tag == .r_paren) parenthesis_depth -|= 1;
        if (saw_initializer and parenthesis_depth == 0 and token.tag == .ampersand and
            index + 1 < end and context.tokenIs(index + 1, binding)) return index;
    }
    return null;
}

fn enclosingFunctionScope(context: RuleRun, index: usize) ?usize {
    var cursor = index;
    var nested: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_brace => nested += 1,
            .l_brace => {
                if (nested != 0) {
                    nested -= 1;
                    continue;
                }
                var signature = cursor;
                while (signature > 0) {
                    signature -= 1;
                    switch (context.tokens[signature].tag) {
                        .keyword_fn, .keyword_test => return cursor,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn enclosingFunctionHasOnlyComptimeParameters(context: RuleRun, declaration_index: usize) bool {
    const body_opening = context.enclosingOpeningBrace(declaration_index) orelse return false;
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    } else return false;

    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    if (parameters_closing == parameters_opening + 1) return false;

    var saw_parameter = false;
    var segment_has_comptime = false;
    var nested: usize = 0;
    for (context.tokens[parameters_opening + 1 .. parameters_closing]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => nested += 1,
            .r_paren, .r_bracket, .r_brace => nested -|= 1,
            .keyword_comptime => {
                if (nested == 0) segment_has_comptime = true;
            },
            .comma => if (nested == 0) {
                if (!segment_has_comptime) return false;
                saw_parameter = true;
                segment_has_comptime = false;
            },
            else => {},
        }
    }
    if (!segment_has_comptime) return false;
    return saw_parameter or segment_has_comptime;
}

fn declarationStoresArray(context: RuleRun, declaration_index: usize, declaration_end: usize) bool {
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        if (context.tokens[index].tag == .colon and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
        if (context.tokens[index].tag == .equal and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
    }
    return false;
}

fn arrayLengthToken(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .number_literal, .identifier => true,
        else => false,
    };
}

fn containsRange(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .ellipsis2) return true;
    return false;
}

fn insideFunctionOrTestBody(tokens: []const std.zig.Token, declaration_index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = declaration_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn, .keyword_test => return true,
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

test "returning a slice of a local array expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn bytes() []u8 { var local = [_]u8{ 1, 2 }; return local[0..]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    var configuration = @import("types.zig").Configuration.defaults();
    const context: RuleRun = .{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    };
    try run(context);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);

    configuration.levels[@intFromEnum(@import("types.zig").Rule.returning_local_slice)] = .off;
    var disabled: std.ArrayList(@import("types.zig").Finding) = .empty;
    var disabled_context = context;
    disabled_context.configuration = configuration;
    disabled_context.findings = &disabled;
    try run(disabled_context);
    try std.testing.expectEqual(@as(usize, 0), disabled.items.len);
}

test "labeled block aliases and returned interface pointers expire local storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn label(input: []const u8) []const u8 { const result = blk: { var scratch: [8]u8 = undefined; " ++
        "@memcpy(scratch[0..input.len], input); break :blk scratch[0..input.len]; }; return result; }\n" ++
        "fn interface() Interface { var local = Reader{}; return .{ .context = &local }; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 2), findings.items.len);
    try std.testing.expectEqual(@import("types.zig").Rule.returning_local_slice, findings.items[0].rule);
    try std.testing.expectEqual(@import("types.zig").Rule.local_storage_escape, findings.items[1].rule);
}

test "passing a local pointer into a returned call result does not prove storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn completion() Result { var analyser = init(); defer analyser.deinit(); return .{ .list = build(&analyser) }; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "storing a local slice globally expires its backing array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var saved: []const u8 = &.{}; fn retain() void { var scratch = [_]u8{ 1, 2 }; saved = scratch[0..]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(@import("types.zig").Rule.local_storage_escape, findings.items[0].rule);
}

test "storing a local slice through an output parameter expires its backing array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn retain(output: *?[]const u8) void { var local: [8]u8 = undefined; output.* = local[1..]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings.items[0].rule);
}

test "retaining a local pointer in a parameter container expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const types = @import("types.zig");
    const source: [:0]const u8 =
        "fn schedule(scheduler: *Scheduler) !void { var local = Context{};" ++
        "try scheduler.tasks.append(scheduler.allocator, .{ .context = &local }); }" ++
        "fn localOnly(allocator: anytype) !void { var local = Context{}; var tasks = Tasks.empty;" ++
        "try tasks.append(allocator, .{ .context = &local }); use(tasks); }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens, .configuration = types.Configuration.defaults(), .findings = &findings });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings.items[0].rule);
}

test "dereferencing the slice returns the array by value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn digest() [4]u8 { var buf = [_]u8{ 1, 2, 3, 4 }; return buf[0..4].*; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "comptime var arrays are interned and outlive the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn snake(comptime input: []const u8) []const u8 { comptime var output: [input.len * 2]u8 = undefined; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "functions with only comptime parameters return promoted local slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn description(comptime input: []const u8) []const u8 { var output: [input.len]u8 = undefined; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a runtime parameter keeps local slice storage temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(comptime size: usize, fill: u8) []const u8 { var output: [size]u8 = undefined; output[0] = fill; return output[0..1]; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
}

test "heap-backed slices and local array values do not warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn heap(allocator: std.mem.Allocator) ![]u8 { var bytes: []u8 = try allocator.alloc(u8, 2); return bytes; }\n" ++
        "fn value() [2]u8 { var local = [_]u8{ 1, 2 }; return local; }";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(@import("types.zig").Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = @import("types.zig").Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
