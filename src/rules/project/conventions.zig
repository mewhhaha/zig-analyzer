//! Project-wide naming, signature, and error-set conventions, each enforced only when the corpus majority is strong (`majority.zig`).
const std = @import("std");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const majority = @import("majority.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const matchingToken = tokens_util.matchingToken;
const topLevelComma = tokens_util.topLevelComma;
const findTag = tokens_util.findTag;
const foreignDeclaration = tokens_util.foreignDeclaration;

pub const rules = [_]types.Rule{
    .minority_naming_style,
    .inconsistent_parameter_vocabulary,
    .inconsistent_error_set_style,
};

const NamingKind = enum { function, type_name, constant };
const NamingStyle = enum { snake, camel, title, other };
const NamingSample = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    name: []const u8,
    kind: NamingKind,
    style: NamingStyle,
};

pub fn findMinorityNamingStyles(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.minority_naming_style) == .off) return;
    var samples: std.ArrayList(NamingSample) = .empty;
    defer samples.deinit(run.allocator);
    for (run.files, 0..) |file, file_index| {
        if (file.generated) continue;
        var brace_depth: usize = 0;
        for (file.tokens, 0..) |token, index| {
            switch (token.tag) {
                .l_brace => brace_depth += 1,
                .r_brace => brace_depth -|= 1,
                .keyword_fn => if (!foreignDeclaration(file.tokens, index) and index + 1 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    try samples.append(run.allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = .function, .style = namingStyle(name) });
                },
                .keyword_const => if (brace_depth == 0 and !foreignDeclaration(file.tokens, index) and index + 2 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    const kind: NamingKind = if (declarationLooksLikeType(file.tokens, index)) .type_name else .constant;
                    try samples.append(run.allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = kind, .style = namingStyle(name) });
                },
                else => {},
            }
        }
    }
    var totals: [@typeInfo(NamingKind).@"enum".field_names.len]usize = @splat(0);
    var counts: [@typeInfo(NamingKind).@"enum".field_names.len][@typeInfo(NamingStyle).@"enum".field_names.len]usize = @splat(@splat(0));
    for (samples.items) |sample| {
        totals[@backingInt(sample.kind)] += 1;
        counts[@backingInt(sample.kind)][@backingInt(sample.style)] += 1;
    }
    for (samples.items) |sample| {
        const total = totals[@backingInt(sample.kind)];
        const kind_counts = counts[@backingInt(sample.kind)];
        var dominant = NamingStyle.snake;
        for (std.enums.values(NamingStyle)) |style| {
            if (kind_counts[@backingInt(style)] > kind_counts[@backingInt(dominant)]) dominant = style;
        }
        const dominant_count = kind_counts[@backingInt(dominant)];
        if (!majority.strong(dominant_count, total) or sample.style == dominant) continue;
        try run.report(.{
            .file_index = sample.file_index,
            .rule = .minority_naming_style,
            .span = sample.span,
            .message = try run.allocator.print(
                "{s} name '{s}' uses {s}, while {d} of {d} project declarations use {s}",
                .{ @tagName(sample.kind), sample.name, @tagName(sample.style), dominant_count, total, @tagName(dominant) },
            ),
        });
    }
}

const ErrorStyleSample = struct { file_index: usize, span: std.zig.Token.Loc, explicit: bool };

const ParameterSample = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    name: []const u8,
    type_name: []const u8,
};

pub fn findInconsistentParameterVocabulary(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.inconsistent_parameter_vocabulary) == .off) return;
    var samples: std.ArrayList(ParameterSample) = .empty;
    defer samples.deinit(run.allocator);
    for (run.files, 0..) |file, file_index| {
        if (file.generated) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren or
                foreignDeclaration(file.tokens, fn_index)) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
            var start = opening + 1;
            while (start < closing) {
                const comma = topLevelComma(file.tokens, start, closing) orelse closing;
                const colon = findTag(file.tokens, start, comma, .colon);
                if (colon) |colon_index| if (colon_index > start and file.tokens[colon_index - 1].tag == .identifier and colon_index + 1 < comma) {
                    const name = tokenText(file.source, file.tokens[colon_index - 1]);
                    if (!std.mem.eql(u8, name, "self") and !std.mem.eql(u8, name, "_")) try samples.append(run.allocator, .{
                        .file_index = file_index,
                        .span = file.tokens[colon_index - 1].loc,
                        .name = name,
                        .type_name = std.mem.trim(u8, file.source[file.tokens[colon_index + 1].loc.start..file.tokens[comma - 1].loc.end], " \t\r\n"),
                    });
                };
                if (comma == closing) break;
                start = comma + 1;
            }
        }
    }
    var names: majority.Tally = .{};
    for (samples.items) |sample| try names.add(run.allocator, sample.type_name, sample.name);
    for (samples.items) |sample| {
        const group = names.lookup(sample.type_name);
        if (!group.isMinority(sample.name)) continue;
        try run.report(.{
            .file_index = sample.file_index,
            .rule = .inconsistent_parameter_vocabulary,
            .span = sample.span,
            .message = try run.allocator.print("parameter '{s}' has type '{s}', for which {d} of {d} project parameters use '{s}'", .{ sample.name, sample.type_name, group.dominant_count, group.total, group.dominant.? }),
        });
    }
}

pub fn findInconsistentErrorSetStyle(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.inconsistent_error_set_style) == .off) return;
    var samples: std.ArrayList(ErrorStyleSample) = .empty;
    defer samples.deinit(run.allocator);
    for (run.files, 0..) |file, file_index| {
        if (file.generated) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index == 0 or file.tokens[fn_index - 1].tag != .keyword_pub) continue;
            const opening = nextTagBefore(file.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
            const body = nextTagBefore(file.tokens, closing + 1, .l_brace, .semicolon) orelse continue;
            const bang = findTag(file.tokens, closing + 1, body, .bang) orelse continue;
            try samples.append(run.allocator, .{ .file_index = file_index, .span = file.tokens[bang].loc, .explicit = bang != closing + 1 });
        }
    }
    var explicit_count: usize = 0;
    for (samples.items) |sample| {
        if (sample.explicit) explicit_count += 1;
    }
    const inferred_count = samples.items.len - explicit_count;
    const dominant_explicit = explicit_count > inferred_count;
    const dominant_count = @max(explicit_count, inferred_count);
    if (!majority.strong(dominant_count, samples.items.len)) return;
    for (samples.items) |sample| {
        if (sample.explicit == dominant_explicit) continue;
        try run.report(.{
            .file_index = sample.file_index,
            .rule = .inconsistent_error_set_style,
            .span = sample.span,
            .message = try run.allocator.print("public function uses an {s} error set, while {d} of {d} public error-returning functions use {s} sets", .{ if (sample.explicit) "explicit" else "inferred", dominant_count, samples.items.len, if (dominant_explicit) "explicit" else "inferred" }),
        });
    }
}

fn declarationLooksLikeType(tokens: []const std.zig.Token, const_index: usize) bool {
    if (const_index + 3 >= tokens.len or tokens[const_index + 2].tag != .equal) return false;
    return switch (tokens[const_index + 3].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_error => true,
        else => false,
    };
}

fn namingStyle(name: []const u8) NamingStyle {
    if (name.len == 0) return .other;
    if (std.mem.findScalar(u8, name, '_') != null) return .snake;
    if (std.ascii.isUpper(name[0])) return .title;
    var has_upper = false;
    for (name[1..]) |character| if (std.ascii.isUpper(character)) {
        has_upper = true;
        break;
    };
    return if (has_upper) .camel else .snake;
}
