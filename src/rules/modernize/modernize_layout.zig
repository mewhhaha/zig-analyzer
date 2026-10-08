const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .modernize_extern_bitcast,
    .modernize_global_linkage,
};

pub fn run(context: RuleRun) !void {
    if (context.level(.modernize_extern_bitcast) == .off and
        context.level(.modernize_global_linkage) == .off) return;
    const scopes = context.scopes;
    try findExternBitcasts(context, scopes);
    try findGlobalLinkage(context, scopes);
}

// Type and value alias chains are bounded; unresolved and cyclic bindings
// never provide the proof needed for a migration diagnostic.
const max_alias_depth = 16;

fn findExternBitcasts(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_extern_bitcast);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .builtin or !context.tokenIs(index, "@bitCast") or
            index + 2 >= context.tokens.len or context.tokens[index + 1].tag != .l_paren) continue;
        const close = scopes.matchingToken(index + 1) orelse continue;
        const argument_end = withoutTrailingComma(context, index + 2, close);
        const source_is_extern = externExpression(context, scopes, index + 2, argument_end, 0);
        const destination_is_extern = externDestination(context, scopes, index, close);
        if (!source_is_extern and !destination_is_extern) continue;
        try context.emit(.{
            .rule = .modernize_extern_bitcast,
            .level = level,
            .span = token.loc,
            .message = "@bitCast involving an extern struct or extern union is forbidden in Zig 0.17; review @ptrCast or an extern union for native-memory reinterpretation, preserving alignment and lifetime requirements",
        });
    }
}

fn externExpression(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize, depth: usize) bool {
    if (depth >= max_alias_depth or start >= end) return false;
    if (context.tokens[start].tag == .l_paren) {
        const close = scopes.matchingToken(start) orelse return false;
        return close + 1 == end and externExpression(context, scopes, start + 1, close, depth + 1);
    }
    if (context.tokenIs(start, "@as") and start + 2 < end and context.tokens[start + 1].tag == .l_paren) {
        const close = scopes.matchingToken(start + 1) orelse return false;
        if (close + 1 != end) return false;
        const comma = topLevelComma(context, scopes, start + 2, close) orelse return false;
        return externTypeEnd(context, scopes, start + 2, depth + 1) == comma;
    }
    if (context.tokens[start].tag == .identifier and end == start + 1) {
        const binding = scopes.findBinding(start) orelse return false;
        const declaration = binding.token_index;
        if (declaration + 2 >= context.tokens.len) return false;
        if (context.tokens[declaration + 1].tag == .colon) {
            const type_end = externTypeEnd(context, scopes, declaration + 2, depth + 1) orelse return false;
            return type_end < context.tokens.len and switch (context.tokens[type_end].tag) {
                .comma, .r_paren, .equal, .semicolon, .keyword_align => true,
                else => false,
            };
        }
        if (context.tokens[declaration + 1].tag != .equal) return false;
        const initializer_end = scopes.statementEnd(declaration) orelse return false;
        return externExpression(context, scopes, declaration + 2, initializer_end, depth + 1);
    }
    // A type name alone is a type value. Only its complete initializer is an
    // extern value; selecting a field from that initializer can yield a scalar.
    const type_end = externTypeEnd(context, scopes, start, depth + 1) orelse return false;
    if (type_end >= end or context.tokens[type_end].tag != .l_brace) return false;
    return (scopes.matchingToken(type_end) orelse return false) + 1 == end;
}

fn externTypeEnd(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, depth: usize) ?usize {
    if (depth >= max_alias_depth or start >= context.tokens.len) return null;
    if (context.tokens[start].tag == .keyword_extern and start + 2 < context.tokens.len and
        (context.tokens[start + 1].tag == .keyword_struct or context.tokens[start + 1].tag == .keyword_union) and
        context.tokens[start + 2].tag == .l_brace)
    {
        return (scopes.matchingToken(start + 2) orelse return null) + 1;
    }
    if (context.tokens[start].tag == .l_paren) {
        const close = scopes.matchingToken(start) orelse return null;
        if (externTypeEnd(context, scopes, start + 1, depth + 1) != close) return null;
        return close + 1;
    }
    if (context.tokens[start].tag != .identifier or (start > 0 and context.tokens[start - 1].tag == .period)) return null;
    const binding = scopes.findBinding(start) orelse return null;
    const declaration = binding.token_index;
    const initializer = typeAliasInitializer(context, declaration) orelse return null;
    const end = scopes.statementEnd(declaration) orelse return null;
    if (externTypeEnd(context, scopes, initializer, depth + 1) != end) return null;
    return start + 1;
}

fn typeAliasInitializer(context: RuleRun, declaration: usize) ?usize {
    if (declaration == 0 or declaration + 2 >= context.tokens.len or
        context.tokens[declaration - 1].tag != .keyword_const) return null;
    if (context.tokens[declaration + 1].tag == .equal) return declaration + 2;
    if (declaration + 4 < context.tokens.len and context.tokens[declaration + 1].tag == .colon and
        context.tokenIs(declaration + 2, "type") and context.tokens[declaration + 3].tag == .equal) return declaration + 4;
    return null;
}

fn externDestination(context: RuleRun, scopes: *const syntax_scope.Index, bitcast: usize, close: usize) bool {
    if (bitcast == 0 or close + 1 >= context.tokens.len) return false;
    // The complete second operand of @as establishes a result type. A member
    // access after @bitCast does not establish the cast's own result type.
    if (context.tokens[bitcast - 1].tag == .comma) {
        var cursor = bitcast - 1;
        while (cursor > 0) {
            cursor -= 1;
            switch (context.tokens[cursor].tag) {
                .r_paren, .r_bracket, .r_brace => cursor = scopes.matchingToken(cursor) orelse return false,
                .l_paren => {
                    if (cursor == 0 or !context.tokenIs(cursor - 1, "@as")) return false;
                    const outer_close = scopes.matchingToken(cursor) orelse return false;
                    if (withoutTrailingComma(context, bitcast, outer_close) != close + 1) return false;
                    return externTypeEnd(context, scopes, cursor + 1, 0) == bitcast - 1;
                },
                .semicolon, .l_brace => return false,
                else => {},
            }
        }
    }
    if (context.tokens[bitcast - 1].tag != .equal or context.tokens[close + 1].tag != .semicolon) return false;
    var cursor = bitcast - 1;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_const, .keyword_var => return cursor + 3 < bitcast and
                context.tokens[cursor + 2].tag == .colon and
                externTypeEnd(context, scopes, cursor + 3, 0) == bitcast - 1,
            .r_brace, .r_bracket, .r_paren => cursor = scopes.matchingToken(cursor) orelse return false,
            .semicolon, .l_brace => return false,
            else => {},
        }
    }
    return false;
}

fn findGlobalLinkage(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_global_linkage);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag == .identifier or token.tag == .builtin) {
            if (stdLangTypeEnd(context, scopes, index, "GlobalLinkage", 0)) |end| {
                if (end + 1 < context.tokens.len and context.tokens[end].tag == .period) {
                    if (removedLinkageTag(context, end + 1)) |name| try emitLinkage(context, end + 1, name, level);
                }
            }
        }
        if (token.tag != .builtin or (!context.tokenIs(index, "@export") and !context.tokenIs(index, "@extern")) or
            index + 1 >= context.tokens.len or context.tokens[index + 1].tag != .l_paren) continue;
        const close = scopes.matchingToken(index + 1) orelse continue;
        const comma = topLevelComma(context, scopes, index + 2, close) orelse continue;
        const options_start = comma + 1;
        const options_end = withoutTrailingComma(context, options_start, close);
        if (options_start >= options_end) continue;
        const opening = if (context.tokens[options_start].tag == .period and options_start + 1 < options_end and
            context.tokens[options_start + 1].tag == .l_brace)
            options_start + 1
        else
            stdLangTypeEnd(context, scopes, options_start, if (context.tokenIs(index, "@export")) "ExportOptions" else "ExternOptions", 0) orelse continue;
        if (opening >= options_end or context.tokens[opening].tag != .l_brace or
            (scopes.matchingToken(opening) orelse continue) + 1 != options_end) continue;
        try findOptionLinkage(context, scopes, opening + 1, options_end - 1, level);
    }
}

fn stdLangTypeEnd(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, name: []const u8, depth: usize) ?usize {
    if (depth >= max_alias_depth or start >= context.tokens.len) return null;
    var root_end: usize = undefined;
    if (context.tokens[start].tag == .identifier and (start == 0 or context.tokens[start - 1].tag != .period)) {
        const binding = scopes.findBinding(start) orelse return null;
        const initializer = typeAliasInitializer(context, binding.token_index) orelse return null;
        const end = scopes.statementEnd(binding.token_index) orelse return null;
        if (stdImportEnd(context, initializer) == end) {
            root_end = start + 1;
        } else {
            if (stdLangTypeEnd(context, scopes, initializer, name, depth + 1) != end) return null;
            return start + 1;
        }
    } else {
        root_end = stdImportEnd(context, start) orelse return null;
    }
    if (root_end + 3 >= context.tokens.len or context.tokens[root_end].tag != .period or
        (!context.tokenIs(root_end + 1, "lang") and !context.tokenIs(root_end + 1, "builtin")) or
        context.tokens[root_end + 2].tag != .period or !context.tokenIs(root_end + 3, name)) return null;
    return root_end + 4;
}

fn stdImportEnd(context: RuleRun, start: usize) ?usize {
    if (start + 3 >= context.tokens.len or !context.tokenIs(start, "@import") or
        context.tokens[start + 1].tag != .l_paren or !context.tokenIs(start + 2, "\"std\"") or
        context.tokens[start + 3].tag != .r_paren) return null;
    return start + 4;
}

fn findOptionLinkage(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize, level: types.Level) !void {
    var cursor = start;
    while (cursor < end) {
        const field_end = topLevelComma(context, scopes, cursor, end) orelse end;
        if (field_end == cursor + 5 and context.tokens[cursor].tag == .period and
            context.tokenIs(cursor + 1, "linkage") and context.tokens[cursor + 2].tag == .equal and
            context.tokens[cursor + 3].tag == .period)
        {
            if (removedLinkageTag(context, cursor + 4)) |name| try emitLinkage(context, cursor + 4, name, level);
        }
        cursor = field_end + 1;
    }
}

fn removedLinkageTag(context: RuleRun, index: usize) ?[]const u8 {
    if (context.tokenIs(index, "internal") or context.tokenIs(index, "@\"internal\"")) return "internal";
    if (context.tokenIs(index, "link_once") or context.tokenIs(index, "@\"link_once\"")) return "link_once";
    return null;
}

fn emitLinkage(context: RuleRun, index: usize, name: []const u8, level: types.Level) !void {
    try context.emit(.{
        .rule = .modernize_global_linkage,
        .level = level,
        .span = context.tokens[index].loc,
        .message = if (std.mem.eql(u8, name, "internal"))
            "GlobalLinkage.internal was removed in Zig 0.17; keep an internal symbol unexported rather than using @export"
        else
            "GlobalLinkage.link_once was removed in Zig 0.17; review whether weak linkage provides the intended symbol behavior",
    });
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

fn withoutTrailingComma(context: RuleRun, start: usize, end: usize) usize {
    return if (end > start and context.tokens[end - 1].tag == .comma) end - 1 else end;
}

test "modernize extern bitCast proves struct union aliases and result types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Record = extern struct { value: u32 };\n" ++
        "const Overlay = extern union { value: u32, bytes: [4]u8 };\n" ++
        "const Alias: type = Record;\n" ++
        "fn f(record: Record, overlay: Overlay, raw: u32) void {\n" ++
        "    const a: u32 = @bitCast(record);\n" ++
        "    const b: u32 = @bitCast(overlay);\n" ++
        "    const c: Alias = @bitCast(raw);\n" ++
        "    const d = @as(Record, @bitCast(raw));\n" ++
        "    const e = @bitCast(@as(Overlay, overlay));\n" ++
        "    const v = Record{ .value = raw }; const copy = v;\n" ++
        "    const g: u32 = @bitCast(copy);\n" ++
        "    const h: u32 = @bitCast(Record{ .value = raw },);\n" ++
        "    const i: extern struct { value: u32 } = @bitCast(raw);\n" ++
        "    const j = @as(extern union { value: u32 }, @bitCast(raw),);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source, .modernize_extern_bitcast);
    try std.testing.expectEqual(@as(usize, 9), findings.len);
    for (findings) |finding| {
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        try std.testing.expectEqualStrings("@bitCast", source[finding.span.start..finding.span.end]);
    }
}

test "modernize extern bitCast skips packed regular unknown and shadowed types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Record = extern struct { value: u32 };\n" ++
        "const Packed = packed struct { value: u32 };\n" ++
        "const Regular = struct { value: u32 };\n" ++
        "const A = B; const B = A;\n" ++
        "fn f(packed_value: Packed, regular: Regular, ptr: *Record, optional: ?Record, unknown: Imported, cyclic: A) void {\n" ++
        "    _ = @bitCast(packed_value); _ = @bitCast(regular); _ = @bitCast(ptr);\n" ++
        "    _ = @bitCast(optional); _ = @bitCast(unknown); _ = @bitCast(cyclic);\n" ++
        "    const scalar: u32 = @bitCast(@as(Packed, packed_value));\n" ++
        "}\n" ++
        "fn g(record: Record) void { { const record: u32 = 0; const f: f32 = @bitCast(record); } }\n" ++
        "fn h() void { const Record = packed struct { value: u32 }; const v: Record = @bitCast(raw); }\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .modernize_extern_bitcast)).len);
}

test "modernize extern bitCast excludes scalar projections and selected initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Record = extern struct { value: u32 };\n" ++
        "fn f(record: Record, records: [2]Record) void {\n" ++
        "    const a: f32 = @bitCast(record.value);\n" ++
        "    _ = @bitCast(records[0].value); _ = @bitCast(records.len);\n" ++
        "    _ = @bitCast(@as(Record, record).value);\n" ++
        "    _ = @bitCast(Record{ .value = 1 }.value);\n" ++
        "    const scalar = Record{ .value = 1 }.value; _ = @bitCast(scalar);\n" ++
        "    const converted = @as(Record, record).value; _ = @bitCast(converted);\n" ++
        "    const v: Record = @bitCast(raw).field;\n" ++
        "    const w = @as(Record, @bitCast(raw).field);\n" ++
        "}\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .modernize_extern_bitcast)).len);
}

test "modernize global linkage proves standard library imports and aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Linkage = std.lang.GlobalLinkage;\n" ++
        "const Alias = Linkage;\n" ++
        "const a = std.lang.GlobalLinkage.internal;\n" ++
        "const b = std.builtin.GlobalLinkage.link_once;\n" ++
        "const c = Alias.internal;\n" ++
        "const d = @import(\"std\").lang.GlobalLinkage.link_once;\n" ++
        "const current = std.lang.GlobalLinkage.weak;\n";
    const findings = try findingsFor(arena.allocator(), source, .modernize_global_linkage);
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize global linkage recognizes only direct export and extern option fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const s = @import(\"std\");\n" ++
        "const Options = s.lang.ExportOptions;\n" ++
        "comptime {\n" ++
        "    @export(&symbol, .{ .name = \"x\", .linkage = .internal });\n" ++
        "    @export(&symbol, Options{ .name = \"y\", .linkage = .link_once },);\n" ++
        "    _ = @extern(*u8, .{ .name = \"z\", .linkage = .@\"link_once\" });\n" ++
        "    _ = @extern(*u8, s.lang.ExternOptions{ .name = \"w\", .linkage = .internal });\n" ++
        "    @export(&symbol, .{ .name = \"current\", .linkage = .weak });\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source, .modernize_global_linkage);
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("internal", source[findings[0].span.start..findings[0].span.end]);
    try std.testing.expectEqualStrings("@\"link_once\"", source[findings[2].span.start..findings[2].span.end]);
}

test "modernize global linkage skips unrelated enums nested fields and shadowed imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Linkage = std.lang.GlobalLinkage;\n" ++
        "const Custom = enum { internal, link_once };\n" ++
        "const a = Custom.internal; const b = .link_once;\n" ++
        "const c = wrapper.std.lang.GlobalLinkage.internal;\n" ++
        "const A = B; const B = A; const cyclic = A.internal;\n" ++
        "fn f(std: Custom, Linkage: Custom) void { _ = std.lang.GlobalLinkage.internal; _ = Linkage.internal; }\n" ++
        "comptime {\n" ++
        "    @export(&symbol, .{ .name = .internal, .metadata = .{ .linkage = .link_once } });\n" ++
        "    @export(&symbol, .{ .linkage = choose(.internal) });\n" ++
        "    @export(&symbol, Custom{ .linkage = .internal });\n" ++
        "    @export(&symbol, unknown_options);\n" ++
        "    other(&symbol, .{ .linkage = .internal });\n" ++
        "}\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .modernize_global_linkage)).len);
}

test "modernize layout rules honor suppression and remain off by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const unsuppressed: [:0]const u8 =
        "const Record = extern struct { value: u32 };\n" ++
        "const std = @import(\"std\");\n" ++
        "fn f(record: Record) void { const a: u32 = @bitCast(record); }\n" ++
        "const linkage = std.lang.GlobalLinkage.internal;\n";
    const source: [:0]const u8 =
        "const Record = extern struct { value: u32 };\n" ++
        "const std = @import(\"std\");\n" ++
        "fn f(record: Record) void {\n" ++
        "// zig-analyzer: disable-next-line modernize-extern-bitcast\n" ++
        "    const a: u32 = @bitCast(record);\n" ++
        "}\n" ++
        "// zig-analyzer: disable-next-line modernize-global-linkage\n" ++
        "const linkage = std.lang.GlobalLinkage.internal;\n";
    inline for (.{ types.Rule.modernize_extern_bitcast, .modernize_global_linkage }) |rule| {
        try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, rule)).len);
    }
    try std.testing.expectEqual(@as(usize, 0), (try support.findings(arena.allocator(), run, source, types.Configuration.defaults())).len);
    inline for (.{ types.Rule.modernize_extern_bitcast, .modernize_global_linkage }) |rule| {
        try std.testing.expectEqual(types.Level.off, types.Configuration.defaults().level(rule));
        try std.testing.expectEqual(@as(usize, 1), (try findingsFor(arena.allocator(), unsuppressed, rule)).len);
    }
    try std.testing.expectEqual(@as(usize, 0), (try support.findings(arena.allocator(), run, unsuppressed, types.Configuration.defaults())).len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, rule: types.Rule) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{rule}, .information));
}
