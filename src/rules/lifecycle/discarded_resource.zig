//! Opened files, sockets, and directories discarded without being closed.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{.discarded_resource};

pub fn run(context: RuleRun) !void {
    const level = context.level(.discarded_resource);
    if (level == .off) return;
    for (context.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !context.tokenIs(equal_index - 1, "_")) continue;
        const statement_end = context.statementEnd(equal_index) orelse continue;
        for (context.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, call_index| {
            if (candidate.tag != .identifier or call_index + 1 >= statement_end or
                context.tokens[call_index + 1].tag != .l_paren) continue;
            const name = context.tokenText(call_index);
            const acquired = resources.lookup(context.configuration, name, resources.callReceiver(context.source, context.tokens, call_index));
            const discards_resource = if (acquired) |pair| switch (pair.kind) {
                .contract => true,
                .io_handle => ioDirectoryCall(context, call_index),
                .thread, .managed => false,
            } else posixAcquisitionCall(context, call_index) and isOsHandleAcquisition(name);
            if (!discards_resource) continue;
            try context.emit(.{
                .rule = .discarded_resource,
                .level = level,
                .span = candidate.loc,
                .message = try context.allocator.print(
                    "discarded {s} result is an owned resource that must be released",
                    .{name},
                ),
            });
        }
    }
}

fn ioDirectoryCall(context: RuleRun, call_index: usize) bool {
    if (call_index >= 4 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "fs") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "std")) return true;
    if (call_index >= 6 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "Dir") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "Io") and context.tokens[call_index - 5].tag == .period and
        context.tokenIs(call_index - 6, "std")) return true;
    if (call_index < 2 or context.tokens[call_index - 1].tag != .period or
        context.tokens[call_index - 2].tag != .identifier) return false;
    const receiver = context.tokenText(call_index - 2);
    for (context.tokens, 0..) |token, function_index| {
        if (token.tag != .keyword_fn) continue;
        const function = context.functionRange(function_index) orelse continue;
        if (call_index <= function.body_start or call_index >= function.body_end) continue;
        if (context.parameterNamesTypePath(receiver, &.{ "Io", "Dir" }, function.parameters_start, function.parameters_end) or
            context.parameterNamesTypePath(receiver, &.{ "fs", "Dir" }, function.parameters_start, function.parameters_end)) return true;
    }
    return false;
}

fn isOsHandleAcquisition(name: []const u8) bool {
    for (resources.os_handle_acquisitions) |acquisition| if (std.mem.eql(u8, name, acquisition)) return true;
    return false;
}

fn posixAcquisitionCall(context: RuleRun, call_index: usize) bool {
    if (call_index >= 2 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "posix")) return true;
    return call_index >= 6 and context.tokens[call_index - 1].tag == .period and
        context.tokenIs(call_index - 2, "linux") and context.tokens[call_index - 3].tag == .period and
        context.tokenIs(call_index - 4, "os") and context.tokens[call_index - 5].tag == .period and
        context.tokenIs(call_index - 6, "std");
}

test "custom open and socket methods do not imply OS resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(registry: *Registry) !void { _ = try registry.open(); _ = registry.socket(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "discarded Io files preserve resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn openOne(dir: std.Io.Dir, path: []const u8) !void { _ = try dir.openFile(path, .{}); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.discarded_resource});
}

test "discarded descriptors report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn openOne() !void { _ = try std.posix.openat(dir, name, flags, 0); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.discarded_resource});
}

test "discarded directories report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn leak(dir: std.Io.Dir, io: std.Io) !void { _ = try dir.openDir(io, \".\", .{}); }";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, &.{.discarded_resource});
}

test "discarded absolute Io files preserve resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn openOne(io: std.Io) !void { _ = try std.Io.Dir.openFileAbsolute(io, \"/tmp/state\", .{});" ++
        "_ = try std.Io.Dir.createFileAbsolute(io, \"/tmp/output\", .{});" ++
        "_ = try std.fs.openDirAbsolute(\"/tmp\", .{}); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var discarded_count: usize = 0;
    for (findings) |finding| if (finding.rule == .discarded_resource) {
        discarded_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), discarded_count);
}

test "a discarded declared resource pair reports the leaked resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 = "fn open() !void { _ = try Db.open(); _ = try Cache.open(); }";
    const declared = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expectEqual(types.Rule.discarded_resource, declared[0].rule);
    try std.testing.expectEqualStrings("open", source[declared[0].span.start..declared[0].span.end]);
    const builtin = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), builtin.len);
}
