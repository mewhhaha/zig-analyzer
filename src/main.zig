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
    \\  zig-analyzer check [--fix] [--no-cache] [--strict-config]
    \\                     [--baseline <file>] [--write-baseline <file>]
    \\                     [--format <format>] [--rule <code>]... [--fail-on <level>]
    \\                     [path]
    \\  zig-analyzer explain [rule]
    \\  zig-analyzer doctor
    \\  zig-analyzer backend bootstrap
    \\  zig-analyzer version
    \\
;

const check_usage =
    \\Usage: zig-analyzer check [options] [path]
    \\
    \\Lints the Zig files under path, the current directory by default, or the
    \\one file path names.
    \\
    \\Options:
    \\  --fix                    apply the provably safe fixes before reporting
    \\  --no-cache               reanalyze files whose findings are cached
    \\  --strict-config          stop with status 2 on a configuration error
    \\  --baseline <file>        leave out the findings recorded in file
    \\  --write-baseline <file>  record every finding in file instead of reporting it
    \\  --format <format>        text (the default), json, sarif or github
    \\  --rule <code>[,<code>]   report, count and fix only these rules; repeatable
    \\  --fail-on <level>        exit with status 1 only for a finding at level or
    \\                           above: hint (the default, any finding),
    \\                           information, warning, error, or never
    \\  -h, --help               print this help
    \\
    \\Exit status: 0 when no finding reaches the --fail-on level, 1 when one
    \\does, 2 for a usage, I/O or --strict-config error.
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
        var buffer: [256]u8 = undefined;
        var file_writer = std.Io.File.stderr().writer(io, &buffer);
        const parsed = try zig_analyzer.project.check.parseArguments(&arguments, &file_writer.interface);
        try file_writer.interface.flush();
        switch (parsed) {
            .run => |options| return try zig_analyzer.project.check.run(io, allocator, options),
            .help => {
                try std.Io.File.stdout().writeStreamingAll(io, check_usage);
                return 0;
            },
            .invalid => return 2,
        }
    }
    if (std.mem.eql(u8, command, "explain")) {
        const rule = arguments.next();
        if (rule) |code| if (std.mem.eql(u8, code, "--help") or std.mem.eql(u8, code, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return 0;
        };
        if (arguments.next() != null) {
            try std.Io.File.stderr().writeStreamingAll(io, "zig-analyzer explain accepts one rule\n");
            return 2;
        }
        return try zig_analyzer.project.explain.run(io, allocator, rule);
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
