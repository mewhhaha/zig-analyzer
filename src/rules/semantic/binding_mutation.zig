//! Proofs about whether a binding is written after its declaration: never-mutated variables, escaping undefined values and pointer parameters that could be const.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const enclosingScopeEnd = @import("../../syntax/tokens.zig").enclosingScopeEnd;
const isAssignment = @import("../../syntax/tokens.zig").isAssignment;
const insideFunctionOrTestBody = @import("../../syntax/tokens.zig").insideFunctionOrTestBody;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .never_mutated_var,
    .undefined_value_escape,
    .mutable_pointer_parameter,
};

pub fn run(context: RuleRun) !void {
    try findNeverMutatedVariables(context);
    try findUndefinedValueEscapes(context);
    try findPointerParameterIdioms(context);
}

fn identifierIsCaptureBinding(tokens: []const std.zig.Token, index: usize) bool {
    var opening = index;
    while (opening > 0 and index - opening < 16) {
        opening -= 1;
        switch (tokens[opening].tag) {
            .pipe => break,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    } else return false;
    var closing = index + 1;
    while (closing < tokens.len and closing - index < 16) : (closing += 1) {
        switch (tokens[closing].tag) {
            .pipe => return true,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    }
    return false;
}

fn findNeverMutatedVariables(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.never_mutated_var);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_var or index + 1 >= tokens.len or tokens[index + 1].tag != .identifier) continue;
        if (!insideFunctionOrTestBody(tokens, index)) continue;
        const name_token = tokens[index + 1];
        const name = tokenText(source, name_token);
        if (std.mem.eql(u8, name, "_")) continue;
        if (declarationUsesUndefined(source, tokens, index + 2)) continue;
        const scope_end = enclosingScopeEnd(tokens, index) orelse continue;
        if (bindingIsMutated(source, tokens, name, index + 2, scope_end)) continue;
        const fixes = try Fix.single(context.allocator, .{
            .title = try context.allocator.print("Change '{s}' to const", .{name}),
            .span = token.loc,
            .replacement = "const",
            .preferred = true,
        });
        try context.emit(.{
            .rule = .never_mutated_var,
            .level = level,
            .span = name_token.loc,
            .message = try context.allocator.print("variable '{s}' is never mutated", .{name}),
            .fixes = fixes,
        });
    }
}

fn declarationUsesUndefined(source: []const u8, tokens: []const std.zig.Token, start: usize) bool {
    for (tokens[start..]) |token| {
        switch (token.tag) {
            .identifier => if (tokenIs(source, token, "undefined")) return true,
            .semicolon => return false,
            else => {},
        }
    }
    return false;
}

fn bindingIsMutated(
    source: []const u8,
    tokens: []const std.zig.Token,
    name: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], name)) continue;
        const shadows_binding = index > 0 and
            (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var) or
            identifierIsCaptureBinding(tokens, index);
        if (shadows_binding) {
            index = enclosingScopeEnd(tokens, index) orelse index;
            continue;
        }
        if (index > 0 and tokens[index - 1].tag == .ampersand) return true;
        if (usedByAssembly(tokens, index)) return true;
        if (usedByFieldMutation(source, tokens, index)) return true;
        if (usedByMutableOptionalCapture(tokens, index)) return true;
        if (usedByMutableSwitchCapture(tokens, index)) return true;
        if (index + 1 >= tokens.len) continue;
        if (identifierIsLvalueAssignment(tokens, index)) return true;
        if (identifierIsDestructuredAssignmentTarget(tokens, index)) return true;
    }
    return false;
}

fn identifierIsLvalueAssignment(tokens: []const std.zig.Token, index: usize) bool {
    var cursor = index + 1;
    while (cursor < tokens.len) {
        if (tokens[cursor].tag == .period) {
            cursor += 1;
            if (cursor < tokens.len and (tokens[cursor].tag == .identifier or tokens[cursor].tag == .asterisk or tokens[cursor].tag == .question_mark)) {
                if (cursor + 1 < tokens.len and tokens[cursor].tag == .identifier and tokens[cursor + 1].tag == .l_paren) {
                    return true;
                }
                cursor += 1;
                continue;
            }
            return false;
        } else if (tokens[cursor].tag == .l_bracket) {
            cursor = (matchingToken(tokens, cursor, .l_bracket, .r_bracket) orelse return false) + 1;
            continue;
        }
        break;
    }
    if (cursor < tokens.len and isAssignment(tokens[cursor].tag)) return true;
    return false;
}

fn identifierIsDestructuredAssignmentTarget(tokens: []const std.zig.Token, index: usize) bool {
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .comma) return false;
    var cursor = index + 1;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .comma,
            .identifier,
            .period,
            .l_bracket,
            .r_bracket,
            .number_literal,
            .keyword_const,
            .keyword_var,
            .colon,
            => {},
            .equal => return true,
            else => return false,
        }
    }
    return false;
}

fn usedByAssembly(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_asm => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn usedByFieldMutation(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or tokens[use_index - 1].tag != .l_paren or
        !tokenIs(source, tokens[use_index - 2], "@field")) return false;
    const closing = matchingToken(tokens, use_index - 1, .l_paren, .r_paren) orelse return false;
    if (identifierIsLvalueAssignment(tokens, closing)) return true;
    return use_index >= 3 and tokens[use_index - 3].tag == .ampersand;
}

fn usedByMutableOptionalCapture(tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or use_index + 5 >= tokens.len) return false;
    if (tokens[use_index - 1].tag != .l_paren or
        (tokens[use_index - 2].tag != .keyword_if and tokens[use_index - 2].tag != .keyword_while)) return false;
    return tokens[use_index + 1].tag == .r_paren and
        tokens[use_index + 2].tag == .pipe and
        tokens[use_index + 3].tag == .asterisk and
        tokens[use_index + 4].tag == .identifier and
        tokens[use_index + 5].tag == .pipe;
}

fn usedByMutableSwitchCapture(tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index == 0 or tokens[use_index - 1].tag != .l_paren) return false;
    var switch_index = use_index - 1;
    while (switch_index > 0 and use_index - switch_index < 16) {
        switch_index -= 1;
        if (tokens[switch_index].tag == .keyword_switch) break;
        if (tokens[switch_index].tag == .semicolon or tokens[switch_index].tag == .l_brace) return false;
    } else return false;
    const operand_end = matchingToken(tokens, use_index - 1, .l_paren, .r_paren) orelse return false;
    if (operand_end + 1 >= tokens.len or tokens[operand_end + 1].tag != .l_brace) return false;
    const switch_end = matchingToken(tokens, operand_end + 1, .l_brace, .r_brace) orelse return false;
    var index = operand_end + 2;
    while (index + 1 < switch_end) : (index += 1) {
        if (tokens[index].tag == .pipe and tokens[index + 1].tag == .asterisk) return true;
    }
    return false;
}

fn findUndefinedValueEscapes(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.undefined_value_escape);
    if (level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = statementEnd(tokens, declaration_index) orelse continue;
        const undefined_index = undefinedInitializer(tokens, source, declaration_index + 2, statement_end) orelse continue;
        var type_contains_array = false;
        for (tokens[declaration_index + 2 .. undefined_index]) |type_token| {
            if (type_token.tag == .l_bracket) type_contains_array = true;
        }
        if (type_contains_array) continue;
        const binding_name = tokenText(source, tokens[declaration_index + 1]);
        const binding_index = declaration_index + 1;
        const scope_end = enclosingScopeEnd(tokens, declaration_index) orelse continue;
        var index = statement_end + 1;
        while (index < scope_end and index < tokens.len) : (index += 1) {
            if (!tokenIs(source, tokens[index], binding_name)) continue;
            if (index > 0 and tokens[index - 1].tag == .period) continue;
            const visible_binding = context.scopes.findBinding(index) orelse continue;
            if (visible_binding.token_index != binding_index) continue;
            if (index > 0 and (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var) or
                identifierIsCaptureBinding(tokens, index))
            {
                index = enclosingScopeEnd(tokens, index) orelse index;
                continue;
            }
            if (usedByTypeQuery(source, tokens, index) or useBelongsToErrdefer(tokens, index)) continue;
            if (index + 1 < tokens.len and tokens[index + 1].tag == .equal) break;
            if (identifierIsDestructuredAssignmentTarget(tokens, index)) break;
            if (index > 0 and tokens[index - 1].tag == .ampersand or usedByAssembly(tokens, index)) break;
            if (usedByFieldMutation(source, tokens, index)) break;
            if (index + 2 < tokens.len and tokens[index + 1].tag == .period and
                tokens[index + 2].tag == .identifier) break;
            if (index + 3 < tokens.len and tokens[index + 1].tag == .period and
                tokens[index + 3].tag == .equal) break;
            if (index + 1 < tokens.len and tokens[index + 1].tag == .l_bracket) {
                const closing = matchingToken(tokens, index + 1, .l_bracket, .r_bracket) orelse continue;
                if (closing + 1 < tokens.len and tokens[closing + 1].tag == .equal) break;
                break;
            }
            try context.emit(.{
                .rule = .undefined_value_escape,
                .level = level,
                .span = tokens[index].loc,
                .message = try context.allocator.print(
                    "value '{s}' initialized with undefined is read or escapes before whole-value initialization",
                    .{binding_name},
                ),
            });
            break;
        }
    }
}

fn undefinedInitializer(
    tokens: []const std.zig.Token,
    source: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => parenthesis_depth -|= 1,
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .equal => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            if (index + 1 < end and tokenIs(source, tokens[index + 1], "undefined")) return index + 1;
            return null;
        },
        else => {},
    };
    return null;
}

fn usedByTypeQuery(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or tokens[use_index - 1].tag != .l_paren or tokens[use_index - 2].tag != .builtin) return false;
    return tokenIs(source, tokens[use_index - 2], "@TypeOf") or tokenIs(source, tokens[use_index - 2], "@typeInfo");
}

fn useBelongsToErrdefer(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    var braces: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => braces += 1,
            .l_brace => braces -|= 1,
            .keyword_errdefer => return true,
            .semicolon => if (braces == 0) return false,
            .keyword_fn, .keyword_test => return false,
            else => {},
        }
    }
    return false;
}

fn findPointerParameterIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.mutable_pointer_parameter);
    if (level == .off) return;
    // A function passed around as a value (comparator, callback) has its
    // signature dictated by the receiving API, not by its body. One pass over
    // the file collects every identifier that appears without a call's '('.
    var value_referenced_names: std.StringHashMapUnmanaged(void) = .empty;
    defer value_referenced_names.deinit(context.allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        if (index + 1 < tokens.len and tokens[index + 1].tag == .l_paren) continue;
        try value_referenced_names.put(context.allocator, tokenText(source, token), {});
    }
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 3 >= tokens.len or tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        var body_open = parameters_end + 1;
        while (body_open < tokens.len and tokens[body_open].tag != .l_brace and tokens[body_open].tag != .semicolon) : (body_open += 1) {}
        if (body_open >= tokens.len or tokens[body_open].tag != .l_brace) continue;
        const body_close = matchingToken(tokens, body_open, .l_brace, .r_brace) orelse continue;
        // deinit takes '*T' by convention: it invalidates the value even when its
        // body happens to only read through the pointer.
        if (tokens[fn_index + 1].tag == .identifier and tokenIs(source, tokens[fn_index + 1], "deinit")) continue;
        if (tokens[fn_index + 1].tag == .identifier and
            value_referenced_names.contains(tokenText(source, tokens[fn_index + 1]))) continue;
        var parameter_index = fn_index + 3;
        while (parameter_index + 3 < parameters_end) : (parameter_index += 1) {
            if (tokens[parameter_index].tag != .identifier or tokens[parameter_index + 1].tag != .colon or
                tokens[parameter_index + 2].tag != .asterisk or tokens[parameter_index + 3].tag != .identifier) continue;
            const parameter_name = tokenText(source, tokens[parameter_index]);
            if (!pointerParameterReadOnly(source, tokens, parameter_name, body_open, body_close)) continue;
            if (pointerParameterMayOwnMutableParameter(
                source,
                tokens,
                parameter_index,
                parameters_end,
                body_open,
                body_close,
            )) continue;
            const fixes = try Fix.single(context.allocator, .{
                .title = "Make the pointee const",
                .kind = .refactor_rewrite,
                .span = tokens[parameter_index + 2].loc,
                .replacement = "*const ",
            });
            try context.emit(.{
                .rule = .mutable_pointer_parameter,
                .level = level,
                .span = tokens[parameter_index + 2].loc,
                .message = try context.allocator.print(
                    "parameter '{s}' is only read through this pointer; '*const' communicates that contract",
                    .{parameter_name},
                ),
                .fixes = fixes,
            });
        }
    }
}

fn pointerParameterMayOwnMutableParameter(
    source: []const u8,
    tokens: []const std.zig.Token,
    owner_parameter_index: usize,
    parameters_end: usize,
    body_open: usize,
    body_close: usize,
) bool {
    const owner_type = tokenText(source, tokens[owner_parameter_index + 3]);
    var parameter_index = owner_parameter_index + 4;
    while (parameter_index + 3 < parameters_end) : (parameter_index += 1) {
        if (tokens[parameter_index].tag != .identifier or tokens[parameter_index + 1].tag != .colon or
            tokens[parameter_index + 2].tag != .asterisk or tokens[parameter_index + 3].tag != .identifier) continue;
        const mutable_parameter_name = tokenText(source, tokens[parameter_index]);
        if (pointerParameterReadOnly(source, tokens, mutable_parameter_name, body_open, body_close)) continue;
        const mutable_parameter_type = tokenText(source, tokens[parameter_index + 3]);
        if (structContainsFieldType(source, tokens, owner_type, mutable_parameter_type)) return true;
    }
    return false;
}

fn structContainsFieldType(
    source: []const u8,
    tokens: []const std.zig.Token,
    owner_type: []const u8,
    field_type: []const u8,
) bool {
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, owner_type) or index == 0 or index + 3 >= tokens.len) continue;
        if (tokens[index - 1].tag != .keyword_const or tokens[index + 1].tag != .equal or
            tokens[index + 2].tag != .keyword_struct or tokens[index + 3].tag != .l_brace) continue;
        const body_close = matchingToken(tokens, index + 3, .l_brace, .r_brace) orelse return false;
        var depth: usize = 1;
        for (tokens[index + 4 .. body_close]) |field_token| {
            if (field_token.tag == .l_brace) depth += 1;
            if (field_token.tag == .r_brace) depth -= 1;
            if (depth == 1 and field_token.tag == .identifier and tokenIs(source, field_token, field_type)) return true;
        }
        return false;
    }
    return false;
}

fn pointerParameterReadOnly(
    source: []const u8,
    tokens: []const std.zig.Token,
    parameter_name: []const u8,
    body_open: usize,
    body_close: usize,
) bool {
    var uses: usize = 0;
    for (tokens[body_open + 1 .. body_close], body_open + 1..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, parameter_name)) continue;
        uses += 1;
        // '&param.field' escapes as a mutable pointer, which '*const' would forbid.
        if (index > 0 and tokens[index - 1].tag == .ampersand) return false;
        // Likewise '&@field(param, ...)'.
        if (index >= 3 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .builtin and
            tokens[index - 3].tag == .ampersand) return false;
        // 'switch (param.field)' with a '|*capture|' prong mutates through the operand.
        if (index >= 2 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .keyword_switch and
            switchHasPointerCapture(tokens, index - 1, body_close)) return false;
        const address_taken = index > body_open and tokens[index - 1].tag == .ampersand or
            index > body_open + 1 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .ampersand;
        if (address_taken) return false;
        if (usedByMutableSwitchCapture(tokens, index)) return false;
        if (parameterUseIsWithinLoop(tokens, index)) return false;
        var cursor = index + 1;
        while (cursor < body_close) {
            switch (tokens[cursor].tag) {
                .period_asterisk => cursor += 1,
                .period => {
                    if (cursor + 1 >= body_close or tokens[cursor + 1].tag != .identifier) return false;
                    cursor += 2;
                },
                .l_bracket => {
                    const subscript_close = matchingToken(tokens, cursor, .l_bracket, .r_bracket) orelse return false;
                    if (subscript_close >= body_close) return false;
                    // A range subscript produces a mutable slice of the pointee.
                    for (tokens[cursor + 1 .. subscript_close]) |subscript_token| {
                        if (subscript_token.tag == .ellipsis2) return false;
                    }
                    cursor = subscript_close + 1;
                },
                else => break,
            }
        }
        if (cursor + 3 < body_close and tokens[cursor].tag == .r_paren and
            tokens[cursor + 1].tag == .pipe and tokens[cursor + 2].tag == .asterisk and
            tokens[cursor + 3].tag == .identifier) return false;
        if (cursor == index + 1) return false;
        if (cursor < body_close and (isAssignment(tokens[cursor].tag) or tokens[cursor].tag == .l_paren)) return false;
    }
    return uses != 0;
}

fn switchHasPointerCapture(tokens: []const std.zig.Token, condition_open: usize, limit: usize) bool {
    const condition_close = matchingToken(tokens, condition_open, .l_paren, .r_paren) orelse return false;
    if (condition_close + 1 >= limit or tokens[condition_close + 1].tag != .l_brace) return false;
    const body_close = matchingToken(tokens, condition_close + 1, .l_brace, .r_brace) orelse return false;
    for (tokens[condition_close + 2 .. @min(body_close, limit)], condition_close + 2..) |token, index| {
        if (token.tag == .pipe and index + 1 < limit and tokens[index + 1].tag == .asterisk) return true;
    }
    return false;
}

fn parameterUseIsWithinLoop(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .l_paren => if (cursor > 0 and tokens[cursor - 1].tag == .keyword_for) return true,
            .l_brace, .r_brace, .semicolon => return false,
            else => {},
        }
    }
    return false;
}

test "never-mutated analysis ignores mutations of a shadowing binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    var value = 1;\n" ++
        "    { var value = 2; value += 1; _ = value; }\n" ++
        "    _ = value;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .never_mutated_var) {
        warning_count += 1;
        try std.testing.expectEqualStrings("value", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "never-mutated analysis omits top-level state and possible mutable receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var global_state: u32 = 0;\n" ++
        "const State = struct { var namespace_state: u32 = 0; };\n" ++
        "fn run() void {\n" ++
        "    const LocalState = struct { var namespace_state: u32 = 0; };\n" ++
        "    var iterator = Iterator.init();\n" ++
        "    _ = iterator.next();\n" ++
        "    var output: u32 = undefined;\n" ++
        "    asm volatile (\"instruction\" : [value] \"=r\" (output));\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "never-mutated analysis recognizes mutable optional captures and nested assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(optional: ?Resource, root: *const Node) void {\n" ++
        "    var owned = optional;\n" ++
        "    defer if (owned) |*resource| resource.deinit();\n" ++
        "    var current = optional;\n" ++
        "    while (current) |*resource| { resource.advance(); break; }\n" ++
        "    var node = root;\n" ++
        "    var remaining: usize = 2;\n" ++
        "    while (true) {\n" ++
        "        switch (node.content) {\n" ++
        "            .leaf => |leaf| return leaf.bytes[remaining],\n" ++
        "            .branch => |branch| {\n" ++
        "                if (remaining < branch.count) {\n" ++
        "                    node = branch.left;\n" ++
        "                } else {\n" ++
        "                    remaining -= branch.count;\n" ++
        "                    node = branch.right;\n" ++
        "                }\n" ++
        "            },\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "never-mutated analysis identifies variables only read via field or array index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    var s = Point{ .x = 1 };\n" ++
        "    _ = s.x;\n" ++
        "    var arr = [_]u8{ 1, 2, 3 };\n" ++
        "    _ = arr[0];\n" ++
        "    var index: usize = 0;\n" ++
        "    var target = [_]u8{ 4, 5 };\n" ++
        "    target[index] = 9;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var never_mutated_count: usize = 0;
    for (found) |finding| if (finding.rule == .never_mutated_var) {
        never_mutated_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), never_mutated_count);
}

test "mutation through @field keeps a var mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn withStackAlign(cc: Convention, alignment: u64) Convention {\n" ++
        "    var result = cc;\n" ++
        "    @field(result, @tagName(cc)).incoming_stack_alignment = alignment;\n" ++
        "    return result;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "undefined escape warns only before whole-value initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak() u32 { var result: u32 = undefined; return result; }\n" ++
        "fn clean() u32 { var result: u32 = undefined; result = 42; return result; }\n" ++
        "fn initializedByPointer(fill: anytype) u32 { var result: u32 = undefined; fill(&result); return result; }\n" ++
        "fn partial() Pair { var result: Pair = .{ .first = undefined, .second = 1 }; return result; }\n" ++
        "fn shuffled(value: @Vector(4, u32)) @Vector(4, u32) { var result = @shuffle(u32, value, undefined, [_]i32{ 0, 1, 2, 3 }); return result; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .undefined_value_escape) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "undefined tracking ignores same-named members type queries and guarded errdefer cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn outputs(fill: anytype, buffer: anytype) !void {\n" ++
        "    var len: usize = undefined;\n" ++
        "    try fill(buffer.len, &len);\n" ++
        "    _ = len;\n" ++
        "}\n" ++
        "fn parse(fill: anytype) !void {\n" ++
        "    var value: struct { field: bool } = undefined;\n" ++
        "    try fill(@TypeOf(value), &value);\n" ++
        "    _ = value.field;\n" ++
        "}\n" ++
        "fn pipelines() !void {\n" ++
        "    var values: Pair = undefined;\n" ++
        "    errdefer if (initialized()) { @field(values, \"first\").deinit(); };\n" ++
        "    @field(values, \"first\") = try make();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .undefined_value_escape);
}

test "pointer parameters mutated through nested members or subscripts stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Inner = struct { count: u32 };\n" ++
        "const State = struct { inner: Inner };\n" ++
        "const Buffer = struct { bytes: [4]u8 };\n" ++
        "fn touch(state: *State, buffer: *Buffer, counter: *u32) void {\n" ++
        "    state.inner.count = 1;\n" ++
        "    buffer.bytes[0] = 0;\n" ++
        "    counter.* += 1;\n" ++
        "}\n" ++
        "fn observe(state: *State) u32 {\n" ++
        "    return state.inner.count;\n" ++
        "}\n";
    const configuration = support.only(&.{.mutable_pointer_parameter}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| if (finding.rule == .mutable_pointer_parameter) {
        pointer_count += 1;
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "fn observe").?);
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "pointer parameters mutated through captures or returned pointers stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = union(enum) { value: u32 };\n" ++
        "const Store = struct { values: []u32, state: State };\n" ++
        "fn update(store: *Store) void { switch (store.state) { .value => |*value| value.* += 1 } }\n" ++
        "fn clear(store: *Store) void { for (store.values) |*value| value.* = 0; }\n" ++
        "fn first(store: *Store) *u32 { return &store.values[0]; }\n" ++
        "fn observe(store: *Store) usize { return store.values.len; }\n";
    const configuration = support.only(&.{.mutable_pointer_parameter}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .mutable_pointer_parameter) pointer_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "pointer owner stays mutable when another parameter mutates its field type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const OwnedConfiguration = struct { compiled: bool };\n" ++
        "const Highlighter = struct {\n" ++
        "    configurations: []OwnedConfiguration,\n" ++
        "    fn compileConfiguration(self: *Highlighter, owned: *OwnedConfiguration) void {\n" ++
        "        _ = self.configurations.len;\n" ++
        "        owned.compiled = true;\n" ++
        "    }\n" ++
        "    fn count(self: *Highlighter) usize { return self.configurations.len; }\n" ++
        "};\n";
    const configuration = support.only(&.{.mutable_pointer_parameter}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| if (finding.rule == .mutable_pointer_parameter) {
        pointer_count += 1;
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "fn count").?);
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "destructuring assignment counts as mutation of its targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn divmod(a: u32, b: u32) struct { u32, u32 } { return .{ a / b, a % b }; }\n" ++
        "fn run() void {\n" ++
        "    var quotient: u32 = 0;\n" ++
        "    var remainder: u32 = 0;\n" ++
        "    var untouched: u32 = 0;\n" ++
        "    quotient, remainder = divmod(1, 2);\n" ++
        "    _ = quotient; _ = remainder; _ = untouched;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var mutation_count: usize = 0;
    for (found) |finding| if (finding.rule == .never_mutated_var) {
        mutation_count += 1;
        try std.testing.expectEqualStrings("untouched", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), mutation_count);
}

test "undefined values initialized by destructuring do not escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn divmod(a: u32, b: u32) struct { u32, u32 } { return .{ a / b, a % b }; }\n" ++
        "fn run() u32 {\n" ++
        "    var quotient: u32 = undefined;\n" ++
        "    var remainder: u32 = undefined;\n" ++
        "    quotient, remainder = divmod(1, 2);\n" ++
        "    return quotient + remainder;\n" ++
        "}\n" ++
        "fn mixed() u32 {\n" ++
        "    var x: u32 = undefined;\n" ++
        "    const tuple = .{ 1, 2, 3 };\n" ++
        "    x, var y: u32, const z = tuple;\n" ++
        "    return x + y + z;\n" ++
        "}\n" ++
        "fn leak() u32 { var escaped: u32 = undefined; return escaped; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var escape_count: usize = 0;
    for (found) |finding| if (finding.rule == .undefined_value_escape) {
        escape_count += 1;
        try std.testing.expectEqualStrings("escaped", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), escape_count);
}

test "pointer parameters that escape mutably stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Ring = struct { items: [4]u8, index: usize };\n" ++
        "fn itemPtr(ring: *Ring, index: usize) *u8 {\n" ++
        "    return &ring.items[index];\n" ++
        "}\n" ++
        "fn head(ring: *Ring) []u8 {\n" ++
        "    return ring.items[0..ring.index];\n" ++
        "}\n" ++
        "fn advance(ring: *Ring) void {\n" ++
        "    switch (ring.index) { else => |*value| value.* = 0 }\n" ++
        "}\n" ++
        "fn deinit(ring: *Ring) void {\n" ++
        "    _ = ring.items[0];\n" ++
        "}\n";
    const configuration = support.only(&.{.mutable_pointer_parameter}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .mutable_pointer_parameter);
}

test "constrained signatures and field address escapes keep mutable pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Read = struct { ready_at: u64 };\n" ++
        "fn lessThan(_: void, a: *Read, b: *Read) bool {\n" ++
        "    return a.ready_at < b.ready_at;\n" ++
        "}\n" ++
        "const Queue = std.PriorityQueue(*Read, void, lessThan);\n" ++
        "const Forest = struct { grooves: u32 };\n" ++
        "fn groovePtr(forest: *Forest) *u32 {\n" ++
        "    return &@field(forest, \"grooves\");\n" ++
        "}\n";
    const configuration = support.only(&.{.mutable_pointer_parameter}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .mutable_pointer_parameter);
}
