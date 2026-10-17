//! Diagnostics of edited documents, published once the editor pauses. An
//! editor sends an edit per keystroke, faster than a large file lints, so
//! with deferral on `didChange` only applies the text and records that the
//! document's diagnostics are out of date. `Reader` sits between the
//! transport and the dispatcher: it parses edited documents before any
//! message other than another edit, so every request sees the latest text,
//! and once the client has been quiet for `quiet_ms` it publishes the
//! outstanding diagnostics. A burst of edits is parsed and linted once, for
//! its last version.
const std = @import("std");
const lsp = @import("lsp");

const Server = @import("server.zig").Server;

/// Quiet time after the last message before deferred diagnostics publish.
pub const default_quiet_ms: u32 = 200;
/// Longest a deferred diagnostic waits for the client to pause.
pub const default_max_delay_ms: u32 = 1000;

pub const Options = struct {
    /// How long the client must be quiet before outstanding diagnostics are
    /// published. 0 lints every edit before the next message is read.
    quiet_ms: u32 = 0,
    /// Publish anyway once the oldest outstanding edit is this old, so a
    /// client that never pauses still sees diagnostics; null waits for a pause.
    max_delay_ms: ?u32 = null,
    /// Tells when the client has sent more; there is no deferral without it.
    input: ?Input = null,

    pub fn defers(options: Options) bool {
        return options.quiet_ms != 0 and options.input != null;
    }
};

/// Whether the client has sent input the server has not read yet.
pub const Input = struct {
    context: *anyopaque,
    waitFn: *const fn (context: *anyopaque, io: std.Io, timeout: std.Io.Duration) bool,

    /// Whether input arrives within `timeout`; true at once when some waits.
    pub fn wait(input: Input, io: std.Io, timeout: std.Io.Duration) bool {
        return input.waitFn(input.context, io, timeout);
    }

    /// The input of `transport`: bytes it has buffered, else bytes arriving
    /// on its file within the timeout, which are read into its buffer.
    pub fn stdio(transport: *lsp.Transport.Stdio) Input {
        return .{ .context = transport, .waitFn = waitStdio };
    }

    fn waitStdio(context: *anyopaque, io: std.Io, timeout: std.Io.Duration) bool {
        const transport: *lsp.Transport.Stdio = @ptrCast(@alignCast(context));
        const reader = &transport.reader;
        if (reader.end > reader.seek) return true;
        reader.seek = 0;
        reader.end = 0;
        const result = io.operateTimeout(.{ .file_read_streaming = .{
            .file = transport.read_from,
            .data = &.{reader.buffer},
        } }, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch |err| switch (err) {
            // Quiet; or no timed read on this platform, so publish before
            // every blocking read as without deferral.
            error.Timeout, error.ConcurrencyUnavailable, error.Canceled => return false,
        };
        // End of input or a failure: the next read reports it.
        reader.end = result.file_read_streaming catch return true;
        return reader.end != 0;
    }
};

/// The documents whose published diagnostics predate their text.
pub const Pending = struct {
    /// Owned URIs, oldest edit first.
    uris: std.array_hash_map.String(void) = .empty,
    /// When the oldest of them was edited.
    since: std.Io.Timestamp = .zero,

    pub fn deinit(pending: *Pending, allocator: std.mem.Allocator) void {
        for (pending.uris.keys()) |uri| allocator.free(uri);
        pending.uris.deinit(allocator);
        pending.* = undefined;
    }

    pub fn add(pending: *Pending, allocator: std.mem.Allocator, io: std.Io, uri: []const u8) !void {
        if (pending.uris.contains(uri)) return;
        const owned = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned);
        if (pending.uris.count() == 0) pending.since = .now(io, .awake);
        try pending.uris.put(allocator, owned, {});
    }

    /// Forgets `uri`: it was published or closed some other way.
    pub fn remove(pending: *Pending, allocator: std.mem.Allocator, uri: []const u8) void {
        const removed = pending.uris.fetchOrderedRemove(uri) orelse return;
        allocator.free(removed.key);
    }

    /// How long to wait for the client to pause before publishing, or null
    /// to publish now because the oldest edit waited `max_delay_ms` already.
    fn patience(pending: *const Pending, io: std.Io, options: Options) ?std.Io.Duration {
        const quiet: std.Io.Duration = .fromMilliseconds(options.quiet_ms);
        const max_delay_ms = options.max_delay_ms orelse return quiet;
        const waited = pending.since.durationTo(.now(io, .awake));
        const left = std.Io.Duration.fromMilliseconds(max_delay_ms).nanoseconds - waited.nanoseconds;
        if (left <= 0) return null;
        return .fromNanoseconds(@min(left, quiet.nanoseconds));
    }
};

/// The transport the dispatcher reads from: `child`, doing the deferred work
/// between messages. Must not move after `init`.
pub const Reader = struct {
    transport: lsp.Transport,
    child: *lsp.Transport,
    server: *Server,

    pub fn init(child: *lsp.Transport, server: *Server) Reader {
        return .{
            .transport = .{ .vtable = &.{
                .readJsonMessage = readJsonMessage,
                .writeJsonMessage = writeJsonMessage,
            } },
            .child = child,
            .server = server,
        };
    }

    fn readJsonMessage(transport: *lsp.Transport, io: std.Io, allocator: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        const reader: *Reader = @fieldParentPtr("transport", transport);
        const server = reader.server;
        const options = server.diagnostics_options;
        while (server.deferred.uris.count() != 0) {
            if (server.deferred.patience(io, options)) |timeout| {
                if (options.input.?.wait(io, timeout)) break;
            }
            server.publishDeferredDiagnostics() catch |err| std.log.err("could not publish deferred diagnostics: {t}", .{err});
        }
        const message = try reader.child.readJsonMessage(io, allocator);
        errdefer allocator.free(message);
        if (!isDocumentEdit(allocator, message)) try server.documents.refresh();
        return message;
    }

    fn writeJsonMessage(transport: *lsp.Transport, io: std.Io, message: []const u8) lsp.Transport.WriteError!void {
        const reader: *Reader = @fieldParentPtr("transport", transport);
        return reader.child.writeJsonMessage(io, message);
    }
};

/// Whether `message` is a `textDocument/didChange` notification, judged by its
/// top-level `method` without decoding the rest. Anything unexpected counts
/// as no edit, which only costs an earlier parse.
fn isDocumentEdit(allocator: std.mem.Allocator, message: []const u8) bool {
    var scanner: std.json.Scanner = .initCompleteInput(allocator, message);
    defer scanner.deinit();
    if ((scanner.next() catch return false) != .object_begin) return false;
    while (true) {
        const key = switch (scanner.next() catch return false) {
            .string => |key| key,
            else => return false,
        };
        if (!std.mem.eql(u8, key, "method")) {
            scanner.skipValue() catch return false;
            continue;
        }
        return switch (scanner.next() catch return false) {
            .string => |method| std.mem.eql(u8, method, "textDocument/didChange"),
            else => false,
        };
    }
}

test "edits are told apart by their method wherever it appears" {
    const allocator = std.testing.allocator;
    try std.testing.expect(isDocumentEdit(allocator,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{}}
    ));
    try std.testing.expect(isDocumentEdit(allocator,
        \\{"params":{"contentChanges":[{"text":"\"method\":\"x\""}]}, "method" : "textDocument/didChange"}
    ));
    try std.testing.expect(!isDocumentEdit(allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"text":"textDocument/didChange"}}
    ));
    try std.testing.expect(!isDocumentEdit(allocator, "[]"));
    try std.testing.expect(!isDocumentEdit(allocator, "{\"method\":"));
}

test "pending documents wait for a pause but no longer than the delay cap" {
    const io = std.testing.io;
    var pending: Pending = .{};
    defer pending.deinit(std.testing.allocator);
    try pending.add(std.testing.allocator, io, "file:///a.zig");
    try pending.add(std.testing.allocator, io, "file:///a.zig");
    try std.testing.expectEqual(@as(usize, 1), pending.uris.count());
    const waiting = pending.patience(io, .{ .quiet_ms = 50, .max_delay_ms = 60_000 }).?;
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(50).nanoseconds, waiting.nanoseconds);
    pending.since = .zero;
    try std.testing.expectEqual(@as(?std.Io.Duration, null), pending.patience(io, .{ .quiet_ms = 50, .max_delay_ms = 1 }));
    pending.remove(std.testing.allocator, "file:///a.zig");
    try std.testing.expectEqual(@as(usize, 0), pending.uris.count());
}
