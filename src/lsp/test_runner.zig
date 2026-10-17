//! "Run test" code lenses and the command behind them. Every named `test`
//! declaration gets a lens carrying `zig-analyzer.runTest` with the document
//! URI and the test name. Executed by the server, the command runs
//! `zig test <file> --test-filter <name>` from the file's directory in the
//! background, reports whether it passed in an editor message, and writes the
//! output to the server log. A client may handle the command itself instead,
//! such as to run it in a terminal; the arguments are all it needs.
//!
//! `zig test` builds the file on its own, so a test whose file imports build
//! modules fails to compile this way; the filter matches every test whose name
//! contains the given one.
const std = @import("std");

const lsp = @import("lsp");

const document_module = @import("../syntax/document.zig");
const syntax_structure = @import("../syntax/structure.zig");
const uri_module = @import("../uri.zig");

const Document = document_module.Document;

pub const command = "zig-analyzer.runTest";

/// Longest test output kept for the log; a run printing more is reported as
/// failed to report.
const max_output_bytes = 4 * 1024 * 1024;

/// One lens per named test, above its `test` keyword.
pub fn codeLenses(arena: std.mem.Allocator, document: *const Document) ![]const lsp.types.code_lens.Response {
    const tests = try syntax_structure.testDeclarations(arena, document);
    const lenses = try arena.alloc(lsp.types.code_lens.Response, tests.len);
    for (tests, lenses) |declaration, *lens| {
        const arguments = try arena.alloc(std.json.Value, 2);
        arguments[0] = .{ .string = document.uri };
        arguments[1] = .{ .string = declaration.name };
        lens.* = .{
            .range = document.range(declaration.span),
            .command = .{
                .title = "Run test",
                .tooltip = try arena.print("zig test --test-filter \"{s}\"", .{declaration.name}),
                .command = command,
                .arguments = arguments,
            },
        };
    }
    return lenses;
}

/// Runs tests for `zig-analyzer.runTest` without holding up requests. Runs
/// still going when the server stops are cancelled, which kills `zig test`.
pub const TestRunner = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    runs: std.Io.Group = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, transport: *lsp.Transport) TestRunner {
        return .{ .io = io, .allocator = allocator, .transport = transport };
    }

    pub fn deinit(runner: *TestRunner) void {
        runner.runs.cancel(runner.io);
        runner.* = undefined;
    }

    /// Blocks until every started run has reported. For tests.
    pub fn waitIdle(runner: *TestRunner) void {
        runner.runs.await(runner.io) catch |err| std.log.warn("waiting for test runs: {t}", .{err});
    }

    /// Starts the run `arguments` (`[uri, test name]`) asks for and returns
    /// at once; the result arrives as a message. Fails with `InvalidParams`
    /// for anything else, such as an editor listing the command without the
    /// lens's arguments.
    pub fn execute(runner: *TestRunner, arena: std.mem.Allocator, arguments: ?[]const std.json.Value) !?std.json.Value {
        const values = arguments orelse return error.InvalidParams;
        if (values.len != 2) return error.InvalidParams;
        const uri = switch (values[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const name = switch (values[1]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        if (name.len == 0) return error.InvalidParams;
        const path = try uri_module.toPath(arena, uri) orelse return error.InvalidParams;
        const run = try Run.create(runner, path, name);
        runner.runs.concurrent(runner.io, Run.execute, .{run}) catch |err| {
            run.destroy();
            return err;
        };
        return null;
    }

    fn message(runner: *TestRunner, arena: std.mem.Allocator, kind: lsp.types.window.MessageType, text: []const u8) !void {
        try runner.transport.writeNotification(
            runner.io,
            arena,
            "window/showMessage",
            lsp.types.window.ShowMessageParams,
            .{ .type = kind, .message = text },
            .{ .emit_null_optional_fields = false },
        );
    }

    fn log(runner: *TestRunner, arena: std.mem.Allocator, text: []const u8) !void {
        try runner.transport.writeNotification(
            runner.io,
            arena,
            "window/logMessage",
            lsp.types.window.LogMessageParams,
            .{ .type = .Log, .message = text },
            .{ .emit_null_optional_fields = false },
        );
    }
};

const Run = struct {
    runner: *TestRunner,
    path: []u8,
    name: []u8,

    fn create(runner: *TestRunner, path: []const u8, name: []const u8) !*Run {
        const run = try runner.allocator.create(Run);
        errdefer runner.allocator.destroy(run);
        const owned_path = try runner.allocator.dupe(u8, path);
        errdefer runner.allocator.free(owned_path);
        run.* = .{ .runner = runner, .path = owned_path, .name = try runner.allocator.dupe(u8, name) };
        return run;
    }

    fn destroy(run: *Run) void {
        const allocator = run.runner.allocator;
        allocator.free(run.path);
        allocator.free(run.name);
        allocator.destroy(run);
    }

    fn execute(run: *Run) std.Io.Cancelable!void {
        defer run.destroy();
        run.report() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => std.log.warn("could not report the test run: {t}", .{err}),
        };
    }

    fn report(run: *Run) !void {
        const runner = run.runner;
        var arena_state: std.heap.ArenaAllocator = .init(runner.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const directory = std.Io.Dir.path.dirname(run.path) orelse ".";
        try runner.log(arena, try arena.print("zig test {s} --test-filter \"{s}\"", .{ run.path, run.name }));
        const result = std.process.run(arena, runner.io, .{
            .argv = &.{ "zig", "test", run.path, "--test-filter", run.name },
            .cwd = .{ .path = directory },
            .stdout_limit = .limited(max_output_bytes),
            .stderr_limit = .limited(max_output_bytes),
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                try runner.message(arena, .Error, try arena.print("Could not run zig test for \"{s}\": {t}", .{ run.name, err }));
                return;
            },
        };
        // The test runner reports on stderr; a test may print to stdout.
        const output = std.mem.trim(u8, try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr }), " \t\r\n");
        if (output.len != 0) try runner.log(arena, output);
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (passed and std.mem.find(u8, result.stderr, "All 0 tests passed.") != null) {
            try runner.message(arena, .Warning, try arena.print("No test matched \"{s}\".", .{run.name}));
        } else if (passed) {
            try runner.message(arena, .Info, try arena.print("Test \"{s}\" passed.", .{run.name}));
        } else {
            try runner.message(arena, .Error, try arena.print(
                "Test \"{s}\" failed{s}{s}; the output is in the zig-analyzer log.",
                .{ run.name, if (summaryLine(result.stderr)) |_| ": " else "", summaryLine(result.stderr) orelse "" },
            ));
        }
    }
};

/// The test runner's `N passed; N skipped; N failed.` line, if it printed one.
fn summaryLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.find(u8, trimmed, " passed; ") != null and std.mem.endsWith(u8, trimmed, " failed.")) return trimmed;
    }
    return null;
}

test "the summary line is found among the failure output" {
    try std.testing.expectEqualStrings(
        "0 passed; 0 skipped; 1 failed.",
        summaryLine("1/1 t.test.fails...FAIL (TestUnexpectedResult)\n0 passed; 0 skipped; 1 failed.\nerror: the following test command failed with exit code 1:\n").?,
    );
    try std.testing.expect(summaryLine("error: expected type\n") == null);
}
