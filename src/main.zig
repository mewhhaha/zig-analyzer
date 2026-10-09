const builtin = @import("builtin");
const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

comptime {
    @setEvalBranchQuota(50_000);
}

const usage =
    \\zig-analyzer - compiler-backed language intelligence for Zig
    \\
    \\Usage:
    \\  zig-analyzer lsp
    \\  zig-analyzer check [--fix] [--no-cache] [path]
    \\  zig-analyzer doctor
    \\  zig-analyzer backend bootstrap
    \\  zig-analyzer version
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (builtin.mode == .debug) {
        _ = debug_allocator.deinit();
    };
    const allocator = if (builtin.mode == .debug) debug_allocator.allocator() else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arguments = try init.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();

    const command = arguments.next() orelse {
        try std.Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    };
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try writeVersion(io);
        return 0;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try std.Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        return try runDoctor(io, allocator);
    }
    if (std.mem.eql(u8, command, "check")) {
        var fix = false;
        var cache = true;
        var path: ?[]const u8 = null;
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--fix")) {
                fix = true;
                continue;
            }
            if (std.mem.eql(u8, argument, "--no-cache")) {
                cache = false;
                continue;
            }
            if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
                try std.Io.File.stdout().writeStreamingAll(io, usage);
                return 0;
            }
            if (argument.len > 0 and argument[0] == '-') {
                var buffer: [256]u8 = undefined;
                var file_writer = std.Io.File.stderr().writer(io, &buffer);
                try file_writer.interface.print("zig-analyzer check: unknown option '{s}'\n", .{argument});
                try file_writer.interface.flush();
                return 2;
            }
            if (path != null) {
                try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer check accepts one path\n");
                return 2;
            }
            path = argument;
        }
        return try zig_analyzer.project.check.run(io, allocator, .{
            .path = path orelse ".",
            .fix = fix,
            .cache = cache,
        });
    }
    if (std.mem.eql(u8, command, "backend")) {
        const backend_command = arguments.next() orelse {
            try std.Io.File.stderr().writeStreamingAll(io, "backend command is required; expected 'bootstrap'\n");
            return 2;
        };
        if (!std.mem.eql(u8, backend_command, "bootstrap")) {
            try std.Io.File.stderr().writeStreamingAll(io, "unknown backend command; expected 'bootstrap'\n");
            return 2;
        }
        zig_analyzer.compiler.bootstrap.bootstrap(io, allocator, init.environ) catch |err| switch (err) {
            error.BootstrapFailed => return 1,
            else => return err,
        };
        return 0;
    }
    if (std.mem.eql(u8, command, "lsp")) {
        try zig_analyzer.lsp.server.run(io, allocator, init.environ);
        return 0;
    }

    try std.Io.File.stderr().writeStreamingAll(io, "unknown command\n\n");
    try std.Io.File.stderr().writeStreamingAll(io, usage);
    return 2;
}

fn writeVersion(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.print("zig-analyzer {s}\nZig {s}\ncompiler protocol {d}\n", .{
        zig_analyzer.build_options.version_string,
        zig_analyzer.build_options.zig_version,
        zig_analyzer.compiler.protocol.version,
    });
    try writer.flush();
}

fn runDoctor(io: std.Io, allocator: std.mem.Allocator) !u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const actual_version = std.mem.trim(u8, result.stdout, " \t\r\n");
    const exited_successfully = switch (result.term) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
    if (!exited_successfully) {
        try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer doctor: failed to execute 'zig version'\n");
        return 1;
    }
    if (!std.mem.eql(u8, actual_version, zig_analyzer.build_options.zig_version)) {
        var buffer: [256]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        try file_writer.interface.print("zig-analyzer doctor: expected Zig {s}, found {s}\n", .{
            zig_analyzer.build_options.zig_version,
            actual_version,
        });
        try file_writer.interface.flush();
        return 1;
    }
    _ = zig_analyzer.compiler.zig_environment.libDirectory(io) catch |err| {
        var buffer: [256]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        try file_writer.interface.print("zig-analyzer doctor: could not locate the Zig standard library ({t})\n", .{err});
        try file_writer.interface.flush();
        return 1;
    };

    try std.Io.File.stdout().writeStreamingAll(io, "zig-analyzer doctor: Zig " ++ zig_analyzer.build_options.zig_version ++ " is available\n");

    var backend = (try zig_analyzer.compiler.bootstrap.findBackend(io, allocator)) orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer doctor: compiler backend is missing; install a release archive or run 'zig build backend'\n");
        return 1;
    };
    defer backend.deinit(allocator);
    var manifest = zig_analyzer.compiler.bootstrap.readManifestAt(io, allocator, backend.manifest_path) catch |err| {
        var buffer: [512]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        try file_writer.interface.print("zig-analyzer doctor: backend manifest {s} is unreadable ({t})\n", .{ backend.manifest_path, err });
        try file_writer.interface.flush();
        return 1;
    };
    defer manifest.deinit();

    const expected = zig_analyzer.build_options;
    if (!std.mem.eql(u8, manifest.value.analyzer_version, expected.version_string) or
        !std.mem.eql(u8, manifest.value.zig_version, expected.zig_version) or
        !std.mem.eql(u8, manifest.value.zig_commit, expected.zig_commit) or
        !std.mem.eql(u8, manifest.value.backend_sha256, zig_analyzer.compiler.bootstrap.expected_inputs_sha256) or
        manifest.value.compiler_protocol_version != zig_analyzer.compiler.protocol.version)
    {
        try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer doctor: compiler backend manifest is incompatible with this executable\n");
        return 1;
    }

    const backend_version = try std.process.run(allocator, io, .{
        .argv = &.{ backend.binary_path, "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(backend_version.stdout);
    defer allocator.free(backend_version.stderr);
    const version_text = std.mem.trim(u8, backend_version.stdout, " \t\r\n");
    if (!std.mem.eql(u8, version_text, zig_analyzer.build_options.backend_version)) {
        var buffer: [256]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        try file_writer.interface.print("zig-analyzer doctor: backend reports {s}; expected {s}\n", .{ version_text, zig_analyzer.build_options.backend_version });
        try file_writer.interface.flush();
        return 1;
    }

    try std.Io.File.stdout().writeStreamingAll(io, "zig-analyzer doctor: compiler backend is compatible\n");
    return 0;
}
