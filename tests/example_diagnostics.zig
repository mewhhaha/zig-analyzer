//! Golden diagnostics for the examples. Each `examples/diagnostics/*.zig` file
//! marks the findings the repository configuration must report with a comment
//! line `// expect: <rule-code>[, <rule-code>...]`; the marker applies to the
//! next line that is not itself a marker, and a marker trailing code applies to
//! its own line (needed where a finding anchors at the first byte of the file). The test runs the real file and
//! project pipelines and requires exactly the marked (line, rule) set, so a
//! missing finding and an unexpected one both fail. `examples/README.md`
//! carries a table generated from the markers, which must match too.
//! `examples/lsp` and `examples/compiler` carry no markers: they must be
//! finding-free, since their cases are editor interactions rather than lints.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

const analysis = zig_analyzer.analysis;

const marker_prefix = "// expect:";
const table_begin = "<!-- diagnostics:begin -->";
const table_end = "<!-- diagnostics:end -->";

/// A finding anchored on a one-based source line.
const Site = struct {
    line: usize,
    rule: analysis.Rule,

    fn lessThan(_: void, left: Site, right: Site) bool {
        if (left.line != right.line) return left.line < right.line;
        return @backingInt(left.rule) < @backingInt(right.rule);
    }
};

fn ruleFromCode(code: []const u8) !analysis.Rule {
    for (std.enums.values(analysis.Rule)) |rule| {
        if (std.mem.eql(u8, rule.code(), code)) return rule;
    }
    std.debug.print("unknown rule code in expect marker: {s}\n", .{code});
    return error.UnknownRuleCode;
}

/// The sites the markers in `source` promise, sorted.
fn expectedSites(arena: std.mem.Allocator, source: []const u8) ![]Site {
    var sites: std.ArrayList(Site) = .empty;
    var pending: std.ArrayList(analysis.Rule) = .empty;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, marker_prefix)) {
            var codes = std.mem.splitScalar(u8, trimmed[marker_prefix.len..], ',');
            while (codes.next()) |code| try pending.append(arena, try ruleFromCode(std.mem.trim(u8, code, " ")));
            continue;
        }
        if (std.mem.find(u8, line, marker_prefix)) |trailing| {
            var codes = std.mem.splitScalar(u8, line[trailing + marker_prefix.len ..], ',');
            while (codes.next()) |code| {
                try sites.append(arena, .{ .line = line_number, .rule = try ruleFromCode(std.mem.trim(u8, code, " ")) });
            }
        }
        for (pending.items) |rule| try sites.append(arena, .{ .line = line_number, .rule = rule });
        pending.clearRetainingCapacity();
    }
    try std.testing.expectEqual(@as(usize, 0), pending.items.len);
    std.mem.sort(Site, sites.items, {}, Site.lessThan);
    return sites.items;
}

fn lineOf(source: []const u8, offset: usize) usize {
    return 1 + std.mem.countScalar(u8, source[0..offset], '\n');
}

/// Every finding the file and project engines report for one file, sorted.
fn actualSites(arena: std.mem.Allocator, path: []const u8, source: [:0]const u8, configuration: analysis.Configuration) ![]Site {
    var sites: std.ArrayList(Site) = .empty;
    for (try analysis.findings(arena, source, configuration)) |finding| {
        try sites.append(arena, .{ .line = lineOf(source, finding.span.start), .rule = finding.rule });
    }
    const files = [_]zig_analyzer.project_rules.SourceFile{.{ .path = path, .source = source }};
    for (try zig_analyzer.project_rules.findings(arena, &files, configuration)) |entry| {
        try sites.append(arena, .{ .line = lineOf(source, entry.finding.span.start), .rule = entry.finding.rule });
    }
    std.mem.sort(Site, sites.items, {}, Site.lessThan);
    return sites.items;
}

fn printSites(label: []const u8, sites: []const Site) void {
    for (sites) |site| std.debug.print("  {s} line {d}: {s}\n", .{ label, site.line, site.rule.code() });
}

fn sameSites(left: []const Site, right: []const Site) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.line != b.line or a.rule != b.rule) return false;
    }
    return true;
}

fn loadConfiguration(arena: std.mem.Allocator, io: std.Io) !analysis.Configuration {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "zig-analyzer.json", arena, .limited(1 << 20));
    const configuration = try analysis.parseConfiguration(arena, text);
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    return configuration;
}

/// The `.zig` file names directly under `path`, sorted.
fn zigNames(arena: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var walker = try directory.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try names.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return names.items;
}

test "diagnostic examples report exactly their marked findings" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const configuration = try loadConfiguration(arena, io);

    var directory = try std.Io.Dir.cwd().openDir(io, "examples/diagnostics", .{ .iterate = true });
    defer directory.close(io);
    const names = try zigNames(arena, io, directory);
    try std.testing.expect(names.len >= 13);

    var table: std.ArrayList(u8) = .empty;
    try table.appendSlice(arena, "| File | Rules reported |\n| --- | --- |\n");
    var failed = false;
    for (names) |name| {
        const text = try directory.readFileAlloc(io, name, arena, .limited(1 << 20));
        const source = try arena.dupeSentinel(u8, text, 0);
        const expected = try expectedSites(arena, source);
        const actual = try actualSites(arena, name, source, configuration);
        if (!sameSites(expected, actual)) {
            failed = true;
            std.debug.print("examples/diagnostics/{s}: findings differ from `// expect:` markers\n", .{name});
            printSites("expected", expected);
            printSites("actual  ", actual);
        }
        try table.print(arena, "| `diagnostics/{s}` |", .{name});
        var written: std.EnumSet(analysis.Rule) = .empty;
        for (expected) |site| {
            if (written.contains(site.rule)) continue;
            written.insert(site.rule);
            try table.print(arena, "{s} `{s}`", .{ if (written.count() == 1) "" else ",", site.rule.code() });
        }
        if (expected.len == 0) try table.appendSlice(arena, " none");
        try table.appendSlice(arena, " |\n");
    }
    try std.testing.expect(!failed);

    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "examples/README.md", arena, .limited(1 << 20));
    const begin = std.mem.find(u8, readme, table_begin) orelse return error.ReadmeTableMissing;
    const end = std.mem.find(u8, readme, table_end) orelse return error.ReadmeTableMissing;
    const documented = std.mem.trim(u8, readme[begin + table_begin.len .. end], "\n");
    if (!std.mem.eql(u8, documented, std.mem.trim(u8, table.items, "\n"))) {
        std.debug.print("examples/README.md is stale; replace the block between the diagnostics markers with:\n{s}\n", .{table.items});
        return error.ReadmeTableStale;
    }
}

test "language-server and compiler examples are finding-free" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const configuration = try loadConfiguration(arena, io);

    var failed = false;
    for ([_][]const u8{ "examples/lsp", "examples/compiler" }) |root| {
        var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer directory.close(io);
        const names = try zigNames(arena, io, directory);
        try std.testing.expect(names.len != 0);
        for (names) |name| {
            const text = try directory.readFileAlloc(io, name, arena, .limited(1 << 20));
            const source = try arena.dupeSentinel(u8, text, 0);
            const actual = try actualSites(arena, name, source, configuration);
            if (actual.len == 0) continue;
            failed = true;
            std.debug.print("{s}/{s}: unexpected findings\n", .{ root, name });
            printSites("actual", actual);
        }
    }
    try std.testing.expect(!failed);
}
