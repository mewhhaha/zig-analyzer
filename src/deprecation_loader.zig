const std = @import("std");
const declarations = @import("rules/deprecated_declarations.zig");
const zig_environment = @import("zig_environment.zig");

/// A request owns this loader. Zig's library path is discovered at most once,
/// and missing toolchains do not prevent local or relative-import diagnostics.
pub const Context = struct {
    io: std.Io,
    std_directory: ?[]const u8 = null,
    owns_directory: bool = false,
    directory_attempted: bool = false,

    pub fn deinit(context: *Context, allocator: std.mem.Allocator) void {
        if (context.owns_directory) allocator.free(context.std_directory.?);
    }

    pub fn loader(context: *Context) declarations.Loader {
        return .{ .context = context, .resolve = resolve, .load = load };
    }

    fn resolve(raw_context: *anyopaque, allocator: std.mem.Allocator, current: []const u8, spelling: []const u8) !?[]const u8 {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        if (std.mem.eql(u8, spelling, "std")) {
            if (context.std_directory == null and !context.directory_attempted) {
                context.directory_attempted = true;
                context.std_directory = zig_environment.libDirectory(context.io, allocator) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => return err,
                    else => return null,
                };
                context.owns_directory = true;
            }
            const directory = context.std_directory orelse return null;
            return try std.Io.Dir.path.join(allocator, &.{ directory, "std", "std.zig" });
        }
        if (std.mem.endsWith(u8, spelling, ".zig")) {
            if (std.Io.Dir.path.isAbsolute(spelling)) return null;
            return try std.Io.Dir.path.resolveAlloc(allocator, &.{ std.Io.Dir.path.dirname(current) orelse ".", spelling });
        }
        // A textual addModule call does not prove this compilation's import map.
        // Named build modules require resolved compilation bindings.
        return null;
    }

    fn load(raw_context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !?declarations.Source {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        const bytes = std.Io.Dir.cwd().readFileAlloc(context.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return null,
        };
        defer allocator.free(bytes);
        return .{ .path = path, .source = try allocator.dupeSentinel(u8, bytes, 0), .owned_source = true };
    }
};
