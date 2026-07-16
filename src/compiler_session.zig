const std = @import("std");
const build_options = @import("build_options");
const backend_bootstrap = @import("backend_bootstrap.zig");
const compiler_client = @import("compiler_client.zig");
const protocol = @import("compiler_protocol.zig");
const DrainResult = @typeInfo(@TypeOf(drainCompilerStdout)).@"fn".return_type.?;

pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdout_future: std.Io.Future(DrainResult),
    /// Set by the stdout drain task when the backend releases its stdout,
    /// which the backend only does when it exits. Lets deinit wait for a
    /// graceful exit with a deadline instead of blocking forever.
    stdout_closed: *std.Io.Event,
    client: compiler_client.Client,
    exit_deadline_ms: i64 = compiler_client.default_response_deadline_ms,

    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        root_source_path: []const u8,
    ) !Session {
        try std.Io.Dir.cwd().createDirPath(io, ".zig-analyzer/analysis-cache");
        try std.Io.Dir.cwd().createDirPath(io, ".zig-analyzer/compiler-global-cache");
        var random_bytes: [18]u8 = undefined;
        try io.randomSecure(&random_bytes);
        const port = 20_000 + std.mem.readInt(u16, random_bytes[0..2], .little) % 30_000;
        const authentication_token = std.fmt.bytesToHex(random_bytes[2..], .lower);
        var port_buffer: [5]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});

        var environ_map = try std.process.Environ.createMap(environ, allocator);
        defer environ_map.deinit();
        try environ_map.put("ZIG_ANALYZER_PORT", port_text);
        try environ_map.put("ZIG_ANALYZER_TOKEN", &authentication_token);

        var child = try std.process.spawn(io, .{
            .argv = &.{
                backend_bootstrap.backend_binary,
                "build-obj",
                root_source_path,
                "-fincremental",
                "--debug-incremental",
                "-fno-emit-bin",
                "--cache-dir",
                ".zig-analyzer/analysis-cache",
                "--global-cache-dir",
                ".zig-analyzer/compiler-global-cache",
                "--listen=-",
            },
            .environ_map = &environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        const stdout_closed = try allocator.create(std.Io.Event);
        errdefer allocator.destroy(stdout_closed);
        stdout_closed.* = .unset;
        var stdout_future = try io.concurrent(drainCompilerStdout, .{ io, child.stdout.?, stdout_closed });
        errdefer stdout_future.cancel(io) catch |err| std.log.warn("failed to cancel compiler output reader: {t}", .{err});

        var stdin_writer = child.stdin.?.writer(io, &.{});
        try stdin_writer.interface.writeStruct(std.zig.Client.Message.Header{
            .tag = .update,
            .bytes_len = 0,
        }, .little);
        try stdin_writer.interface.flush();

        var incompatible_protocol = try connectCompilerClient(io, allocator, port);
        if (incompatible_protocol.probeHandshake(build_options.zig_version, protocol.current_version + 1, &authentication_token)) |_| {
            incompatible_protocol.deinit();
            return error.IncompatibleProtocolAccepted;
        } else |err| switch (err) {
            error.IncompatibleProtocol => incompatible_protocol.deinit(),
            else => {
                incompatible_protocol.deinit();
                return err;
            },
        }

        var incompatible_zig = try connectCompilerClient(io, allocator, port);
        if (incompatible_zig.probeHandshake("0.15.2", protocol.current_version, &authentication_token)) |_| {
            incompatible_zig.deinit();
            return error.IncompatibleZigAccepted;
        } else |err| switch (err) {
            error.IncompatibleZig => incompatible_zig.deinit(),
            else => {
                incompatible_zig.deinit();
                return err;
            },
        }

        var rejected = try connectCompilerClient(io, allocator, port);
        var invalid_token = authentication_token;
        invalid_token[0] = if (invalid_token[0] == '0') '1' else '0';
        if (rejected.handshake(&invalid_token)) |_| {
            rejected.deinit();
            return error.InvalidAuthenticationAccepted;
        } else |err| switch (err) {
            error.AuthenticationFailed => rejected.deinit(),
            else => {
                rejected.deinit();
                return err;
            },
        }

        var client = try connectCompilerClient(io, allocator, port);
        errdefer client.deinit();
        client.handshake(&authentication_token) catch |err| {
            std.log.err("compiler protocol handshake failed: {t}", .{err});
            return err;
        };

        return .{
            .io = io,
            .allocator = allocator,
            .child = child,
            .stdout_future = stdout_future,
            .stdout_closed = stdout_closed,
            .client = client,
        };
    }

    pub fn deinit(session: *Session) void {
        session.client.shutdown() catch |err| std.log.warn("failed to send compiler protocol shutdown: {t}", .{err});
        session.client.deinit();

        var graceful_shutdown = true;
        if (session.child.stdin) |stdin| {
            var writer = stdin.writer(session.io, &.{});
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
            stdin.close(session.io);
            session.child.stdin = null;
        } else {
            graceful_shutdown = false;
        }
        var backend_exited = false;
        if (graceful_shutdown) {
            const exit_timeout: std.Io.Timeout = .{ .duration = .{
                .raw = .fromMilliseconds(session.exit_deadline_ms),
                .clock = .awake,
            } };
            backend_exited = if (session.stdout_closed.waitTimeout(session.io, exit_timeout)) |_| true else |err| switch (err) {
                error.Timeout, error.Canceled => false,
            };
            if (!backend_exited) {
                std.log.warn("compiler backend did not exit within {d} ms; killing it", .{session.exit_deadline_ms});
            }
        }

        if (backend_exited) {
            _ = session.stdout_future.await(session.io) catch |err| switch (err) {
                error.Canceled => {},
                else => std.log.warn("compiler output reader failed during shutdown: {t}", .{err}),
            };
        } else {
            // Cancel the reader before kill: kill closes the stdout handle
            // while the reader would still be blocked on it.
            _ = session.stdout_future.cancel(session.io) catch |err| switch (err) {
                error.Canceled => {},
                else => std.log.warn("compiler output reader failed during shutdown: {t}", .{err}),
            };
            session.child.kill(session.io);
        }
        session.allocator.destroy(session.stdout_closed);
        if (session.child.id != null) {
            const term = session.child.wait(session.io) catch |err| {
                std.log.warn("failed to wait for compiler shutdown: {t}", .{err});
                session.child.kill(session.io);
                session.* = undefined;
                return;
            };
            switch (term) {
                .exited => |exit_code| if (exit_code != 0) std.log.warn("compiler exited with status {d}", .{exit_code}),
                else => std.log.warn("compiler terminated during shutdown: {t}", .{term}),
            }
        }
        session.* = undefined;
    }

    pub fn replaceOverlay(
        session: *Session,
        uri: []const u8,
        document_version: i32,
        source: []const u8,
    ) !protocol.DocumentFacts {
        return try session.client.replaceOverlay(uri, document_version, source);
    }

    pub fn analyzeOverlay(session: *Session, uri: []const u8, document_version: i32) !protocol.DocumentFacts {
        return try session.client.analyzeOverlay(uri, document_version);
    }

    pub fn removeOverlay(session: *Session, uri: []const u8) !void {
        try session.client.removeOverlay(uri);
    }

    pub fn workspaceDeclarations(
        session: *Session,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        return try session.client.workspaceDeclarations(allocator);
    }

    pub fn diagnostics(session: *Session, allocator: std.mem.Allocator) !std.zig.ErrorBundle {
        return try session.client.diagnostics(allocator);
    }

    pub fn typeMembers(
        session: *Session,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]const []const u8 {
        return try session.client.typeMembers(allocator, name);
    }

    pub fn typeShape(
        session: *Session,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !compiler_client.TypeShape {
        return try session.client.typeShape(allocator, name);
    }
};

fn connectCompilerClient(io: std.Io, allocator: std.mem.Allocator, port: u16) !compiler_client.Client {
    for (0..100) |_| {
        if (compiler_client.Client.connect(io, allocator, port)) |client| return client else |err| switch (err) {
            error.ConnectionRefused => try io.sleep(.fromMilliseconds(10), .awake),
            else => return err,
        }
    }
    return error.CompilerProtocolUnavailable;
}

fn drainCompilerStdout(io: std.Io, file: std.Io.File, stdout_closed: *std.Io.Event) !void {
    defer stdout_closed.set(io);
    var reader = file.readerStreaming(io, &.{});
    while (true) {
        const header = reader.interface.takeStruct(std.zig.Server.Message.Header, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return reader.err.?,
        };
        try reader.interface.discardAll(header.bytes_len);
    }
}

test "deinit kills a backend that never exits instead of blocking forever" {
    // The kill-after-deadline warn is expected here; silence it so the
    // accumulated stderr is not attributed to whichever test fails later.
    std.testing.log_level = .err;
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // A listener that never replies stands in for the backend's socket side.
    const address: std.Io.net.IpAddress = .{ .ip6 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = try compiler_client.Client.connect(io, allocator, server.socket.address.getPort());
    errdefer client.deinit();
    client.response_deadline_ms = 100;

    // sleep ignores the exit message and never closes its stdout, exactly
    // like a hung compiler process.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "300" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    const stdout_closed = try allocator.create(std.Io.Event);
    errdefer allocator.destroy(stdout_closed);
    stdout_closed.* = .unset;
    const stdout_future = try io.concurrent(drainCompilerStdout, .{ io, child.stdout.?, stdout_closed });

    var session: Session = .{
        .io = io,
        .allocator = allocator,
        .child = child,
        .stdout_future = stdout_future,
        .stdout_closed = stdout_closed,
        .client = client,
        .exit_deadline_ms = 100,
    };
    session.deinit();
}
