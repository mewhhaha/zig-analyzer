//! What `zig-analyzer check` reports and the formats it prints it in: text
//! lines for people, one JSON document, a SARIF 2.1.0 log, or GitHub Actions
//! workflow commands. Each pass of a check turns what it found into `Entry`
//! values in the order the text report prints them; the formats differ only
//! in how they render the same entries.

const std = @import("std");
const build_options = @import("build_options");
const analysis = @import("../analysis.zig");
const catalog = @import("../rules/catalog.zig");
const uri = @import("../uri.zig");

pub const Format = enum { text, json, sarif, github };

/// The least severe level of a counted entry that makes a check exit with
/// status 1. `hint`, the default, fails on every finding.
pub const FailOn = enum {
    hint,
    information,
    warning,
    @"error",
    never,

    fn fails(fail_on: FailOn, level: analysis.Level) bool {
        const threshold: analysis.Level = switch (fail_on) {
            .never => return false,
            .hint => .hint,
            .information => .information,
            .warning => .warning,
            .@"error" => .@"error",
        };
        return @backingInt(level) >= @backingInt(threshold);
    }
};

/// A 1-based line and column; columns count Unicode code points.
pub const Location = struct { line: usize, column: usize };

/// What an entry that is not a rule finding is about.
pub const Notice = enum {
    /// An invalid project configuration or suppression directive.
    configuration,
    /// A file that could not be read or rewritten.
    io,
    generated_source,
    nesting_limit,
    compiler_backend,

    pub fn code(notice: Notice) []const u8 {
        return switch (notice) {
            .configuration => "configuration",
            .io => "io",
            .generated_source => "generated-source",
            .nesting_limit => "nesting-limit",
            .compiler_backend => "compiler-backend",
        };
    }

    /// Whether the notice counts as a finding: it says the check did not run
    /// as configured, so it is reported and counted whatever `--rule` selects.
    fn counted(notice: Notice) bool {
        return switch (notice) {
            .configuration, .io => true,
            .generated_source, .nesting_limit, .compiler_backend => false,
        };
    }

    fn description(notice: Notice) []const u8 {
        return switch (notice) {
            .configuration => "The project configuration or a suppression directive is invalid.",
            .io => "A file could not be read or rewritten.",
            .generated_source => "A generated file was skipped.",
            .nesting_limit => "A file nested too deeply to parse safely was skipped.",
            .compiler_backend => "Compiler-backed facts are incomplete.",
        };
    }
};

pub const Subject = union(enum) {
    rule: analysis.Rule,
    notice: Notice,
};

pub const Related = struct {
    message: []const u8,
    start: Location,
    end: Location,
};

/// One finding or notice.
pub const Entry = struct {
    subject: Subject,
    level: analysis.Level,
    /// The path the text report prints.
    text_path: []const u8,
    /// Relative to the scan root; null for an entry about the whole project.
    path: ?[]const u8,
    message: []const u8,
    /// Null for an entry about a whole file.
    start: ?Location = null,
    end: ?Location = null,
    related: []const Related = &.{},
    fix: catalog.Fixes = .none,

    pub fn code(entry: Entry) []const u8 {
        return switch (entry.subject) {
            .rule => |rule| rule.code(),
            .notice => |notice| notice.code(),
        };
    }

    fn counted(entry: Entry) bool {
        return switch (entry.subject) {
            .rule => true,
            .notice => |notice| notice.counted(),
        };
    }
};

pub const Totals = struct {
    files_checked: usize = 0,
    files_changed: usize = 0,
    edits_applied: usize = 0,
};

pub const BaselineCount = struct { path: []const u8, findings: usize };

pub const Report = struct {
    /// The scanned directory as given, which `Entry.path` is relative to.
    root: []const u8,
    root_absolute: []const u8,
    /// The entries of each pass, in report order.
    parts: []const []const Entry,
    totals: Totals = .{},
    /// Whether `--fix` ran, which the text report then summarizes.
    fix: bool = false,
    baseline: union(enum) {
        none,
        /// Findings a `--baseline` file covered.
        read: BaselineCount,
        /// Findings `--write-baseline` recorded.
        written: BaselineCount,
    } = .none,

    /// The counted entries at `fail_on`'s level or above; at `hint`, the
    /// findings the text report's last line counts.
    pub fn count(report: Report, fail_on: FailOn) usize {
        var total: usize = 0;
        for (report.parts) |part| for (part) |entry| {
            if (entry.counted() and fail_on.fails(entry.level)) total += 1;
        };
        return total;
    }
};

/// Renders `report`; `allocator` holds only scratch.
pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, format: Format, report: Report) !void {
    switch (format) {
        .text => {
            try writeEntries(writer, report.parts);
            try writeTrailer(writer, report);
        },
        .json => try writeJson(writer, report),
        .sarif => {
            var arena_state: std.heap.ArenaAllocator = .init(allocator);
            defer arena_state.deinit();
            try writeSarif(arena_state.allocator(), writer, report);
        },
        .github => {
            try writeGithub(writer, report);
            try writeTrailer(writer, report);
        },
    }
}

/// The text report's entry lines.
pub fn writeEntries(writer: *std.Io.Writer, parts: []const []const Entry) !void {
    for (parts) |part| for (part) |entry| {
        if (entry.start) |start| {
            try writer.print("{s}:{d}:{d}: {t}[{s}]: {s}\n", .{ entry.text_path, start.line, start.column, entry.level, entry.code(), entry.message });
        } else {
            try writer.print("{s}: {t}[{s}]: {s}\n", .{ entry.text_path, entry.level, entry.code(), entry.message });
        }
    };
}

fn writeTrailer(writer: *std.Io.Writer, report: Report) !void {
    switch (report.baseline) {
        .none => {},
        .written => |written| try writer.print("recorded {d} findings in {s}\n", .{ written.findings, written.path }),
        .read => |read| try writer.print("{d} findings recorded in {s} were not reported\n", .{ read.findings, read.path }),
    }
    if (report.fix) {
        try writer.print("applied {d} safe edits across {d} files\n", .{ report.totals.edits_applied, report.totals.files_changed });
    }
    try writer.print("checked {d} Zig files; {d} findings remain\n", .{ report.totals.files_checked, report.count(.hint) });
}

/// Bumped when a field of the JSON report changes meaning or goes away.
const json_version = 1;

fn writeJson(writer: *std.Io.Writer, report: Report) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("version");
    try json.write(json_version);
    try json.objectField("root");
    try json.write(report.root);
    try json.objectField("findings");
    try json.beginArray();
    for (report.parts) |part| for (part) |entry| switch (entry.subject) {
        .rule => |rule| try json.write(.{
            .path = entry.path,
            .rule = rule.code(),
            .level = entry.level,
            .message = entry.message,
            .start = entry.start,
            .end = entry.end,
            .related = entry.related,
            .fix = if (entry.fix == .none) null else entry.fix,
        }),
        .notice => {},
    };
    try json.endArray();
    try json.objectField("notices");
    try json.beginArray();
    for (report.parts) |part| for (part) |entry| switch (entry.subject) {
        .rule => {},
        .notice => |notice| try json.write(.{
            .kind = notice.code(),
            .level = entry.level,
            .path = entry.path,
            .start = entry.start,
            .message = entry.message,
        }),
    };
    try json.endArray();
    try json.objectField("summary");
    try json.write(.{
        .files_checked = report.totals.files_checked,
        .findings = report.count(.hint),
        .files_changed = report.totals.files_changed,
        .edits_applied = report.totals.edits_applied,
        .baseline_covered = switch (report.baseline) {
            .read => |read| read.findings,
            .none, .written => 0,
        },
        .baseline_recorded = switch (report.baseline) {
            .written => |written| written.findings,
            .none, .read => 0,
        },
    });
    try json.endObject();
    try writer.writeByte('\n');
}

const sarif_schema = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json";
/// The `uriBaseId` every artifact location is relative to; the run's
/// `originalUriBaseIds` resolves it to the scanned directory.
const sarif_root = "SRCROOT";

const SarifText = struct { text: []const u8 };

const SarifRegion = struct {
    startLine: usize,
    startColumn: usize,
    endLine: usize,
    endColumn: usize,

    fn of(start: Location, end: Location) SarifRegion {
        return .{ .startLine = start.line, .startColumn = start.column, .endLine = end.line, .endColumn = end.column };
    }
};

const SarifLocation = struct {
    id: ?usize = null,
    physicalLocation: struct {
        artifactLocation: struct { uri: []const u8, uriBaseId: []const u8 = sarif_root },
        region: ?SarifRegion = null,
    },
    message: ?SarifText = null,
};

fn sarifLevel(level: analysis.Level) []const u8 {
    return switch (level) {
        .@"error" => "error",
        .warning => "warning",
        .information, .hint => "note",
        .off => "none",
    };
}

/// Every location is relative to the scanned directory, `SRCROOT`; columns
/// count Unicode code points (`columnKind`), as the text report's do, and an
/// end column is the one after the region.
fn writeSarif(arena: std.mem.Allocator, writer: *std.Io.Writer, report: Report) !void {
    var rule_indexes: [@typeInfo(analysis.Rule).@"enum".field_names.len]?usize = @splat(null);
    for (report.parts) |part| for (part) |entry| switch (entry.subject) {
        .rule => |rule| rule_indexes[@backingInt(rule)] = 0,
        .notice => {},
    };
    var rule_count: usize = 0;
    for (&rule_indexes) |*index| if (index.* != null) {
        index.* = rule_count;
        rule_count += 1;
    };

    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false } };
    try json.beginObject();
    try json.objectField("$schema");
    try json.write(sarif_schema);
    try json.objectField("version");
    try json.write("2.1.0");
    try json.objectField("runs");
    try json.beginArray();
    try json.beginObject();

    try json.objectField("tool");
    try json.beginObject();
    try json.objectField("driver");
    try json.beginObject();
    try json.objectField("name");
    try json.write("zig-analyzer");
    try json.objectField("version");
    try json.write(build_options.version_string);
    try json.objectField("informationUri");
    try json.write(catalog.repository_url);
    try json.objectField("rules");
    try json.beginArray();
    for (std.enums.values(analysis.Rule)) |rule| {
        if (rule_indexes[@backingInt(rule)] == null) continue;
        const row = catalog.entry(rule);
        try json.write(.{
            .id = rule.code(),
            .shortDescription = SarifText{ .text = row.summary },
            .helpUri = catalog.documentationUrl(rule),
            .properties = .{ .tags = [_][]const u8{@tagName(row.tier)} },
        });
    }
    try json.endArray();
    try json.objectField("notifications");
    try json.beginArray();
    for (std.enums.values(Notice)) |notice| try json.write(.{
        .id = notice.code(),
        .shortDescription = SarifText{ .text = notice.description() },
    });
    try json.endArray();
    try json.endObject();
    try json.endObject();

    try json.objectField("columnKind");
    try json.write("unicodeCodePoints");
    try json.objectField("originalUriBaseIds");
    const root_uri = try uri.fromPath(arena, report.root_absolute);
    try json.write(.{ .SRCROOT = .{
        .uri = if (root_uri[root_uri.len - 1] == '/') root_uri else try std.mem.concat(arena, u8, &.{ root_uri, "/" }),
    } });

    try json.objectField("results");
    try json.beginArray();
    for (report.parts) |part| for (part) |entry| {
        const rule = switch (entry.subject) {
            .rule => |known| known,
            .notice => continue,
        };
        const artifact = try uri.fromRelativePath(arena, entry.path.?);
        const related = try arena.alloc(SarifLocation, entry.related.len);
        for (entry.related, related, 0..) |span, *location, id| location.* = .{
            .id = id,
            .physicalLocation = .{ .artifactLocation = .{ .uri = artifact }, .region = SarifRegion.of(span.start, span.end) },
            .message = .{ .text = span.message },
        };
        try json.write(.{
            .ruleId = rule.code(),
            .ruleIndex = rule_indexes[@backingInt(rule)].?,
            .level = sarifLevel(entry.level),
            .message = SarifText{ .text = entry.message },
            .locations = [_]SarifLocation{.{
                .physicalLocation = .{ .artifactLocation = .{ .uri = artifact }, .region = SarifRegion.of(entry.start.?, entry.end.?) },
            }},
            .relatedLocations = if (related.len == 0) null else related,
        });
    };
    try json.endArray();

    try json.objectField("invocations");
    try json.beginArray();
    try json.beginObject();
    var execution_successful = true;
    for ([_]enum { configuration, execution }{ .configuration, .execution }) |group| {
        try json.objectField(switch (group) {
            .configuration => "toolConfigurationNotifications",
            .execution => "toolExecutionNotifications",
        });
        try json.beginArray();
        for (report.parts) |part| for (part) |entry| {
            const notice = switch (entry.subject) {
                .rule => continue,
                .notice => |known| known,
            };
            if ((notice == .configuration) != (group == .configuration)) continue;
            // An error-level notification means the run failed (SARIF §3.20.21).
            if (entry.level == .@"error") execution_successful = false;
            const locations = if (entry.path) |path| locations: {
                const location = try arena.create(SarifLocation);
                location.* = .{ .physicalLocation = .{
                    .artifactLocation = .{ .uri = try uri.fromRelativePath(arena, path) },
                    .region = if (entry.start) |start| SarifRegion.of(start, entry.end orelse start) else null,
                } };
                break :locations location[0..1];
            } else null;
            try json.write(.{
                .level = sarifLevel(entry.level),
                .message = SarifText{ .text = entry.message },
                .descriptor = .{ .id = notice.code() },
                .locations = locations,
            });
        };
        try json.endArray();
    }
    try json.objectField("executionSuccessful");
    try json.write(execution_successful);
    try json.endObject();
    try json.endArray();

    try json.objectField("properties");
    try json.write(.{
        .filesChecked = report.totals.files_checked,
        .findings = report.count(.hint),
        .filesChanged = report.totals.files_changed,
        .editsApplied = report.totals.edits_applied,
    });
    try json.endObject();
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

/// One workflow command per entry, which GitHub Actions turns into an
/// annotation: `::error file=…,line=…,col=…,endLine=…,endColumn=…,title=…::…`.
/// Columns are given only for a single-line region, where GitHub reads them.
fn writeGithub(writer: *std.Io.Writer, report: Report) !void {
    for (report.parts) |part| for (part) |entry| {
        try writer.print("::{s} ", .{switch (entry.level) {
            .@"error" => "error",
            .warning => "warning",
            .information, .hint, .off => "notice",
        }});
        if (entry.path != null) {
            try writer.writeAll("file=");
            try writeCommandText(writer, entry.text_path, .property);
            try writer.writeByte(',');
        }
        if (entry.start) |start| {
            const end = entry.end orelse start;
            if (end.line == start.line) {
                try writer.print("line={d},col={d},endLine={d},endColumn={d},", .{ start.line, start.column, end.line, end.column });
            } else {
                try writer.print("line={d},endLine={d},", .{ start.line, end.line });
            }
        }
        try writer.writeAll("title=");
        try writeCommandText(writer, entry.code(), .property);
        try writer.writeAll("::");
        try writeCommandText(writer, entry.message, .message);
        try writer.writeByte('\n');
    };
}

/// Escapes `text` as the Actions toolkit does (`escapeData` and
/// `escapeProperty` in `@actions/core`): `%`, CR and LF everywhere, and the
/// `:` and `,` that would end a property.
fn writeCommandText(writer: *std.Io.Writer, text: []const u8, part: enum { property, message }) !void {
    for (text) |byte| switch (byte) {
        '%' => try writer.writeAll("%25"),
        '\r' => try writer.writeAll("%0D"),
        '\n' => try writer.writeAll("%0A"),
        ':' => try writer.writeAll(if (part == .property) "%3A" else ":"),
        ',' => try writer.writeAll(if (part == .property) "%2C" else ","),
        else => try writer.writeByte(byte),
    };
}

test "workflow commands escape their properties and message" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const entries = [_]Entry{
        .{
            .subject = .{ .rule = .discarded_error },
            .level = .warning,
            .text_path = "src/a,b:c%.zig",
            .path = "a,b:c%.zig",
            .message = "100% of\r\nthis: a, b",
            .start = .{ .line = 2, .column = 5 },
            .end = .{ .line = 2, .column = 9 },
        },
        .{
            .subject = .{ .rule = .missing_errdefer },
            .level = .@"error",
            .text_path = "main.zig",
            .path = "main.zig",
            .message = "spans lines",
            .start = .{ .line = 3, .column = 1 },
            .end = .{ .line = 5, .column = 2 },
        },
        .{
            .subject = .{ .notice = .configuration },
            .level = .warning,
            .text_path = ".",
            .path = null,
            .message = "zig-analyzer.json is malformed",
        },
        .{
            .subject = .{ .notice = .generated_source },
            .level = .information,
            .text_path = "gen.zig",
            .path = "gen.zig",
            .message = "skipped translate-c output",
        },
    };
    try writeGithub(&output.writer, .{ .root = ".", .root_absolute = "/", .parts = &.{&entries} });
    try std.testing.expectEqualStrings(
        "::warning file=src/a%2Cb%3Ac%25.zig,line=2,col=5,endLine=2,endColumn=9,title=discarded-error::100%25 of%0D%0Athis: a, b\n" ++
            "::error file=main.zig,line=3,endLine=5,title=missing-errdefer::spans lines\n" ++
            "::warning title=configuration::zig-analyzer.json is malformed\n" ++
            "::notice file=gen.zig,title=generated-source::skipped translate-c output\n",
        output.written(),
    );
}

test "fail-on thresholds count findings at or above their level" {
    const entries = [_]Entry{
        .{ .subject = .{ .rule = .discarded_error }, .level = .hint, .text_path = "a.zig", .path = "a.zig", .message = "" },
        .{ .subject = .{ .rule = .discarded_error }, .level = .warning, .text_path = "a.zig", .path = "a.zig", .message = "" },
        .{ .subject = .{ .notice = .io }, .level = .@"error", .text_path = "b.zig", .path = "b.zig", .message = "" },
        .{ .subject = .{ .notice = .generated_source }, .level = .information, .text_path = "c.zig", .path = "c.zig", .message = "" },
    };
    const report: Report = .{ .root = ".", .root_absolute = "/", .parts = &.{&entries} };
    try std.testing.expectEqual(@as(usize, 3), report.count(.hint));
    try std.testing.expectEqual(@as(usize, 2), report.count(.information));
    try std.testing.expectEqual(@as(usize, 2), report.count(.warning));
    try std.testing.expectEqual(@as(usize, 1), report.count(.@"error"));
    try std.testing.expectEqual(@as(usize, 0), report.count(.never));
}
