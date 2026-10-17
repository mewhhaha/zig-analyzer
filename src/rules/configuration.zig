const std = @import("std");
const catalog = @import("catalog.zig");
const rule_types = @import("types.zig");
const lineStart = @import("../syntax/tokens.zig").lineStart;
const lineContentEnd = @import("../syntax/tokens.zig").lineContentEnd;

const Configuration = rule_types.Configuration;
const Edit = rule_types.Edit;
const Level = rule_types.Level;
const LintChanges = rule_types.LintChanges;
const LintProfile = rule_types.LintProfile;
const Override = rule_types.Override;
const Rule = rule_types.Rule;
const Tier = rule_types.Tier;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Configuration {
    var configuration = Configuration.defaults();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| {
        configuration.warning = try allocator.print("zig-analyzer.json is malformed: {t}", .{err});
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
    // A malformed value stops the parse where it is found; an unknown key
    // is reported only when everything else parsed, so a typo in one key
    // does not discard the rest of the file.
    configuration.warning = if (try parseRoot(allocator, root, &configuration)) |warning|
        warning
    else
        try unknownKeyWarning(allocator, root);
    return configuration;
}

const root_keys = [_][]const u8{ "check", "contracts", "lints", "overrides" };
const check_keys = [_][]const u8{"exclude"};
const lints_keys = [_][]const u8{ "profile", "correctness", "style", "banned", "rules" };
const override_keys = [_][]const u8{ "paths", "lints" };
const override_lints_keys = [_][]const u8{ "profile", "correctness", "style", "rules" };

fn parseRoot(allocator: std.mem.Allocator, root: std.json.ObjectMap, configuration: *Configuration) !?[]const u8 {
    if (root.get("check")) |check_value| {
        const check = switch (check_value) {
            .object => |object| object,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'check' must contain an object"),
        };
        if (check.get("exclude")) |exclude_value| {
            const excludes = switch (exclude_value) {
                .array => |array| array,
                else => return try allocator.dupe(u8, "zig-analyzer.json key 'check.exclude' must contain an array of relative paths"),
            };
            var paths: std.ArrayList([]const u8) = .empty;
            var paths_transferred = false;
            defer if (!paths_transferred) {
                for (paths.items) |path| allocator.free(path);
                paths.deinit(allocator);
            };
            for (excludes.items) |value| {
                const path = switch (value) {
                    .string => |string| string,
                    else => return try allocator.dupe(u8, "zig-analyzer.json key 'check.exclude' must contain only relative path strings"),
                };
                if (!validPathPattern(path)) {
                    return try allocator.print(
                        "zig-analyzer.json check exclusion '{s}' must be a non-empty relative path without '..' components",
                        .{path},
                    );
                }
                const owned_path = try allocator.dupe(u8, std.mem.trimEnd(u8, path, "/"));
                errdefer allocator.free(owned_path);
                try paths.append(allocator, owned_path);
            }
            configuration.check_excludes = try paths.toOwnedSlice(allocator);
            paths_transferred = true;
        }
    }

    if (root.get("contracts")) |contracts_value| {
        if (try parseContracts(allocator, contracts_value, configuration)) |warning| return warning;
    }

    if (root.get("lints")) |lints_value| {
        const lints = switch (lints_value) {
            .object => |object| object,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'lints' must contain an object"),
        };
        var selection: LintChanges = .{};
        const selection_warning = try parseLintSelection(allocator, lints, "lints", &selection);
        applySelection(configuration, selection);
        if (selection_warning) |warning| return warning;
        if (lints.get("banned")) |banned_value| {
            if (try parseBanned(allocator, banned_value, configuration)) |warning| return warning;
        }
        if (lints.get("rules")) |rules_value| {
            if (try parseLintRules(allocator, rules_value, "lints.rules", configuration)) |warning| return warning;
        }
    }

    if (root.get("overrides")) |overrides_value| {
        if (try parseOverrides(allocator, overrides_value, configuration)) |warning| return warning;
    }
    return null;
}

/// The `profile`, `correctness` and `style` keys of a `lints` object at
/// `location`, read into `changes`.
fn parseLintSelection(
    allocator: std.mem.Allocator,
    lints: std.json.ObjectMap,
    location: []const u8,
    changes: *LintChanges,
) !?[]const u8 {
    if (lints.get("profile")) |profile_value| {
        const names: []const std.json.Value = switch (profile_value) {
            .string => (&profile_value)[0..1],
            .array => |array| array.items,
            else => return try invalidProfileMessage(allocator, location),
        };
        if (names.len == 0) return try invalidProfileMessage(allocator, location);
        for (names) |name_value| {
            const name = switch (name_value) {
                .string => |string| string,
                else => return try invalidProfileMessage(allocator, location),
            };
            const lint_profile = std.meta.stringToEnum(LintProfile, name) orelse return try invalidProfileMessage(allocator, location);
            if (lint_profile == .none) return try invalidProfileMessage(allocator, location);
            changes.profiles.insert(lint_profile);
        }
    }
    inline for (.{ "correctness", "style" }) |tier_name| {
        if (lints.get(tier_name)) |value| {
            @field(changes.*, tier_name) = parseLevel(value) orelse {
                const key = try allocator.print("{s}.{s}", .{ location, tier_name });
                defer allocator.free(key);
                return try invalidLevelMessage(allocator, key);
            };
        }
    }
    return null;
}

fn invalidProfileMessage(allocator: std.mem.Allocator, location: []const u8) ![]const u8 {
    return try allocator.print(
        "zig-analyzer.json key '{s}.profile' must be official, idiomatic, strict, modernize, or disciplined, or an array of them",
        .{location},
    );
}

/// Enables the profiles of `changes`, then applies its tier levels.
fn applySelection(configuration: *Configuration, changes: LintChanges) void {
    var profiles = changes.profiles.iterator();
    while (profiles.next()) |profile| applyLintProfile(configuration, profile);
    configuration.lint_profiles.setUnion(changes.profiles);
    if (changes.correctness) |level| setTier(configuration, .correctness, level);
    if (changes.style) |level| setTier(configuration, .style, level);
}

/// Applies an override's changes on top of a file's configuration.
fn applyChanges(configuration: *Configuration, changes: LintChanges) void {
    applySelection(configuration, changes);
    for (changes.rule_levels) |entry| configuration.levels[@backingInt(entry.rule)] = entry.level;
    if (changes.function_length_limit) |limit| configuration.function_length_limit = limit;
    if (changes.line_length_limit) |limit| configuration.line_length_limit = limit;
    if (changes.line_length_allow_unsplittable) |allowed| configuration.line_length_allow_unsplittable = allowed;
    if (changes.todo_markers) |markers| configuration.todo_markers = markers;
    if (changes.function_case) |case| {
        configuration.function_case = case;
        configuration.function_case_explicit = true;
    }
}

fn parseBanned(allocator: std.mem.Allocator, banned_value: std.json.Value, configuration: *Configuration) !?[]const u8 {
    const entries = switch (banned_value) {
        .array => |array| array.items,
        else => return try allocator.dupe(u8, "zig-analyzer.json key 'lints.banned' must contain an array of objects"),
    };
    const banned = try allocator.alloc(rule_types.BannedIdentifier, entries.len);
    for (entries, banned) |entry_value, *banned_entry| {
        const entry = switch (entry_value) {
            .object => |object| object,
            else => return try allocator.dupe(u8, "zig-analyzer.json entries in 'lints.banned' must be objects with a 'path' and optional 'hint'"),
        };
        if (try unknownKey(allocator, entry, "lints.banned", &.{ "path", "hint" })) |warning| return warning;
        const path_value = entry.get("path") orelse {
            return try allocator.dupe(u8, "zig-analyzer.json entries in 'lints.banned' must contain a 'path' string");
        };
        const path = switch (path_value) {
            .string => |string| string,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'lints.banned' paths must be strings"),
        };
        if (!validBannedPath(path)) {
            return try allocator.print(
                "zig-analyzer.json banned path '{s}' must be identifiers separated by single dots",
                .{path},
            );
        }
        const hint: ?[]const u8 = if (entry.get("hint")) |hint_value| switch (hint_value) {
            .string => |string| try allocator.dupe(u8, string),
            else => return try allocator.print(
                "zig-analyzer.json key 'lints.banned' hint for '{s}' must be a string",
                .{path},
            ),
        } else null;
        banned_entry.* = .{ .path = try allocator.dupe(u8, path), .hint = hint };
    }
    configuration.banned = banned;
    if (banned.len != 0) configuration.levels[@backingInt(Rule.banned_identifier)] = .warning;
    return null;
}

/// Collects the rule levels of an override, which apply only later, to the
/// files the override matches.
const OverrideRules = struct {
    changes: LintChanges = .{},
    rule_levels: std.ArrayList(rule_types.RuleLevel) = .empty,
};

/// Reads a `rules` object into `target`: the configuration itself for the
/// top-level `lints`, or an `OverrideRules` for an override.
fn parseLintRules(
    allocator: std.mem.Allocator,
    rules_value: std.json.Value,
    location: []const u8,
    target: anytype,
) !?[]const u8 {
    const rules = switch (rules_value) {
        .object => |object| object,
        else => return try allocator.print("zig-analyzer.json key '{s}' must contain an object", .{location}),
    };
    var iterator = rules.iterator();
    while (iterator.next()) |entry| {
        const rule = ruleNamed(entry.key_ptr.*) orelse {
            const suggestion = nearestName(entry.key_ptr.*, &rule_codes);
            return try allocator.print(
                "zig-analyzer.json contains unknown lint rule '{s}'{f}",
                .{ entry.key_ptr.*, DidYouMean{ .name = suggestion } },
            );
        };
        if (rule.tier() == .semantic) {
            return try allocator.print(
                "zig-analyzer.json rule '{s}' is an always-on semantic diagnostic and cannot be configured",
                .{entry.key_ptr.*},
            );
        }
        switch (entry.value_ptr.*) {
            .string => {
                const level = parseLevel(entry.value_ptr.*) orelse return try invalidLevelMessage(allocator, entry.key_ptr.*);
                try setRuleLevel(allocator, target, rule, level);
            },
            .object => if (try parseRuleSettings(allocator, rule, entry.value_ptr.*, target)) |warning| return warning,
            else => return try invalidLevelMessage(allocator, entry.key_ptr.*),
        }
    }
    return null;
}

fn setRuleLevel(allocator: std.mem.Allocator, target: anytype, rule: Rule, level: Level) !void {
    if (@TypeOf(target) == *Configuration) {
        target.levels[@backingInt(rule)] = level;
    } else {
        try target.rule_levels.append(allocator, .{ .rule = rule, .level = level });
    }
}

/// Where a rule's settings go: straight into the configuration, or into an
/// override's changes.
fn settingsTarget(target: anytype) if (@TypeOf(target) == *Configuration) *Configuration else *LintChanges {
    return if (@TypeOf(target) == *Configuration) target else &target.changes;
}

fn parseOverrides(allocator: std.mem.Allocator, value: std.json.Value, configuration: *Configuration) !?[]const u8 {
    const entries = switch (value) {
        .array => |array| array.items,
        else => return try allocator.dupe(u8, "zig-analyzer.json key 'overrides' must contain an array of objects with 'paths' and 'lints'"),
    };
    const overrides = try allocator.alloc(Override, entries.len);
    for (entries, overrides, 0..) |entry_value, *override, index| {
        const location = try allocator.print("overrides[{d}]", .{index});
        const entry = switch (entry_value) {
            .object => |object| object,
            else => return try allocator.print("zig-analyzer.json key '{s}' must be an object with 'paths' and 'lints'", .{location}),
        };
        const path_values = switch (entry.get("paths") orelse .null) {
            .array => |array| array.items,
            else => return try allocator.print("zig-analyzer.json key '{s}.paths' must contain an array of path patterns", .{location}),
        };
        if (path_values.len == 0) return try allocator.print("zig-analyzer.json key '{s}.paths' must not be empty", .{location});
        const paths = try allocator.alloc([]const u8, path_values.len);
        for (path_values, paths) |path_value, *path| {
            const pattern = switch (path_value) {
                .string => |string| string,
                else => return try allocator.print("zig-analyzer.json key '{s}.paths' must contain only path pattern strings", .{location}),
            };
            if (!validPathPattern(pattern)) {
                return try allocator.print(
                    "zig-analyzer.json override path '{s}' must be a non-empty relative pattern without '..' components",
                    .{pattern},
                );
            }
            path.* = try allocator.dupe(u8, std.mem.trimEnd(u8, pattern, "/"));
        }
        const lints = switch (entry.get("lints") orelse .null) {
            .object => |object| object,
            else => return try allocator.print("zig-analyzer.json key '{s}.lints' must contain an object", .{location}),
        };
        var rules: OverrideRules = .{};
        const lints_location = try allocator.print("{s}.lints", .{location});
        if (try parseLintSelection(allocator, lints, lints_location, &rules.changes)) |warning| return warning;
        if (lints.get("rules")) |rules_value| {
            const rules_location = try allocator.print("{s}.rules", .{lints_location});
            if (try parseLintRules(allocator, rules_value, rules_location, &rules)) |warning| return warning;
        }
        rules.changes.rule_levels = try rules.rule_levels.toOwnedSlice(allocator);
        override.* = .{ .paths = paths, .lints = rules.changes };
    }
    configuration.overrides = overrides;
    return null;
}

/// The first unknown key in the configuration, with the nearest known key.
fn unknownKeyWarning(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]const u8 {
    if (try unknownKey(allocator, root, null, &root_keys)) |warning| return warning;
    if (root.get("check")) |check| {
        if (try unknownKey(allocator, check.object, "check", &check_keys)) |warning| return warning;
    }
    if (root.get("lints")) |lints| {
        if (try unknownKey(allocator, lints.object, "lints", &lints_keys)) |warning| return warning;
    }
    if (root.get("overrides")) |overrides| for (overrides.array.items, 0..) |entry, index| {
        var location_buffer: [64]u8 = undefined;
        const location = std.mem.print(&location_buffer, "overrides[{d}]", .{index}) catch "overrides";
        if (try unknownKey(allocator, entry.object, location, &override_keys)) |warning| return warning;
        var lints_buffer: [64]u8 = undefined;
        const lints_location = std.mem.print(&lints_buffer, "{s}.lints", .{location}) catch "overrides";
        if (try unknownKey(allocator, entry.object.get("lints").?.object, lints_location, &override_lints_keys)) |warning| return warning;
    };
    return null;
}

/// A warning naming the first key of `object` that is not in `known`; the
/// location is the dotted key of `object`, null for the top level.
fn unknownKey(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    location: ?[]const u8,
    known: []const []const u8,
) !?[]const u8 {
    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        for (known) |known_key| {
            if (std.mem.eql(u8, key, known_key)) break;
        } else {
            const suggestion = DidYouMean{ .name = nearestName(key, known) };
            if (location) |path| {
                return try allocator.print("zig-analyzer.json key '{s}' contains unknown key '{s}'{f}", .{ path, key, suggestion });
            }
            return try allocator.print("zig-analyzer.json contains unknown key '{s}'{f}", .{ key, suggestion });
        }
    }
    return null;
}

/// Formats as "; did you mean 'name'?" when there is a suggestion.
pub const DidYouMean = struct {
    name: ?[]const u8,

    pub fn format(suggestion: DidYouMean, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (suggestion.name) |name| try writer.print("; did you mean '{s}'?", .{name});
    }
};

/// The candidate closest to `name` by edit distance (a transposition counts
/// as one edit), when it is close enough to be a likely typo.
fn nearestName(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    const max_length = 64;
    if (name.len == 0 or name.len > max_length) return null;
    const allowed: usize = @max(1, @min(3, name.len / 3));
    var best: ?[]const u8 = null;
    var best_distance: usize = allowed + 1;
    for (candidates) |candidate| {
        if (candidate.len > max_length) continue;
        const length_difference = if (candidate.len > name.len) candidate.len - name.len else name.len - candidate.len;
        if (length_difference >= best_distance) continue;
        const distance = editDistance(name, candidate);
        if (distance < best_distance) {
            best_distance = distance;
            best = candidate;
        }
    }
    return best;
}

/// Optimal string alignment distance between two strings of at most 64 bytes.
fn editDistance(left: []const u8, right: []const u8) usize {
    var rows: [3][65]usize = undefined;
    for (0..right.len + 1) |column| rows[0][column] = column;
    for (left, 1..) |left_byte, row| {
        const current = &rows[row % 3];
        const above = &rows[(row - 1) % 3];
        // The row before `above`, read only from the second row on.
        const before_above = &rows[(row + 1) % 3];
        current[0] = row;
        for (right, 1..) |right_byte, column| {
            const cost: usize = @intFromBool(left_byte != right_byte);
            var distance = @min(above[column] +| 1, current[column - 1] +| 1, above[column - 1] +| cost);
            if (row > 1 and column > 1 and left_byte == right[column - 2] and left[row - 2] == right_byte) {
                distance = @min(distance, before_above[column - 2] +| 1);
            }
            current[column] = distance;
        }
    }
    return rows[left.len % 3][right.len];
}

const rule_codes = codes: {
    @setEvalBranchQuota(100_000);
    var codes: [@typeInfo(Rule).@"enum".field_names.len][]const u8 = undefined;
    for (std.enums.values(Rule), &codes) |rule, *code| code.* = rule.code();
    break :codes codes;
};

fn validPathPattern(path: []const u8) bool {
    return path.len != 0 and !std.Io.Dir.path.isAbsolute(path) and !containsParentPathComponent(path);
}

fn parseContracts(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    configuration: *Configuration,
) !?[]const u8 {
    const contracts = switch (value) {
        .object => |object| object,
        else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts' must contain an object"),
    };
    if (try unknownKey(allocator, contracts, "contracts", &.{ "imports", "resources", "arena-allocators", "must-use" })) |warning| return warning;

    if (contracts.get("imports")) |imports_value| {
        const entries = switch (imports_value) {
            .array => |array| array.items,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.imports' must contain an array of objects"),
        };
        const boundaries = try allocator.alloc(rule_types.ImportBoundary, entries.len);
        for (entries, boundaries) |entry_value, *boundary| {
            const entry = switch (entry_value) {
                .object => |object| object,
                else => return try allocator.dupe(u8, "zig-analyzer.json entries in 'contracts.imports' must contain objects with 'from' and 'deny'"),
            };
            if (try unknownKey(allocator, entry, "contracts.imports", &.{ "from", "deny" })) |warning| return warning;
            const from_result = try contractRelativePath(allocator, entry.get("from") orelse return try allocator.dupe(
                u8,
                "zig-analyzer.json entries in 'contracts.imports' require a 'from' path",
            ), "contracts.imports.from");
            const from = switch (from_result) {
                .value => |path| path,
                .warning => |warning| return warning,
            };
            const denied_values = switch (entry.get("deny") orelse return try allocator.dupe(
                u8,
                "zig-analyzer.json entries in 'contracts.imports' require a 'deny' array",
            )) {
                .array => |array| array.items,
                else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.imports.deny' must contain an array of relative paths"),
            };
            if (denied_values.len == 0) return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.imports.deny' must not be empty");
            const denied = try allocator.alloc([]const u8, denied_values.len);
            for (denied_values, denied) |denied_value, *denied_path| {
                const denied_result = try contractRelativePath(allocator, denied_value, "contracts.imports.deny");
                denied_path.* = switch (denied_result) {
                    .value => |path| path,
                    .warning => |warning| return warning,
                };
            }
            boundary.* = .{ .from = from, .denied = denied };
        }
        configuration.import_boundaries = boundaries;
        if (boundaries.len != 0) configuration.levels[@backingInt(Rule.import_boundary)] = .warning;
    }

    if (contracts.get("resources")) |resources_value| {
        const entries = switch (resources_value) {
            .array => |array| array.items,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.resources' must contain an array of objects"),
        };
        const resources = try allocator.alloc(rule_types.ResourceContract, entries.len);
        for (entries, resources) |entry_value, *resource| {
            const entry = switch (entry_value) {
                .object => |object| object,
                else => return try allocator.dupe(u8, "zig-analyzer.json entries in 'contracts.resources' must contain objects with 'acquire' and 'release'"),
            };
            if (try unknownKey(allocator, entry, "contracts.resources", &.{ "acquire", "release" })) |warning| return warning;
            const acquire_result = try callableContract(allocator, entry.get("acquire") orelse return try allocator.dupe(
                u8,
                "zig-analyzer.json entries in 'contracts.resources' require an 'acquire' callable",
            ), "contracts.resources.acquire");
            const acquire = switch (acquire_result) {
                .value => |callable| callable,
                .warning => |warning| return warning,
            };
            const release_result = try callableContract(allocator, entry.get("release") orelse return try allocator.dupe(
                u8,
                "zig-analyzer.json entries in 'contracts.resources' require a 'release' callable",
            ), "contracts.resources.release");
            const release = switch (release_result) {
                .value => |callable| callable,
                .warning => |warning| return warning,
            };
            resource.* = .{ .acquire = acquire, .release = release };
        }
        configuration.resource_contracts = resources;
    }

    if (contracts.get("arena-allocators")) |arena_allocators_value| {
        const entries = switch (arena_allocators_value) {
            .array => |array| array.items,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.arena-allocators' must contain an array of owner-member strings"),
        };
        const arena_allocators = try allocator.alloc([]const u8, entries.len);
        for (entries, arena_allocators) |entry, *arena_allocator| {
            const contract_result = try callableContract(allocator, entry, "contracts.arena-allocators");
            arena_allocator.* = switch (contract_result) {
                .value => |name| if (std.mem.findScalar(u8, name, '.') != null)
                    name
                else
                    return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.arena-allocators' entries must name an owner and allocator member"),
                .warning => |warning| return warning,
            };
        }
        configuration.arena_allocator_contracts = arena_allocators;
    }

    if (contracts.get("must-use")) |must_use_value| {
        const entries = switch (must_use_value) {
            .array => |array| array.items,
            else => return try allocator.dupe(u8, "zig-analyzer.json key 'contracts.must-use' must contain an array of callable strings"),
        };
        const callables = try allocator.alloc([]const u8, entries.len);
        for (entries, callables) |entry, *callable| {
            const callable_result = try callableContract(allocator, entry, "contracts.must-use");
            callable.* = switch (callable_result) {
                .value => |name| name,
                .warning => |warning| return warning,
            };
        }
        configuration.must_use_contracts = callables;
        if (callables.len != 0) configuration.levels[@backingInt(Rule.discarded_must_use)] = .warning;
    }
    return null;
}

const ParsedString = union(enum) { value: []const u8, warning: []const u8 };

fn contractRelativePath(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !ParsedString {
    const path = switch (value) {
        .string => |string| string,
        else => return .{ .warning = try allocator.print("zig-analyzer.json key '{s}' must be a relative path string", .{key}) },
    };
    if (path.len == 0 or std.Io.Dir.path.isAbsolute(path) or containsParentPathComponent(path)) {
        return .{ .warning = try allocator.print("zig-analyzer.json key '{s}' path '{s}' must be non-empty, relative, and contain no '..' component", .{ key, path }) };
    }
    return .{ .value = try allocator.dupe(u8, std.mem.trimEnd(u8, path, "/\\")) };
}

fn callableContract(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !ParsedString {
    const callable = switch (value) {
        .string => |string| string,
        else => return .{ .warning = try allocator.print("zig-analyzer.json key '{s}' must contain callable strings", .{key}) },
    };
    if (!validBannedPath(callable)) {
        return .{ .warning = try allocator.print("zig-analyzer.json key '{s}' callable '{s}' must be identifiers separated by single dots", .{ key, callable }) };
    }
    return .{ .value = try allocator.dupe(u8, callable) };
}

fn parseRuleSettings(
    allocator: std.mem.Allocator,
    rule: Rule,
    value: std.json.Value,
    target: anytype,
) !?[]const u8 {
    const options = catalog.entry(rule).settings.options();
    if (options.len == 0) {
        return try allocator.print(
            "zig-analyzer.json rule '{s}' accepts a severity string, not an options object",
            .{rule.code()},
        );
    }
    const settings = switch (value) {
        .object => |object| object,
        else => return try invalidLevelMessage(allocator, rule.code()),
    };
    var iterator = settings.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "level")) {
            const level = parseLevel(entry.value_ptr.*) orelse return try invalidLevelMessage(allocator, rule.code());
            try setRuleLevel(allocator, target, rule, level);
            continue;
        }
        const setting = for (options) |option| {
            if (settingKeyMatches(option, key)) break option;
        } else {
            var known: [8][]const u8 = undefined;
            known[0] = "level";
            for (options, known[1 .. options.len + 1]) |option, *name| name.* = settingKey(option);
            return try allocator.print(
                "zig-analyzer.json rule '{s}' contains unknown setting '{s}'{f}",
                .{ rule.code(), key, DidYouMean{ .name = nearestName(key, known[0 .. options.len + 1]) } },
            );
        };
        if (try applySetting(allocator, rule, setting, entry.value_ptr.*, settingsTarget(target))) |warning| return warning;
    }
    return null;
}

fn settingKeyMatches(setting: catalog.Setting, key: []const u8) bool {
    return std.mem.eql(u8, key, settingKey(setting));
}

fn settingKey(setting: catalog.Setting) []const u8 {
    return switch (setting) {
        inline else => |known| comptime catalog.Setting.key(known),
    };
}

fn applySetting(
    allocator: std.mem.Allocator,
    rule: Rule,
    setting: catalog.Setting,
    value: std.json.Value,
    /// A `*Configuration`, or the `*LintChanges` of an override.
    settings: anytype,
) !?[]const u8 {
    const key = settingKey(setting);
    switch (setting) {
        .max_lines, .max_columns => {
            const limit = positiveInteger(value) orelse return try settingTypeWarning(allocator, rule, key, "a positive integer");
            if (setting == .max_lines) settings.function_length_limit = limit else settings.line_length_limit = limit;
        },
        .allow_unsplittable => settings.line_length_allow_unsplittable = switch (value) {
            .bool => |enabled| enabled,
            else => return try settingTypeWarning(allocator, rule, key, "a boolean"),
        },
        .markers => {
            const expected = "a non-empty array of non-empty strings";
            const values = switch (value) {
                .array => |array| array.items,
                else => return try settingTypeWarning(allocator, rule, key, expected),
            };
            if (values.len == 0) return try settingTypeWarning(allocator, rule, key, expected);
            const markers = try allocator.alloc([]const u8, values.len);
            for (values, markers) |marker_value, *marker| marker.* = switch (marker_value) {
                .string => |text| if (text.len != 0) try allocator.dupe(u8, text) else return try settingTypeWarning(allocator, rule, key, expected),
                else => return try settingTypeWarning(allocator, rule, key, expected),
            };
            settings.todo_markers = markers;
        },
        .function_case => {
            const expected = "\"camelCase\" or \"snake_case\"";
            const text = switch (value) {
                .string => |string| string,
                else => return try settingTypeWarning(allocator, rule, key, expected),
            };
            settings.function_case = for (std.enums.values(rule_types.FunctionCase)) |case| {
                if (std.mem.eql(u8, text, case.text())) break case;
            } else return try settingTypeWarning(allocator, rule, key, expected);
            if (@TypeOf(settings) == *Configuration) settings.function_case_explicit = true;
        },
    }
    return null;
}

fn positiveInteger(value: std.json.Value) ?usize {
    const integer = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (integer <= 0) return null;
    return std.math.cast(usize, integer);
}

fn settingTypeWarning(allocator: std.mem.Allocator, rule: Rule, key: []const u8, expected: []const u8) ![]const u8 {
    return try allocator.print(
        "zig-analyzer.json rule '{s}' setting '{s}' must be {s}",
        .{ rule.code(), key, expected },
    );
}

fn containsParentPathComponent(path: []const u8) bool {
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
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
                return try allocator.print(
                    "zig-analyzer disable-file suppression on line {d} must appear before code",
                    .{line_number},
                );
            }
            if (try invalidDirectiveTargets(allocator, directive.targets, line_number)) |warning| return warning;
        } else if (containsDirectiveMarker(line)) {
            return try allocator.print("malformed zig-analyzer suppression on line {d}", .{line_number});
        }
        if (lineHasCode(line)) file_header = false;
    }
    return null;
}

/// The suppression directives of one file, parsed once so that every finding
/// can be checked without rescanning the source.
pub const Suppressions = struct {
    source: []const u8,
    directives: []const Placed,
    /// Per directive, a bit for each target that suppressed a finding in
    /// `filter` or `markUsed`, numbered as `Target.index` numbers them.
    used: []u64,

    const Placed = struct {
        directive: Directive,
        /// Start of the line holding the directive.
        line_start: usize,
        /// End of that line, excluding the newline.
        line_end: usize,
        /// A disable-file directive that sits in the file header, before any code.
        in_header: bool,
    };

    /// One rule list entry of one directive.
    pub const Target = struct {
        directive: usize,
        /// Position of the name in the directive's list; 0 for a directive
        /// that names no rule or `all`. Names past the 64th share the last.
        index: u6,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Suppressions {
        if (std.mem.find(u8, source, "// zig-analyzer:") == null) return .{ .source = source, .directives = &.{}, .used = &.{} };
        var placed: std.ArrayList(Placed) = .empty;
        errdefer placed.deinit(allocator);
        var cursor: usize = 0;
        var file_header = true;
        while (cursor < source.len) {
            const end = lineContentEnd(source, cursor);
            const line = source[cursor..end];
            if (directiveOnLine(line)) |directive| {
                try placed.append(allocator, .{
                    .directive = directive,
                    .line_start = cursor,
                    .line_end = end,
                    .in_header = directive.kind == .disable_file and file_header and
                        !lineHasCodeBeforeDirective(line, directive.comment_start),
                });
            }
            if (lineHasCode(line)) file_header = false;
            if (end == source.len) break;
            cursor = end + 1;
        }
        const used = try allocator.alloc(u64, placed.items.len);
        errdefer allocator.free(used);
        @memset(used, 0);
        return .{ .source = source, .directives = try placed.toOwnedSlice(allocator), .used = used };
    }

    pub fn deinit(suppressions: Suppressions, allocator: std.mem.Allocator) void {
        allocator.free(suppressions.directives);
        allocator.free(suppressions.used);
    }

    pub fn isEmpty(suppressions: Suppressions) bool {
        return suppressions.directives.len == 0;
    }

    pub fn isSuppressed(suppressions: Suppressions, rule: Rule, offset: usize) bool {
        return suppressions.suppressing(rule, offset, null) != null;
    }

    /// The directive target that suppresses `rule` at `offset`, leaving out
    /// the directive at index `skip`.
    pub fn suppressing(suppressions: Suppressions, rule: Rule, offset: usize, skip: ?usize) ?Target {
        const source = suppressions.source;
        const target_offset = @min(offset, source.len);
        const target_line_start = lineStart(source, target_offset);
        var disabled: ?Target = null;
        for (suppressions.directives, 0..) |placed, directive_index| {
            if (placed.line_start > target_line_start) break;
            if (skip == directive_index) continue;
            const directive = placed.directive;
            const hit: ?Target = if (targetIndex(directive.targets, rule)) |index|
                .{ .directive = directive_index, .index = index }
            else
                null;
            if (placed.in_header and hit != null) return hit;
            if (placed.line_start < target_line_start) {
                switch (directive.kind) {
                    .disable => if (hit != null) {
                        disabled = hit;
                    },
                    .enable => if (hit != null) {
                        disabled = null;
                    },
                    .disable_next_line => if (hit != null and placed.line_end + 1 == target_line_start) return hit,
                    else => {},
                }
            } else {
                if (directive.kind == .disable_line and hit != null) return hit;
                if (placed.line_start + directive.comment_start <= target_offset) switch (directive.kind) {
                    .disable => if (hit != null) {
                        disabled = hit;
                    },
                    .enable => if (hit != null) {
                        disabled = null;
                    },
                    else => {},
                };
            }
        }
        return disabled;
    }

    /// Whether `rule` at `offset` is suppressed, recording the directive
    /// target that suppresses it.
    pub fn markUsed(suppressions: Suppressions, rule: Rule, offset: usize) bool {
        const target = suppressions.suppressing(rule, offset, null) orelse return false;
        suppressions.used[target.directive] |= @as(u64, 1) << target.index;
        return true;
    }

    pub fn wasUsed(suppressions: Suppressions, target: Target) bool {
        return suppressions.used[target.directive] & (@as(u64, 1) << target.index) != 0;
    }

    /// Drops every finding that a directive suppresses, recording which
    /// directive targets suppressed something.
    pub fn filter(suppressions: Suppressions, found: *std.ArrayList(rule_types.Finding)) void {
        if (suppressions.isEmpty()) return;
        var kept: usize = 0;
        for (found.items) |finding| {
            if (suppressions.markUsed(finding.rule, finding.span.start)) continue;
            found.items[kept] = finding;
            kept += 1;
        }
        found.shrinkRetainingCapacity(kept);
    }

    /// The targets of the directives that suppress, in source order:
    /// every named rule of a directive, or one entry for a directive that
    /// names none or `all`. `enable` directives have none.
    pub fn targets(suppressions: *const Suppressions) TargetIterator {
        return .{ .suppressions = suppressions };
    }

    pub const NamedTarget = struct {
        target: Target,
        /// Null for a directive that names no rule or `all`; an unknown
        /// name, which `suppressionWarning` reports, is skipped.
        rule: ?Rule,
        /// The rule name, or the directive itself when it names none.
        span: std.zig.Token.Loc,
        /// The bytes to delete to drop this target: its name and a comma, or
        /// the whole directive when it is the directive's only target.
        removal: std.zig.Token.Loc,
    };

    pub const TargetIterator = struct {
        suppressions: *const Suppressions,
        directive: usize = 0,
        names: ?std.mem.SplitIterator(u8, .scalar) = null,
        index: usize = 0,

        pub fn next(iterator: *TargetIterator) ?NamedTarget {
            const suppressions = iterator.suppressions;
            while (iterator.directive < suppressions.directives.len) {
                const placed = suppressions.directives[iterator.directive];
                const directive = placed.directive;
                if (directive.kind == .enable) {
                    iterator.directive += 1;
                    continue;
                }
                const directive_removal = suppressions.directiveRemoval(placed);
                if (directive.targets.len == 0 or std.mem.eql(u8, directive.targets, "all")) {
                    defer iterator.directive += 1;
                    const comment_start = placed.line_start + directive.comment_start;
                    const comment = std.mem.trimEnd(u8, suppressions.source[comment_start..placed.line_end], " \t\r");
                    return .{
                        .target = .{ .directive = iterator.directive, .index = 0 },
                        .rule = null,
                        .span = .{ .start = comment_start, .end = comment_start + comment.len },
                        .removal = directive_removal,
                    };
                }
                if (iterator.names == null) {
                    iterator.names = std.mem.splitScalar(u8, directive.targets, ',');
                    iterator.index = 0;
                }
                const names = &iterator.names.?;
                const raw_name = names.next() orelse {
                    iterator.names = null;
                    iterator.directive += 1;
                    continue;
                };
                const index = iterator.index;
                iterator.index += 1;
                const name = std.mem.trim(u8, raw_name, " \t\r");
                const rule = ruleNamed(name) orelse continue;
                const start = @intFromPtr(name.ptr) - @intFromPtr(suppressions.source.ptr);
                const only_target = index == 0 and names.peek() == null;
                return .{
                    .target = .{ .directive = iterator.directive, .index = @intCast(@min(index, 63)) },
                    .rule = rule,
                    .span = .{ .start = start, .end = start + name.len },
                    .removal = if (only_target) directive_removal else nameRemoval(suppressions.source, directive.targets, raw_name, index == 0),
                };
            }
            return null;
        }
    };

    /// The bytes that delete a whole directive: its line when the comment
    /// stands alone, else the comment and the spaces before it.
    fn directiveRemoval(suppressions: Suppressions, placed: Placed) std.zig.Token.Loc {
        const source = suppressions.source;
        const line = source[placed.line_start..placed.line_end];
        if (!lineHasCodeBeforeDirective(line, placed.directive.comment_start)) {
            return .{ .start = placed.line_start, .end = @min(placed.line_end + 1, source.len) };
        }
        const code_end = std.mem.trimEnd(u8, line[0..placed.directive.comment_start], " \t").len;
        return .{ .start = placed.line_start + code_end, .end = placed.line_end };
    }
};

/// The bytes that delete `raw_name` from a directive's comma-separated
/// `targets`: the name and the comma after it when it comes first, else the
/// comma before it and the name.
fn nameRemoval(source: []const u8, targets: []const u8, raw_name: []const u8, first: bool) std.zig.Token.Loc {
    const base = @intFromPtr(source.ptr);
    const name_start = @intFromPtr(raw_name.ptr) - base;
    const name_end = name_start + raw_name.len;
    if (first) {
        // Up to the next name, past the comma and its spaces.
        const after = source[name_end .. @intFromPtr(targets.ptr) - base + targets.len];
        const comma = std.mem.findScalar(u8, after, ',').?;
        const trimmed = std.mem.trim(u8, raw_name, " \t\r");
        const start = @intFromPtr(trimmed.ptr) - base;
        var end = name_end + comma + 1;
        while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
        return .{ .start = start, .end = end };
    }
    // From the comma before the name to the end of the name.
    const trimmed = std.mem.trimEnd(u8, raw_name, " \t\r");
    return .{ .start = name_start - 1, .end = @intFromPtr(trimmed.ptr) - base + trimmed.len };
}

pub const SuppressionEdits = struct {
    line: Edit,
    file: Edit,
};

/// Byte edits that would suppress the rule reported at offset: one placing a
/// disable-next-line directive above the finding's line (extending a directive
/// already there), one placing a disable-file directive in the file header.
pub fn suppressionEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    rule: Rule,
    offset: usize,
) !SuppressionEdits {
    const target_line_start = lineStart(source, offset);
    const line_edit = if (extendableDirectiveEnd(source, target_line_start)) |directive_end| Edit{
        .span = .{ .start = directive_end, .end = directive_end },
        .replacement = try allocator.print(", {s}", .{rule.code()}),
    } else line_edit: {
        var indentation_end = target_line_start;
        while (indentation_end < source.len and
            (source[indentation_end] == ' ' or source[indentation_end] == '\t')) indentation_end += 1;
        break :line_edit Edit{
            .span = .{ .start = target_line_start, .end = target_line_start },
            .replacement = try allocator.print(
                "{s}// zig-analyzer: disable-next-line {s}\n",
                .{ source[target_line_start..indentation_end], rule.code() },
            ),
        };
    };
    const header_end = fileHeaderEnd(source);
    return .{
        .line = line_edit,
        .file = .{
            .span = .{ .start = header_end, .end = header_end },
            .replacement = try allocator.print("// zig-analyzer: disable-file {s}\n", .{rule.code()}),
        },
    };
}

/// End of the rule list of a disable-next-line directive directly above the
/// target line, when appending another rule name keeps the directive valid.
fn extendableDirectiveEnd(source: []const u8, target_line_start: usize) ?usize {
    if (target_line_start == 0) return null;
    const previous_line_start = lineStart(source, target_line_start - 1);
    const previous_line = source[previous_line_start .. target_line_start - 1];
    const directive = directiveOnLine(previous_line) orelse return null;
    if (directive.kind != .disable_next_line) return null;
    if (directive.targets.len == 0 or std.mem.eql(u8, directive.targets, "all")) return null;
    return previous_line_start + std.mem.trimEnd(u8, previous_line, " \t\r").len;
}

/// Start of the first line containing code; a disable-file directive inserted
/// here stays within the file header after any module doc comments.
fn fileHeaderEnd(source: []const u8) usize {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const end = lineContentEnd(source, cursor);
        if (lineHasCode(source[cursor..end])) return cursor;
        if (end == source.len) break;
        cursor = end + 1;
    }
    return cursor;
}

const DirectiveKind = enum {
    disable_file,
    disable_line,
    disable_next_line,
    disable,
    enable,
};

const directive_kinds = std.StaticStringMap(DirectiveKind).initComptime(.{
    .{ "disable-file", .disable_file },
    .{ "disable-line", .disable_line },
    .{ "disable-next-line", .disable_next_line },
    .{ "disable", .disable },
    .{ "enable", .enable },
});

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
    const name_end = std.mem.findAny(u8, remainder, " \t\r") orelse remainder.len;
    const name = remainder[0..name_end];
    const kind = directive_kinds.get(name) orelse return null;
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
            return try allocator.print("empty lint rule in zig-analyzer suppression on line {d}", .{line_number});
        }
        name_count += 1;
        if (std.mem.eql(u8, name, "all")) {
            names_all = true;
            continue;
        }
        if (ruleNamed(name) == null) {
            return try allocator.print(
                "zig-analyzer suppression on line {d} contains unknown lint rule '{s}'{f}",
                .{ line_number, name, DidYouMean{ .name = nearestName(name, &rule_codes) } },
            );
        }
    }
    if (names_all and name_count != 1) {
        return try allocator.print(
            "zig-analyzer suppression on line {d} cannot combine 'all' with named rules",
            .{line_number},
        );
    }
    return null;
}

/// The position of `rule` in a directive's rule list, 0 for a directive
/// that names no rule or `all`; null when the directive does not target it.
fn targetIndex(targets: []const u8, rule: Rule) ?u6 {
    if (targets.len == 0 or std.mem.eql(u8, targets, "all")) return 0;
    var names = std.mem.splitScalar(u8, targets, ',');
    var index: usize = 0;
    while (names.next()) |raw_name| : (index += 1) {
        if (std.mem.eql(u8, std.mem.trim(u8, raw_name, " \t\r"), rule.code())) return @intCast(@min(index, 63));
    }
    return null;
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

fn parseLevel(value: std.json.Value) ?Level {
    const name = switch (value) {
        .string => |string| string,
        else => return null,
    };
    inline for (@typeInfo(Level).@"enum".field_names, @typeInfo(Level).@"enum".field_values) |field_name, field_value| {
        if (std.mem.eql(u8, name, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn invalidLevelMessage(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try allocator.print(
        "zig-analyzer.json key '{s}' must be off, hint, information, warning, or error",
        .{path},
    );
}

/// Sets the level of the tier's rules that are selected: on by default (the
/// correctness rules) or enabled by a selected profile. A tier setting never
/// turns on a rule that only a profile it lacks, or its name, enables.
fn setTier(configuration: *Configuration, tier: Tier, level: Level) void {
    for (std.enums.values(Rule)) |rule| {
        const row = catalog.entry(rule);
        if (row.tier != tier or row.needs != .nothing) continue;
        const selected = if (row.profile) |minimum_profile|
            profilesInclude(configuration.lint_profiles, minimum_profile)
        else
            row.defaultLevel() != .off;
        if (selected) configuration.levels[@backingInt(rule)] = level;
    }
}

fn applyLintProfile(configuration: *Configuration, profile: LintProfile) void {
    for (std.enums.values(Rule)) |rule| {
        const minimum_profile = rule.profile() orelse continue;
        if (profileIncludes(profile, minimum_profile)) {
            configuration.levels[@backingInt(rule)] = .information;
        }
    }
}

fn profilesInclude(selected: std.EnumSet(LintProfile), required: LintProfile) bool {
    var profiles = selected.iterator();
    while (profiles.next()) |profile| {
        if (profileIncludes(profile, required)) return true;
    }
    return false;
}

fn profileIncludes(selected: LintProfile, required: LintProfile) bool {
    return switch (selected) {
        .none => false,
        .official => required == .official,
        .idiomatic => required == .official or required == .idiomatic,
        .strict => required == .official or required == .idiomatic or required == .strict,
        .modernize => required == .modernize,
        .disciplined => required == .disciplined,
    };
}

/// `configuration` for the source at `path`, relative to the project root,
/// which the CLI and the language server apply alike: the built-in
/// relaxations for the path's role, then every override whose `paths` match.
///
/// Test sources and `build.zig` may print rather than log. Test, fuzz and
/// script sources are not production code, so the rules the `disciplined`
/// profile enables do not apply to them, and their `pub` declarations (shared
/// fixtures, script helpers) are no library API. A `build.zig` exports its
/// declarations to dependent build scripts, and a `testing/` directory may be
/// a library's testing API (`std.testing`). Tests and fixtures also skip
/// `test_relaxed_rules`.
pub fn forPath(configuration: Configuration, path: []const u8) Configuration {
    var file_configuration = forRole(configuration, path);
    for (configuration.overrides) |override| {
        for (override.paths) |pattern| {
            if (!pathMatches(pattern, path)) continue;
            applyChanges(&file_configuration, override.lints);
            break;
        }
    }
    return file_configuration;
}

fn forRole(configuration: Configuration, path: []const u8) Configuration {
    const role = sourceRole(path);
    if (role == .production) return configuration;
    var file_configuration = configuration;
    const build_script = std.mem.eql(u8, std.Io.Dir.path.basename(path), "build.zig");
    const testing_library = testingLibrary(path);
    if (role == .testing or role == .fixture or build_script) {
        file_configuration.levels[@backingInt(Rule.prefer_log_over_print)] = .off;
    }
    if (!build_script and !testing_library) {
        file_configuration.levels[@backingInt(Rule.public_declaration_docs)] = .off;
    }
    if ((role == .testing and !testing_library) or role == .fixture) {
        for (test_relaxed_rules) |rule| file_configuration.levels[@backingInt(rule)] = .off;
    }
    for (discipline_rules) |rule| file_configuration.levels[@backingInt(rule)] = .off;
    return file_configuration;
}

/// Style rules whose reason does not carry over to tests and the fixtures
/// they read: assertions and expected values make long lines that wrap
/// worse than they read, declarations exist to be inspected by a harness
/// rather than called, and a literal `true` or `false` in a table of cases
/// is the expected outcome, not a hidden flag. Correctness rules stay on.
const test_relaxed_rules = [_]Rule{ .line_length, .unused_private_declaration, .literal_boolean_argument };

/// `configuration` for a file a tool generated (`generated_source`): its
/// style is the generator's, so only correctness and semantic findings, which
/// the generator can be fixed for, remain.
pub fn forGeneratedSource(configuration: Configuration) Configuration {
    var file_configuration = configuration;
    for (std.enums.values(Rule)) |rule| {
        if (rule.tier() == .style) file_configuration.levels[@backingInt(rule)] = .off;
    }
    return file_configuration;
}

/// The rules whose lowest profile is `disciplined`.
const discipline_rules = rules: {
    @setEvalBranchQuota(100_000);
    var found: []const Rule = &.{};
    for (std.enums.values(Rule)) |rule| {
        if (catalog.entry(rule).profile == .disciplined) found = found ++ .{rule};
    }
    break :rules found;
};

const SourceRole = enum { production, testing, fixture, fuzzing, script };

/// What the source at `path` is for, judged by the conventions Zig projects
/// name these files with: `*_test.zig`, `*_tests.zig` and `test/`, `tests/`
/// or `testing/` directories hold tests; `fixtures/`, `fixture/`,
/// `testdata/` and `test_data/` directories hold inputs that tests read; a
/// `fuzz` anywhere in a component marks a fuzzer (`forest_fuzz.zig`,
/// `fuzz/`); `build.zig` and the `build/`, `scripts/` and `tools/`
/// directories hold build and maintenance scripts.
fn sourceRole(path: []const u8) SourceRole {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig") or std.mem.endsWith(u8, basename, "_tests.zig")) return .testing;
    if (std.mem.eql(u8, basename, "build.zig")) return .script;
    var role: SourceRole = .production;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (components.peek() == null) break;
        if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests") or
            std.mem.eql(u8, component, "testing")) return .testing;
        if (std.mem.eql(u8, component, "fixtures") or std.mem.eql(u8, component, "fixture") or
            std.mem.eql(u8, component, "testdata") or std.mem.eql(u8, component, "test_data")) return .fixture;
        if (role != .production) continue;
        if (std.mem.find(u8, component, "fuzz") != null) {
            role = .fuzzing;
        } else if (std.mem.eql(u8, component, "build") or std.mem.eql(u8, component, "scripts") or
            std.mem.eql(u8, component, "tools"))
        {
            role = .script;
        }
    }
    if (role == .production and std.mem.find(u8, basename, "fuzz") != null) role = .fuzzing;
    return role;
}

/// Whether `path` is a test source only by lying under a `testing/`
/// directory, which libraries also use for the helpers they publish.
fn testingLibrary(path: []const u8) bool {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.endsWith(u8, basename, "_test.zig") or std.mem.endsWith(u8, basename, "_tests.zig")) return false;
    var testing = false;
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests") or
            std.mem.find(u8, component, "fuzz") != null) return false;
        if (std.mem.eql(u8, component, "testing")) testing = true;
    }
    return testing;
}

/// Whether `path` (relative, `/` or `\\` separated) lies at or below a path
/// that `pattern` matches. In a pattern, `*` matches any run of characters
/// within one path component, `?` one character, and a `**` component any
/// number of components; a pattern without them names one path and
/// everything below it, as the entries of `check.exclude` always have.
pub fn pathMatches(pattern: []const u8, path: []const u8) bool {
    var pattern_rest = pattern;
    const pattern_component = nextPathComponent(&pattern_rest) orelse return true;
    if (std.mem.eql(u8, pattern_component, "**")) {
        var path_rest = path;
        while (true) {
            if (pathMatches(pattern_rest, path_rest)) return true;
            _ = nextPathComponent(&path_rest) orelse return false;
        }
    }
    var path_rest = path;
    const path_component = nextPathComponent(&path_rest) orelse return false;
    return componentMatches(pattern_component, path_component) and pathMatches(pattern_rest, path_rest);
}

/// The next non-empty component of `rest` other than `.`, advancing it.
fn nextPathComponent(rest: *[]const u8) ?[]const u8 {
    while (rest.len != 0) {
        const end = std.mem.findAny(u8, rest.*, "/\\") orelse rest.len;
        const component = rest.*[0..end];
        rest.* = rest.*[@min(end + 1, rest.len)..];
        if (component.len != 0 and !std.mem.eql(u8, component, ".")) return component;
    }
    return null;
}

/// Glob match of one path component, with `*` and `?`.
fn componentMatches(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star: ?usize = null;
    var star_text: usize = 0;
    while (text_index < text.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index])) {
            pattern_index += 1;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            star_text = text_index;
            pattern_index += 1;
        } else if (star) |star_index| {
            pattern_index = star_index + 1;
            star_text += 1;
            text_index = star_text;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn validBannedPath(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        if (!std.zig.isValidId(segment)) return false;
    }
    return true;
}

pub fn ruleNamed(name: []const u8) ?Rule {
    for (std.enums.values(Rule)) |rule| {
        if (std.mem.eql(u8, name, rule.code())) return rule;
    }
    return null;
}

/// The rule code closest to `name`, when it is close enough to be a likely
/// typo of it.
pub fn nearestRuleCode(name: []const u8) ?[]const u8 {
    return nearestName(name, &rule_codes);
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

test "modernize and disciplined profiles enable only their rule families" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const modernize = try parse(arena.allocator(),
        \\{"lints":{"profile":"modernize"}}
    );
    try std.testing.expectEqual(Level.information, modernize.level(.modernize_managed_container));
    inline for (.{ Rule.modernize_extern_bitcast, .modernize_global_linkage, .modernize_array_list_access, .modernize_container_init }) |rule| {
        try std.testing.expectEqual(Level.information, modernize.level(rule));
    }
    try std.testing.expectEqual(Level.off, modernize.level(.prefer_div_ceil));
    try std.testing.expectEqual(Level.off, modernize.level(.function_length));
    try std.testing.expectEqual(Level.off, modernize.level(.prefer_range_for));

    const disciplined = try parse(arena.allocator(),
        \\{"lints":{"profile":"disciplined"}}
    );
    try std.testing.expectEqual(Level.information, disciplined.level(.function_length));
    try std.testing.expectEqual(Level.off, disciplined.level(.modernize_deprecated_io));
    try std.testing.expectEqual(Level.off, disciplined.level(.line_length));
    try std.testing.expectEqual(Level.off, disciplined.level(.todo_comment));

    const idiomatic = try parse(arena.allocator(),
        \\{"lints":{"profile":"idiomatic"}}
    );
    try std.testing.expectEqual(Level.information, idiomatic.level(.prefer_range_for));
    try std.testing.expectEqual(Level.information, idiomatic.level(.prefer_div_ceil));
    try std.testing.expectEqual(Level.off, idiomatic.level(.modernize_extern_bitcast));
    try std.testing.expectEqual(Level.off, idiomatic.level(.exposed_private_type));
    try std.testing.expectEqual(Level.off, idiomatic.level(.allocator_first_parameter));
    try std.testing.expectEqual(Level.off, idiomatic.level(.minority_naming_style));

    const strict = try parse(arena.allocator(),
        \\{"lints":{"profile":"strict"}}
    );
    try std.testing.expectEqual(Level.information, strict.level(.exposed_private_type));
    try std.testing.expectEqual(Level.information, strict.level(.exposed_private_error_set));
}

test "tier settings preserve contract and compiler fact opt-ins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"correctness":"error","style":"information"}}
    );

    try std.testing.expectEqual(Level.off, configuration.level(.import_boundary));
    try std.testing.expectEqual(Level.off, configuration.level(.discarded_must_use));
    try std.testing.expectEqual(Level.off, configuration.level(.configuration_divergent_api));
    try std.testing.expectEqual(Level.off, configuration.level(.unreachable_public_declaration));
    try std.testing.expectEqual(Level.@"error", configuration.level(.missing_errdefer));
}

test "tier settings set the level of selected rules and turn no opt-in rule on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Without a profile, no style rule is selected.
    const bare = try parse(arena.allocator(),
        \\{"lints":{"style":"warning"}}
    );
    for ([_]Rule{ .line_length, .non_idiomatic_name, .public_declaration_docs, .function_length, .todo_comment }) |rule| {
        try std.testing.expectEqual(Level.off, bare.level(rule));
    }

    const idiomatic = try parse(arena.allocator(),
        \\{"lints":{"profile":"idiomatic","style":"warning","rules":{"line-length":"hint"}}}
    );
    try std.testing.expectEqual(Level.warning, idiomatic.level(.non_idiomatic_name));
    try std.testing.expectEqual(Level.warning, idiomatic.level(.prefer_range_for));
    try std.testing.expectEqual(Level.hint, idiomatic.level(.line_length));
    // The strict and disciplined profiles stay opt-in.
    try std.testing.expectEqual(Level.off, idiomatic.level(.public_declaration_docs));
    try std.testing.expectEqual(Level.off, idiomatic.level(.function_length));
    try std.testing.expectEqual(Level.off, idiomatic.level(.modernize_bitcast));

    const combined = try parse(arena.allocator(),
        \\{"lints":{"profile":["strict","disciplined"],"style":"hint","correctness":"off"}}
    );
    try std.testing.expect(combined.lint_profiles.contains(.strict) and combined.lint_profiles.contains(.disciplined));
    try std.testing.expectEqual(Level.hint, combined.level(.public_declaration_docs));
    try std.testing.expectEqual(Level.hint, combined.level(.non_idiomatic_name));
    try std.testing.expectEqual(Level.hint, combined.level(.function_length));
    try std.testing.expectEqual(Level.off, combined.level(.modernize_bitcast));
    try std.testing.expectEqual(Level.off, combined.level(.line_length));
    try std.testing.expectEqual(Level.off, combined.level(.missing_errdefer));
    try std.testing.expectEqual(Level.@"error", combined.level(.unresolved_call));

    for ([_][]const u8{
        \\{"lints":{"profile":[]}}
        ,
        \\{"lints":{"profile":["strict",3]}}
        ,
        \\{"lints":{"profile":"none"}}
    }) |source| {
        const rejected = try parse(arena.allocator(), source);
        try std.testing.expect(std.mem.find(u8, rejected.warning.?, "'lints.profile' must be") != null);
    }
}

test "overrides apply to matching paths after the built-in relaxations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{
        \\  "lints": {"profile": "idiomatic", "correctness": "off", "rules": {"line-length": "warning"}},
        \\  "overrides": [
        \\    {"paths": ["tests/**"], "lints": {"style": "off", "rules": {"line-length": {"level": "hint", "max-columns": 120}}}},
        \\    {"paths": ["src/core", "src/**/*_unsafe.zig"], "lints": {"correctness": "error", "profile": "disciplined"}},
        \\    {"paths": ["src/core/legacy.zig"], "lints": {"rules": {"missing-errdefer": "off"}}}
        \\  ]
        \\}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqual(@as(usize, 3), configuration.overrides.len);

    const production = forPath(configuration, "src/main.zig");
    try std.testing.expectEqual(Level.off, production.level(.missing_errdefer));
    try std.testing.expectEqual(Level.warning, production.level(.line_length));
    try std.testing.expectEqual(@as(usize, 100), production.line_length_limit);

    // A test file: line-length is relaxed for tests, and the override turns
    // it back on with its own limit after turning the style tier off.
    const test_file = forPath(configuration, "tests/parser/walk.zig");
    try std.testing.expectEqual(Level.off, test_file.level(.non_idiomatic_name));
    try std.testing.expectEqual(Level.hint, test_file.level(.line_length));
    try std.testing.expectEqual(@as(usize, 120), test_file.line_length_limit);

    const core = forPath(configuration, "src/core/db/table.zig");
    try std.testing.expectEqual(Level.@"error", core.level(.missing_errdefer));
    try std.testing.expectEqual(Level.@"error", core.level(.unreleased_allocation));
    try std.testing.expectEqual(Level.information, core.level(.function_length));
    try std.testing.expect(core.lint_profiles.contains(.disciplined));
    try std.testing.expectEqual(Level.@"error", forPath(configuration, "src/io/read_unsafe.zig").level(.missing_errdefer));
    try std.testing.expectEqual(Level.off, forPath(configuration, "src/io/read.zig").level(.missing_errdefer));

    // Later overrides win.
    const legacy = forPath(configuration, "src/core/legacy.zig");
    try std.testing.expectEqual(Level.off, legacy.level(.missing_errdefer));
    try std.testing.expectEqual(Level.@"error", legacy.level(.unreleased_allocation));
}

test "malformed overrides name the offending entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "{\"overrides\":{}}", .expected = "key 'overrides' must contain an array" },
        .{ .source = "{\"overrides\":[{\"lints\":{}}]}", .expected = "key 'overrides[0].paths' must contain an array" },
        .{ .source = "{\"overrides\":[{\"paths\":[],\"lints\":{}}]}", .expected = "key 'overrides[0].paths' must not be empty" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"../x\"],\"lints\":{}}]}", .expected = "override path '../x'" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"x\"]}]}", .expected = "key 'overrides[0].lints' must contain an object" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"x\"],\"lints\":{\"style\":\"loud\"}}]}", .expected = "key 'overrides[0].lints.style' must be off" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"x\"],\"lints\":{\"rules\":{\"line-lenght\":\"hint\"}}}]}", .expected = "unknown lint rule 'line-lenght'; did you mean 'line-length'?" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"x\"],\"lints\":{\"banned\":[]}}]}", .expected = "key 'overrides[0].lints' contains unknown key 'banned'" },
        .{ .source = "{\"overrides\":[{\"paths\":[\"x\"],\"path\":[],\"lints\":{}}]}", .expected = "key 'overrides[0]' contains unknown key 'path'; did you mean 'paths'?" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source {s}\n", .{case.source});
        const configuration = try parse(arena.allocator(), case.source);
        try std.testing.expect(std.mem.find(u8, configuration.warning.?, case.expected) != null);
    }
}

test "unknown keys are reported with the nearest known key without discarding the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source: []const u8, warning: []const u8 }{
        .{
            .source = "{\"lint\":{}}",
            .warning = "zig-analyzer.json contains unknown key 'lint'; did you mean 'lints'?",
        },
        .{
            .source = "{\"lints\":{\"rulez\":{},\"rules\":{\"line-length\":\"warning\"}}}",
            .warning = "zig-analyzer.json key 'lints' contains unknown key 'rulez'; did you mean 'rules'?",
        },
        .{
            .source = "{\"check\":{\"excludes\":[]}}",
            .warning = "zig-analyzer.json key 'check' contains unknown key 'excludes'; did you mean 'exclude'?",
        },
        .{
            .source = "{\"contracts\":{\"must_use\":[]}}",
            .warning = "zig-analyzer.json key 'contracts' contains unknown key 'must_use'; did you mean 'must-use'?",
        },
        .{
            .source = "{\"lints\":{\"rules\":{\"line-length\":{\"max-column\":90}}}}",
            .warning = "zig-analyzer.json rule 'line-length' contains unknown setting 'max-column'; did you mean 'max-columns'?",
        },
        .{
            .source = "{\"lints\":{\"rules\":{\"unsued-import\":\"warning\"}}}",
            .warning = "zig-analyzer.json contains unknown lint rule 'unsued-import'; did you mean 'unused-import'?",
        },
        .{
            .source = "{\"something-else\":true}",
            .warning = "zig-analyzer.json contains unknown key 'something-else'",
        },
    };
    for (cases) |case| {
        const configuration = try parse(arena.allocator(), case.source);
        try std.testing.expectEqualStrings(case.warning, configuration.warning.?);
    }
    // The known keys beside an unknown one still apply.
    const typo = try parse(arena.allocator(), cases[1].source);
    try std.testing.expectEqual(Level.warning, typo.level(.line_length));
}

test "path patterns match components, globs and everything below a match" {
    const cases = [_]struct { pattern: []const u8, path: []const u8, matches: bool }{
        .{ .pattern = "tests", .path = "tests/a.zig", .matches = true },
        .{ .pattern = "tests", .path = "tests", .matches = true },
        .{ .pattern = "tests", .path = "tests_extra/a.zig", .matches = false },
        .{ .pattern = "src/gen", .path = "src\\gen\\a.zig", .matches = true },
        .{ .pattern = "tests/**", .path = "tests/deep/a.zig", .matches = true },
        .{ .pattern = "**/*_test.zig", .path = "parser_test.zig", .matches = true },
        .{ .pattern = "**/*_test.zig", .path = "src/lex/lexer_test.zig", .matches = true },
        .{ .pattern = "**/*_test.zig", .path = "src/lex/lexer.zig", .matches = false },
        .{ .pattern = "src/*.zig", .path = "src/main.zig", .matches = true },
        .{ .pattern = "src/*.zig", .path = "src/sub/main.zig", .matches = false },
        .{ .pattern = "src/**/gen?.zig", .path = "src/a/b/gen1.zig", .matches = true },
        .{ .pattern = "src/**/gen?.zig", .path = "src/gen12.zig", .matches = false },
        .{ .pattern = "./vendor/", .path = "vendor/lib.zig", .matches = true },
        .{ .pattern = "*", .path = "anything/at/all.zig", .matches = true },
    };
    for (cases) |case| {
        errdefer std.debug.print("pattern {s} path {s}\n", .{ case.pattern, case.path });
        try std.testing.expectEqual(case.matches, pathMatches(std.mem.trimEnd(u8, case.pattern, "/"), case.path));
    }
}

test "tests and fixtures are not held to layout and hygiene style rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"profile":"strict","rules":{"line-length":"warning","unused-private-declaration":"warning"}}}
    );
    for ([_][]const u8{ "tests/analysis/basic.zig", "src/parser_tests.zig", "fixtures/hover_types.zig", "src/font/testdata/glyph.zig" }) |path| {
        errdefer std.debug.print("path {s} was not relaxed\n", .{path});
        const relaxed = forPath(configuration, path);
        for (test_relaxed_rules) |rule| try std.testing.expectEqual(Level.off, relaxed.level(rule));
        // Naming and correctness hold everywhere.
        try std.testing.expectEqual(Level.information, relaxed.level(.non_idiomatic_name));
        try std.testing.expectEqual(Level.warning, relaxed.level(.missing_errdefer));
    }
    // A testing library publishes API and keeps its rules; so do scripts.
    for ([_][]const u8{ "lib/std/testing/FailingAllocator.zig", "tools/release.zig", "src/main.zig", "src/fixtures.zig" }) |path| {
        errdefer std.debug.print("path {s} was relaxed\n", .{path});
        try std.testing.expectEqual(Level.warning, forPath(configuration, path).level(.line_length));
    }
}

test "generated sources keep only correctness and semantic rules" {
    var configuration = Configuration.defaults();
    configuration.levels[@backingInt(Rule.line_length)] = .warning;
    const generated = forGeneratedSource(configuration);
    try std.testing.expectEqual(Level.off, generated.level(.line_length));
    try std.testing.expectEqual(Level.warning, generated.level(.missing_errdefer));
    try std.testing.expectEqual(Level.@"error", generated.level(.unresolved_call));
}

test "threshold and marker rules parse typed settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"rules":{
        \\  "function-length":{"level":"warning","max-lines":90},
        \\  "line-length":{"level":"information","max-columns":120,"allow-unsplittable":false},
        \\  "todo-comment":{"level":"hint","markers":["DEBT","LATER"]}
        \\}}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqual(@as(usize, 90), configuration.function_length_limit);
    try std.testing.expectEqual(@as(usize, 120), configuration.line_length_limit);
    try std.testing.expect(!configuration.line_length_allow_unsplittable);
    try std.testing.expectEqualStrings("DEBT", configuration.todo_markers[0]);
    try std.testing.expectEqual(Level.warning, configuration.level(.function_length));
    try std.testing.expectEqual(Level.information, configuration.level(.line_length));
    try std.testing.expectEqual(Level.hint, configuration.level(.todo_comment));
}

test "test, fuzz and script paths are not held to the discipline rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"profile":"disciplined","rules":{"prefer-log-over-print":"warning"}}}
    );
    const relaxed_paths = [_][]const u8{
        "tests/walk.zig",           "src/parser_test.zig", "src/testing/storage.zig", "src/lsm/forest_fuzz.zig",
        "src/fuzz/terminal.zig",    "build.zig",           "src/scripts/release.zig", "tools/update_cpu.zig",
        "src/build/SharedDeps.zig",
    };
    for (relaxed_paths) |path| {
        errdefer std.debug.print("path {s} was not relaxed\n", .{path});
        const relaxed = forPath(configuration, path);
        try std.testing.expectEqual(Level.off, relaxed.level(.function_length));
        try std.testing.expectEqual(Level.off, relaxed.level(.allocation_after_init));
        try std.testing.expectEqual(Level.off, relaxed.level(.recursive_call));
        try std.testing.expectEqual(Level.off, relaxed.level(.unbounded_loop));
    }
    const production_paths = [_][]const u8{ "src/main.zig", "src/build.zig.zon.zig", "src/tools.zig", "Build/Step.zig", "src/contest.zig" };
    for (production_paths) |path| {
        errdefer std.debug.print("path {s} was relaxed\n", .{path});
        try std.testing.expectEqual(Level.information, forPath(configuration, path).level(.function_length));
    }
    // Printing stays a production-only concern for tests and build.zig.
    try std.testing.expectEqual(Level.off, forPath(configuration, "tests/walk.zig").level(.prefer_log_over_print));
    try std.testing.expectEqual(Level.warning, forPath(configuration, "tools/update_cpu.zig").level(.prefer_log_over_print));
}

test "only production sources and build.zig publish documented API" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"rules":{"public-declaration-docs":"warning"}}}
    );
    for ([_][]const u8{ "src/check_tests.zig", "tests/fixtures.zig", "src/lsm/forest_fuzz.zig", "tools/release.zig" }) |path| {
        try std.testing.expectEqual(Level.off, forPath(configuration, path).level(.public_declaration_docs));
    }
    for ([_][]const u8{ "src/main.zig", "build.zig", "lib/std/testing/FailingAllocator.zig" }) |path| {
        try std.testing.expectEqual(Level.warning, forPath(configuration, path).level(.public_declaration_docs));
    }
}

test "naming rule parses its function case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"rules":{"non-idiomatic-name":{"level":"warning","function-case":"snake_case"}}}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqual(rule_types.FunctionCase.snake_case, configuration.function_case);
    try std.testing.expect(configuration.function_case_explicit);
    try std.testing.expectEqual(Level.warning, configuration.level(.non_idiomatic_name));
    const rejected = try parse(arena.allocator(),
        \\{"lints":{"rules":{"non-idiomatic-name":{"function-case":"kebab-case"}}}}
    );
    try std.testing.expectEqualStrings(
        "zig-analyzer.json rule 'non-idiomatic-name' setting 'function-case' must be \"camelCase\" or \"snake_case\"",
        rejected.warning.?,
    );
    try std.testing.expectEqual(rule_types.FunctionCase.camel_case, rejected.function_case);
    try std.testing.expect(!rejected.function_case_explicit);
    // Only a file an override's `function-case` matches has an explicit case.
    const overridden = try parse(arena.allocator(),
        \\{"lints":{"rules":{"non-idiomatic-name":"warning"}},
        \\ "overrides":[{"paths":["src/ffi"],"lints":{"rules":{"non-idiomatic-name":{"function-case":"snake_case"}}}}]}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), overridden.warning);
    try std.testing.expect(!overridden.function_case_explicit);
    try std.testing.expect(!forPath(overridden, "src/main.zig").function_case_explicit);
    const ffi = forPath(overridden, "src/ffi/c.zig");
    try std.testing.expect(ffi.function_case_explicit);
    try std.testing.expectEqual(rule_types.FunctionCase.snake_case, ffi.function_case);
}

test "rule setting errors name the offending rule and setting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{"lints":{"rules":{"line-length":{"max-columns":0}}}}
    );
    try std.testing.expectEqualStrings(
        "zig-analyzer.json rule 'line-length' setting 'max-columns' must be a positive integer",
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

test "invalid check exclusion releases earlier owned paths" {
    const configuration = try parse(std.testing.allocator,
        \\{"check":{"exclude":["zig-cache",42]}}
    );
    defer std.testing.allocator.free(configuration.warning.?);

    try std.testing.expectEqualStrings(
        "zig-analyzer.json key 'check.exclude' must contain only relative path strings",
        configuration.warning.?,
    );
}

test "configuration parses project contracts and activates contract rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = try parse(arena.allocator(),
        \\{
        \\  "contracts": {
        \\    "imports": [{"from":"src/rules","deny":["src/lsp_server.zig"]}],
        \\    "resources": [{"acquire":"Db.open","release":"Db.close"}],
        \\    "arena-allocators": ["RequestContext.allocator"],
        \\    "must-use": ["Builder.finish"]
        \\  }
        \\}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), configuration.warning);
    try std.testing.expectEqualStrings("src/rules", configuration.import_boundaries[0].from);
    try std.testing.expectEqualStrings("src/lsp_server.zig", configuration.import_boundaries[0].denied[0]);
    try std.testing.expectEqualStrings("Db.open", configuration.resource_contracts[0].acquire);
    try std.testing.expectEqualStrings("Db.close", configuration.resource_contracts[0].release);
    try std.testing.expectEqualStrings("RequestContext.allocator", configuration.arena_allocator_contracts[0]);
    try std.testing.expectEqualStrings("Builder.finish", configuration.must_use_contracts[0]);
    try std.testing.expectEqual(Level.warning, configuration.level(.import_boundary));
    try std.testing.expectEqual(Level.warning, configuration.level(.discarded_must_use));
}

test "malformed project contracts identify the invalid contract field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{
            .source = "{\"contracts\":{\"imports\":[{\"from\":\"../rules\",\"deny\":[\"src/lsp_server.zig\"]}]}}",
            .expected = "contracts.imports.from",
        },
        .{
            .source = "{\"contracts\":{\"resources\":[{\"acquire\":\"Db..open\",\"release\":\"Db.close\"}]}}",
            .expected = "Db..open",
        },
        .{
            .source = "{\"contracts\":{\"must-use\":[3]}}",
            .expected = "contracts.must-use",
        },
        .{
            .source = "{\"contracts\":{\"arena-allocators\":[\"allocator\"]}}",
            .expected = "owner and allocator member",
        },
    };
    for (cases) |case| {
        const configuration = try parse(arena.allocator(), case.source);
        try std.testing.expect(std.mem.find(u8, configuration.warning.?, case.expected) != null);
    }
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

fn suppressedAt(source: []const u8, rule: Rule, offset: usize) bool {
    const suppressions = Suppressions.init(std.testing.allocator, source) catch @panic("out of memory");
    defer suppressions.deinit(std.testing.allocator);
    return suppressions.isSuppressed(rule, offset);
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

    const line_value = std.mem.find(u8, source, "line_value").?;
    const next_value = std.mem.find(u8, source, "next_value").?;
    const scoped_value = std.mem.find(u8, source, "scoped_value").?;
    const enabled_value = std.mem.find(u8, source, "enabled_value").?;
    const first_defer = std.mem.find(u8, source, "defer { close(); }").?;
    const second_defer = std.mem.find(u8, source, "defer { closeAgain(); }").?;

    try std.testing.expect(suppressedAt(source, .never_mutated_var, line_value));
    try std.testing.expect(!suppressedAt(source, .needless_defer_block, line_value));
    try std.testing.expect(suppressedAt(source, .never_mutated_var, next_value));
    try std.testing.expect(suppressedAt(source, .never_mutated_var, scoped_value));
    try std.testing.expect(!suppressedAt(source, .never_mutated_var, enabled_value));
    try std.testing.expect(suppressedAt(source, .needless_defer_block, first_defer));
    try std.testing.expect(!suppressedAt(source, .needless_defer_block, second_defer));
}

test "file and unnamed suppressions target all rules" {
    const file_source =
        "// zig-analyzer: disable-file never-mutated-var, needless-defer-block\n" ++
        "var value = 1;\n";
    const value = std.mem.find(u8, file_source, "value").?;
    try std.testing.expect(suppressedAt(file_source, .never_mutated_var, value));
    try std.testing.expect(suppressedAt(file_source, .needless_defer_block, value));
    try std.testing.expect(!suppressedAt(file_source, .redundant_boolean_if, value));

    const scoped_source =
        "// zig-analyzer: disable\n" ++
        "var disabled = 1;\n" ++
        "// zig-analyzer: enable\n" ++
        "var enabled = 2;\n";
    const disabled = std.mem.find(u8, scoped_source, "disabled").?;
    const enabled = std.mem.find(u8, scoped_source, "enabled =").?;
    try std.testing.expect(suppressedAt(scoped_source, .never_mutated_var, disabled));
    try std.testing.expect(!suppressedAt(scoped_source, .never_mutated_var, enabled));
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
    try std.testing.expect(std.mem.find(u8, ambiguous, "cannot combine 'all'") != null);

    const misplaced = (try suppressionWarning(
        std.testing.allocator,
        "const value = 1;\n// zig-analyzer: disable-file never-mutated-var\n",
    )).?;
    defer std.testing.allocator.free(misplaced);
    try std.testing.expect(std.mem.find(u8, misplaced, "must appear before code") != null);
}

test "directive markers inside strings are ignored" {
    const source =
        "const marker = \"// zig-analyzer: disable-line never-mutated-var\";\n" ++
        "const multiline = \\\\// zig-analyzer: disable-file all;\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try suppressionWarning(std.testing.allocator, source));
    const marker = std.mem.find(u8, source, "marker").?;
    try std.testing.expect(!suppressedAt(source, .never_mutated_var, marker));
}

test "suppression edits insert an indented next-line directive that suppresses the finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "fn run() void {\n" ++
        "    var value = 1;\n" ++
        "}\n";
    const offset = std.mem.find(u8, source, "value").?;
    const edits = try suppressionEdits(arena.allocator(), source, .never_mutated_var, offset);

    const suppressed = try applyEdit(arena.allocator(), source, edits.line);
    try std.testing.expectEqualStrings(
        "fn run() void {\n" ++
            "    // zig-analyzer: disable-next-line never-mutated-var\n" ++
            "    var value = 1;\n" ++
            "}\n",
        suppressed,
    );
    try std.testing.expect(suppressedAt(suppressed, .never_mutated_var, std.mem.find(u8, suppressed, "value").?));
    try std.testing.expectEqual(@as(?[]const u8, null), try suppressionWarning(arena.allocator(), suppressed));
}

test "suppression edits extend a next-line directive already above the finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "// zig-analyzer: disable-next-line needless-defer-block\n" ++
        "var value = 1;\n";
    const offset = std.mem.find(u8, source, "value").?;
    const edits = try suppressionEdits(arena.allocator(), source, .never_mutated_var, offset);

    const suppressed = try applyEdit(arena.allocator(), source, edits.line);
    try std.testing.expectEqualStrings(
        "// zig-analyzer: disable-next-line needless-defer-block, never-mutated-var\n" ++
            "var value = 1;\n",
        suppressed,
    );
    try std.testing.expect(suppressedAt(suppressed, .never_mutated_var, std.mem.find(u8, suppressed, "value").?));
    try std.testing.expect(suppressedAt(suppressed, .needless_defer_block, std.mem.find(u8, suppressed, "value").?));
}

test "suppression file edit lands after module doc comments and suppresses the whole file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        "//! Module docs.\n" ++
        "\n" ++
        "var value = 1;\n" ++
        "var again = 2;\n";
    const offset = std.mem.find(u8, source, "again").?;
    const edits = try suppressionEdits(arena.allocator(), source, .never_mutated_var, offset);

    const suppressed = try applyEdit(arena.allocator(), source, edits.file);
    try std.testing.expectEqualStrings(
        "//! Module docs.\n" ++
            "\n" ++
            "// zig-analyzer: disable-file never-mutated-var\n" ++
            "var value = 1;\n" ++
            "var again = 2;\n",
        suppressed,
    );
    try std.testing.expect(suppressedAt(suppressed, .never_mutated_var, std.mem.find(u8, suppressed, "value").?));
    try std.testing.expect(suppressedAt(suppressed, .never_mutated_var, std.mem.find(u8, suppressed, "again").?));
    try std.testing.expectEqual(@as(?[]const u8, null), try suppressionWarning(arena.allocator(), suppressed));
}

fn applyEdit(allocator: std.mem.Allocator, source: []const u8, edit: Edit) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ source[0..edit.span.start], edit.replacement, source[edit.span.end..] });
}

test "suppression table is empty without directives and drops nothing" {
    const source = "const x = 1; // not a directive\n";
    const suppressions = try Suppressions.init(std.testing.allocator, source);
    defer suppressions.deinit(std.testing.allocator);
    try std.testing.expect(suppressions.isEmpty());
    try std.testing.expect(!suppressions.isSuppressed(.never_mutated_var, 0));
}

test "suppression table filters findings by directive scope" {
    const source =
        "// zig-analyzer: disable never-mutated-var\n" ++
        "a;\n" ++
        "// zig-analyzer: enable never-mutated-var\n" ++
        "b;\n" ++
        "c; // zig-analyzer: disable-line needless-defer-block\n" ++
        "// zig-analyzer: disable-next-line all\n" ++
        "d;\n" ++
        "e;\n";
    const suppressions = try Suppressions.init(std.testing.allocator, source);
    defer suppressions.deinit(std.testing.allocator);
    try std.testing.expect(!suppressions.isEmpty());
    var found: std.ArrayList(rule_types.Finding) = .empty;
    defer found.deinit(std.testing.allocator);
    for ([_][]const u8{ "a;", "b;", "c;", "d;", "e;" }) |marker| {
        const start = std.mem.find(u8, source, marker).?;
        for ([_]Rule{ .never_mutated_var, .needless_defer_block }) |rule| {
            try found.append(std.testing.allocator, .{ .rule = rule, .level = .warning, .span = .{ .start = start, .end = start + 1 }, .message = "" });
        }
    }
    suppressions.filter(&found);
    // a: never-mutated-var disabled; b: nothing; c: needless-defer-block; d: both; e: nothing.
    const expected = [_]struct { Rule, u8 }{
        .{ .needless_defer_block, 'a' },
        .{ .never_mutated_var, 'b' },
        .{ .needless_defer_block, 'b' },
        .{ .never_mutated_var, 'c' },
        .{ .never_mutated_var, 'e' },
        .{ .needless_defer_block, 'e' },
    };
    try std.testing.expectEqual(expected.len, found.items.len);
    for (expected, found.items) |want, got| {
        try std.testing.expectEqual(want[0], got.rule);
        try std.testing.expectEqual(want[1], source[got.span.start]);
    }
}

test "disable-file only counts in the file header" {
    const late = "const x = 1;\n// zig-analyzer: disable-file never-mutated-var\nconst y = 2;\n";
    try std.testing.expect(!suppressedAt(late, .never_mutated_var, std.mem.find(u8, late, "y =").?));
    const early = "//! docs\n// zig-analyzer: disable-file never-mutated-var\nconst y = 2;\n";
    try std.testing.expect(suppressedAt(early, .never_mutated_var, std.mem.find(u8, early, "y =").?));
    try std.testing.expect(suppressedAt(early, .never_mutated_var, 0) == false);
}

test "configuration applies tiers and per-rule overrides" {
    const configuration = try parse(std.testing.allocator,
        \\{"lints":{"profile":"idiomatic","correctness":"error","style":"hint","rules":{"discarded-error":"warning","mixed-bitwise-arithmetic":"information"}}}
    );
    try std.testing.expectEqual(Level.@"error", configuration.level(.unreleased_allocation));
    try std.testing.expectEqual(Level.hint, configuration.level(.unsorted_imports));
    try std.testing.expectEqual(Level.warning, configuration.level(.discarded_error));
    try std.testing.expectEqual(Level.information, configuration.level(.mixed_bitwise_arithmetic));
}

test "configuration reports unknown rules" {
    const configuration = try parse(std.testing.allocator,
        \\{"lints":{"rules":{"mystery-rule":"warning"}}}
    );
    defer std.testing.allocator.free(configuration.warning.?);
    try std.testing.expect(std.mem.find(u8, configuration.warning.?, "mystery-rule") != null);
}

test "suppression parser reports malformed and unknown rules" {
    const malformed = try suppressionWarning(std.testing.allocator, "// zig-analyzer: ignore-next-line never-mutated-var\nconst x = 1;");
    defer std.testing.allocator.free(malformed.?);
    try std.testing.expect(std.mem.find(u8, malformed.?, "malformed") != null);

    const unknown = try suppressionWarning(std.testing.allocator, "// zig-analyzer: disable-file unknown-rule\n");
    defer std.testing.allocator.free(unknown.?);
    try std.testing.expect(std.mem.find(u8, unknown.?, "unknown-rule") != null);

    const typo = try suppressionWarning(std.testing.allocator, "// zig-analyzer: disable-file never-mutated-vra\n");
    defer std.testing.allocator.free(typo.?);
    try std.testing.expectEqualStrings(
        "zig-analyzer suppression on line 1 contains unknown lint rule 'never-mutated-vra'; did you mean 'never-mutated-var'?",
        typo.?,
    );
}

test "edit distance counts a transposition as one edit" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("rules", "rules"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("rulez", "rules"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("line-lenght", "line-length"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("lint", "lints"));
    try std.testing.expectEqual(@as(usize, 3), editDistance("kitten", "sitting"));
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "lints"));
    try std.testing.expectEqual(@as(?[]const u8, null), nearestName("not-a-rule", &rule_codes));
}
