const std = @import("std");
const rule_types = @import("types.zig");

const Configuration = rule_types.Configuration;
const Level = rule_types.Level;
const LintProfile = rule_types.LintProfile;
const Rule = rule_types.Rule;
const Tier = rule_types.Tier;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Configuration {
    var configuration = Configuration.defaults();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| {
        configuration.warning = try std.fmt.allocPrint(allocator, "zig-analyzer.json is malformed: {t}", .{err});
        return configuration;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            configuration.warning = try allocator.dupe(u8, "zig-analyzer.json must contain a JSON object");
            return configuration;
        },
    };
    const removed_format = root.get("format") != null;

    const lints_value = root.get("lints") orelse {
        if (removed_format) configuration.warning = try removedFormatWarning(allocator);
        return configuration;
    };
    const lints = switch (lints_value) {
        .object => |object| object,
        else => {
            configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints' must contain an object");
            return configuration;
        },
    };
    if (lints.get("profile")) |profile_value| {
        const profile_name = switch (profile_value) {
            .string => |string| string,
            else => {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.profile' must be official, idiomatic, or strict");
                return configuration;
            },
        };
        configuration.lint_profile = if (std.mem.eql(u8, profile_name, "official"))
            .official
        else if (std.mem.eql(u8, profile_name, "idiomatic"))
            .idiomatic
        else if (std.mem.eql(u8, profile_name, "strict"))
            .strict
        else {
            configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.profile' must be official, idiomatic, or strict");
            return configuration;
        };
        applyLintProfile(&configuration, configuration.lint_profile);
    }
    if (lints.get("correctness")) |value| {
        const level = parseLevel(value) orelse {
            configuration.warning = try invalidLevelMessage(allocator, "lints.correctness");
            return configuration;
        };
        setTier(&configuration, .correctness, level);
    }
    if (lints.get("style")) |value| {
        const level = parseLevel(value) orelse {
            configuration.warning = try invalidLevelMessage(allocator, "lints.style");
            return configuration;
        };
        setTier(&configuration, .style, level);
    }
    if (lints.get("banned")) |banned_value| {
        const entries = switch (banned_value) {
            .array => |array| array.items,
            else => {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.banned' must contain an array of objects");
                return configuration;
            },
        };
        const banned = try allocator.alloc(rule_types.BannedIdentifier, entries.len);
        for (entries, banned) |entry_value, *banned_entry| {
            const entry = switch (entry_value) {
                .object => |object| object,
                else => {
                    configuration.warning = try allocator.dupe(u8, "zig-analyzer.json entries in 'lints.banned' must be objects with a 'path' and optional 'hint'");
                    return configuration;
                },
            };
            var keys = entry.iterator();
            while (keys.next()) |pair| {
                if (std.mem.eql(u8, pair.key_ptr.*, "path") or std.mem.eql(u8, pair.key_ptr.*, "hint")) continue;
                configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer.json key 'lints.banned' contains unknown key '{s}'",
                    .{pair.key_ptr.*},
                );
                return configuration;
            }
            const path_value = entry.get("path") orelse {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json entries in 'lints.banned' must contain a 'path' string");
                return configuration;
            };
            const path = switch (path_value) {
                .string => |string| string,
                else => {
                    configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.banned' paths must be strings");
                    return configuration;
                },
            };
            if (!validBannedPath(path)) {
                configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer.json banned path '{s}' must be identifiers separated by single dots",
                    .{path},
                );
                return configuration;
            }
            const hint: ?[]const u8 = if (entry.get("hint")) |hint_value| switch (hint_value) {
                .string => |string| try allocator.dupe(u8, string),
                else => {
                    configuration.warning = try std.fmt.allocPrint(
                        allocator,
                        "zig-analyzer.json key 'lints.banned' hint for '{s}' must be a string",
                        .{path},
                    );
                    return configuration;
                },
            } else null;
            banned_entry.* = .{ .path = try allocator.dupe(u8, path), .hint = hint };
        }
        configuration.banned = banned;
        if (banned.len != 0) configuration.levels[@intFromEnum(Rule.banned_identifier)] = .warning;
    }
    if (lints.get("rules")) |rules_value| {
        const rules = switch (rules_value) {
            .object => |object| object,
            else => {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.rules' must contain an object");
                return configuration;
            },
        };
        var iterator = rules.iterator();
        while (iterator.next()) |entry| {
            const rule = ruleNamed(entry.key_ptr.*) orelse {
                configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer.json contains unknown lint rule '{s}'",
                    .{entry.key_ptr.*},
                );
                return configuration;
            };
            if (rule.tier() == .semantic) {
                configuration.warning = try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer.json rule '{s}' is an always-on semantic diagnostic and cannot be configured",
                    .{entry.key_ptr.*},
                );
                return configuration;
            }
            const level = parseLevel(entry.value_ptr.*) orelse {
                configuration.warning = try invalidLevelMessage(allocator, entry.key_ptr.*);
                return configuration;
            };
            configuration.levels[@intFromEnum(rule)] = level;
        }
    }
    if (removed_format) configuration.warning = try removedFormatWarning(allocator);
    return configuration;
}

fn removedFormatWarning(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(
        u8,
        "zig-analyzer.json key 'format' is no longer supported; formatting always delegates to zig fmt",
    );
}

pub fn suppressionWarning(allocator: std.mem.Allocator, source: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    var file_header = true;
    while (lines.next()) |line| {
        line_number += 1;
        const parsed = directiveOnLine(line);
        if (parsed) |directive| {
            if (directive.kind == .disable_file and (!file_header or lineHasCodeBeforeDirective(line, directive.comment_start))) {
                return try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer disable-file suppression on line {d} must appear before code",
                    .{line_number},
                );
            }
            if (try invalidDirectiveTargets(allocator, directive.targets, line_number)) |warning| return warning;
        } else if (containsDirectiveMarker(line)) {
            return try std.fmt.allocPrint(allocator, "malformed zig-analyzer suppression on line {d}", .{line_number});
        }
        if (lineHasCode(line)) file_header = false;
    }
    return null;
}

pub fn isSuppressed(source: []const u8, rule: Rule, offset: usize) bool {
    if (std.mem.indexOf(u8, source, "// zig-analyzer:") == null) return false;
    const target_offset = @min(offset, source.len);
    const target_line_start = lineStart(source, target_offset);
    var cursor: usize = 0;
    var disabled = false;
    var disable_next_line = false;
    var file_header = true;

    while (cursor <= target_line_start and cursor < source.len) {
        const end = lineEnd(source, cursor);
        const line = source[cursor..end];
        if (directiveOnLine(line)) |directive| {
            const targets_rule = directiveTargetsRule(directive.targets, rule);
            if (directive.kind == .disable_file and file_header and
                !lineHasCodeBeforeDirective(line, directive.comment_start) and targets_rule) return true;

            if (cursor < target_line_start) {
                switch (directive.kind) {
                    .disable => if (targets_rule) {
                        disabled = true;
                    },
                    .enable => if (targets_rule) {
                        disabled = false;
                    },
                    .disable_next_line => disable_next_line = targets_rule,
                    else => {},
                }
            } else {
                if (directive.kind == .disable_line and targets_rule) return true;
                const absolute_comment_start = cursor + directive.comment_start;
                if (absolute_comment_start <= target_offset) switch (directive.kind) {
                    .disable => if (targets_rule) {
                        disabled = true;
                    },
                    .enable => if (targets_rule) {
                        disabled = false;
                    },
                    else => {},
                };
            }
        }

        if (cursor < target_line_start) {
            const next_start = if (end < source.len) end + 1 else source.len;
            if (next_start == target_line_start and disable_next_line) return true;
            if (next_start != target_line_start) disable_next_line = false;
        }
        if (lineHasCode(line)) file_header = false;
        if (end == source.len) break;
        cursor = end + 1;
    }
    return disabled;
}

const DirectiveKind = enum {
    disable_file,
    disable_line,
    disable_next_line,
    disable,
    enable,
};

const Directive = struct {
    kind: DirectiveKind,
    targets: []const u8,
    comment_start: usize,
};

fn directiveOnLine(line: []const u8) ?Directive {
    const comment_start = lineCommentStart(line) orelse return null;
    const marker = "// zig-analyzer:";
    const comment = std.mem.trimStart(u8, line[comment_start..], " \t\r");
    if (!std.mem.startsWith(u8, comment, marker)) return null;
    const remainder = std.mem.trim(u8, comment[marker.len..], " \t\r");
    const name_end = std.mem.indexOfAny(u8, remainder, " \t\r") orelse remainder.len;
    const name = remainder[0..name_end];
    const kind: DirectiveKind = if (std.mem.eql(u8, name, "disable-file"))
        .disable_file
    else if (std.mem.eql(u8, name, "disable-line"))
        .disable_line
    else if (std.mem.eql(u8, name, "disable-next-line"))
        .disable_next_line
    else if (std.mem.eql(u8, name, "disable"))
        .disable
    else if (std.mem.eql(u8, name, "enable"))
        .enable
    else
        return null;
    return .{
        .kind = kind,
        .targets = std.mem.trim(u8, remainder[name_end..], " \t\r"),
        .comment_start = comment_start,
    };
}

fn invalidDirectiveTargets(
    allocator: std.mem.Allocator,
    targets: []const u8,
    line_number: usize,
) !?[]const u8 {
    if (targets.len == 0) return null;
    var names = std.mem.splitScalar(u8, targets, ',');
    var name_count: usize = 0;
    var names_all = false;
    while (names.next()) |raw_name| {
        const name = std.mem.trim(u8, raw_name, " \t\r");
        if (name.len == 0) {
            return try std.fmt.allocPrint(allocator, "empty lint rule in zig-analyzer suppression on line {d}", .{line_number});
        }
        name_count += 1;
        if (std.mem.eql(u8, name, "all")) {
            names_all = true;
            continue;
        }
        if (ruleNamed(name) == null) {
            return try std.fmt.allocPrint(
                allocator,
                "zig-analyzer suppression on line {d} contains unknown lint rule '{s}'",
                .{ line_number, name },
            );
        }
    }
    if (names_all and name_count != 1) {
        return try std.fmt.allocPrint(
            allocator,
            "zig-analyzer suppression on line {d} cannot combine 'all' with named rules",
            .{line_number},
        );
    }
    return null;
}

fn directiveTargetsRule(targets: []const u8, rule: Rule) bool {
    if (targets.len == 0 or std.mem.eql(u8, targets, "all")) return true;
    var names = std.mem.splitScalar(u8, targets, ',');
    while (names.next()) |raw_name| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw_name, " \t\r"), rule.code())) return true;
    }
    return false;
}

fn containsDirectiveMarker(line: []const u8) bool {
    const comment_start = lineCommentStart(line) orelse return false;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line[comment_start..], " \t\r"), "// zig-analyzer:");
}

fn lineHasCode(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    const comment_start = lineCommentStart(line) orelse return true;
    return lineHasCodeBeforeDirective(line, comment_start);
}

fn lineHasCodeBeforeDirective(line: []const u8, comment_start: usize) bool {
    return std.mem.trim(u8, line[0..comment_start], " \t\r").len != 0;
}

fn lineCommentStart(line: []const u8) ?usize {
    const trimmed = std.mem.trimStart(u8, line, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return null;
    var quote: ?u8 = null;
    var escaped = false;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |delimiter| {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == delimiter) {
                quote = null;
            }
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '\\' and line[index + 1] == '\\') return null;
        if (byte == '/' and line[index + 1] == '/') return index;
    }
    return null;
}

fn lineStart(source: []const u8, offset: usize) usize {
    return (std.mem.lastIndexOfScalar(u8, source[0..@min(offset, source.len)], '\n') orelse return 0) + 1;
}

fn lineEnd(source: []const u8, offset: usize) usize {
    const start = @min(offset, source.len);
    const relative = std.mem.indexOfScalar(u8, source[start..], '\n') orelse return source.len;
    return start + relative;
}

fn parseLevel(value: std.json.Value) ?Level {
    const name = switch (value) {
        .string => |string| string,
        else => return null,
    };
    inline for (std.meta.fields(Level)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn invalidLevelMessage(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "zig-analyzer.json key '{s}' must be off, hint, information, warning, or error",
        .{path},
    );
}

fn setTier(configuration: *Configuration, tier: Tier, level: Level) void {
    for (std.enums.values(Rule)) |rule| {
        if (rule.tier() == tier) configuration.levels[@intFromEnum(rule)] = level;
    }
}

fn applyLintProfile(configuration: *Configuration, profile: LintProfile) void {
    for (std.enums.values(Rule)) |rule| {
        const minimum_profile = rule.profile() orelse continue;
        if (@intFromEnum(profile) >= @intFromEnum(minimum_profile)) {
            configuration.levels[@intFromEnum(rule)] = .information;
        }
    }
}

fn validBannedPath(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        if (!std.zig.isValidId(segment)) return false;
    }
    return true;
}

fn ruleNamed(name: []const u8) ?Rule {
    for (std.enums.values(Rule)) |rule| {
        if (std.mem.eql(u8, name, rule.code())) return rule;
    }
    return null;
}

test "configuration reports an unknown rule" {
    const configuration = try parse(std.testing.allocator,
        \\{"lints":{"rules":{"not-a-rule":"warning"}}}
    );
    defer if (configuration.warning) |warning| std.testing.allocator.free(warning);
    try std.testing.expectEqualStrings(
        "zig-analyzer.json contains unknown lint rule 'not-a-rule'",
        configuration.warning.?,
    );
}

test "configuration parses banned identifiers and activates the rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"banned":[
        \\  {"path":"std.BoundedArray","hint":"use stdx.BoundedArrayType"},
        \\  {"path":"sleep"}
        \\]}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqual(@as(usize, 2), configuration.banned.len);
    try std.testing.expectEqualStrings("std.BoundedArray", configuration.banned[0].path);
    try std.testing.expectEqualStrings("use stdx.BoundedArrayType", configuration.banned[0].hint.?);
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.banned[1].hint);
    try std.testing.expectEqual(Level.warning, configuration.level(.banned_identifier));
}

test "an explicit rule level overrides the banned default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"banned":[{"path":"sleep"}],"rules":{"banned-identifier":"error"}}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqual(Level.@"error", configuration.level(.banned_identifier));
}

test "malformed banned configuration reports the offending key or value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source: []const u8, warning: []const u8 }{
        .{
            .source = "{\"lints\":{\"banned\":{}}}",
            .warning = "zig-analyzer.json key 'lints.banned' must contain an array of objects",
        },
        .{
            .source = "{\"lints\":{\"banned\":[\"std.BoundedArray\"]}}",
            .warning = "zig-analyzer.json entries in 'lints.banned' must be objects with a 'path' and optional 'hint'",
        },
        .{
            .source = "{\"lints\":{\"banned\":[{\"path\":\"sleep\",\"replacement\":\"nap\"}]}}",
            .warning = "zig-analyzer.json key 'lints.banned' contains unknown key 'replacement'",
        },
        .{
            .source = "{\"lints\":{\"banned\":[{\"hint\":\"use stdx\"}]}}",
            .warning = "zig-analyzer.json entries in 'lints.banned' must contain a 'path' string",
        },
        .{
            .source = "{\"lints\":{\"banned\":[{\"path\":42}]}}",
            .warning = "zig-analyzer.json key 'lints.banned' paths must be strings",
        },
        .{
            .source = "{\"lints\":{\"banned\":[{\"path\":\"std..BoundedArray\"}]}}",
            .warning = "zig-analyzer.json banned path 'std..BoundedArray' must be identifiers separated by single dots",
        },
        .{
            .source = "{\"lints\":{\"banned\":[{\"path\":\"sleep\",\"hint\":7}]}}",
            .warning = "zig-analyzer.json key 'lints.banned' hint for 'sleep' must be a string",
        },
    };
    for (cases) |case| {
        const configuration = try parse(arena.allocator(), case.source);
        try std.testing.expectEqualStrings(case.warning, configuration.warning.?);
        try std.testing.expectEqual(Level.off, configuration.level(.banned_identifier));
    }
}

test "suppression reports its source line" {
    const warning = (try suppressionWarning(
        std.testing.allocator,
        "const first = 1;\n// zig-analyzer: disable-next-line not-a-rule\n",
    )).?;
    defer std.testing.allocator.free(warning);
    try std.testing.expectEqualStrings(
        "zig-analyzer suppression on line 2 contains unknown lint rule 'not-a-rule'",
        warning,
    );
}

test "line next-line and scoped suppressions target several rules" {
    const source =
        "var line_value = 1; // zig-analyzer: disable-line never-mutated-var, redundant-boolean-if\n" ++
        "// zig-analyzer: disable-next-line never-mutated-var, needless-defer-block\n" ++
        "var next_value = 2;\n" ++
        "// zig-analyzer: disable never-mutated-var, needless-defer-block\n" ++
        "var scoped_value = 3;\n" ++
        "// zig-analyzer: enable never-mutated-var\n" ++
        "var enabled_value = 4;\n" ++
        "defer { close(); }\n" ++
        "// zig-analyzer: enable all\n" ++
        "defer { closeAgain(); }\n";

    const line_value = std.mem.indexOf(u8, source, "line_value").?;
    const next_value = std.mem.indexOf(u8, source, "next_value").?;
    const scoped_value = std.mem.indexOf(u8, source, "scoped_value").?;
    const enabled_value = std.mem.indexOf(u8, source, "enabled_value").?;
    const first_defer = std.mem.indexOf(u8, source, "defer { close(); }").?;
    const second_defer = std.mem.indexOf(u8, source, "defer { closeAgain(); }").?;

    try std.testing.expect(isSuppressed(source, .never_mutated_var, line_value));
    try std.testing.expect(!isSuppressed(source, .needless_defer_block, line_value));
    try std.testing.expect(isSuppressed(source, .never_mutated_var, next_value));
    try std.testing.expect(isSuppressed(source, .never_mutated_var, scoped_value));
    try std.testing.expect(!isSuppressed(source, .never_mutated_var, enabled_value));
    try std.testing.expect(isSuppressed(source, .needless_defer_block, first_defer));
    try std.testing.expect(!isSuppressed(source, .needless_defer_block, second_defer));
}

test "file and unnamed suppressions target all rules" {
    const file_source =
        "// zig-analyzer: disable-file never-mutated-var, needless-defer-block\n" ++
        "var value = 1;\n";
    const value = std.mem.indexOf(u8, file_source, "value").?;
    try std.testing.expect(isSuppressed(file_source, .never_mutated_var, value));
    try std.testing.expect(isSuppressed(file_source, .needless_defer_block, value));
    try std.testing.expect(!isSuppressed(file_source, .redundant_boolean_if, value));

    const scoped_source =
        "// zig-analyzer: disable\n" ++
        "var disabled = 1;\n" ++
        "// zig-analyzer: enable\n" ++
        "var enabled = 2;\n";
    const disabled = std.mem.indexOf(u8, scoped_source, "disabled").?;
    const enabled = std.mem.indexOf(u8, scoped_source, "enabled =").?;
    try std.testing.expect(isSuppressed(scoped_source, .never_mutated_var, disabled));
    try std.testing.expect(!isSuppressed(scoped_source, .never_mutated_var, enabled));
}

test "suppression validation accepts eslint-style forms and rejects ambiguous targets" {
    const valid = try suppressionWarning(
        std.testing.allocator,
        "const value = 1; // zig-analyzer: disable-line never-mutated-var, redundant-boolean-if\n" ++
            "// zig-analyzer: disable-next-line all\n" ++
            "// zig-analyzer: disable\n" ++
            "// zig-analyzer: enable needless-defer-block\n",
    );
    try std.testing.expectEqual(@as(?[]const u8, null), valid);

    const ambiguous = (try suppressionWarning(
        std.testing.allocator,
        "// zig-analyzer: disable all, never-mutated-var\n",
    )).?;
    defer std.testing.allocator.free(ambiguous);
    try std.testing.expect(std.mem.indexOf(u8, ambiguous, "cannot combine 'all'") != null);

    const misplaced = (try suppressionWarning(
        std.testing.allocator,
        "const value = 1;\n// zig-analyzer: disable-file never-mutated-var\n",
    )).?;
    defer std.testing.allocator.free(misplaced);
    try std.testing.expect(std.mem.indexOf(u8, misplaced, "must appear before code") != null);
}

test "directive markers inside strings are ignored" {
    const source =
        "const marker = \"// zig-analyzer: disable-line never-mutated-var\";\n" ++
        "const multiline = \\\\// zig-analyzer: disable-file all;\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try suppressionWarning(std.testing.allocator, source));
    const marker = std.mem.indexOf(u8, source, "marker").?;
    try std.testing.expect(!isSuppressed(source, .never_mutated_var, marker));
}
