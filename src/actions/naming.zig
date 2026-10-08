//! Name-level rewrites: the identifier a style finding should be renamed to,
//! and the places besides identifier tokens that spell a field name.
const std = @import("std");

const analysis = @import("../analysis.zig");
const tokens_util = @import("../syntax/tokens.zig");
const syntax_types = @import("../syntax/types.zig");
const tokenize = tokens_util.tokenize;
const matchingSyntaxToken = tokens_util.matchingToken;
const isIdentifier = syntax_types.isIdentifier;

pub fn isContainerField(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    span: std.zig.Token.Loc,
) !bool {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const index = for (tokens, 0..) |token, token_index| {
        if (std.meta.eql(token.loc, span)) break token_index;
    } else return false;
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .colon) return false;
    var cursor = index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        if (cursor == 0) return false;
        const container_token = tokens[cursor - 1];
        if (container_token.tag == .keyword_struct or
            container_token.tag == .keyword_enum or
            container_token.tag == .keyword_union) return true;
        if (container_token.tag != .r_paren) return false;
        const parameters_start = tokens_util.matchingOpeningToken(tokens, cursor - 1, .l_paren, .r_paren) orelse return false;
        return parameters_start > 0 and tokens[parameters_start - 1].tag == .keyword_union;
    }
    return false;
}

pub fn reflectionStringSpans(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
) ![]const std.zig.Token.Loc {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or
            (!std.mem.eql(u8, source[token.loc.start..token.loc.end], "@field") and
                !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@hasField") and
                !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@hasDecl"))) continue;
        if (index + 5 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        const closing = matchingSyntaxToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        var comma = index + 2;
        while (comma < closing and tokens[comma].tag != .comma) : (comma += 1) {}
        if (comma + 1 >= closing or tokens[comma + 1].tag != .string_literal) continue;
        const literal = source[tokens[comma + 1].loc.start..tokens[comma + 1].loc.end];
        if (literal.len < 2 or !std.mem.eql(u8, literal[1 .. literal.len - 1], name)) continue;
        try spans.append(allocator, .{
            .start = tokens[comma + 1].loc.start + 1,
            .end = tokens[comma + 1].loc.end - 1,
        });
    }
    return try spans.toOwnedSlice(allocator);
}

pub fn suggestedStyleName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
    rule: analysis.Rule,
) !?[]const u8 {
    const name = source[declaration_span.start..declaration_span.end];
    return switch (rule) {
        .non_idiomatic_name => try suggestedDeclarationName(allocator, source, declaration_span),
        .underscore_private_name => if (name.len > 1) try allocator.dupe(u8, name[1..]) else null,
        .redundant_qualified_name => try redundantQualifiedSuggestion(allocator, source, declaration_span),
        else => null,
    };
}

fn redundantQualifiedSuggestion(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
) !?[]const u8 {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    const declaration_index = for (tokens, 0..) |token, index| {
        if (std.meta.eql(token.loc, declaration_span)) break index;
    } else return null;
    var cursor = declaration_index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        if (cursor < 4 or tokens[cursor - 1].tag != .keyword_struct or tokens[cursor - 2].tag != .equal or
            tokens[cursor - 3].tag != .identifier or tokens[cursor - 4].tag != .keyword_const) return null;
        const namespace_name = source[tokens[cursor - 3].loc.start..tokens[cursor - 3].loc.end];
        const declaration_name = source[declaration_span.start..declaration_span.end];
        if (declaration_name.len <= namespace_name.len) return null;
        return try allocator.dupe(u8, declaration_name[namespace_name.len..]);
    }
    return null;
}

fn suggestedDeclarationName(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    declaration_span: std.zig.Token.Loc,
) !?[]const u8 {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    const index = for (tokens.items, 0..) |token, token_index| {
        if (std.meta.eql(token.loc, declaration_span)) break token_index;
    } else return null;
    if (index == 0) return null;
    const name = source[declaration_span.start..declaration_span.end];
    const convention: enum { camel, title, snake } = convention: {
        switch (tokens.items[index - 1].tag) {
            .keyword_fn => {
                if (index + 1 < tokens.items.len and tokens.items[index + 1].tag == .l_paren) {
                    const parameters_end = matchingSyntaxToken(tokens.items, index + 1, .l_paren, .r_paren) orelse break :convention .camel;
                    if (parameters_end + 1 < tokens.items.len and
                        std.mem.eql(u8, source[tokens.items[parameters_end + 1].loc.start..tokens.items[parameters_end + 1].loc.end], "type"))
                    {
                        break :convention .title;
                    }
                }
                break :convention .camel;
            },
            .keyword_const => {
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .builtin and tokens.items[index + 3].tag == .l_paren)
                {
                    const builtin_name = source[tokens.items[index + 2].loc.start..tokens.items[index + 2].loc.end];
                    const type_builtins = [_][]const u8{
                        "@TypeOf", "@Type", "@Int", "@Enum", "@Union", "@Struct", "@Pointer", "@Array", "@Vector", "@Fn", "@Tuple",
                    };
                    for (type_builtins) |type_builtin| {
                        if (std.mem.eql(u8, builtin_name, type_builtin)) break :convention .title;
                    }
                    if (std.mem.eql(u8, builtin_name, "@typeInfo")) {
                        var cursor = index + 3;
                        while (cursor < tokens.items.len and tokens.items[cursor].tag != .semicolon) : (cursor += 1) {
                            if (tokens.items[cursor].tag != .identifier or cursor == 0 or tokens.items[cursor - 1].tag != .period) continue;
                            const field_name = source[tokens.items[cursor].loc.start..tokens.items[cursor].loc.end];
                            const type_fields = [_][]const u8{ "child", "payload", "error_set", "return_type", "tag_type" };
                            for (type_fields) |type_field| {
                                if (std.mem.eql(u8, field_name, type_field)) break :convention .title;
                            }
                        }
                    }
                }
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    (tokens.items[index + 2].tag == .keyword_extern or tokens.items[index + 2].tag == .keyword_packed) and
                    switch (tokens.items[index + 3].tag) {
                        .keyword_struct, .keyword_union => true,
                        else => false,
                    }) break :convention .title;
                if (index + 3 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .keyword_struct and tokens.items[index + 3].tag == .l_brace)
                {
                    const closing = matchingSyntaxToken(tokens.items, index + 3, .l_brace, .r_brace) orelse break :convention .title;
                    var has_field = false;
                    for (tokens.items[index + 4 .. closing], index + 4..) |candidate, candidate_index| {
                        if (candidate.tag == .identifier and candidate_index + 1 < closing and
                            tokens.items[candidate_index + 1].tag == .colon)
                        {
                            has_field = true;
                            break;
                        }
                    }
                    break :convention if (has_field) .title else .snake;
                }
                if (index + 2 < tokens.items.len and tokens.items[index + 1].tag == .equal and switch (tokens.items[index + 2].tag) {
                    .keyword_union, .keyword_enum, .keyword_opaque => true,
                    else => false,
                }) break :convention .title;
                if (index + 2 < tokens.items.len and tokens.items[index + 1].tag == .equal and
                    tokens.items[index + 2].tag == .identifier)
                {
                    const target_name = source[tokens.items[index + 2].loc.start..tokens.items[index + 2].loc.end];
                    for (tokens.items, 0..) |candidate, candidate_index| {
                        if (candidate.tag != .identifier or candidate_index == 0 or candidate_index + 2 >= tokens.items.len or
                            tokens.items[candidate_index - 1].tag != .keyword_const or
                            !std.mem.eql(u8, source[candidate.loc.start..candidate.loc.end], target_name) or
                            tokens.items[candidate_index + 1].tag != .equal) continue;
                        if (switch (tokens.items[candidate_index + 2].tag) {
                            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => true,
                            else => false,
                        }) break :convention .title;
                    }
                }
                break :convention .snake;
            },
            .keyword_var => break :convention .snake,
            else => return null,
        }
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    switch (convention) {
        .camel => {
            var words = std.mem.splitScalar(u8, name, '_');
            var word_index: usize = 0;
            while (words.next()) |word| {
                if (word.len == 0) continue;
                if (word_index == 0) {
                    try writer.writer.writeAll(word);
                } else {
                    try writer.writer.writeByte(std.ascii.toUpper(word[0]));
                    try writer.writer.writeAll(word[1..]);
                }
                word_index += 1;
            }
        },
        .title => {
            var capitalize = true;
            for (name) |character| {
                if (character == '_') {
                    capitalize = true;
                    continue;
                }
                try writer.writer.writeByte(if (capitalize) std.ascii.toUpper(character) else character);
                capitalize = false;
            }
        },
        .snake => for (name, 0..) |character, character_index| {
            if (std.ascii.isUpper(character)) {
                if (character_index != 0) try writer.writer.writeByte('_');
                try writer.writer.writeByte(std.ascii.toLower(character));
            } else {
                try writer.writer.writeByte(character);
            }
        },
    }
    const suggestion = try writer.toOwnedSlice();
    if (suggestion.len == 0 or std.mem.eql(u8, suggestion, name) or !isIdentifier(suggestion)) return null;
    return suggestion;
}

test "reflection string spans participate in field rename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32 };\n" ++
        "fn inspect(state: State) void { _ = @field(state, \"value\"); _ = @hasField(State, \"value\"); }\n";
    const spans = try reflectionStringSpans(arena.allocator(), source, "value");
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    for (spans) |span| try std.testing.expectEqualStrings("value", source[span.start..span.end]);
}

test "field rename classification excludes typed locals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32 };\n" ++
        "const Event = union(enum) { ready: u32 };\n" ++
        "fn inspect() void { var local: u32 = 1; _ = local; }\n";
    const struct_field_start = std.mem.find(u8, source, "value: u32") orelse unreachable;
    const union_field_start = std.mem.find(u8, source, "ready: u32") orelse unreachable;
    const local_start = std.mem.find(u8, source, "local: u32") orelse unreachable;

    try std.testing.expect(try isContainerField(arena.allocator(), source, .{
        .start = struct_field_start,
        .end = struct_field_start + "value".len,
    }));
    try std.testing.expect(try isContainerField(arena.allocator(), source, .{
        .start = union_field_start,
        .end = union_field_start + "ready".len,
    }));
    try std.testing.expect(!try isContainerField(arena.allocator(), source, .{
        .start = local_start,
        .end = local_start + "local".len,
    }));
}

test "style rename preserves type-producing declaration semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const inferred_type = @TypeOf(1);\n" ++
        "const reflected_type = @typeInfo(@TypeOf(make)).@\"fn\".return_type.?;\n" ++
        "const external_state = extern struct { value: u32 };\n";
    const inferred_start = std.mem.find(u8, source, "inferred_type") orelse unreachable;
    const reflected_start = std.mem.find(u8, source, "reflected_type") orelse unreachable;
    const external_start = std.mem.find(u8, source, "external_state") orelse unreachable;

    const inferred_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = inferred_start,
        .end = inferred_start + "inferred_type".len,
    })).?;
    const external_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = external_start,
        .end = external_start + "external_state".len,
    })).?;
    const reflected_name = (try suggestedDeclarationName(arena.allocator(), source, .{
        .start = reflected_start,
        .end = reflected_start + "reflected_type".len,
    })).?;
    try std.testing.expectEqualStrings("InferredType", inferred_name);
    try std.testing.expectEqualStrings("ReflectedType", reflected_name);
    try std.testing.expectEqualStrings("ExternalState", external_name);
}
