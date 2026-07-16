const std = @import("std");
const analysis = @import("../analysis.zig");
const action_context = @import("context.zig");
const expression = @import("expression.zig");
const language = @import("language.zig");
const ownership = @import("ownership.zig");
const testing = @import("testing.zig");

pub const Candidate = action_context.Candidate;

pub fn actions(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    selection: std.zig.Token.Loc,
    shapes: []const analysis.ResolvedShape,
) ![]const Candidate {
    const tokens = try action_context.tokenize(allocator, source);
    var candidates: std.ArrayList(Candidate) = .empty;
    const context: action_context.ActionRun = .{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .selection = selection,
        .shapes = shapes,
        .candidates = &candidates,
    };
    try expression.run(context);
    try ownership.run(context);
    try language.run(context);
    try testing.run(context);
    return try candidates.toOwnedSlice(allocator);
}

test {
    _ = expression;
    _ = language;
    _ = ownership;
    _ = testing;
}
