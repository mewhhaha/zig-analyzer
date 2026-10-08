//! Regenerates `docs/rules` from the rule catalog: `zig build rule-docs`.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    try zig_analyzer.rule_docs.sync(threaded.io(), allocator, std.Io.Dir.cwd(), .write);
}
