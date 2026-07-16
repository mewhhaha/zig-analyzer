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
    if (root.get("format")) |format_value| {
        const format = switch (format_value) {
            .object => |object| object,
            else => {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'format' must contain an object");
                return configuration;
            },
        };
        if (format.get("profile")) |profile_value| {
            const profile_name = switch (profile_value) {
                .string => |string| string,
                else => {
                    configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'format.profile' must be zig or analyzer");
                    return configuration;
                },
            };
            configuration.format_profile = if (std.mem.eql(u8, profile_name, "zig"))
                .zig
            else if (std.mem.eql(u8, profile_name, "analyzer"))
                .analyzer
            else {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'format.profile' must be zig or analyzer");
                return configuration;
            };
        }
        if (format.get("organizeImports")) |organize_value| {
            configuration.format_organize_imports = switch (organize_value) {
                .bool => |enabled| enabled,
                else => {
                    configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'format.organizeImports' must be a boolean");
                    return configuration;
                },
            };
        }
    }

    const lints_value = root.get("lints") orelse return configuration;
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
    return configuration;
}

pub fn suppressionWarning(allocator: std.mem.Allocator, source: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        const marker = "// zig-analyzer:";
        const trimmed_line = std.mem.trimStart(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed_line, marker)) continue;
        const directive = std.mem.trim(u8, trimmed_line[marker.len..], " \t\r");
        const names_text = if (std.mem.startsWith(u8, directive, "disable-next-line "))
            directive["disable-next-line ".len..]
        else if (std.mem.startsWith(u8, directive, "disable-file "))
            directive["disable-file ".len..]
        else
            return try std.fmt.allocPrint(allocator, "malformed zig-analyzer suppression on line {d}", .{line_number});
        var names = std.mem.splitScalar(u8, names_text, ',');
        var name_count: usize = 0;
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r");
            if (name.len == 0) {
                return try std.fmt.allocPrint(allocator, "empty lint rule in zig-analyzer suppression on line {d}", .{line_number});
            }
            name_count += 1;
            if (ruleNamed(name) == null) {
                return try std.fmt.allocPrint(
                    allocator,
                    "zig-analyzer suppression on line {d} contains unknown lint rule '{s}'",
                    .{ line_number, name },
                );
            }
        }
        if (name_count == 0) return try std.fmt.allocPrint(allocator, "zig-analyzer suppression on line {d} names no lint rules", .{line_number});
    }
    return null;
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
