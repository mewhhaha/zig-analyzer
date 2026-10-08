const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const support = @import("../test_support.zig");

pub fn run(context: RuleRun) !void {
    if (context.level(.modernize_deprecated_io) == .off and
        context.level(.modernize_deprecated_stdlib) == .off and
        context.level(.unreported_partial_send) == .off) return;
    const scopes = context.scopes;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or context.tokens[index - 1].tag != .period) continue;
        const name = context.tokenText(index);
        if (!interestingMember(name)) continue;
        const receiver_start = chainStart(context, scopes, index - 2) orelse continue;
        const receiver = resolve(context, scopes, receiver_start, index - 1, 0);
        if ((receiver == .reader_type or receiver == .reader_value) and std.mem.eql(u8, name, "readAlloc")) {
            try emitRename(context, index, .modernize_deprecated_io, "std.Io.Reader", "readAllocAll");
        } else if ((receiver == .socket_type or receiver == .socket_value) and std.mem.eql(u8, name, "sendMany")) {
            try emitAdvice(context, index, .unreported_partial_send, "Socket.sendMany cannot report how many messages were sent before an error; use sendManyTimeout(..., .none) and handle both the optional error and the sent-message count");
        } else if (receiver == .query_type or receiver == .query_value) {
            if (std.mem.eql(u8, name, "allocDescription")) {
                try emitRename(context, index, .modernize_deprecated_stdlib, "std.Target.Query", "zigTriple");
            } else if (std.mem.eql(u8, name, "setGnuLibCVersion")) {
                try emitAdvice(context, index, .modernize_deprecated_stdlib, "std.Target.Query.setGnuLibCVersion is deprecated and scheduled for removal in Zig 0.18; set glibc_version directly with a std.SemanticVersion value");
            }
        } else if (receiver == .arch_type or receiver == .arch_value) {
            if (arch_replacements.get(name)) |replacement| {
                try emitRename(context, index, .modernize_deprecated_stdlib, "std.Target.Cpu.Arch", replacement);
            }
        } else if (receiver == .target_type or receiver == .target_value) {
            if (triple_replacements.get(name)) |replacement| {
                // Simple helpers have no Target receiver argument.
                if (receiver == .target_value and std.mem.endsWith(u8, name, "Simple")) continue;
                try emitAdvice(context, index, .modernize_deprecated_stdlib, try context.allocator.print("std.Target.{s} is deprecated and scheduled for removal in Zig 0.18; use std.zig.target.{s} and review the argument order", .{ name, replacement }));
            }
        }
    }
}

const arch_replacements = std.StaticStringMap([]const u8).initComptime(.{
    .{ "isAARCH64", "isAarch64" },
    .{ "isLoongArch", "isLoongarch" },
    .{ "isRISCV", "isRiscv" },
    .{ "isMIPS", "isMips" },
    .{ "isMIPS32", "isMips32" },
    .{ "isMIPS64", "isMips64" },
    .{ "isPowerPC", "isPowerpc" },
    .{ "isPowerPC32", "isPowerpc32" },
    .{ "isPowerPC64", "isPowerpc64" },
    .{ "isSPARC", "isSparc" },
    .{ "isSpirV", "isSpirv" },
});

const triple_replacements = std.StaticStringMap([]const u8).initComptime(.{
    .{ "hurdTupleSimple", "hurdTupleSimple" },
    .{ "hurdTuple", "hurdTuple" },
    .{ "linuxTripleSimple", "linuxTripleSimple" },
    .{ "linuxTriple", "linuxTriple" },
});

fn interestingMember(name: []const u8) bool {
    return std.mem.eql(u8, name, "readAlloc") or std.mem.eql(u8, name, "sendMany") or
        std.mem.eql(u8, name, "allocDescription") or std.mem.eql(u8, name, "setGnuLibCVersion") or
        arch_replacements.has(name) or triple_replacements.has(name);
}

fn emitRename(context: RuleRun, index: usize, rule: types.Rule, owner: []const u8, replacement: []const u8) !void {
    const level = context.level(rule);
    if (level == .off) return;
    const fixes = try context.singleFix(.{
        .title = try context.allocator.print("Use {s}", .{replacement}),
        .span = context.tokens[index].loc,
        .replacement = replacement,
        .preferred = true,
        .fix_all = true,
    });
    try context.emit(.{
        .rule = rule,
        .level = level,
        .span = context.tokens[index].loc,
        .message = try context.allocator.print("{s}.{s} is deprecated in Zig 0.17; use {s}", .{ owner, context.tokenText(index), replacement }),
        .fixes = fixes,
    });
}

fn emitAdvice(context: RuleRun, index: usize, rule: types.Rule, message: []const u8) !void {
    try context.emit(.{ .rule = rule, .level = context.level(rule), .span = context.tokens[index].loc, .message = message });
}

const Family = enum {
    unknown,
    standard,
    io,
    net,
    reader_type,
    socket_type,
    target_type,
    query_type,
    cpu_namespace,
    arch_type,
    reader_value,
    socket_value,
    target_value,
    query_value,
    arch_value,
    reader_factory,
};

// Proof follows lexical bindings and complete known expressions. Arbitrary
// calls and projections cannot establish the receiver's standard-library type.
fn resolve(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize, depth: usize) Family {
    if (start >= end or end > context.tokens.len or depth >= 20) return .unknown;
    var cursor = start;
    while (cursor < end and (context.tokens[cursor].tag == .ampersand or
        context.tokens[cursor].tag == .asterisk or context.tokens[cursor].tag == .keyword_const)) cursor += 1;
    if (cursor == end) return .unknown;
    var family: Family = .unknown;
    if (context.tokenIs(cursor, "@import")) {
        if (cursor + 3 >= end or context.tokens[cursor + 1].tag != .l_paren or
            !context.tokenIs(cursor + 2, "\"std\"") or context.tokens[cursor + 3].tag != .r_paren) return .unknown;
        family = .standard;
        cursor += 4;
    } else if (context.tokenIs(cursor, "@as")) {
        if (cursor + 1 >= end or context.tokens[cursor + 1].tag != .l_paren) return .unknown;
        const closing = scopes.matchingToken(cursor + 1) orelse return .unknown;
        if (closing >= end) return .unknown;
        const comma = topLevelComma(context, scopes, cursor + 2, closing) orelse return .unknown;
        family = instanceFamily(resolve(context, scopes, cursor + 2, comma, depth + 1));
        cursor = closing + 1;
    } else if (context.tokens[cursor].tag == .identifier) {
        const binding = scopes.findBinding(cursor) orelse return .unknown;
        family = bindingFamily(context, scopes, binding.token_index, depth + 1);
        cursor += 1;
    } else if (context.tokens[cursor].tag == .l_paren) {
        const closing = scopes.matchingToken(cursor) orelse return .unknown;
        if (closing >= end) return .unknown;
        family = resolve(context, scopes, cursor + 1, closing, depth + 1);
        cursor = closing + 1;
    } else return .unknown;
    while (cursor < end and family != .unknown) {
        switch (context.tokens[cursor].tag) {
            .period => {
                if (cursor + 1 >= end or context.tokens[cursor + 1].tag != .identifier) return .unknown;
                family = memberFamily(family, context.tokenText(cursor + 1));
                cursor += 2;
            },
            .l_brace => {
                const closing = scopes.matchingToken(cursor) orelse return .unknown;
                if (closing >= end) return .unknown;
                family = instanceFamily(family);
                cursor = closing + 1;
            },
            .l_paren => {
                const closing = scopes.matchingToken(cursor) orelse return .unknown;
                if (closing >= end) return .unknown;
                family = if (family == .reader_factory) .reader_value else .unknown;
                cursor = closing + 1;
            },
            else => return .unknown,
        }
    }
    return family;
}

fn memberFamily(family: Family, name: []const u8) Family {
    return switch (family) {
        .standard => if (std.mem.eql(u8, name, "Io")) .io else if (std.mem.eql(u8, name, "Target")) .target_type else .unknown,
        .io => if (std.mem.eql(u8, name, "Reader")) .reader_type else if (std.mem.eql(u8, name, "net")) .net else .unknown,
        .net => if (std.mem.eql(u8, name, "Socket")) .socket_type else .unknown,
        .target_type => if (std.mem.eql(u8, name, "Query")) .query_type else if (std.mem.eql(u8, name, "Cpu")) .cpu_namespace else .unknown,
        .cpu_namespace => if (std.mem.eql(u8, name, "Arch")) .arch_type else .unknown,
        .reader_type => if (std.mem.eql(u8, name, "fixed")) .reader_factory else .unknown,
        else => .unknown,
    };
}

fn instanceFamily(family: Family) Family {
    return switch (family) {
        .reader_type => .reader_value,
        .socket_type => .socket_value,
        .target_type => .target_value,
        .query_type => .query_value,
        .arch_type => .arch_value,
        .unknown,
        .standard,
        .io,
        .net,
        .cpu_namespace,
        .reader_value,
        .socket_value,
        .target_value,
        .query_value,
        .arch_value,
        .reader_factory,
        => .unknown,
    };
}

fn bindingFamily(context: RuleRun, scopes: *const syntax_scope.Index, binding: usize, depth: usize) Family {
    if (binding + 2 >= context.tokens.len) return .unknown;
    if (context.tokens[binding + 1].tag == .colon) {
        var end = binding + 2;
        while (end < context.tokens.len) {
            switch (context.tokens[end].tag) {
                .l_paren, .l_bracket => end = scopes.matchingToken(end) orelse return .unknown,
                .comma, .r_paren, .equal, .semicolon, .keyword_align => break,
                else => {},
            }
            end += 1;
        }
        if (end == binding + 3 and context.tokenIs(binding + 2, "type") and
            end < context.tokens.len and context.tokens[end].tag == .equal)
        {
            const statement_end = scopes.statementEnd(end + 1) orelse return .unknown;
            return stableFamily(context, binding, resolve(context, scopes, end + 1, statement_end, depth));
        }
        return instanceFamily(resolve(context, scopes, binding + 2, end, depth));
    }
    if (context.tokens[binding + 1].tag != .equal) return .unknown;
    const end = scopes.statementEnd(binding + 2) orelse return .unknown;
    return stableFamily(context, binding, resolve(context, scopes, binding + 2, end, depth));
}

fn stableFamily(context: RuleRun, binding: usize, family: Family) Family {
    return switch (family) {
        .reader_value, .socket_value, .target_value, .query_value, .arch_value => family,
        else => if (binding > 0 and context.tokens[binding - 1].tag == .keyword_const) family else .unknown,
    };
}

fn chainStart(context: RuleRun, scopes: *const syntax_scope.Index, final: usize) ?usize {
    var start = final;
    for (0..128) |_| {
        switch (context.tokens[start].tag) {
            .r_paren, .r_brace => {
                start = scopes.matchingToken(start) orelse return null;
                if (start > 0 and (context.tokens[start - 1].tag == .identifier or
                    context.tokens[start - 1].tag == .builtin or context.tokens[start - 1].tag == .r_paren))
                {
                    start -= 1;
                    continue;
                }
            },
            .identifier, .builtin => {},
            else => return null,
        }
        if (start >= 2 and context.tokens[start - 1].tag == .period) {
            start -= 2;
            continue;
        }
        while (start > 0 and context.tokens[start - 1].tag == .ampersand) start -= 1;
        return start;
    }
    return null;
}

fn topLevelComma(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize) ?usize {
    var cursor = start;
    while (cursor < end) : (cursor += 1) {
        switch (context.tokens[cursor].tag) {
            .l_paren, .l_bracket, .l_brace => cursor = scopes.matchingToken(cursor) orelse return null,
            .comma => return cursor,
            else => {},
        }
    }
    return null;
}

test "reader deprecation proves imports types aliases parameters and fixed results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const library = @import(\"std\"); const io = library.Io;\n" ++
        "const Reader: type = io.Reader; const fixed = Reader.fixed;\n" ++
        "fn f(reader: *Reader) void {\n" ++
        "    const copy = reader; _ = copy.readAlloc(allocator, 4);\n" ++
        "    _ = Reader.readAlloc(reader, allocator, 4);\n" ++
        "    var buffer = fixed(\"data\"); _ = buffer.readAlloc(allocator, 4);\n" ++
        "    _ = (@import(\"std\").Io.Reader.fixed(\"data\")).readAlloc(allocator, 4);\n" ++
        "    const cast = @as(*Reader, reader); _ = cast.readAlloc(allocator, 4);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| {
        try std.testing.expectEqual(types.Rule.modernize_deprecated_io, finding.rule);
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expectEqual(@as(usize, 1), finding.fixes[0].edits.len);
        const edit = finding.fixes[0].edits[0];
        try std.testing.expectEqualStrings("readAlloc", source[edit.span.start..edit.span.end]);
        try std.testing.expectEqualStrings("readAllocAll", edit.replacement);
    }
}

test "target deprecation distinguishes safe aliases from shape changing helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Target = std.Target;\n" ++
        "const Query = Target.Query; const Cpu = Target.Cpu; const Arch = Cpu.Arch;\n" ++
        "fn f(query: *Query, arch: Arch, target: *const Target) void {\n" ++
        "    const alias = query; _ = alias.allocDescription(allocator);\n" ++
        "    var value: Query = .{}; _ = value.allocDescription;\n" ++
        "    _ = Query.allocDescription(query, allocator);\n" ++
        "    _ = query.setGnuLibCVersion(2, 31, 0);\n" ++
        "    _ = Arch.isAARCH64(arch); _ = arch.isRISCV();\n" ++
        "    _ = Target.linuxTripleSimple(allocator, arch, .linux, .gnu);\n" ++
        "    _ = target.hurdTuple(allocator);\n" ++
        "    _ = arch.isArm(); _ = arch.isAarch64();\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 8), findings.len);
    const replacements = [_]?[]const u8{ "zigTriple", "zigTriple", "zigTriple", null, "isAarch64", "isRiscv", null, null };
    for (findings, replacements) |finding, replacement| {
        try std.testing.expectEqual(types.Rule.modernize_deprecated_stdlib, finding.rule);
        if (replacement) |name| {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            try std.testing.expectEqual(@as(usize, 1), finding.fixes[0].edits.len);
            try std.testing.expectEqualStrings(name, finding.fixes[0].edits[0].replacement);
        } else try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    }
}

test "socket partial send warning proves receivers and never changes error handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Socket = std.Io.net.Socket;\n" ++
        "fn f(socket: *const Socket) void {\n" ++
        "    const alias = socket; try alias.sendMany(io, messages, .{});\n" ++
        "    try Socket.sendMany(socket, io, messages, .{});\n" ++
        "    var value: Socket = undefined; value.sendMany(io, messages, .{}) catch {};\n" ++
        "    _ = socket.sendManyTimeout(io, messages, .{}, .none);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source, .defaults);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    for (findings) |finding| {
        try std.testing.expectEqual(types.Rule.unreported_partial_send, finding.rule);
        try std.testing.expectEqual(types.Level.warning, finding.level);
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    }
    try std.testing.expectEqual(types.Tier.correctness, types.Rule.unreported_partial_send.tier());
}

test "IO and target deprecations skip custom shadowed projected unknown and mutable types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Reader = std.Io.Reader; const Query = std.Target.Query;\n" ++
        "const Custom = @import(\"custom.zig\");\n" ++
        "fn shadows(std: Custom, reader: Custom, query: Custom, socket: Custom, arch: Custom) void {\n" ++
        "    _ = std.Io.Reader.readAlloc; _ = reader.readAlloc; _ = query.allocDescription;\n" ++
        "    _ = socket.sendMany; _ = arch.isAARCH64;\n" ++
        "}\n" ++
        "fn unknown(reader: *Reader, query: *Query) void {\n" ++
        "    _ = reader.field.readAlloc; _ = reader[0].readAlloc; _ = query.field.allocDescription;\n" ++
        "    const arbitrary = makeReader(); _ = arbitrary.readAlloc;\n" ++
        "    const maybe = Reader.unknownFactory(); _ = maybe.readAlloc;\n" ++
        "    const fake = Custom.Io.Reader; _ = fake.readAlloc;\n" ++
        "    const alias = reader.field; _ = alias.readAlloc;\n" ++
        "    var library: type = std; library = Custom; _ = library.Io.Reader.readAlloc;\n" ++
        "    var io = std.Io; io = Custom; _ = io.net.Socket.sendMany;\n" ++
        "    var Type: type = Reader; Type = Custom; var value: Type = .{}; _ = value.readAlloc;\n" ++
        "    var Arch = std.Target.Cpu.Arch; Arch = Custom; _ = Arch.isAARCH64;\n" ++
        "    var factory = Reader.fixed; factory = Custom.fixed; _ = factory(\"\").readAlloc;\n" ++
        "    const cyclic = cyclic; _ = cyclic.sendMany;\n" ++
        "}\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .enabled)).len);
}

test "IO and target deprecations respect suppression explicit off and modernization defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "_ = std.Io.Reader.readAlloc; _ = std.Target.Query.allocDescription;\n" ++
        "_ = std.Io.net.Socket.sendMany;\n";
    const defaults = try findingsFor(arena.allocator(), source, .defaults);
    try std.testing.expectEqual(@as(usize, 1), defaults.len);
    try std.testing.expectEqual(types.Rule.unreported_partial_send, defaults[0].rule);
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .off)).len);
    const suppressed: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "// zig-analyzer: disable modernize-deprecated-io, modernize-deprecated-stdlib, unreported-partial-send\n" ++
        "_ = std.Io.Reader.readAlloc; _ = std.Target.Query.allocDescription; _ = std.Io.net.Socket.sendMany;\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), suppressed, .enabled)).len);
}

test "safe IO and target replacements compile against Zig 0.17" {
    var reader = std.Io.Reader.fixed("data");
    const bytes = try reader.readAllocAll(std.testing.allocator, 4);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("data", bytes);
    const query: std.Target.Query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu };
    const triple = try query.zigTriple(std.testing.allocator);
    defer std.testing.allocator.free(triple);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", triple);
    inline for (comptime arch_replacements.keys()) |old_name| {
        const replacement = comptime arch_replacements.get(old_name).?;
        for ([_]std.Target.Cpu.Arch{ .aarch64, .riscv64, .mips, .powerpc, .spirv64 }) |arch| {
            try std.testing.expectEqual(@field(std.Target.Cpu.Arch, old_name)(arch), @field(std.Target.Cpu.Arch, replacement)(arch));
        }
    }
}

test "target architecture deprecation covers each actual legacy alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena.allocator(), "const std = @import(\"std\"); const Arch = std.Target.Cpu.Arch;\n");
    for (arch_replacements.keys()) |name| {
        try source.appendSlice(arena.allocator(), try arena.allocator().print("_ = Arch.{s};\n", .{name}));
    }
    const findings = try findingsFor(arena.allocator(), try arena.allocator().dupeSentinel(u8, source.items, 0), .enabled);
    try std.testing.expectEqual(arch_replacements.keys().len, findings.len);
    for (findings) |finding| {
        const name = source.items[finding.span.start..finding.span.end];
        try std.testing.expectEqualStrings(arch_replacements.get(name).?, finding.fixes[0].edits[0].replacement);
    }
}

const TestMode = enum { defaults, enabled, off };

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, mode: TestMode) ![]const types.Finding {
    const config = switch (mode) {
        .defaults => types.Configuration.defaults(),
        .enabled => support.only(&.{ .modernize_deprecated_io, .modernize_deprecated_stdlib, .unreported_partial_send }, .information),
        .off => support.only(&.{ .modernize_deprecated_io, .modernize_deprecated_stdlib, .unreported_partial_send }, .off),
    };
    return support.findings(allocator, run, source, config);
}
