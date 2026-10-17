//! `@Type` calls, which Zig 0.16 replaced with one type-creating builtin per kind.
const std = @import("std");
const Ast = std.zig.Ast;
const containsComment = @import("../../syntax/tokens.zig").containsComment;
const identifierName = @import("../../syntax/tokens.zig").identifierName;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .modernize_reify_type,
};

/// The replacement for each `std.lang.Type` tag `@Type` reified. Signatures are
/// Zig 0.17's (`lib/std/zig/BuiltinFn.zig` and the language reference).
const replacements = [_]struct { tag: []const u8, advice: []const u8 }{
    .{ .tag = "int", .advice = "@Int(signedness, bits)" },
    .{ .tag = "struct", .advice = "@Struct(layout, BackingInt, field_names, field_types, field_attrs), or @Tuple(field_types) for a tuple" },
    .{ .tag = "union", .advice = "@Union(layout, ArgType, field_names, field_types, field_attrs)" },
    .{ .tag = "enum", .advice = "@Enum(TagInt, mode, field_names, field_values)" },
    .{ .tag = "pointer", .advice = "@Pointer(size, attrs, Element, sentinel)" },
    .{ .tag = "fn", .advice = "@Fn(param_types, param_attrs, ReturnType, attrs)" },
    .{ .tag = "enum_literal", .advice = "@EnumLiteral()" },
    .{ .tag = "vector", .advice = "@Vector(len, Element)" },
    .{ .tag = "float", .advice = "std.meta.Float(bits) or the float type itself" },
    .{ .tag = "array", .advice = "array type syntax, [len]Element or [len:sentinel]Element" },
    .{ .tag = "optional", .advice = "optional type syntax, ?T" },
    .{ .tag = "error_union", .advice = "error union type syntax, E!T" },
    .{ .tag = "error_set", .advice = "an error{...} declaration, since error sets can no longer be reified" },
    .{ .tag = "opaque", .advice = "an opaque {} declaration" },
};

/// Payload-free tags that name a primitive type, which replaces the call.
const primitives = [_][]const u8{ "type", "void", "bool", "noreturn", "comptime_int", "comptime_float" };

pub fn run(context: RuleRun) !void {
    const level = context.level(.modernize_reify_type);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        var buffer: [2]Ast.Node.Index = undefined;
        const parameters = tree.builtinCallParams(&buffer, node) orelse continue;
        const builtin = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(builtin), "@Type") or parameters.len != 1) continue;
        try report(context, level, node, parameters[0]);
    }
}

fn report(context: RuleRun, level: types.Level, call: Ast.Node.Index, argument: Ast.Node.Index) !void {
    const tree = context.tree;
    const builtin = tree.nodeMainToken(call);
    const call_span: std.zig.Token.Loc = .{
        .start = context.tokens[builtin].loc.start,
        .end = context.tokens[tree.lastToken(call)].loc.end,
    };
    var replacement: ?[]const u8 = null;
    var advice: []const u8 = "@Int, @Struct, @Tuple, @Union, @Enum, @Pointer, @Fn, @EnumLiteral, @Vector or type syntax for the kind it builds";
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.nodeTag(argument) == .enum_literal) {
        // `@Type(.enum_literal)`, `@Type(.bool)`
        const tag = identifierName(tree.tokenSlice(tree.nodeMainToken(argument)));
        if (std.mem.eql(u8, tag, "enum_literal")) {
            replacement = "@EnumLiteral()";
            advice = "@EnumLiteral()";
        } else for (primitives) |primitive| {
            if (!std.mem.eql(u8, tag, primitive)) continue;
            replacement = primitive;
            advice = primitive;
        }
    } else if (tree.fullStructInit(&buffer, argument)) |initializer| {
        // `@Type(.{ .int = .{ .signedness = .unsigned, .bits = 8 } })`
        if (initializer.ast.type_expr == .none and initializer.ast.fields.len == 1) {
            const payload = initializer.ast.fields[0];
            const tag = identifierName(tree.tokenSlice(tree.firstToken(payload) - 2));
            for (replacements) |entry| if (std.mem.eql(u8, entry.tag, tag)) {
                advice = entry.advice;
            };
            if (std.mem.eql(u8, tag, "int")) replacement = try intReplacement(context, payload);
        }
    }
    // The rewrite replaces the whole call, so a comment inside it declines the fix.
    if (containsComment(context.source[call_span.start..call_span.end])) replacement = null;
    const fixes: []const types.Fix = if (replacement) |text| try context.singleFix(.{
        .title = try context.allocator.print("Replace with {s}", .{text}),
        .span = call_span,
        .replacement = text,
        .preferred = true,
        .fix_all = true,
    }) else &.{};
    try context.emit(.{
        .rule = .modernize_reify_type,
        .level = level,
        .span = context.tokens[builtin].loc,
        .message = try context.allocator.print("@Type was removed in Zig 0.16; use {s}", .{advice}),
        .fixes = fixes,
    });
}

/// `@Int(signedness, bits)` for an `.{ .signedness = s, .bits = b }` payload in
/// either order, keeping each expression as written; null for another shape.
fn intReplacement(context: RuleRun, payload: Ast.Node.Index) !?[]const u8 {
    const tree = context.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const initializer = tree.fullStructInit(&buffer, payload) orelse return null;
    if (initializer.ast.type_expr != .none or initializer.ast.fields.len != 2) return null;
    var signedness: ?[]const u8 = null;
    var bits: ?[]const u8 = null;
    for (initializer.ast.fields) |field| {
        const first = tree.firstToken(field);
        const text = context.source[context.tokens[first].loc.start..context.tokens[tree.lastToken(field)].loc.end];
        const name = tree.tokenSlice(first - 2);
        if (std.mem.eql(u8, name, "signedness")) signedness = text else if (std.mem.eql(u8, name, "bits")) bits = text else return null;
    }
    return try context.allocator.print("@Int({s}, {s})", .{ signedness orelse return null, bits orelse return null });
}

test "reify type rewrites integers enum literals and primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const U8 = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 8 } });
        \\const Wide = @Type(.{ .int = .{ .bits = 2 * width, .signedness = signedness } });
        \\const Literal = @Type(.enum_literal);
        \\const Boolean = @Type(.bool);
        \\const width = 16;
        \\const signedness = .signed;
    ;
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    const expected = [_][]const u8{ "@Int(.unsigned, 8)", "@Int(signedness, 2 * width)", "@EnumLiteral()", "bool" };
    for (findings, expected) |finding, replacement| {
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(finding.fixes[0].fix_all);
        try std.testing.expectEqualStrings(replacement, finding.fixes[0].edits[0].replacement);
    }
    try std.testing.expectEqualStrings("@Type was removed in Zig 0.16; use @Int(signedness, bits)", findings[0].message);
}

test "reify type names the replacement builtin for other kinds without a fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const S = @Type(.{ .@"struct" = .{ .layout = .auto, .fields = &.{}, .decls = &.{}, .is_tuple = false } });
        \\const P = @Type(.{ .pointer = info });
        \\const A = @Type(.{ .array = .{ .len = 4, .child = u8, .sentinel_ptr = null } });
        \\const Commented = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 8 } // keep
        \\});
        \\const Generic = @Type(info);
        \\const Current = @Int(.unsigned, 8);
    ;
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[0].message, 1, "@Struct(layout, BackingInt"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[1].message, 1, "@Pointer(size, attrs, Element, sentinel)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[2].message, 1, "[len]Element"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[3].message, 1, "@Int(signedness, bits)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[4].message, 1, "@EnumLiteral"));
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.modernize_reify_type}, .warning));
}
