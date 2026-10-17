//! Project-wide naming, signature, and error-set conventions, each enforced only when the corpus majority is strong (`majority.zig`).
const std = @import("std");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const majority = @import("majority.zig");
const official_style = @import("../style/official_style.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const matchingToken = tokens_util.matchingToken;
const topLevelComma = tokens_util.topLevelComma;
const findTag = tokens_util.findTag;
const foreignDeclaration = tokens_util.foreignDeclaration;
const project = @import("../project.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .minority_naming_style,
    .inconsistent_parameter_vocabulary,
    .inconsistent_error_set_style,
};

const NamingKind = enum { function, type_name, constant };
/// `lower` is one lowercase word, which is valid snake and camel case alike.
const NamingStyle = enum { snake, camel, title, lower, other };
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
    var samples = try collectNamingSamples(run.allocator, run.files);
    defer samples.deinit(run.allocator);
    const tally: NamingTally = .init(samples.items);
    const function_case = run.configuration.function_case.nameCase();
    for (samples.items) |sample| {
        const dominant = tally.convention(sample.kind) orelse continue;
        if (sample.style == dominant.style) continue;
        if (sample.style == .lower and (dominant.style == .snake or dominant.style == .camel)) continue;
        // `non-idiomatic-name` already reports a name that breaks Zig's
        // convention, and with it the project's; this rule adds the names
        // that follow Zig's guide but not the convention the project chose.
        if (run.levelFor(sample.file_index, .non_idiomatic_name) != .off and
            !official_style.followsCase(zigCase(sample.kind, function_case), sample.name)) continue;
        try run.report(.{
            .file_index = sample.file_index,
            .rule = .minority_naming_style,
            .span = sample.span,
            .message = try run.allocator.print(
                "{s} name '{s}' uses {s}, while {d} of {d} project declarations use {s}",
                .{ @tagName(sample.kind), sample.name, @tagName(if (sample.style == .lower) .snake else sample.style), dominant.count, dominant.total, @tagName(dominant.style) },
            ),
        });
    }
}

/// The casing a strong majority of the project's declarations of each kind
/// use, which `non-idiomatic-name` accepts as the project's convention.
pub fn namingConventions(allocator: std.mem.Allocator, files: []const run_module.File) !types.NamingConventions {
    var samples = try collectNamingSamples(allocator, files);
    defer samples.deinit(allocator);
    const tally: NamingTally = .init(samples.items);
    return .{
        .function = nameCase(tally.convention(.function)),
        .type_name = nameCase(tally.convention(.type_name)),
        .constant = nameCase(tally.convention(.constant)),
    };
}

fn nameCase(convention: ?NamingTally.Convention) ?types.NameCase {
    return switch ((convention orelse return null).style) {
        .snake => .snake_case,
        .camel => .camel_case,
        .title => .title_case,
        .lower, .other => null,
    };
}

/// The casing Zig's style guide gives the kind of declaration.
fn zigCase(kind: NamingKind, function_case: types.NameCase) types.NameCase {
    return switch (kind) {
        .function => function_case,
        .type_name => .title_case,
        .constant => .snake_case,
    };
}

fn collectNamingSamples(allocator: std.mem.Allocator, files: []const run_module.File) !std.ArrayList(NamingSample) {
    var samples: std.ArrayList(NamingSample) = .empty;
    errdefer samples.deinit(allocator);
    for (files, 0..) |file, file_index| {
        if (file.generated) continue;
        var brace_depth: usize = 0;
        for (file.tokens, 0..) |token, index| {
            switch (token.tag) {
                .l_brace => brace_depth += 1,
                .r_brace => brace_depth -|= 1,
                .keyword_fn => if (!foreignDeclaration(file.tokens, index) and index + 1 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    if (abiName(name)) continue;
                    // `fn ArrayList(T: type) type` is named like the type it returns.
                    const kind: NamingKind = if (functionReturnsType(file.source, file.tokens, index)) .type_name else .function;
                    try samples.append(allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = kind, .style = namingStyle(name) });
                },
                .keyword_const => if (brace_depth == 0 and !foreignDeclaration(file.tokens, index) and index + 2 < file.tokens.len and file.tokens[index + 1].tag == .identifier) {
                    const name = tokenText(file.source, file.tokens[index + 1]);
                    // A struct without fields is a namespace, which Zig style
                    // names like a value rather than a type.
                    if (declarationIsNamespace(file.tokens, index)) continue;
                    const kind: NamingKind = if (declarationLooksLikeType(file.tokens, index)) .type_name else .constant;
                    // `IORING_OP`, `R_X86_64` or `clockid_t` mirrors a C or ABI
                    // name rather than choosing among the Zig styles.
                    if (kind == .type_name and (abiName(name) or cTypeName(name))) continue;
                    try samples.append(allocator, .{ .file_index = file_index, .span = file.tokens[index + 1].loc, .name = name, .kind = kind, .style = namingStyle(name) });
                },
                else => {},
            }
        }
    }
    return samples;
}

/// How many declarations of each kind use each style. A `lower` name counts
/// for snake and camel case alike.
const NamingTally = struct {
    totals: [kind_count]usize = @splat(0),
    counts: [kind_count][style_count]usize = @splat(@splat(0)),

    const kind_count = @typeInfo(NamingKind).@"enum".field_names.len;
    const style_count = @typeInfo(NamingStyle).@"enum".field_names.len;

    const Convention = struct { style: NamingStyle, count: usize, total: usize };

    fn init(samples: []const NamingSample) NamingTally {
        var tally: NamingTally = .{};
        for (samples) |sample| {
            tally.totals[@backingInt(sample.kind)] += 1;
            if (sample.style == .lower) {
                tally.counts[@backingInt(sample.kind)][@backingInt(NamingStyle.snake)] += 1;
                tally.counts[@backingInt(sample.kind)][@backingInt(NamingStyle.camel)] += 1;
            } else tally.counts[@backingInt(sample.kind)][@backingInt(sample.style)] += 1;
        }
        return tally;
    }

    /// The style of the kind's strong majority, if it has one.
    fn convention(tally: NamingTally, kind: NamingKind) ?Convention {
        const kind_counts = tally.counts[@backingInt(kind)];
        var dominant = NamingStyle.snake;
        for (std.enums.values(NamingStyle)) |style| {
            if (kind_counts[@backingInt(style)] > kind_counts[@backingInt(dominant)]) dominant = style;
        }
        const total = tally.totals[@backingInt(kind)];
        const count = kind_counts[@backingInt(dominant)];
        if (!majority.strong(count, total)) return null;
        return .{ .style = dominant, .count = count, .total = total };
    }
};

const ErrorStyleSample = struct { file_index: usize, span: std.zig.Token.Loc, explicit: bool };

const ParameterSample = struct {
    file_index: usize,
    span: std.zig.Token.Loc,
    name: []const u8,
    type_name: []const u8,
    /// The parameter list's `(` and `)`.
    list_opening: usize,
    list_closing: usize,
    /// Another parameter of the function has the same type, so the two
    /// cannot share one name.
    shares_type: bool = false,
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
            const function_samples = samples.items.len;
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
                        .list_opening = opening,
                        .list_closing = closing,
                    });
                };
                if (comma == closing) break;
                start = comma + 1;
            }
            const parameters = samples.items[function_samples..];
            for (parameters, 0..) |*parameter, index| for (parameters, 0..) |other, other_index| {
                if (index != other_index and std.mem.eql(u8, parameter.type_name, other.type_name)) parameter.shares_type = true;
            };
        }
    }
    var names: majority.Tally = .{};
    for (samples.items) |sample| try names.add(run.allocator, sample.type_name, sample.name);
    for (samples.items) |sample| {
        const group = names.lookup(sample.type_name);
        if (!group.isMinority(sample.name) or sample.shares_type or variantOf(sample.name, group.dominant.?) or
            try nameTaken(run, sample, group.dominant.?)) continue;
        try run.report(.{
            .file_index = sample.file_index,
            .rule = .inconsistent_parameter_vocabulary,
            .span = sample.span,
            .message = try run.allocator.print("parameter '{s}' has type '{s}', for which {d} of {d} project parameters use '{s}'", .{ sample.name, sample.type_name, group.dominant_count, group.total, group.dominant.? }),
        });
    }
}

/// Words a callback's opaque context goes by interchangeably.
const context_words = [_][]const u8{ "context", "ctx", "userdata", "user_data" };

/// Whether `name` deliberately departs from the majority word `dominant`: it
/// ends in `_` to avoid a shadow (`io_`), differs only by such underscores,
/// is a synonym for a callback context (`ctx` for `userdata`), or qualifies
/// the word, or a synonym of it, to tell one of several apart
/// (`parent_block`, `switch_inst`, `ctx_ptr`).
fn variantOf(name: []const u8, dominant: []const u8) bool {
    if (name.len > 0 and name[name.len - 1] == '_') return true;
    const word = std.mem.trimEnd(u8, dominant, "_");
    if (std.mem.eql(u8, name, word) or qualifies(name, word)) return true;
    const context_word = for (context_words) |synonym| {
        if (std.mem.eql(u8, word, synonym)) break true;
    } else false;
    if (!context_word) return false;
    for (context_words) |synonym| if (std.mem.eql(u8, name, synonym) or qualifies(name, synonym)) return true;
    return false;
}

/// Whether `name` holds `word` as whole `_`-separated parts, as
/// `parent_block` and `block_inst` hold `block`.
fn qualifies(name: []const u8, word: []const u8) bool {
    if (word.len == 0 or name.len <= word.len) return false;
    for (0..name.len - word.len + 1) |start| {
        const end = start + word.len;
        if (!std.mem.eql(u8, name[start..end], word)) continue;
        if ((start == 0 or name[start - 1] == '_') and (end == name.len or name[end] == '_')) return true;
    }
    return false;
}

/// Whether renaming the parameter to `name` would collide: a declaration of
/// that name is visible at the parameter (Zig rejects the shadowing, as with a
/// function named like its parameter), or the function's own parameters,
/// locals or captures already use it.
fn nameTaken(run: ProjectRun, sample: ParameterSample, name: []const u8) !bool {
    const file = run.files[sample.file_index];
    const scopes = try run.scopes(sample.file_index);
    const bindings = scopes.bindings.get(name) orelse return false;
    const body = nextTagBefore(file.tokens, sample.list_closing + 1, .l_brace, .semicolon);
    const function_end = if (body) |opening| scopes.matchingToken(opening) orelse sample.list_closing else sample.list_closing;
    for (bindings.items) |binding| {
        if (binding.token_index > sample.list_opening and binding.token_index < function_end) return true;
        if (binding.scope.start <= sample.span.start and sample.span.end <= binding.scope.end) return true;
    }
    return false;
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

/// `const n = struct { ... }` whose body declares no field: no `name:` and no
/// comma at its top level, where only fields have either.
fn declarationIsNamespace(tokens: []const std.zig.Token, const_index: usize) bool {
    if (const_index + 4 >= tokens.len or tokens[const_index + 2].tag != .equal or
        tokens[const_index + 3].tag != .keyword_struct or tokens[const_index + 4].tag != .l_brace) return false;
    var depth: usize = 0;
    for (tokens[const_index + 5 ..], const_index + 5..) |token, index| switch (token.tag) {
        .l_brace, .l_paren, .l_bracket => depth += 1,
        .r_brace, .r_paren, .r_bracket => {
            if (depth == 0) return true;
            depth -= 1;
        },
        .comma => if (depth == 0) return false,
        // `name:` opening a member; a block label follows `=` instead.
        .identifier => if (depth == 0 and tokens[index + 1].tag == .colon) switch (tokens[index - 1].tag) {
            .l_brace, .r_brace, .comma, .semicolon, .doc_comment, .keyword_comptime => return false,
            else => {},
        },
        .eof => return false,
        else => {},
    };
    return false;
}

fn declarationLooksLikeType(tokens: []const std.zig.Token, const_index: usize) bool {
    if (const_index + 3 >= tokens.len or tokens[const_index + 2].tag != .equal) return false;
    return switch (tokens[const_index + 3].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_error => true,
        else => false,
    };
}

/// `fn Name(...) type` at the `fn` token.
fn functionReturnsType(source: []const u8, tokens: []const std.zig.Token, fn_index: usize) bool {
    if (fn_index + 2 >= tokens.len or tokens[fn_index + 2].tag != .l_paren) return false;
    const parameters_end = matchingToken(tokens, fn_index + 2, .l_paren, .r_paren) orelse return false;
    return parameters_end + 1 < tokens.len and tokens[parameters_end + 1].tag == .identifier and
        std.mem.eql(u8, tokenText(source, tokens[parameters_end + 1]), "type");
}

/// A C typedef or tag name such as `clockid_t`, `queue_s` or translate-c's
/// `struct_timespec`.
fn cTypeName(name: []const u8) bool {
    if (std.mem.findScalar(u8, name, '_') == null) return false;
    return std.mem.endsWith(u8, name, "_t") or std.mem.endsWith(u8, name, "_s") or std.mem.startsWith(u8, name, "struct_");
}

/// `ISDIR`, `MAKE_TAG` or `__tls_base`: a C macro, ABI symbol or reserved
/// name, mirrored rather than chosen among the Zig styles.
fn abiName(name: []const u8) bool {
    if (name.len < 2 or name[0] == '_') return name.len != 0;
    for (name) |character| if (std.ascii.isLower(character)) return false;
    return true;
}

/// A trailing underscore only tells a name apart from another (`type_`,
/// `callback_`), so the style is judged without it.
fn namingStyle(full_name: []const u8) NamingStyle {
    const name = std.mem.trimEnd(u8, full_name, "_");
    if (name.len == 0) return .other;
    if (std.mem.findScalar(u8, name, '_') != null) return .snake;
    if (std.ascii.isUpper(name[0])) return .title;
    var has_upper = false;
    for (name[1..]) |character| if (std.ascii.isUpper(character)) {
        has_upper = true;
        break;
    };
    return if (has_upper) .camel else .lower;
}

/// Sixty files that each declare `fn useN(pool: *Pool) void` and a
/// `const TypeN = struct { field: u8 }`, followed by `extra`.
fn conventionFixture(allocator: std.mem.Allocator, extra: []const project.SourceFile) ![]const project.SourceFile {
    const files = try allocator.alloc(project.SourceFile, 60 + extra.len);
    inline for (files[0..60], 0..) |*file, index| file.* = .{
        .path = std.fmt.comptimePrint("src/file{d}.zig", .{index}),
        .source = std.fmt.comptimePrint("const Type{d} = struct {{ field: u8 }};\nfn use{d}(pool: *Pool) void {{ _ = pool; }}\n", .{ index, index }),
    };
    @memcpy(files[60..], extra);
    return files;
}

test "parameters that cannot take the majority name are not reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try conventionFixture(arena.allocator(), &.{
        .{ .path = "src/named.zig", .source = "fn pool(names: *Pool) void { _ = names; }\n" },
        .{ .path = "src/odd.zig", .source =
        \\fn stateEqual(left: *Pool, right: *Pool) void { _ = left; _ = right; }
        \\fn walk(store: *Pool, all: []const *Pool) void {
        \\    for (all) |pool| _ = pool;
        \\    _ = store;
        \\}
        \\fn rename(names: *Pool) void { _ = names; }
        },
    });
    const found = try project.findings(arena.allocator(), files, support.only(&.{.inconsistent_parameter_vocabulary}, .information));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const odd = files[found[0].file_index];
    try std.testing.expectEqualStrings("src/odd.zig", odd.path);
    try std.testing.expectEqual(std.mem.find(u8, odd.source, "names").?, found[0].finding.span.start);
}

test "a struct without fields is a namespace, not a type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try conventionFixture(arena.allocator(), &.{
        .{ .path = "src/odd.zig", .source =
        \\const d = struct {
        \\    /// Offset of the length field.
        \\    const length = 4;
        \\    const ports = blk: {
        \\        break :blk length * 2;
        \\    };
        \\    pub fn root() u32 { return 8; }
        \\};
        \\const hex = struct {
        \\    pub fn encode(encoded: []u8) error{SizeMismatch}!void {
        \\        if (encoded.len == 0) return error.SizeMismatch;
        \\    }
        \\};
        \\const IORING_OP = enum(u8) { nop, readv };
        \\const node = struct { left: u32, right: u32 };
        },
    });
    const found = try project.findings(arena.allocator(), files, support.only(&.{.minority_naming_style}, .information));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(std.mem.find(u8, files[found[0].file_index].source, "node").?, found[0].finding.span.start);
}

test "one-word names, type functions and C type names follow any style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try arena.allocator().alloc(project.SourceFile, 41);
    inline for (files[0..40], 0..) |*file, index| file.* = .{
        .path = std.fmt.comptimePrint("src/file{d}.zig", .{index}),
        .source = std.fmt.comptimePrint("const Type{d} = struct {{ field: u8 }};\nfn useValue{d}() void {{}}\nfn deinit{d}x() void {{}}\n", .{ index, index, index }),
    };
    files[40] = .{ .path = "src/odd.zig", .source =
        \\fn deinit() void {}
        \\fn List(comptime T: type) type { return struct { items: []T }; }
        \\const clockid_t = enum(u32) { realtime, monotonic };
        \\const struct_timespec = extern struct { sec: i64, nsec: i64 };
        \\fn read_all() void {}
        \\fn ISDIR(mode: u32) bool { return mode != 0; }
        \\fn __tls_base() void {}
        \\fn callback_() void {}
        \\const priority = enum { low, high };
    };
    const found = try project.findings(arena.allocator(), files, support.only(&.{.minority_naming_style}, .information));
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const source = files[40].source;
    try std.testing.expectEqual(std.mem.find(u8, source, "read_all").?, found[0].finding.span.start);
    try std.testing.expectEqual(std.mem.find(u8, source, "priority").?, found[1].finding.span.start);
}

/// Twenty files that each declare a function spelled by `function_format`
/// and a `TypeN` struct, followed by `extra`.
fn namingFixture(allocator: std.mem.Allocator, comptime function_format: []const u8, extra: []const project.SourceFile) ![]const project.SourceFile {
    const files = try allocator.alloc(project.SourceFile, 20 + extra.len);
    inline for (files[0..20], 0..) |*file, index| file.* = .{
        .path = std.fmt.comptimePrint("src/file{d}.zig", .{index}),
        .source = std.fmt.comptimePrint("const Type{d} = struct {{ field: u8 }};\nfn " ++ function_format ++ "() void {{}}\n", .{ index, index }),
    };
    @memcpy(files[20..], extra);
    return files;
}

test "a strong majority casing becomes the project's naming convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snake = try namingFixture(arena.allocator(), "read_value_{d}", &.{});
    const conventions = try project.namingConventions(arena.allocator(), snake);
    try std.testing.expectEqual(types.NameCase.snake_case, conventions.function.?);
    try std.testing.expectEqual(types.NameCase.title_case, conventions.type_name.?);
    try std.testing.expectEqual(@as(?types.NameCase, null), conventions.constant);
    const sparse = try project.namingConventions(arena.allocator(), snake[0..10]);
    try std.testing.expectEqual(@as(?types.NameCase, null), sparse.function);
}

test "names that break Zig's convention are left to non-idiomatic-name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const camel = try namingFixture(arena.allocator(), "readValue{d}", &.{
        .{ .path = "src/odd.zig", .source = "fn read_snake() void {}\nfn Read_Mixed() void {}\n" },
    });
    const alone = try project.findings(arena.allocator(), camel, support.only(&.{.minority_naming_style}, .information));
    try std.testing.expectEqual(@as(usize, 2), alone.len);
    const both = try project.findings(arena.allocator(), camel, support.only(&.{ .minority_naming_style, .non_idiomatic_name }, .information));
    try std.testing.expectEqual(@as(usize, 0), both.len);
    // A camelCase function follows Zig's guide, so only this rule reports it.
    const snake = try namingFixture(arena.allocator(), "read_value_{d}", &.{
        .{ .path = "src/odd.zig", .source = "fn readCamel() void {}\n" },
    });
    const departures = try project.findings(arena.allocator(), snake, support.only(&.{ .minority_naming_style, .non_idiomatic_name }, .information));
    try std.testing.expectEqual(@as(usize, 1), departures.len);
    try std.testing.expectEqual(std.mem.find(u8, snake[20].source, "readCamel").?, departures[0].finding.span.start);
}

test "qualified, underscored and synonymous parameter names are deliberate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try conventionFixture(arena.allocator(), &.{
        .{ .path = "src/odd.zig", .source =
        \\fn parentUse(parent_pool: *Pool) void { _ = parent_pool; }
        \\fn shadowed(pool_: *Pool) void { _ = pool_; }
        \\fn inner(pool_inner: *Pool) void { _ = pool_inner; }
        \\fn other(store: *Pool) void { _ = store; }
        \\fn similar(pooled: *Pool) void { _ = pooled; }
        },
    });
    const found = try project.findings(arena.allocator(), files, support.only(&.{.inconsistent_parameter_vocabulary}, .information));
    try std.testing.expectEqual(@as(usize, 2), found.len);
    const odd = files[found[0].file_index].source;
    try std.testing.expectEqual(std.mem.find(u8, odd, "store").?, found[0].finding.span.start);
    try std.testing.expectEqual(std.mem.find(u8, odd, "pooled").?, found[1].finding.span.start);
    try std.testing.expect(variantOf("ctx", "userdata"));
    try std.testing.expect(variantOf("ctx_ptr", "userdata"));
    try std.testing.expect(variantOf("terminal", "terminal_"));
    try std.testing.expect(variantOf("manifest_log_verify", "manifest_log"));
    try std.testing.expect(!variantOf("data", "userdata"));
    try std.testing.expect(!variantOf("endianness", "endian"));
}
