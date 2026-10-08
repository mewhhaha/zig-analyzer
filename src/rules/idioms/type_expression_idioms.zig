//! Type expressions that repeat what the result location already establishes, and initializers that restate their result type.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .redundant_type_qualification,
    .prefer_anonymous_initializer,
};

pub fn run(context: RuleRun) !void {
    try findTypeExpressionIdioms(context);
}

fn findTypeExpressionIdioms(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const qualification_level = context.level(.redundant_type_qualification);
    const initializer_level = context.level(.prefer_anonymous_initializer);
    if (qualification_level == .off and initializer_level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .colon or
            tokens[declaration_index + 3].tag != .identifier or tokens[declaration_index + 4].tag != .equal or
            tokens[declaration_index + 5].tag != .identifier or
            !tokenIs(source, tokens[declaration_index + 3], tokenText(source, tokens[declaration_index + 5]))) continue;
        const type_name = tokenText(source, tokens[declaration_index + 3]);
        if (qualification_level != .off and declaration_index + 7 < tokens.len and
            tokens[declaration_index + 6].tag == .period and tokens[declaration_index + 7].tag == .identifier)
        {
            const fixes = try Fix.single(context.allocator, .{
                .title = "Use inferred enum literal",
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 7].loc.end },
                .replacement = try context.allocator.print(".{s}", .{tokenText(source, tokens[declaration_index + 7])}),
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .redundant_type_qualification,
                .level = qualification_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try context.allocator.print("type '{s}' is already established by the result location", .{type_name}),
                .fixes = fixes,
            });
        } else if (initializer_level != .off and tokens[declaration_index + 6].tag == .l_brace) {
            const fixes = try Fix.single(context.allocator, .{
                .title = "Use an anonymous initializer",
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 6].loc.end },
                .replacement = ".{",
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .prefer_anonymous_initializer,
                .level = initializer_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try context.allocator.print("initializer repeats result type '{s}'", .{type_name}),
                .fixes = fixes,
            });
        }
    }
}

test "qualification and initializers repeating the result type are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32 };\n" ++
        "fn inspect(pointer: *u32) void {\n" ++
        "    const mode: Mode = Mode.fast;\n" ++
        "    const options: Options = Options{ .count = pointer.* };\n" ++
        "    _ = mode; _ = options;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .redundant_type_qualification, .prefer_anonymous_initializer }, .information));
    try support.expectRules(found, &.{ .redundant_type_qualification, .prefer_anonymous_initializer });
}
