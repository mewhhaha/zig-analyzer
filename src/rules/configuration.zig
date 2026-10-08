const std = @import("std");
const catalog = @import("catalog.zig");
const rule_types = @import("types.zig");

const Configuration = rule_types.Configuration;
const Edit = rule_types.Edit;
const Level = rule_types.Level;
const LintProfile = rule_types.LintProfile;
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

    if (root.get("check")) |check_value| {
        const check = switch (check_value) {
            .object => |object| object,
            else => {
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'check' must contain an object");
                return configuration;
            },
        };
        if (check.get("exclude")) |exclude_value| {
            const excludes = switch (exclude_value) {
                .array => |array| array,
                else => {
                    configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'check.exclude' must contain an array of relative paths");
                    return configuration;
                },
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
                    else => {
                        configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'check.exclude' must contain only relative path strings");
                        return configuration;
                    },
                };
                if (path.len == 0 or std.Io.Dir.path.isAbsolute(path) or containsParentPathComponent(path)) {
                    configuration.warning = try allocator.print(
                        "zig-analyzer.json check exclusion '{s}' must be a non-empty relative path without '..' components",
                        .{path},
                    );
                    return configuration;
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
        if (try parseContracts(allocator, contracts_value, &configuration)) |warning| {
            configuration.warning = warning;
            return configuration;
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
                configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.profile' must be official, idiomatic, strict, modernize, or disciplined");
                return configuration;
            },
        };
        const lint_profile = std.meta.stringToEnum(LintProfile, profile_name) orelse {
            configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.profile' must be official, idiomatic, strict, modernize, or disciplined");
            return configuration;
        };
        if (lint_profile == .none) {
            configuration.warning = try allocator.dupe(u8, "zig-analyzer.json key 'lints.profile' must be official, idiomatic, strict, modernize, or disciplined");
            return configuration;
        }
        configuration.lint_profile = lint_profile;
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
                configuration.warning = try allocator.print(
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
                configuration.warning = try allocator.print(
                    "zig-analyzer.json banned path '{s}' must be identifiers separated by single dots",
                    .{path},
                );
                return configuration;
            }
            const hint: ?[]const u8 = if (entry.get("hint")) |hint_value| switch (hint_value) {
                .string => |string| try allocator.dupe(u8, string),
                else => {
                    configuration.warning = try allocator.print(
                        "zig-analyzer.json key 'lints.banned' hint for '{s}' must be a string",
                        .{path},
                    );
                    return configuration;
                },
            } else null;
            banned_entry.* = .{ .path = try allocator.dupe(u8, path), .hint = hint };
        }
        configuration.banned = banned;
        if (banned.len != 0) configuration.levels[@backingInt(Rule.banned_identifier)] = .warning;
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
                configuration.warning = try allocator.print(
                    "zig-analyzer.json contains unknown lint rule '{s}'",
                    .{entry.key_ptr.*},
                );
                return configuration;
            };
            if (rule.tier() == .semantic) {
                configuration.warning = try allocator.print(
                    "zig-analyzer.json rule '{s}' is an always-on semantic diagnostic and cannot be configured",
                    .{entry.key_ptr.*},
                );
                return configuration;
            }
            switch (entry.value_ptr.*) {
                .string => {
                    const level = parseLevel(entry.value_ptr.*) orelse {
                        configuration.warning = try invalidLevelMessage(allocator, entry.key_ptr.*);
                        return configuration;
                    };
                    configuration.levels[@backingInt(rule)] = level;
                },
                .object => if (try parseRuleSettings(allocator, rule, entry.value_ptr.*, &configuration)) |warning| {
                    configuration.warning = warning;
                    return configuration;
                },
                else => {
                    configuration.warning = try invalidLevelMessage(allocator, entry.key_ptr.*);
                    return configuration;
                },
            }
        }
    }
    return configuration;
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
    var keys = contracts.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "imports") or std.mem.eql(u8, key, "resources") or
            std.mem.eql(u8, key, "arena-allocators") or std.mem.eql(u8, key, "must-use")) continue;
        return try allocator.print("zig-analyzer.json key 'contracts' contains unknown key '{s}'", .{key});
    }

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
            var entry_keys = entry.iterator();
            while (entry_keys.next()) |pair| {
                if (std.mem.eql(u8, pair.key_ptr.*, "from") or std.mem.eql(u8, pair.key_ptr.*, "deny")) continue;
                return try allocator.print("zig-analyzer.json key 'contracts.imports' contains unknown key '{s}'", .{pair.key_ptr.*});
            }
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
            var entry_keys = entry.iterator();
            while (entry_keys.next()) |pair| {
                if (std.mem.eql(u8, pair.key_ptr.*, "acquire") or std.mem.eql(u8, pair.key_ptr.*, "release")) continue;
                return try allocator.print("zig-analyzer.json key 'contracts.resources' contains unknown key '{s}'", .{pair.key_ptr.*});
            }
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
    configuration: *Configuration,
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
            configuration.levels[@backingInt(rule)] = level;
            continue;
        }
        const setting = for (options) |option| {
            if (settingKeyMatches(option, key)) break option;
        } else return try allocator.print(
            "zig-analyzer.json rule '{s}' contains unknown setting '{s}'",
            .{ rule.code(), key },
        );
        if (try applySetting(allocator, rule, setting, entry.value_ptr.*, configuration)) |warning| return warning;
    }
    return null;
}

fn settingKeyMatches(setting: catalog.Setting, key: []const u8) bool {
    return switch (setting) {
        inline else => |known| std.mem.eql(u8, key, comptime catalog.Setting.key(known)),
    };
}

fn applySetting(
    allocator: std.mem.Allocator,
    rule: Rule,
    setting: catalog.Setting,
    value: std.json.Value,
    configuration: *Configuration,
) !?[]const u8 {
    const key = switch (setting) {
        inline else => |known| comptime catalog.Setting.key(known),
    };
    switch (setting) {
        .max_lines, .max_columns => {
            const limit = positiveInteger(value) orelse return try settingTypeWarning(allocator, rule, key, "a positive integer");
            if (setting == .max_lines) configuration.function_length_limit = limit else configuration.line_length_limit = limit;
        },
        .allow_unsplittable => configuration.line_length_allow_unsplittable = switch (value) {
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
            configuration.todo_markers = markers;
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

    const Placed = struct {
        directive: Directive,
        /// Start of the line holding the directive.
        line_start: usize,
        /// End of that line, excluding the newline.
        line_end: usize,
        /// A disable-file directive that sits in the file header, before any code.
        in_header: bool,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Suppressions {
        if (std.mem.find(u8, source, "// zig-analyzer:") == null) return .{ .source = source, .directives = &.{} };
        var placed: std.ArrayList(Placed) = .empty;
        errdefer placed.deinit(allocator);
        var cursor: usize = 0;
        var file_header = true;
        while (cursor < source.len) {
            const end = lineEnd(source, cursor);
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
        return .{ .source = source, .directives = try placed.toOwnedSlice(allocator) };
    }

    pub fn deinit(suppressions: Suppressions, allocator: std.mem.Allocator) void {
        allocator.free(suppressions.directives);
    }

    pub fn isEmpty(suppressions: Suppressions) bool {
        return suppressions.directives.len == 0;
    }

    pub fn isSuppressed(suppressions: Suppressions, rule: Rule, offset: usize) bool {
        const source = suppressions.source;
        const target_offset = @min(offset, source.len);
        const target_line_start = lineStart(source, target_offset);
        var disabled = false;
        for (suppressions.directives) |placed| {
            if (placed.line_start > target_line_start) break;
            const directive = placed.directive;
            const targets_rule = directiveTargetsRule(directive.targets, rule);
            if (placed.in_header and targets_rule) return true;
            if (placed.line_start < target_line_start) {
                switch (directive.kind) {
                    .disable => if (targets_rule) {
                        disabled = true;
                    },
                    .enable => if (targets_rule) {
                        disabled = false;
                    },
                    .disable_next_line => if (targets_rule and placed.line_end + 1 == target_line_start) return true,
                    else => {},
                }
            } else {
                if (directive.kind == .disable_line and targets_rule) return true;
                if (placed.line_start + directive.comment_start <= target_offset) switch (directive.kind) {
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
        return disabled;
    }

    /// Drops every finding that a directive suppresses.
    pub fn filter(suppressions: Suppressions, found: *std.ArrayList(rule_types.Finding)) void {
        if (suppressions.isEmpty()) return;
        var kept: usize = 0;
        for (found.items) |finding| {
            if (suppressions.isSuppressed(finding.rule, finding.span.start)) continue;
            found.items[kept] = finding;
            kept += 1;
        }
        found.shrinkRetainingCapacity(kept);
    }
};

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
        const end = lineEnd(source, cursor);
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
                "zig-analyzer suppression on line {d} contains unknown lint rule '{s}'",
                .{ line_number, name },
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
    return (std.mem.findScalarLast(u8, source[0..@min(offset, source.len)], '\n') orelse return 0) + 1;
}

fn lineEnd(source: []const u8, offset: usize) usize {
    const start = @min(offset, source.len);
    const relative = std.mem.findScalar(u8, source[start..], '\n') orelse return source.len;
    return start + relative;
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

fn setTier(configuration: *Configuration, tier: Tier, level: Level) void {
    for (std.enums.values(Rule)) |rule| {
        if (rule.tier() == tier and catalog.entry(rule).needs == .nothing) {
            configuration.levels[@backingInt(rule)] = level;
        }
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
        \\{"lints":{"correctness":"warning","style":"information"}}
    );

    try std.testing.expectEqual(Level.off, configuration.level(.import_boundary));
    try std.testing.expectEqual(Level.off, configuration.level(.discarded_must_use));
    try std.testing.expectEqual(Level.off, configuration.level(.configuration_divergent_api));
    try std.testing.expectEqual(Level.off, configuration.level(.unreachable_public_declaration));
    try std.testing.expectEqual(Level.warning, configuration.level(.missing_errdefer));
    try std.testing.expectEqual(Level.information, configuration.level(.line_length));
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
        \\{"lints":{"correctness":"error","style":"hint","rules":{"discarded-error":"warning","mixed-bitwise-arithmetic":"information"}}}
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
}
