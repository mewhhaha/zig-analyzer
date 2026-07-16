const std = @import("std");
const analysis = @import("../analysis.zig");
const action_context = @import("context.zig");

pub const Candidate = action_context.Candidate;

const action_modules = .{
    @import("expression.zig"),
    @import("ownership.zig"),
    @import("language.zig"),
    @import("testing.zig"),
};

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
    inline for (action_modules) |action_module| try action_module.run(context);
    return try candidates.toOwnedSlice(allocator);
}

test {
    _ = action_modules;
}
