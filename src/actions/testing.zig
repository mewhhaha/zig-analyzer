const std = @import("std");
const action_context = @import("context.zig");

const ActionRun = action_context.ActionRun;

pub fn run(context: ActionRun) !void {
    const selected_index = action_context.selectedTokenIndex(context) orelse return;
    if (context.tokens[selected_index].tag != .identifier or selected_index == 0) return;
    if (!atTopLevel(context, selected_index)) return;
    const name = context.tokenText(selected_index);
    if (context.tokens[selected_index - 1].tag == .keyword_fn) {
        if (testNamed(context, name)) return;
        try context.oneEdit(
            try std.fmt.allocPrint(context.allocator, "Generate test for '{s}'", .{name}),
            .refactor_rewrite,
            .{ .start = context.source.len, .end = context.source.len },
            try std.fmt.allocPrint(context.allocator, "\n\ntest \"{s}\" {{\n    _ = {s};\n}}\n", .{ name, name }),
            false,
        );
        return;
    }
    if (context.tokens[selected_index - 1].tag != .keyword_const or !isContainerDeclaration(context, selected_index)) return;
    if (testNamed(context, name)) return;
    try context.oneEdit(
        try std.fmt.allocPrint(context.allocator, "Generate declaration smoke test for '{s}'", .{name}),
        .refactor_rewrite,
        .{ .start = context.source.len, .end = context.source.len },
        try std.fmt.allocPrint(
            context.allocator,
            "\n\ntest \"{s} declarations compile\" {{\n    @import(\"std\").testing.refAllDecls({s});\n}}\n",
            .{ name, name },
        ),
        false,
    );
}

fn atTopLevel(context: ActionRun, name_index: usize) bool {
    var depth: usize = 0;
    for (context.tokens[0..name_index]) |token| switch (token.tag) {
        .l_brace => depth += 1,
        .r_brace => depth -|= 1,
        else => {},
    };
    return depth == 0;
}

fn isContainerDeclaration(context: ActionRun, name_index: usize) bool {
    if (name_index + 2 >= context.tokens.len or context.tokens[name_index + 1].tag != .equal) return false;
    for (context.tokens[name_index + 2 .. @min(name_index + 8, context.tokens.len)]) |token| switch (token.tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return true,
        .semicolon => return false,
        else => {},
    };
    return context.shapeNamed(context.tokenText(name_index)) != null;
}

fn testNamed(context: ActionRun, name: []const u8) bool {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_test or index + 1 >= context.tokens.len or context.tokens[index + 1].tag != .string_literal) continue;
        const literal = context.tokenText(index + 1);
        if (std.mem.indexOf(u8, literal, name) != null) return true;
    }
    return false;
}

test "functions and containers get Zig test harnesses" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const function_source: [:0]const u8 = "fn parse() !void {}";
    const function_start = std.mem.indexOf(u8, function_source, "parse") orelse unreachable;
    const function_actions = try registry.actions(arena.allocator(), function_source, .{ .start = function_start, .end = function_start + 5 }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, function_actions[0].edits[0].replacement, "test \"parse\"") != null);

    const container_source: [:0]const u8 = "const Config = struct { value: u8 };";
    const container_start = std.mem.indexOf(u8, container_source, "Config") orelse unreachable;
    const container_actions = try registry.actions(arena.allocator(), container_source, .{ .start = container_start, .end = container_start + 6 }, &.{});
    try std.testing.expect(std.mem.indexOf(u8, container_actions[0].edits[0].replacement, "refAllDecls") != null);
}

test "nested declarations get no file-scope test harness" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const S = struct { fn parse() void {} };";
    const start = std.mem.indexOf(u8, source, "parse") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}
