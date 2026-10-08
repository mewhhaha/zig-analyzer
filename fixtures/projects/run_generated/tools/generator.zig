const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arguments = try init.args.iterateAllocator(allocator);
    _ = arguments.next();
    const output = arguments.next() orelse return error.MissingOutput;
    const marker = arguments.next() orelse return error.MissingMarker;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "ran\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "pub const value: u32 = 1;\n" });
}
