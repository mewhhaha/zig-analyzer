const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    try findUselessErrorReturns(context);
    try findExposedPrivateTypes(context);
    try findDeprecatedReferences(context);
    try findMutatedContainerCopies(context);
}

fn findUselessErrorReturns(context: RuleRun) !void {
    const level = context.level(.useless_error_return);
    if (level == .off) return;
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or isExported(context, fn_index)) continue;
        const opening = nextTag(context.tokens, fn_index + 1, .l_paren) orelse continue;
        const parameters_end = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        const body_open = nextTagBefore(context.tokens, parameters_end + 1, .l_brace, .semicolon) orelse continue;
        const error_separator = firstTag(context.tokens, parameters_end + 1, body_open, .bang) orelse continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (!bodyIsProvenInfallible(context, body_open + 1, body_end)) continue;
        const name = if (fn_index + 1 < context.tokens.len and context.tokens[fn_index + 1].tag == .identifier)
            context.tokenText(fn_index + 1)
        else
            "function";
        try context.emit(.{
            .rule = .useless_error_return,
            .level = level,
            .span = context.tokens[error_separator].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "function '{s}' returns an error union, but its fully visible body has no operation that can fail",
                .{name},
            ),
        });
    }
}

fn bodyIsProvenInfallible(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return false,
        .keyword_error => return false,
        .identifier => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) return false,
        .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren and
            !context.tokenIs(index, "@as") and !context.tokenIs(index, "@intCast") and
            !context.tokenIs(index, "@floatCast") and !context.tokenIs(index, "@ptrCast") and
            !context.tokenIs(index, "@enumFromInt") and !context.tokenIs(index, "@intFromEnum") and
            !context.tokenIs(index, "@TypeOf")) return false,
        else => {},
    };
    return true;
}

const PrivateDeclaration = struct {
    name: []const u8,
    identifier_index: usize,
    error_set: bool,
};

fn findExposedPrivateTypes(context: RuleRun) !void {
    const type_level = context.level(.exposed_private_type);
    const error_level = context.level(.exposed_private_error_set);
    if (type_level == .off and error_level == .off) return;

    var declarations: std.ArrayList(PrivateDeclaration) = .empty;
    var brace_depth: usize = 0;
    for (context.tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .keyword_const => if (brace_depth == 0 and index + 3 < context.tokens.len and
                context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .equal)
            {
                const initializer = context.tokens[index + 3].tag;
                const names_type = initializer == .keyword_struct or initializer == .keyword_union or
                    initializer == .keyword_enum or initializer == .keyword_opaque or initializer == .keyword_error;
                if (names_type and (index == 0 or context.tokens[index - 1].tag != .keyword_pub)) {
                    try declarations.append(context.allocator, .{
                        .name = context.tokenText(index + 1),
                        .identifier_index = index + 1,
                        .error_set = initializer == .keyword_error,
                    });
                }
            },
            else => {},
        }
    }

    for (context.tokens, 0..) |token, pub_index| {
        if (token.tag != .keyword_pub or pub_index + 1 >= context.tokens.len) continue;
        var signature_start = pub_index + 1;
        if (context.tokens[signature_start].tag == .keyword_extern or context.tokens[signature_start].tag == .keyword_export) continue;
        while (signature_start < context.tokens.len and context.tokens[signature_start].tag != .keyword_fn and
            context.tokens[signature_start].tag != .keyword_const and context.tokens[signature_start].tag != .keyword_var) : (signature_start += 1)
        {}
        if (signature_start >= context.tokens.len) continue;
        const signature_end = nextTagBefore(context.tokens, signature_start + 1, .l_brace, .semicolon) orelse continue;
        for (declarations.items) |declaration| {
            const reference = findIdentifier(context, signature_start + 1, signature_end, declaration.name) orelse continue;
            const rule: types.Rule = if (declaration.error_set) .exposed_private_error_set else .exposed_private_type;
            const level = if (declaration.error_set) error_level else type_level;
            if (level == .off) continue;
            try context.emit(.{
                .rule = rule,
                .level = level,
                .span = context.tokens[reference].loc,
                .message = try std.fmt.allocPrint(
                    context.allocator,
                    "public declaration exposes private {s} '{s}', which callers cannot name",
                    .{ if (declaration.error_set) "error set" else "type", declaration.name },
                ),
                .related = try relatedDeclaration(context, declaration),
            });
        }
    }
}

fn relatedDeclaration(context: RuleRun, declaration: PrivateDeclaration) ![]const types.RelatedSpan {
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{
        .span = context.tokens[declaration.identifier_index].loc,
        .message = "private declaration is defined here",
    };
    return related;
}

const DeprecatedDeclaration = struct {
    name: []const u8,
    declaration_index: usize,
    advice: []const u8,
};

fn findDeprecatedReferences(context: RuleRun) !void {
    const level = context.level(.deprecated_declaration);
    if (level == .off) return;
    var declarations: std.ArrayList(DeprecatedDeclaration) = .empty;
    for (context.tokens, 0..) |token, doc_index| {
        if (token.tag != .doc_comment and token.tag != .container_doc_comment) continue;
        const comment = std.mem.trim(u8, context.tokenText(doc_index), "/!< \t\r\n");
        if (!startsWithIgnoreCase(comment, "Deprecated:")) continue;
        var declaration_index = doc_index + 1;
        while (declaration_index < context.tokens.len and
            (context.tokens[declaration_index].tag == .doc_comment or context.tokens[declaration_index].tag == .container_doc_comment or
                context.tokens[declaration_index].tag == .keyword_pub or context.tokens[declaration_index].tag == .keyword_export or
                context.tokens[declaration_index].tag == .keyword_extern)) : (declaration_index += 1)
        {}
        if (declaration_index + 1 >= context.tokens.len) continue;
        if (context.tokens[declaration_index].tag != .keyword_fn and context.tokens[declaration_index].tag != .keyword_const and
            context.tokens[declaration_index].tag != .keyword_var) continue;
        if (context.tokens[declaration_index + 1].tag != .identifier) continue;
        try declarations.append(context.allocator, .{
            .name = context.tokenText(declaration_index + 1),
            .declaration_index = declaration_index + 1,
            .advice = std.mem.trim(u8, comment["Deprecated:".len..], " \t\r\n"),
        });
    }
    for (declarations.items) |declaration| {
        if (identifierDeclarationCount(context, declaration.name) != 1) continue;
        for (context.tokens, 0..) |token, index| {
            if (token.tag != .identifier or index == declaration.declaration_index or
                !context.tokenIs(index, declaration.name)) continue;
            try context.emit(.{
                .rule = .deprecated_declaration,
                .level = level,
                .span = token.loc,
                .message = if (declaration.advice.len == 0)
                    try std.fmt.allocPrint(context.allocator, "declaration '{s}' is deprecated", .{declaration.name})
                else
                    try std.fmt.allocPrint(context.allocator, "declaration '{s}' is deprecated: {s}", .{ declaration.name, declaration.advice }),
            });
        }
    }
}

fn findMutatedContainerCopies(context: RuleRun) !void {
    const level = context.level(.mutated_container_copy);
    if (level == .off) return;
    for (context.tokens, 0..) |token, var_index| {
        if (token.tag != .keyword_var or var_index + 5 >= context.tokens.len or
            context.tokens[var_index + 1].tag != .identifier) continue;
        const equal = nextTagBefore(context.tokens, var_index + 2, .equal, .semicolon) orelse continue;
        if (equal + 3 >= context.tokens.len or context.tokens[equal + 1].tag != .identifier or
            context.tokens[equal + 2].tag != .period or context.tokens[equal + 3].tag != .identifier) continue;
        const end = context.enclosingScopeEnd(var_index) orelse continue;
        const copy_name = context.tokenText(var_index + 1);
        const original = context.source[context.tokens[equal + 1].loc.start..context.tokens[equal + 3].loc.end];
        if (copyIsReturnedOrWrittenBack(context, equal + 4, end, copy_name, original)) continue;
        const mutation = mutatingCall(context, equal + 4, end, copy_name) orelse continue;
        try context.emit(.{
            .rule = .mutated_container_copy,
            .level = level,
            .span = context.tokens[mutation].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "mutation of container copy '{s}' is not written back; original '{s}' will not observe length or allocation changes",
                .{ copy_name, original },
            ),
        });
    }
}

fn mutatingCall(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
    const methods = [_][]const u8{ "append", "appendSlice", "insert", "addOne", "ensureTotalCapacity", "resize", "clearAndFree", "pop" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index + 3 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier or
            context.tokens[index + 3].tag != .l_paren) continue;
        for (methods) |method| if (context.tokenIs(index + 2, method)) return index;
    }
    return null;
}

fn copyIsReturnedOrWrittenBack(context: RuleRun, start: usize, end: usize, name: []const u8, original: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return and index + 1 < end and context.tokenIs(index + 1, name)) return true;
        if (token.tag != .identifier or !context.tokenIs(index, name) or index < 4) continue;
        if (context.tokens[index - 1].tag != .equal) continue;
        const assignment_start = context.source[context.tokens[index - 4].loc.start..context.tokens[index - 2].loc.end];
        if (std.mem.eql(u8, assignment_start, original)) return true;
    }
    return false;
}

fn isExported(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 4) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_export or context.tokens[cursor].tag == .keyword_extern) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
    }
    return false;
}

fn identifierDeclarationCount(context: RuleRun, name: []const u8) usize {
    var count: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index == 0) continue;
        switch (context.tokens[index - 1].tag) {
            .keyword_fn, .keyword_const, .keyword_var => count += 1,
            else => {},
        }
    }
    return count;
}

fn findIdentifier(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return index;
    }
    return null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (value[0..prefix.len], prefix) |actual, expected| {
        if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
    }
    return true;
}

fn nextTag(tokens: []const std.zig.Token, start: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn nextTagBefore(tokens: []const std.zig.Token, start: usize, wanted: std.zig.Token.Tag, stop: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| {
        if (token.tag == stop) return null;
        if (token.tag == wanted) return index;
    }
    return null;
}

fn firstTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

test "compiler hygiene rules report only locally proven contracts and ownership mistakes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Secret = struct {};\n" ++
        "const Failure = error{Bad};\n" ++
        "/// Deprecated: use current instead.\n" ++
        "const old = 1;\n" ++
        "fn flag() !bool { return true; }\n" ++
        "pub fn secret() Secret { return .{}; }\n" ++
        "pub fn fail() Failure!void { return error.Bad; }\n" ++
        "fn use(self: *State) void { _ = old; var copy = self.list; copy.append(1); }\n";
    const found = try findingsFor(arena.allocator(), source, types.Configuration.defaults());
    var seen = [_]bool{false} ** 5;
    for (found) |finding| switch (finding.rule) {
        .useless_error_return => seen[0] = true,
        .exposed_private_type => seen[1] = true,
        .exposed_private_error_set => seen[2] = true,
        .deprecated_declaration => seen[3] = true,
        .mutated_container_copy => seen[4] = true,
        else => {},
    };
    for (seen) |value| try std.testing.expect(value);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, configuration: types.Configuration) ![]const types.Finding {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    return try found.toOwnedSlice(allocator);
}
