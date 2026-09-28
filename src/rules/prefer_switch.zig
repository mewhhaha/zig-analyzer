const std = @import("std");
const syntax_scope = @import("../syntax_scope.zig");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

const SwitchDomain = enum { integer, enumeration, error_set };

const IntegerProng = struct {
    negative: bool,
    magnitude: u64,
};

const SwitchProng = struct {
    source: []const u8,
    domain: SwitchDomain,
    integer: ?IntegerProng = null,
};

const SwitchComparison = struct {
    subject: []const u8,
    subject_start: usize,
    subject_end: usize,
    prong: SwitchProng,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_switch);
    if (level == .off) return;

    var scope_index = try syntax_scope.Index.init(context.allocator, context.source, context.tokens);
    defer scope_index.deinit();
    var prongs: std.ArrayList(SwitchProng) = .empty;
    defer prongs.deinit(context.allocator);

    for (context.tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index > 0 and context.tokens[if_index - 1].tag == .keyword_else) continue;

        prongs.clearRetainingCapacity();
        var current_if = if_index;
        var subject: ?[]const u8 = null;
        var subject_start: ?usize = null;
        var subject_end: ?usize = null;
        var domain: ?SwitchDomain = null;
        var chain_is_switchable = true;
        while (true) {
            if (current_if + 1 >= context.tokens.len or context.tokens[current_if + 1].tag != .l_paren) {
                chain_is_switchable = false;
                break;
            }
            const condition_end = context.matchingToken(current_if + 1, .l_paren, .r_paren) orelse {
                chain_is_switchable = false;
                break;
            };
            const comparison = switchComparison(context, current_if + 2, condition_end) orelse {
                chain_is_switchable = false;
                break;
            };
            if (subject) |known_subject| {
                if (!std.mem.eql(u8, known_subject, comparison.subject)) {
                    chain_is_switchable = false;
                    break;
                }
            } else {
                subject = comparison.subject;
                subject_start = comparison.subject_start;
                subject_end = comparison.subject_end;
                domain = comparison.prong.domain;
            }
            if (domain.? != comparison.prong.domain) chain_is_switchable = false;
            for (prongs.items) |prong| {
                const duplicate = if (prong.integer) |integer|
                    integer.negative == comparison.prong.integer.?.negative and
                        integer.magnitude == comparison.prong.integer.?.magnitude
                else
                    std.mem.eql(u8, prong.source, comparison.prong.source);
                if (!duplicate) continue;
                chain_is_switchable = false;
                break;
            }
            if (!chain_is_switchable) break;
            try prongs.append(context.allocator, comparison.prong);

            const body_start = condition_end + 1;
            if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) {
                chain_is_switchable = false;
                break;
            }
            const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse {
                chain_is_switchable = false;
                break;
            };
            if (body_end + 2 >= context.tokens.len or context.tokens[body_end + 1].tag != .keyword_else or
                context.tokens[body_end + 2].tag != .keyword_if) break;
            current_if = body_end + 2;
        }

        if (!chain_is_switchable or prongs.items.len < 2) continue;
        if (subjectSwitchDomain(context, &scope_index, subject_start.?, subject_end.?, domain.?) != domain.?) continue;
        try context.emit(.{
            .rule = .prefer_switch,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "{d} equality branches dispatch on '{s}'; use a switch",
                .{ prongs.items.len, subject.? },
            ),
        });
    }
}

fn switchComparison(context: RuleRun, start: usize, end: usize) ?SwitchComparison {
    const equality = singleEquality(context.tokens, start, end) orelse return null;
    if (switchProng(context, start, equality)) |prong| {
        const span = stableSubject(context, equality + 1, end) orelse return null;
        return .{
            .subject = context.source[context.tokens[span.start].loc.start..context.tokens[span.end - 1].loc.end],
            .subject_start = span.start,
            .subject_end = span.end,
            .prong = prong,
        };
    }
    const span = stableSubject(context, start, equality) orelse return null;
    const prong = switchProng(context, equality + 1, end) orelse return null;
    return .{
        .subject = context.source[context.tokens[span.start].loc.start..context.tokens[span.end - 1].loc.end],
        .subject_start = span.start,
        .subject_end = span.end,
        .prong = prong,
    };
}

fn singleEquality(tokens: []const std.zig.Token, start: usize, end: usize) ?usize {
    var equality: ?usize = null;
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .equal_equal) continue;
        if (equality != null) return null;
        equality = index;
    }
    return equality;
}

const SubjectSpan = struct {
    start: usize,
    end: usize,
};

fn stableSubject(context: RuleRun, start: usize, end: usize) ?SubjectSpan {
    if (start >= end) return null;
    for (context.tokens[start..end], 0..) |token, offset| {
        if (offset % 2 == 0) {
            if (token.tag != .identifier) return null;
        } else {
            if (token.tag != .period) return null;
        }
    }
    if ((end - start) % 2 != 1) return null;
    return .{ .start = start, .end = end };
}

fn switchProng(context: RuleRun, start: usize, end: usize) ?SwitchProng {
    if (start + 2 == end and context.tokens[start].tag == .minus and context.tokens[start + 1].tag == .number_literal) {
        return switch (std.zig.parseNumberLiteral(context.tokenText(start + 1))) {
            .int => |magnitude| .{
                .source = context.source[context.tokens[start].loc.start..context.tokens[start + 1].loc.end],
                .domain = .integer,
                .integer = .{ .negative = magnitude != 0, .magnitude = magnitude },
            },
            .big_int, .float, .failure => null,
        };
    }
    if (start + 1 == end and context.tokens[start].tag == .number_literal) {
        switch (std.zig.parseNumberLiteral(context.tokenText(start))) {
            .int => |magnitude| return .{
                .source = context.tokenText(start),
                .domain = .integer,
                .integer = .{ .negative = false, .magnitude = magnitude },
            },
            .big_int, .float, .failure => return null,
        }
    }
    if (start + 1 == end and context.tokens[start].tag == .char_literal) {
        const value = switch (std.zig.parseCharLiteral(context.tokenText(start))) {
            .success => |value| value,
            .failure => return null,
        };
        return .{
            .source = context.tokenText(start),
            .domain = .integer,
            .integer = .{ .negative = false, .magnitude = value },
        };
    }
    if (start + 2 == end and context.tokens[start].tag == .period and context.tokens[start + 1].tag == .identifier) {
        return .{
            .source = context.source[context.tokens[start].loc.start..context.tokens[end - 1].loc.end],
            .domain = .enumeration,
        };
    }
    if (start + 3 == end and context.tokens[start].tag == .keyword_error and
        context.tokens[start + 1].tag == .period and context.tokens[start + 2].tag == .identifier)
    {
        return .{
            .source = context.source[context.tokens[start].loc.start..context.tokens[end - 1].loc.end],
            .domain = .error_set,
        };
    }
    return null;
}

fn subjectSwitchDomain(
    context: RuleRun,
    scope_index: *const syntax_scope.Index,
    start: usize,
    end: usize,
    domain: SwitchDomain,
) ?SwitchDomain {
    if (start + 1 == end) {
        return bindingSwitchDomain(context, scope_index, start);
    }
    const root_binding = scope_index.findBinding(start) orelse return null;
    if (bindingIsAnytype(context, root_binding)) return null;

    if (resolveDottedFieldDomain(context, scope_index, start, end)) |res| {
        return res;
    }
    if ((domain == .enumeration or domain == .error_set) and hasExplicitType(context, root_binding)) {
        return domain;
    }
    return null;
}

fn bindingIsAnytype(context: RuleRun, binding: syntax_scope.Binding) bool {
    if (binding.token_index + 2 >= context.tokens.len or
        context.tokens[binding.token_index + 1].tag != .colon) return false;
    return context.tokenIs(binding.token_index + 2, "anytype");
}

fn hasExplicitType(context: RuleRun, binding: syntax_scope.Binding) bool {
    if (binding.token_index + 2 >= context.tokens.len or
        context.tokens[binding.token_index + 1].tag != .colon) return false;
    return !context.tokenIs(binding.token_index + 2, "anytype");
}

fn resolveDottedFieldDomain(
    context: RuleRun,
    scope_index: *const syntax_scope.Index,
    start: usize,
    end: usize,
) ?SwitchDomain {
    var current_binding = scope_index.findBinding(start) orelse return null;
    var cursor = start;
    while (cursor + 2 < end) {
        cursor += 2;
        const field_name = context.tokenText(cursor);
        const container_type_binding = resolveContainerTypeBinding(context, scope_index, current_binding) orelse return null;
        current_binding = findFieldInContainer(context, container_type_binding, field_name) orelse return null;
    }
    return bindingDomainFromDecl(context, scope_index, current_binding.token_index);
}

fn resolveContainerTypeBinding(
    context: RuleRun,
    scope_index: *const syntax_scope.Index,
    binding: syntax_scope.Binding,
) ?syntax_scope.Binding {
    if (binding.token_index + 2 >= context.tokens.len or
        context.tokens[binding.token_index + 1].tag != .colon) return null;
    var type_cursor = binding.token_index + 2;
    while (type_cursor < context.tokens.len and
        (context.tokens[type_cursor].tag == .asterisk or
            context.tokens[type_cursor].tag == .question_mark or
            context.tokens[type_cursor].tag == .keyword_const)) : (type_cursor += 1)
    {}
    if (type_cursor >= context.tokens.len or context.tokens[type_cursor].tag != .identifier) return null;
    return scope_index.findBindingNamed(context.tokenText(type_cursor), binding.token_index);
}

fn findFieldInContainer(
    context: RuleRun,
    container_binding: syntax_scope.Binding,
    field_name: []const u8,
) ?syntax_scope.Binding {
    const decl_idx = container_binding.token_index;
    if (decl_idx + 2 >= context.tokens.len or context.tokens[decl_idx + 1].tag != .equal) return null;
    var struct_kw = decl_idx + 2;
    if (struct_kw < context.tokens.len and context.tokens[struct_kw].tag == .keyword_packed) struct_kw += 1;
    if (struct_kw >= context.tokens.len or context.tokens[struct_kw].tag != .keyword_struct) return null;
    if (struct_kw + 1 >= context.tokens.len or context.tokens[struct_kw + 1].tag != .l_brace) return null;
    const closing = context.matchingToken(struct_kw + 1, .l_brace, .r_brace) orelse return null;

    var index = struct_kw + 2;
    while (index < closing) : (index += 1) {
        if (context.tokens[index].tag == .identifier and context.tokenIs(index, field_name) and
            index + 1 < closing and context.tokens[index + 1].tag == .colon)
        {
            return .{
                .token_index = index,
                .scope = context.tokens[index].loc,
                .kind = .non_callable,
            };
        }
    }
    return null;
}

fn bindingDomainFromDecl(
    context: RuleRun,
    scope_index: *const syntax_scope.Index,
    field_decl_index: usize,
) ?SwitchDomain {
    const type_start = field_decl_index + 2;
    if (field_decl_index + 1 >= context.tokens.len or context.tokens[field_decl_index + 1].tag != .colon or
        type_start >= context.tokens.len) return null;
    const type_end = bindingTypeEnd(context.tokens, type_start) orelse return null;
    if (type_start + 1 != type_end or context.tokens[type_start].tag != .identifier) return null;
    if (context.tokenIs(type_start, "anyerror")) return .error_set;
    if (integerTypeName(context.tokenText(type_start))) return .integer;

    const type_binding = scope_index.findBinding(type_start) orelse return null;
    if (type_binding.token_index + 2 >= context.tokens.len or
        context.tokens[type_binding.token_index + 1].tag != .equal) return null;
    return switch (context.tokens[type_binding.token_index + 2].tag) {
        .keyword_enum => .enumeration,
        .keyword_error => .error_set,
        else => null,
    };
}

fn bindingSwitchDomain(
    context: RuleRun,
    scope_index: *const syntax_scope.Index,
    subject_index: usize,
) ?SwitchDomain {
    const binding = scope_index.findBinding(subject_index) orelse return null;
    const type_start = binding.token_index + 2;
    if (binding.token_index + 1 >= context.tokens.len or context.tokens[binding.token_index + 1].tag != .colon or
        type_start >= context.tokens.len) return null;
    const type_end = bindingTypeEnd(context.tokens, type_start) orelse return null;
    if (type_start + 1 != type_end or context.tokens[type_start].tag != .identifier) return null;
    if (context.tokenIs(type_start, "anyerror")) return .error_set;
    if (integerTypeName(context.tokenText(type_start))) return .integer;

    const type_binding = scope_index.findBinding(type_start) orelse return null;
    if (type_binding.token_index + 2 >= context.tokens.len or
        context.tokens[type_binding.token_index + 1].tag != .equal) return null;
    return switch (context.tokens[type_binding.token_index + 2].tag) {
        .keyword_enum => .enumeration,
        .keyword_error => .error_set,
        else => null,
    };
}

fn integerTypeName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize") or
        std.mem.eql(u8, name, "comptime_int")) return true;
    const c_integer_types = [_][]const u8{
        "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong",
    };
    for (c_integer_types) |type_name| if (std.mem.eql(u8, name, type_name)) return true;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
    for (name[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn bindingTypeEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => {
            if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index;
            parenthesis_depth -= 1;
        },
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        .comma, .equal, .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index,
        else => {},
    };
    return null;
}

test "enum equality chains prefer switch dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe, small };\n" ++
        "fn modeValue(mode: Mode) u8 {\n" ++
        "    var value: u8 = 0;\n" ++
        "    if (mode == .fast) { value = 1; } else if (.safe == mode) { value = 2; } else if (mode == .small) { value = 3; }\n" ++
        "    return value;\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "3 equality branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'mode'") != null);
    try std.testing.expectEqual(@as(usize, 0), findings[0].fixes.len);
}

test "error equality chains prefer switch dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Failure = error { Missing, Denied };\n" ++
        "fn classify(err: Failure) void {\n" ++
        "    if (err == error.Missing) {} else if (err == error.Denied) {} else {}\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "2 equality branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'err'") != null);
}

test "integer equality chains prefer switch dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn classify(code: i16) void {\n" ++
        "    if (code == 0) {} else if (code == 'A') {} else if (code == -1) {}\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "3 equality branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "'code'") != null);
}

test "ambiguous or invalid switch conversions stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { one, two };\n" ++
        "fn examples(first: anytype, second: anytype, optional: ?Mode) void {\n" ++
        "    if (first == .one) {}\n" ++
        "    if (first == .one) {} else if (second == .two) {}\n" ++
        "    if (first == .one) {} else if (first == .one) {}\n" ++
        "    if (first == .one) {} else if (ready() and first == .two) {}\n" ++
        "    if (first == 1) {} else if (first == 2) {}\n" ++
        "    if (current() == .one) {} else if (current() == .two) {}\n" ++
        "    if (optional == .one) {} else if (optional == .two) {}\n" ++
        "    if (first.value == .one) {} else if (first.value == .two) {}\n" ++
        "    if (first == .one) first = .two else if (first == .two) first = .one;\n" ++
        "}\n" ++
        "fn duplicateCode(code: u8) void { if (code == 1) {} else if (code == 0x1) {} }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "prefer switch is disabled by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn run(mode: Mode) void {\n" ++
        "    if (mode == .fast) {} else if (mode == .safe) {}\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "prefer switch respects source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn run(mode: Mode) void {\n" ++
        "    // zig-analyzer: disable-next-line prefer-switch\n" ++
        "    if (mode == .fast) {} else if (mode == .safe) {}\n" ++
        "}";
    const tokens = try tokenize(arena.allocator(), source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_switch)] = .information;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "prefer switch supports dotted field dispatch on typed struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Config = struct { mode: Mode };\n" ++
        "fn run(cfg: Config) void {\n" ++
        "    if (cfg.mode == .fast) {} else if (cfg.mode == .safe) {}\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(std.mem.indexOf(u8, findings[0].message, "cfg.mode") != null);
}

test "prefer switch ignores anytype receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(cfg: anytype) void {\n" ++
        "    if (cfg.mode == .fast) {} else if (cfg.mode == .safe) {}\n" ++
        "}";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@intFromEnum(types.Rule.prefer_switch)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
