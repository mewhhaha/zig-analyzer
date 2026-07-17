const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

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
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arguments = try init.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();

    const command = arguments.next() orelse "lsp";
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
            if (std.mem.startsWith(u8, argument, "-")) {
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
        return try zig_analyzer.project_check.run(io, allocator, .{
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
        zig_analyzer.backend_bootstrap.bootstrap(io, allocator) catch |err| switch (err) {
            error.BootstrapFailed => return 1,
            else => return err,
        };
        return 0;
    }
    if (std.mem.eql(u8, command, "lsp")) {
        try zig_analyzer.lsp_server.run(io, allocator, init.environ);
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
        zig_analyzer.compiler_protocol.current_version,
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

    try std.Io.File.stdout().writeStreamingAll(io, "zig-analyzer doctor: Zig 0.16.0 is available\n");

    var manifest = zig_analyzer.backend_bootstrap.readManifest(io, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.File.stdout().writeStreamingAll(io, "zig-analyzer doctor: compiler backend is not bootstrapped\n");
            return 1;
        },
        else => {
            var buffer: [512]u8 = undefined;
            var file_writer = std.Io.File.stderr().writer(io, &buffer);
            try file_writer.interface.print("zig-analyzer doctor: backend manifest {s} is unreadable ({t}); rerun 'zig build backend'\n", .{
                zig_analyzer.backend_bootstrap.manifest_path,
                err,
            });
            try file_writer.interface.flush();
            return 1;
        },
    };
    defer manifest.deinit();

    const expected_patch_sha256 = try zig_analyzer.backend_bootstrap.expectedPatchSha256(io, allocator);
    defer allocator.free(expected_patch_sha256);
    const expected = zig_analyzer.build_options;
    if (!std.mem.eql(u8, manifest.value.zig_version, expected.zig_version) or
        !std.mem.eql(u8, manifest.value.zig_commit, expected.zig_commit) or
        !std.mem.eql(u8, manifest.value.patch_sha256, expected_patch_sha256) or
        manifest.value.compiler_protocol_version != expected.compiler_protocol_version)
    {
        try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer doctor: compiler backend manifest is incompatible; rerun 'zig build backend'\n");
        return 1;
    }
    std.Io.Dir.cwd().access(io, zig_analyzer.backend_bootstrap.backend_binary, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer doctor: compiler backend binary is missing\n");
            return 1;
        },
        else => return err,
    };

    const backend_version = try std.process.run(allocator, io, .{
        .argv = &.{ zig_analyzer.backend_bootstrap.backend_binary, "version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(backend_version.stdout);
    defer allocator.free(backend_version.stderr);
    const version_text = std.mem.trim(u8, backend_version.stdout, " \t\r\n");
    if (!std.mem.eql(u8, version_text, "0.16.0+zig-analyzer.1")) {
        var buffer: [256]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        try file_writer.interface.print("zig-analyzer doctor: backend reports {s}; expected 0.16.0+zig-analyzer.1\n", .{version_text});
        try file_writer.interface.flush();
        return 1;
    }

    try std.Io.File.stdout().writeStreamingAll(io, "zig-analyzer doctor: compiler backend is compatible\n");
    return 0;
}
