//! The patched compiler as a child process: spawning it, learning the port it
//! listens on, draining its output pipes, driving incremental updates over its
//! stdin, and stopping it. The wire protocol on that port belongs to
//! `compiler_client.zig`; this module never speaks it.
const std = @import("std");
const backend_bootstrap = @import("bootstrap.zig");
const build_graph = @import("build_graph.zig");
const protocol = @import("protocol.zig");

/// How long the analyzer waits on the backend before declaring it hung:
/// startup, incremental updates, protocol responses, and process exit.
pub const default_deadline_ms: i64 = 60_000;

/// Bytes of backend stderr kept for failure diagnostics.
const stderr_tail_capacity = 8 * 1024;

const DrainResult = anyerror!void;

pub const StartOptions = struct {
    backend_binary: []const u8,
    /// What to analyze: the compile unit's command and module arguments.
    launch: build_graph.Launch,
    /// Absolute directory that owns the analysis caches (`.zig-analyzer/...`).
    cache_root: []const u8,
    zig_lib_directory: []const u8,
};

pub const Process = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    shared: *Shared,
    stdout_future: std.Io.Future(DrainResult),
    stderr_future: std.Io.Future(DrainResult),
    exit_deadline_ms: i64 = default_deadline_ms,
    /// TCP port of the protocol listener once `awaitPort` succeeded.
    port: u16 = 0,
    authentication_token: [token_hex_length]u8,

    const token_hex_length = 32;

    /// Spawns the backend on the compile unit `options.launch` describes
    /// and starts its first incremental update. The protocol port is not known
    /// until `awaitPort` returns.
    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        options: StartOptions,
    ) !Process {
        var token_bytes: [token_hex_length / 2]u8 = undefined;
        try io.randomSecure(&token_bytes);
        const authentication_token = std.fmt.bytesToHex(token_bytes, .lower);

        var environ_map = try std.process.Environ.createMap(environ, allocator);
        defer environ_map.deinit();
        // Port 0: the backend binds a free port and announces it on stderr.
        try environ_map.put("ZIG_ANALYZER_PORT", "0");
        try environ_map.put("ZIG_ANALYZER_TOKEN", &authentication_token);

        const analysis_cache = try std.Io.Dir.path.join(allocator, &.{ options.cache_root, backend_bootstrap.analysis_cache_directory });
        defer allocator.free(analysis_cache);
        const global_cache = try std.Io.Dir.path.join(allocator, &.{ options.cache_root, backend_bootstrap.global_cache_directory });
        defer allocator.free(global_cache);
        try std.Io.Dir.cwd().createDirPath(io, analysis_cache);
        try std.Io.Dir.cwd().createDirPath(io, global_cache);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ options.backend_binary, options.launch.command });
        try argv.appendSlice(allocator, options.launch.arguments);
        try argv.appendSlice(allocator, &.{
            "--zig-lib-dir",
            options.zig_lib_directory,
            "-fincremental",
            "--debug-incremental",
            "-fno-emit-bin",
            "--cache-dir",
            analysis_cache,
            "--global-cache-dir",
            global_cache,
            "--listen=-",
        });
        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        var process = try adopt(io, allocator, child, authentication_token);
        errdefer process.stop();
        try process.sendUpdate();
        return process;
    }

    /// Takes ownership of an already spawned `child` (stdin, stdout and stderr
    /// piped) and starts draining its output.
    pub fn adopt(
        io: std.Io,
        allocator: std.mem.Allocator,
        spawned: std.process.Child,
        authentication_token: [token_hex_length]u8,
    ) !Process {
        var child = spawned;
        errdefer child.kill(io);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{};
        var stdout_future = try io.concurrent(drainStdout, .{ io, child.stdout.?, shared });
        errdefer stdout_future.cancel(io) catch |err| std.log.warn("failed to cancel compiler output reader: {t}", .{err});
        const stderr_future = try io.concurrent(drainStderr, .{ io, child.stderr.?, shared });
        return .{
            .io = io,
            .allocator = allocator,
            .child = child,
            .shared = shared,
            .stdout_future = stdout_future,
            .stderr_future = stderr_future,
            .authentication_token = authentication_token,
        };
    }

    /// Waits for the backend to announce its protocol port. If the backend
    /// exits or stays silent instead, the failure is logged together with
    /// whatever it wrote to stderr.
    pub fn awaitPort(process: *Process, deadline_ms: i64) !u16 {
        const outcome = process.shared.startup_resolved.waitTimeout(process.io, timeout(deadline_ms));
        if (outcome) |_| {
            const port = process.shared.port.load(.acquire);
            if (port != 0) {
                process.port = port;
                return port;
            }
            process.logBackendOutput("compiler backend exited before listening");
            return error.CompilerExited;
        } else |err| switch (err) {
            error.Timeout => {
                process.logBackendOutput("compiler backend did not announce its protocol port");
                return error.CompilerStartTimeout;
            },
            error.Canceled => return error.Canceled,
        }
    }

    /// Asks the backend to run an incremental update and waits for it to
    /// report. The backend only reports through the error bundle it prints
    /// when an update ends.
    pub fn requestUpdate(process: *Process, deadline_ms: i64) !void {
        process.shared.update_finished.reset();
        try process.sendUpdate();
        try process.awaitUpdate(deadline_ms);
    }

    /// Waits for the update started by `start`.
    pub fn awaitUpdate(process: *Process, deadline_ms: i64) !void {
        process.shared.update_finished.waitTimeout(process.io, timeout(deadline_ms)) catch |err| switch (err) {
            error.Timeout => return error.CompilerUpdateTimeout,
            error.Canceled => return error.Canceled,
        };
    }

    /// Marks the first update as consumed so the next `requestUpdate` waits
    /// for its own completion.
    pub fn resetUpdate(process: *Process) void {
        process.shared.update_finished.reset();
    }

    /// Copies the most recent backend stderr into `buffer`.
    pub fn stderrTail(process: *const Process, buffer: []u8) []const u8 {
        return process.shared.copyTail(process.io, buffer);
    }

    /// Stops the backend: asks it to exit and waits up to `exit_deadline_ms`,
    /// then kills it. Logs the backend's stderr when it did not exit cleanly.
    pub fn stop(process: *Process) void {
        var graceful_shutdown = true;
        if (process.child.stdin) |stdin| {
            var writer = stdin.writer(process.io, &.{});
            writer.interface.writeStruct(std.zig.Client.Message.Header{
                .tag = .exit,
                .bytes_len = 0,
            }, .little) catch |err| {
                std.log.warn("failed to send compiler exit message: {t}", .{err});
                graceful_shutdown = false;
            };
            writer.interface.flush() catch |err| {
                std.log.warn("failed to flush compiler exit message: {t}", .{err});
                graceful_shutdown = false;
            };
            stdin.close(process.io);
            process.child.stdin = null;
        } else {
            graceful_shutdown = false;
        }
        var backend_exited = false;
        if (graceful_shutdown) {
            backend_exited = if (process.shared.stdout_closed.waitTimeout(process.io, timeout(process.exit_deadline_ms))) |_| true else |err| switch (err) {
                error.Timeout, error.Canceled => false,
            };
            if (!backend_exited) {
                std.log.warn("compiler backend did not exit within {d} ms; killing it", .{process.exit_deadline_ms});
            }
        }

        var clean_exit = backend_exited;
        if (backend_exited) {
            process.awaitDrain(&process.stdout_future);
            process.awaitDrain(&process.stderr_future);
        } else {
            // Cancel the readers before kill: kill closes the pipe handles
            // while the readers would still be blocked on them.
            process.cancelDrain(&process.stdout_future);
            process.cancelDrain(&process.stderr_future);
            process.child.kill(process.io);
        }
        if (process.child.id != null) {
            if (process.child.wait(process.io)) |term| switch (term) {
                .exited => |exit_code| if (exit_code != 0) {
                    std.log.warn("compiler exited with status {d}", .{exit_code});
                    clean_exit = false;
                },
                else => {
                    std.log.warn("compiler terminated during shutdown: {t}", .{term});
                    clean_exit = false;
                },
            } else |err| {
                std.log.warn("failed to wait for compiler shutdown: {t}", .{err});
                process.child.kill(process.io);
                clean_exit = false;
            }
        }
        if (!clean_exit) process.logBackendOutput("compiler backend did not shut down cleanly");
        process.allocator.destroy(process.shared);
        process.* = undefined;
    }

    fn sendUpdate(process: *const Process) !void {
        const stdin = process.child.stdin orelse return error.CompilerExited;
        var writer = stdin.writer(process.io, &.{});
        try writer.interface.writeStruct(std.zig.Client.Message.Header{
            .tag = .update,
            .bytes_len = 0,
        }, .little);
        try writer.interface.flush();
    }

    fn awaitDrain(process: *Process, future: *std.Io.Future(DrainResult)) void {
        _ = future.await(process.io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.log.warn("compiler output reader failed during shutdown: {t}", .{err}),
        };
    }

    fn cancelDrain(process: *Process, future: *std.Io.Future(DrainResult)) void {
        _ = future.cancel(process.io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.log.warn("compiler output reader failed during shutdown: {t}", .{err}),
        };
    }

    /// Logs the backend's recent stderr under `headline`.
    pub fn logBackendOutput(process: *const Process, comptime headline: []const u8) void {
        var buffer: [stderr_tail_capacity]u8 = undefined;
        const tail = process.stderrTail(&buffer);
        if (tail.len == 0) {
            std.log.warn(headline ++ " (no stderr output)", .{});
        } else {
            std.log.warn(headline ++ "; backend stderr:\n{s}", .{std.mem.trimEnd(u8, tail, "\n")});
        }
    }
};

/// State the output readers share with the owning `Process`; heap-allocated
/// because the reader tasks outlive any move of the `Process` value.
const Shared = struct {
    /// Set by the stdout reader when the backend releases stdout, which it
    /// only does when it exits. Lets `stop` wait for a graceful exit with a
    /// deadline instead of blocking forever.
    stdout_closed: std.Io.Event = .unset,
    /// Set when an incremental update ends (the backend prints an error
    /// bundle for every update, empty or not).
    update_finished: std.Io.Event = .unset,
    /// Set when the port announcement arrived or stderr closed without one.
    startup_resolved: std.Io.Event = .unset,
    port: std.atomic.Value(u16) = .init(0),
    mutex: std.Io.Mutex = .init,
    tail: [stderr_tail_capacity]u8 = undefined,
    tail_length: usize = 0,

    fn copyTail(shared: *Shared, io: std.Io, buffer: []u8) []const u8 {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        const length = @min(buffer.len, shared.tail_length);
        @memcpy(buffer[0..length], shared.tail[shared.tail_length - length .. shared.tail_length]);
        return buffer[0..length];
    }

    fn appendTail(shared: *Shared, io: std.Io, bytes: []const u8) void {
        shared.mutex.lockUncancelable(io);
        defer shared.mutex.unlock(io);
        const kept = bytes[bytes.len -| stderr_tail_capacity..];
        const overflow = (shared.tail_length + kept.len) -| stderr_tail_capacity;
        if (overflow > 0) {
            @memmove(shared.tail[0 .. shared.tail_length - overflow], shared.tail[overflow..shared.tail_length]);
            shared.tail_length -= overflow;
        }
        @memcpy(shared.tail[shared.tail_length..][0..kept.len], kept);
        shared.tail_length += kept.len;
    }
};

fn timeout(deadline_ms: i64) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .fromMilliseconds(deadline_ms),
        .clock = .awake,
    } };
}

fn drainStdout(io: std.Io, file: std.Io.File, shared: *Shared) anyerror!void {
    defer shared.stdout_closed.set(io);
    var reader = file.readerStreaming(io, &.{});
    while (true) {
        const header = reader.interface.takeStruct(std.zig.Server.Message.Header, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return reader.err.?,
        };
        try reader.interface.discardAll(header.bytes_len);
        if (header.tag == .error_bundle) shared.update_finished.set(io);
    }
}

/// Keeps a bounded tail of stderr and extracts the protocol port from the
/// announcement line.
fn drainStderr(io: std.Io, file: std.Io.File, shared: *Shared) anyerror!void {
    defer shared.startup_resolved.set(io);
    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => {
                shared.appendTail(io, reader.interface.buffered());
                reader.interface.tossBuffered();
                continue;
            },
        } orelse return;
        shared.appendTail(io, line);
        shared.appendTail(io, "\n");
        if (parsePortAnnouncement(line)) |port| {
            shared.port.store(port, .release);
            shared.startup_resolved.set(io);
        }
    }
}

fn parsePortAnnouncement(line: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, line, protocol.port_announcement)) return null;
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, line[protocol.port_announcement.len..], " \r"), 10) catch return null;
    return if (port == 0) null else port;
}

test "port announcement is recognised only in its exact form" {
    try std.testing.expectEqual(@as(?u16, 40123), parsePortAnnouncement(protocol.port_announcement ++ "40123"));
    try std.testing.expectEqual(@as(?u16, 7), parsePortAnnouncement(protocol.port_announcement ++ "7\r"));
    try std.testing.expectEqual(@as(?u16, null), parsePortAnnouncement(protocol.port_announcement ++ "0"));
    try std.testing.expectEqual(@as(?u16, null), parsePortAnnouncement(protocol.port_announcement ++ "banana"));
    try std.testing.expectEqual(@as(?u16, null), parsePortAnnouncement(protocol.port_announcement ++ "70000"));
    try std.testing.expectEqual(@as(?u16, null), parsePortAnnouncement("error: listen failed"));
}

test "stderr tail keeps only the most recent bytes" {
    const io = std.testing.io;
    const shared = try std.testing.allocator.create(Shared);
    defer std.testing.allocator.destroy(shared);
    shared.* = .{};
    shared.appendTail(io, "first line\n");
    var buffer: [stderr_tail_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("first line\n", shared.copyTail(io, &buffer));

    const filler: [stderr_tail_capacity - 4]u8 = @splat('x');
    shared.appendTail(io, &filler);
    shared.appendTail(io, "last");
    const tail = shared.copyTail(io, &buffer);
    try std.testing.expectEqual(stderr_tail_capacity, tail.len);
    try std.testing.expect(std.mem.endsWith(u8, tail, "xxlast"));
    try std.testing.expect(std.mem.find(u8, tail, "first") == null);
}

test "a backend that exits without announcing a port fails startup with its stderr" {
    // The failure warn is expected here; silence it so the accumulated stderr
    // is not attributed to whichever test fails later in this binary.
    std.testing.log_level = .err;
    const io = std.testing.io;
    const child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "echo 'listen failed: AddressInUse' >&2" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var process = try Process.adopt(io, std.testing.allocator, child, @splat('0'));
    defer process.stop();
    try std.testing.expectError(error.CompilerExited, process.awaitPort(5_000));
    var buffer: [stderr_tail_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("listen failed: AddressInUse\n", process.stderrTail(&buffer));
}

test "a backend that announces a port is reachable through it" {
    const io = std.testing.io;
    const child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "echo noise >&2; echo '" ++ protocol.port_announcement ++ "4242' >&2; sleep 300" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var process = try Process.adopt(io, std.testing.allocator, child, @splat('0'));
    process.exit_deadline_ms = 100;
    defer process.stop();
    std.testing.log_level = .err;
    try std.testing.expectEqual(@as(u16, 4242), try process.awaitPort(5_000));
}

test "stop kills a backend that never exits instead of blocking forever" {
    // The kill-after-deadline warn is expected here; silence it so the
    // accumulated stderr is not attributed to whichever test fails later.
    std.testing.log_level = .err;
    const io = std.testing.io;
    // sleep ignores the exit message and never closes its stdout, exactly
    // like a hung compiler process.
    const child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "300" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var process = try Process.adopt(io, std.testing.allocator, child, @splat('0'));
    process.exit_deadline_ms = 100;
    process.stop();
}
