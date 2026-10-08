//! Shared harness for the language-server exchange tests: a scripted
//! transport that records every message the server writes, and helpers that
//! drive the server through its public notification handlers.
const std = @import("std");
const lsp = @import("lsp");
const zig_analyzer = @import("zig_analyzer");

const Server = zig_analyzer.lsp.server.Server;

/// Feeds `incoming` to the server one message at a time and keeps what the
/// server writes, in order. Must not move after `init`.
pub const TestTransport = struct {
    transport: lsp.Transport,
    incoming: []const []const u8,
    incoming_index: usize = 0,
    mutex: std.Io.Mutex = .init,
    outputs: std.ArrayList([]u8) = .empty,
    /// How many messages the server has written.
    output_count: usize = 0,

    pub fn init(incoming: []const []const u8) TestTransport {
        return .{
            .transport = .{ .vtable = &.{
                .readJsonMessage = readJsonMessage,
                .writeJsonMessage = writeJsonMessage,
            } },
            .incoming = incoming,
        };
    }

    pub fn deinit(transport: *TestTransport) void {
        for (transport.outputs.items) |message| std.testing.allocator.free(message);
        transport.outputs.deinit(std.testing.allocator);
    }

    pub fn output(transport: *const TestTransport, index: usize) []const u8 {
        return transport.outputs.items[index];
    }

    /// Scripted messages name documents inside this checkout by a
    /// `file://examples/...` or `file://fixtures/...` placeholder; it becomes
    /// an absolute URI, so configuration lookup finds the checkout's
    /// `zig-analyzer.json` the way it would for a real project.
    const checkout_directories = [_][]const u8{ "examples", "fixtures" };

    fn readJsonMessage(
        transport: *lsp.Transport,
        _: std.Io,
        allocator: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        const test_transport: *TestTransport = @fieldParentPtr("transport", transport);
        if (test_transport.incoming_index == test_transport.incoming.len) return error.EndOfStream;
        var message = try allocator.dupe(u8, test_transport.incoming[test_transport.incoming_index]);
        errdefer allocator.free(message);
        test_transport.incoming_index += 1;
        inline for (checkout_directories) |directory| {
            const directory_uri = checkoutUri(allocator, directory) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("cannot resolve the {s} directory: {t}", .{ directory, err }),
            };
            defer allocator.free(directory_uri);
            const prefix = try std.mem.concat(allocator, u8, &.{ directory_uri, "/" });
            defer allocator.free(prefix);
            const replaced = try std.mem.replaceOwned(u8, allocator, message, "file://" ++ directory ++ "/", prefix);
            allocator.free(message);
            message = replaced;
        }
        return message;
    }

    fn writeJsonMessage(
        transport: *lsp.Transport,
        io: std.Io,
        message: []const u8,
    ) lsp.Transport.WriteError!void {
        const test_transport: *TestTransport = @fieldParentPtr("transport", transport);
        const copy = std.testing.allocator.dupe(u8, message) catch @panic("out of memory");
        test_transport.mutex.lockUncancelable(io);
        defer test_transport.mutex.unlock(io);
        test_transport.outputs.append(std.testing.allocator, copy) catch @panic("out of memory");
        test_transport.output_count = test_transport.outputs.items.len;
    }
};

/// URI of `relative`, a path inside this checkout (tests run at its root).
pub fn checkoutUri(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const working_directory = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(working_directory);
    const path = try std.Io.Dir.path.join(allocator, &.{ working_directory, relative });
    defer allocator.free(path);
    return zig_analyzer.uri.fromPath(allocator, path);
}

/// Opens `uri` with `text` through the notification handlers.
pub fn openDocument(server: *Server, arena: std.mem.Allocator, uri: []const u8, version: i32, text: []const u8) !void {
    try server.@"textDocument/didOpen"(arena, .{ .textDocument = .{ .uri = uri, .languageId = .{ .custom_value = "zig" }, .version = version, .text = text } });
}

/// Replaces the whole text of `uri` through the notification handlers.
pub fn replaceDocument(server: *Server, arena: std.mem.Allocator, uri: []const u8, version: i32, text: []const u8) !void {
    try server.@"textDocument/didChange"(arena, .{
        .textDocument = .{ .uri = uri, .version = version },
        .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = text } }},
    });
}

/// The last `publishDiagnostics` written for `uri`, or null.
pub fn lastPublished(transport: *const TestTransport, uri: []const u8) ?[]const u8 {
    var index = transport.output_count;
    while (index > 0) {
        index -= 1;
        const message = transport.output(index);
        if (std.mem.find(u8, message, "publishDiagnostics") == null) continue;
        if (std.mem.find(u8, message, uri) != null) return message;
    }
    return null;
}

/// Runs the scripted exchange in `transport` to its end.
pub fn run(server: *Server, transport: *TestTransport) !void {
    try zig_analyzer.lsp.server.runBasicServer(std.testing.io, std.testing.allocator, &transport.transport, server, null);
}
