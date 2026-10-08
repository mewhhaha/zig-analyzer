const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .modernize_array_list_access,
    .modernize_container_init,
};

pub fn run(context: RuleRun) !void {
    if (context.level(.modernize_array_list_access) == .off and
        context.level(.modernize_container_init) == .off) return;
    const scopes = context.scopes;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or index + 1 >= context.tokens.len or
            context.tokens[index - 1].tag != .period or context.tokens[index + 1].tag != .l_paren) continue;
        const is_last = context.tokenIs(index, "getLast");
        const is_nullable_last = context.tokenIs(index, "getLastOrNull");
        const is_empty = context.tokenIs(index, "initEmpty");
        const is_full = context.tokenIs(index, "initFull");
        if (!is_last and !is_nullable_last and !is_empty and !is_full) continue;
        const rule: types.Rule = if (is_last or is_nullable_last) .modernize_array_list_access else .modernize_container_init;
        const level = context.level(rule);
        if (level == .off) continue;
        const closing = scopes.matchingToken(index + 1) orelse continue;
        const receiver_start = chainStart(context, scopes, index - 2) orelse continue;
        const receiver = resolve(context, scopes, receiver_start, index - 1, 0, .value);
        if (rule == .modernize_array_list_access and receiver != .list_value) continue;
        if (rule == .modernize_container_init and receiver != .fixed_type) continue;

        var fixes: []const types.Fix = &.{};
        if (closing == index + 2) {
            if (rule == .modernize_array_list_access) {
                const edits = try context.allocator.alloc(types.Edit, if (is_last) 2 else 1);
                edits[0] = .{ .span = token.loc, .replacement = "last" };
                if (is_last) edits[1] = .{
                    .span = .{ .start = context.tokens[closing].loc.end, .end = context.tokens[closing].loc.end },
                    .replacement = ".?",
                };
                fixes = try makeFix(context, if (is_last) "Use last().?" else "Use last()", edits);
            } else {
                const call_source = context.source[token.loc.start..context.tokens[closing].loc.end];
                // Keep comments intact when removing the old call's parentheses.
                if (std.mem.find(u8, call_source, "//") == null) {
                    const edits = try context.allocator.alloc(types.Edit, 1);
                    edits[0] = .{
                        .span = .{ .start = token.loc.start, .end = context.tokens[closing].loc.end },
                        .replacement = if (is_empty) "empty" else "full",
                    };
                    fixes = try makeFix(context, if (is_empty) "Use the empty value" else "Use the full value", edits);
                }
            }
        }
        try context.emit(.{
            .rule = rule,
            .level = level,
            .span = token.loc,
            .message = if (is_last)
                "ArrayList.getLast is deprecated in Zig 0.17; use last().? to retain the nonempty requirement"
            else if (is_nullable_last)
                "ArrayList.getLastOrNull was renamed in Zig 0.17; use last()"
            else if (is_empty)
                "this fixed-size container's initEmpty was removed in Zig 0.17; use its empty value"
            else
                "this fixed-size container's initFull was removed in Zig 0.17; use its full value",
            .fixes = fixes,
        });
    }
    try findDefaultInitializers(context, scopes);
}

fn makeFix(context: RuleRun, title: []const u8, edits: []const types.Edit) ![]const types.Fix {
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = title, .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
    return fixes;
}

const Family = enum {
    unknown,
    standard,
    array_list,
    bit_set,
    enums,
    hash_map,
    array_hash_map,
    heap,
    arena_allocator,
    list_constructor,
    fixed_constructor,
    map_constructor,
    list_type,
    fixed_type,
    map_type,
    arena_state_type,
    list_value,
    fixed_value,
    map_value,
    arena_state_value,
    list_initializer,
};

const ProofMode = enum { value, exact_type };

/// Resolve only known standard-library paths and lexical aliases of them.
/// Unknown member access, custom constructors and arbitrary calls lose proof.
fn resolve(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize, depth: usize, mode: ProofMode) Family {
    if (start >= end or end > context.tokens.len or depth >= 20) return .unknown;
    var cursor = start;
    while (mode == .value and cursor < end and (context.tokens[cursor].tag == .keyword_try or
        context.tokens[cursor].tag == .asterisk or context.tokens[cursor].tag == .ampersand or
        context.tokens[cursor].tag == .keyword_const)) cursor += 1;
    if (cursor == end) return .unknown;
    var family: Family = .unknown;
    if (context.tokenIs(cursor, "@import")) {
        if (cursor + 3 >= end or context.tokens[cursor + 1].tag != .l_paren or
            !context.tokenIs(cursor + 2, "\"std\"") or context.tokens[cursor + 3].tag != .r_paren) return .unknown;
        family = .standard;
        cursor += 4;
    } else if (context.tokens[cursor].tag == .identifier) {
        const binding = scopes.findBinding(cursor) orelse return .unknown;
        family = bindingFamily(context, scopes, binding.token_index, depth + 1, mode);
        cursor += 1;
    } else if (context.tokens[cursor].tag == .l_paren) {
        const closing = scopes.matchingToken(cursor) orelse return .unknown;
        if (closing >= end) return .unknown;
        family = resolve(context, scopes, cursor + 1, closing, depth + 1, mode);
        cursor = closing + 1;
    } else return .unknown;

    while (cursor < end) {
        switch (context.tokens[cursor].tag) {
            .period => {
                if (cursor + 1 >= end or context.tokens[cursor + 1].tag != .identifier) return .unknown;
                family = memberFamily(family, context.tokenText(cursor + 1));
                cursor += 2;
            },
            .l_paren => {
                const closing = scopes.matchingToken(cursor) orelse return .unknown;
                if (closing >= end) return .unknown;
                family = switch (family) {
                    .list_constructor => .list_type,
                    .fixed_constructor => .fixed_type,
                    .map_constructor => .map_type,
                    .list_initializer => .list_value,
                    .unknown,
                    .standard,
                    .array_list,
                    .bit_set,
                    .enums,
                    .hash_map,
                    .array_hash_map,
                    .heap,
                    .arena_allocator,
                    .list_type,
                    .fixed_type,
                    .map_type,
                    .arena_state_type,
                    .list_value,
                    .fixed_value,
                    .map_value,
                    .arena_state_value,
                    => .unknown,
                };
                cursor = closing + 1;
            },
            .l_brace => {
                const closing = scopes.matchingToken(cursor) orelse return .unknown;
                if (closing >= end) return .unknown;
                family = instanceFamily(family);
                cursor = closing + 1;
            },
            else => return .unknown,
        }
        if (family == .unknown) return .unknown;
    }
    return family;
}

const standard_members = std.StaticStringMap(Family).initComptime(.{
    .{ "array_list", .array_list },
    .{ "bit_set", .bit_set },
    .{ "enums", .enums },
    .{ "hash_map", .hash_map },
    .{ "array_hash_map", .array_hash_map },
    .{ "heap", .heap },
    .{ "ArrayList", .list_constructor },
    .{ "ArrayListUnmanaged", .list_constructor },
    .{ "ArrayListAligned", .list_constructor },
    .{ "ArrayListAlignedUnmanaged", .list_constructor },
    .{ "StaticBitSet", .fixed_constructor },
    .{ "HashMapUnmanaged", .map_constructor },
    .{ "AutoHashMapUnmanaged", .map_constructor },
    .{ "StringHashMapUnmanaged", .map_constructor },
    .{ "ArrayHashMapUnmanaged", .map_constructor },
    .{ "AutoArrayHashMapUnmanaged", .map_constructor },
    .{ "StringArrayHashMapUnmanaged", .map_constructor },
});

fn memberFamily(family: Family, name: []const u8) Family {
    return switch (family) {
        .standard => standard_members.get(name) orelse .unknown,
        .array_list => if (std.mem.eql(u8, name, "Aligned")) .list_constructor else .unknown,
        .bit_set => if (oneOf(name, &.{ "Integer", "Array", "Static", "IntegerBitSet", "ArrayBitSet", "StaticBitSet" })) .fixed_constructor else .unknown,
        .enums => if (std.mem.eql(u8, name, "EnumSet")) .fixed_constructor else if (std.mem.eql(u8, name, "EnumMap")) .map_constructor else .unknown,
        .hash_map => if (oneOf(name, &.{ "HashMapUnmanaged", "AutoHashMapUnmanaged", "StringHashMapUnmanaged" })) .map_constructor else .unknown,
        .array_hash_map => if (oneOf(name, &.{ "Custom", "Auto", "String", "ArrayHashMap" })) .map_constructor else .unknown,
        .heap => if (std.mem.eql(u8, name, "ArenaAllocator")) .arena_allocator else .unknown,
        .arena_allocator => if (std.mem.eql(u8, name, "State")) .arena_state_type else .unknown,
        .list_type => if (std.mem.eql(u8, name, "empty")) .list_value else if (oneOf(name, &.{ "initCapacity", "initBuffer", "fromOwnedSlice", "fromOwnedSliceSentinel" })) .list_initializer else .unknown,
        .list_value => if (std.mem.eql(u8, name, "clone")) .list_initializer else .unknown,
        .fixed_type => if (oneOf(name, &.{ "empty", "full" })) .fixed_value else .unknown,
        .map_type => if (std.mem.eql(u8, name, "empty")) .map_value else .unknown,
        .arena_state_type => if (std.mem.eql(u8, name, "init")) .arena_state_value else .unknown,
        .unknown,
        .list_constructor,
        .fixed_constructor,
        .map_constructor,
        .fixed_value,
        .map_value,
        .arena_state_value,
        .list_initializer,
        => .unknown,
    };
}

fn oneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn instanceFamily(family: Family) Family {
    return switch (family) {
        .list_type => .list_value,
        .fixed_type => .fixed_value,
        .map_type => .map_value,
        .arena_state_type => .arena_state_value,
        .unknown,
        .standard,
        .array_list,
        .bit_set,
        .enums,
        .hash_map,
        .array_hash_map,
        .heap,
        .arena_allocator,
        .list_constructor,
        .fixed_constructor,
        .map_constructor,
        .list_value,
        .fixed_value,
        .map_value,
        .arena_state_value,
        .list_initializer,
        => .unknown,
    };
}

fn bindingFamily(context: RuleRun, scopes: *const syntax_scope.Index, binding: usize, depth: usize, mode: ProofMode) Family {
    if (binding + 2 >= context.tokens.len) return .unknown;
    if (context.tokens[binding + 1].tag == .colon) {
        var end = binding + 2;
        while (end < context.tokens.len) {
            switch (context.tokens[end].tag) {
                .l_paren, .l_bracket => end = scopes.matchingToken(end) orelse return .unknown,
                .comma, .r_paren, .equal, .semicolon => break,
                else => {},
            }
            end += 1;
        }
        if (end == binding + 3 and context.tokenIs(binding + 2, "type") and
            end < context.tokens.len and context.tokens[end].tag == .equal)
        {
            const statement_end = scopes.statementEnd(end + 1) orelse return .unknown;
            return stableBindingFamily(context, binding, resolve(context, scopes, end + 1, statement_end, depth, mode));
        }
        return instanceFamily(resolve(context, scopes, binding + 2, end, depth, mode));
    }
    if (context.tokens[binding + 1].tag != .equal) return .unknown;
    const end = scopes.statementEnd(binding + 2) orelse return .unknown;
    return stableBindingFamily(context, binding, resolve(context, scopes, binding + 2, end, depth, mode));
}

fn stableBindingFamily(context: RuleRun, binding: usize, family: Family) Family {
    // A mutable container value keeps its declared type. A comptime namespace,
    // constructor, or type variable can instead be reassigned to a custom API.
    return switch (family) {
        .list_value, .fixed_value, .map_value, .arena_state_value => family,
        .unknown,
        .standard,
        .array_list,
        .bit_set,
        .enums,
        .hash_map,
        .array_hash_map,
        .heap,
        .arena_allocator,
        .list_constructor,
        .fixed_constructor,
        .map_constructor,
        .list_type,
        .fixed_type,
        .map_type,
        .arena_state_type,
        .list_initializer,
        => if (binding > 0 and context.tokens[binding - 1].tag == .keyword_const) family else .unknown,
    };
}

const Ast = std.zig.Ast;
const Node = Ast.Node.Index;

fn findDefaultInitializers(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    if (context.level(.modernize_container_init) == .off) return;
    const tree = context.tree;
    if (tree.errors.len != 0) return;
    const reported = try context.allocator.alloc(bool, tree.nodes.len);
    defer context.allocator.free(reported);
    @memset(reported, false);
    for (1..tree.nodes.len) |raw_node| {
        const node: Node = @fromBackingInt(@intCast(raw_node));
        if (tree.fullVarDecl(node)) |variable| {
            if (variable.ast.type_node.unwrap()) |type_node| {
                if (variable.ast.init_node.unwrap()) |value_node| {
                    try emitDefaultInitializer(context, scopes, tree, value_node, type_node, reported);
                }
            }
        }
        if (tree.fullContainerField(node)) |field| {
            if (field.ast.type_expr.unwrap()) |type_node| {
                if (field.ast.value_expr.unwrap()) |value_node| {
                    try emitDefaultInitializer(context, scopes, tree, value_node, type_node, reported);
                }
            }
        }
        var parameters_buffer: [2]Node = undefined;
        if (tree.builtinCallParams(&parameters_buffer, node)) |parameters| {
            if (parameters.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) {
                try emitDefaultInitializer(context, scopes, tree, parameters[1], parameters[0], reported);
            }
        }
        var initializer_buffer: [2]Node = undefined;
        if (tree.fullStructInit(&initializer_buffer, node)) |initializer| {
            if (initializer.ast.type_expr.unwrap()) |type_node| {
                try emitDefaultInitializer(context, scopes, tree, node, type_node, reported);
            }
        }
    }
}

fn emitDefaultInitializer(
    context: RuleRun,
    scopes: *const syntax_scope.Index,
    tree: *const Ast,
    raw_value: Node,
    expected_type: Node,
    reported: []bool,
) !void {
    const value = ungroup(tree, raw_value);
    if (reported[@backingInt(value)]) return;
    var buffer: [2]Node = undefined;
    const initializer = tree.fullStructInit(&buffer, value) orelse return;
    if (initializer.ast.fields.len != 0) return;
    const type_node = ungroup(tree, initializer.ast.type_expr.unwrap() orelse expected_type);
    const start = tree.firstToken(type_node);
    const end = tree.lastToken(type_node) + 1;
    if (end > context.tokens.len or context.tokens[start].loc.start != tree.tokenStart(start)) return;
    // Qualifiers such as pointers, optionals, arrays and error unions do not
    // establish the exact container type of an anonymous initializer.
    if (context.tokens[start].tag != .identifier and !context.tokenIs(start, "@import")) return;
    const family = resolve(context, scopes, start, end, 0, .exact_type);
    if (family != .map_type and family != .arena_state_type) return;
    const lbrace = initializer.ast.lbrace;
    const rbrace = tree.lastToken(value);
    if (lbrace >= context.tokens.len or rbrace >= context.tokens.len or
        context.tokens[lbrace].tag != .l_brace or context.tokens[rbrace].tag != .r_brace) return;
    const anonymous = initializer.ast.type_expr == .none;
    const span: std.zig.Token.Loc = .{
        .start = context.tokens[if (anonymous) lbrace - 1 else lbrace].loc.start,
        .end = context.tokens[rbrace].loc.end,
    };
    const replacement = if (family == .arena_state_type) ".init" else ".empty";
    var fixes: []const types.Fix = &.{};
    if (std.mem.find(u8, context.source[span.start..span.end], "//") == null) {
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = .{ .span = span, .replacement = replacement };
        fixes = try makeFix(context, if (family == .arena_state_type) "Use the initial arena state" else "Use the empty container value", edits);
    }
    reported[@backingInt(value)] = true;
    try context.emit(.{
        .rule = .modernize_container_init,
        .level = context.level(.modernize_container_init),
        .span = span,
        .message = if (family == .arena_state_type)
            "default ArenaAllocator.State initialization is deprecated; use its init value"
        else
            "default initialization of this standard map is deprecated; use its empty value",
        .fixes = fixes,
    });
}

fn ungroup(tree: *const Ast, raw_node: Node) Node {
    var node = raw_node;
    while (tree.nodeTag(node) == .grouped_expression) node = tree.nodeData(node).node_and_token[0];
    return node;
}

fn chainStart(context: RuleRun, scopes: *const syntax_scope.Index, end: usize) ?usize {
    var start = end;
    for (0..128) |_| {
        if (context.tokens[start].tag == .r_paren) {
            start = scopes.matchingToken(start) orelse return null;
            if (start > 0 and (context.tokens[start - 1].tag == .identifier or
                context.tokens[start - 1].tag == .r_paren))
            {
                start -= 1;
                continue;
            }
        } else if (context.tokens[start].tag != .identifier) return null;
        if (start >= 2 and context.tokens[start - 1].tag == .period) {
            start -= 2;
            continue;
        }
        return start;
    }
    return null;
}

test "container modernization recognizes list aliases and preserves empty behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const library = @import(\"std\");\n" ++
        "const list_ns = library.array_list; const List = list_ns.Aligned(u8, null); const Alias: type = List;\n" ++
        "fn use(list: *const Alias) void { _ = list.getLastOrNull(); _ = list.getLast(); }\n" ++
        "fn infer() void { var items = library.ArrayListUnmanaged(u8).empty; _ = items.getLastOrNull(); }\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("last", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqual(@as(usize, 2), found[1].fixes[0].edits.len);
    try std.testing.expectEqualStrings(".?", found[1].fixes[0].edits[1].replacement);
    try std.testing.expect(found[1].fixes[0].fix_all);
}

test "container modernization recognizes fixed bitset and enum set aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const bits = std.bit_set; const Integer = bits.Integer;\n" ++
        "const Small = Integer(8); const Alias = Small; const Enum = enum { a, b }; const Set = std.enums.EnumSet(Enum);\n" ++
        "const a = Alias.initEmpty(); const b = bits.Array(u64, 130).initFull();\n" ++
        "const c = bits.IntegerBitSet(8).initFull(); const d = bits.ArrayBitSet(u8, 12).initEmpty();\n" ++
        "const e = std.StaticBitSet(128).initFull(); const f = bits.StaticBitSet(8).initEmpty();\n" ++
        "const g = Set.initEmpty(); const h = std.enums.EnumSet(Enum).initFull();\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 8), found.len);
    for (found, 0..) |finding, index| {
        try std.testing.expectEqual(types.Rule.modernize_container_init, finding.rule);
        try std.testing.expectEqualStrings(if (index == 0 or index == 3 or index == 5 or index == 6) "empty" else "full", finding.fixes[0].edits[0].replacement);
    }
}

test "container modernization excludes custom dynamic and shadowed receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const List = std.ArrayList(u8); const Bits = std.bit_set.Integer(8);\n" ++
        "const Custom = struct { fn getLastOrNull(_: @This()) ?u8 { return null; } fn initEmpty() @This() { return .{}; } };\n" ++
        "fn custom(value: Custom) void { _ = value.getLastOrNull(); _ = Custom.initEmpty(); }\n" ++
        "fn unknown(value: anytype) void { _ = value.getLast(); }\n" ++
        "fn shadow(List: type, Bits: type, std: anytype) void { var value: List = .{}; _ = value.getLast(); _ = Bits.initFull(); _ = std.bit_set.Integer(8).initEmpty(); }\n" ++
        "fn nested() void { const List = Custom; const Bits = Custom; var value: List = .{}; _ = value.getLastOrNull(); _ = Bits.initEmpty(); }\n" ++
        "const dynamic = std.bit_set.Dynamic.initEmpty(allocator, 20);\n" ++
        "const managed = std.bit_set.DynamicManaged.initFull(allocator, 20);\n" ++
        "const map = std.enums.EnumMap(Enum, u8).initFull(0);\n" ++
        "const now = Bits.empty; fn current(value: List) void { _ = value.last(); }\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "container modernization retains comments and advises on changed call shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Bits = std.bit_set.Integer(8);\n" ++
        "const a = Bits.initEmpty(// keep me\n); const b = Bits.initFull(unexpected);\n" ++
        "fn read(list: std.ArrayList(u8)) void { _ = list.getLast(// keep me too\n); }\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqual(@as(usize, 0), found[0].fixes.len);
    try std.testing.expectEqual(@as(usize, 0), found[1].fixes.len);
    try std.testing.expectEqual(@as(usize, 2), found[2].fixes[0].edits.len);
}

test "container modernization is opt in and honors suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const unsuppressed: [:0]const u8 =
        "const std = @import(\"std\"); const Bits = std.bit_set.Integer(8);\n" ++
        "const bits = Bits.initEmpty(); fn read(list: std.ArrayList(u8)) void { _ = list.getLast(); }\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), unsuppressed, .defaults)).len);
    try std.testing.expectEqual(@as(usize, 2), (try findingsFor(arena.allocator(), unsuppressed, .enabled)).len);
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Bits = std.bit_set.Integer(8);\n" ++
        "// zig-analyzer: disable-next-line modernize-container-init\n" ++
        "const bits = Bits.initEmpty();\n" ++
        "fn read(list: std.ArrayList(u8)) void {\n" ++
        "// zig-analyzer: disable-next-line modernize-array-list-access\n" ++
        "_ = list.getLast();\n}\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .enabled)).len);
}

test "container modernization requires a proven standard library namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][:0]const u8{
        "const std = @import(\"custom.zig\"); const Bits = std.bit_set.Integer(8); const cleared = Bits.initEmpty(); fn read(list: std.ArrayList(u8)) void { _ = list.getLast(); }\n",
        "const List = std.ArrayList(u8); const Bits = std.bit_set.Integer(8); const cleared = Bits.initEmpty(); fn read(list: List) void { _ = list.getLastOrNull(); }\n",
        "const List = Cyclic; const Cyclic = List; fn read(list: List) void { _ = list.getLast(); }\n",
    };
    for (sources) |source| try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .enabled)).len);
}

test "container modernization excludes mutable namespace and type aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Custom = @import(\"custom.zig\");\n" ++
        "fn aliases() void {\n" ++
        "    comptime var library: type = std; library = Custom; _ = library.bit_set.Integer(8).initEmpty();\n" ++
        "    comptime var bits = std.bit_set; bits = Custom; _ = bits.Integer(8).initFull();\n" ++
        "    comptime var factory = std.bit_set.Integer; factory = Custom.Integer; _ = factory(8).initEmpty();\n" ++
        "    comptime var List: type = std.ArrayList(u8); List = Custom; var value: List = .{}; _ = value.getLast();\n" ++
        "    comptime var Bits = std.bit_set.Integer(8); Bits = Custom; _ = Bits.initFull();\n" ++
        "    const Alias = Bits; _ = Alias.initEmpty();\n" ++
        "    var explicit: std.ArrayList(u8) = .empty; _ = explicit.getLast();\n" ++
        "    var inferred = std.ArrayList(u8).empty; _ = inferred.getLastOrNull();\n" ++
        "}\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(types.Rule.modernize_array_list_access, finding.rule);

    const Custom = struct {
        pub const bit_set = struct {
            pub fn Integer(comptime _: usize) type {
                return struct {
                    pub fn initEmpty() usize {
                        return 42;
                    }
                };
            }
        };
    };
    comptime var library: type = std;
    library = Custom;
    try std.testing.expectEqual(@as(usize, 42), library.bit_set.Integer(8).initEmpty());
}

test "container modernization replacements compile with Zig 0.17 APIs" {
    const Enum = enum { a, b };
    const sets = .{ std.bit_set.Integer(8), std.bit_set.Array(u64, 130), std.bit_set.Static(128), std.enums.EnumSet(Enum) };
    inline for (sets) |Set| {
        const empty: Set = .empty;
        const full: Set = .full;
        try std.testing.expectEqual(@as(usize, 0), empty.count());
        try std.testing.expect(full.count() > 0);
    }
    const empty: std.ArrayList(u8) = .empty;
    try std.testing.expectEqual(@as(?u8, null), empty.last());
    var values = [_]u8{42};
    var list: std.array_list.Aligned(u8, null) = .initBuffer(&values);
    list.appendAssumeCapacity(42);
    try std.testing.expectEqual(@as(u8, 42), list.last().?);
}

test "container modernization finds deprecated default map and arena state initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const library = @import(\"std\"); const hm = library.hash_map; const ahm = library.array_hash_map;\n" ++
        "const MakeMap = hm.AutoHashMapUnmanaged; const Map = MakeMap(u32, u8); const Alias: type = Map;\n" ++
        "const Strings = hm.StringHashMapUnmanaged(u8); const Generic = library.HashMapUnmanaged(u32, u8, hm.AutoContext(u32), 80);\n" ++
        "const Array = ahm.Auto(u32, u8); const StringArray = ahm.String(u8);\n" ++
        "const GenericArray = ahm.Custom(u32, u8, ahm.AutoContext(u32), true);\n" ++
        "const Legacy = library.AutoArrayHashMapUnmanaged(u32, u8); const LegacyString = library.StringArrayHashMapUnmanaged(u8);\n" ++
        "const LegacyCustom = library.ArrayHashMapUnmanaged(u32, u8, ahm.AutoContext(u32), true);\n" ++
        "const Enum = enum { a, b }; const Enums = library.enums.EnumMap(Enum, u8);\n" ++
        "const State = library.heap.ArenaAllocator.State; const StateAlias = State;\n" ++
        "var a: Alias = .{}; var b: Strings = .{}; var c: Generic = .{};\n" ++
        "var d: Array = .{}; var e: StringArray = .{}; var f: GenericArray = .{};\n" ++
        "var g: Legacy = .{}; var h: LegacyString = .{}; var i: LegacyCustom = .{};\n" ++
        "var j: Enums = .{}; var k: StateAlias = .{};\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 11), found.len);
    for (found, 0..) |finding, index| {
        try std.testing.expectEqual(types.Rule.modernize_container_init, finding.rule);
        try std.testing.expectEqualStrings(".{}", source[finding.span.start..finding.span.end]);
        try std.testing.expectEqualStrings(if (index == 10) ".init" else ".empty", finding.fixes[0].edits[0].replacement);
        try std.testing.expect(finding.fixes[0].fix_all);
    }
}

test "container modernization proves typed literals field defaults and as result locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Map = std.AutoHashMapUnmanaged(u32, u8);\n" ++
        "const State = std.heap.ArenaAllocator.State;\n" ++
        "const Owner = struct { map: Map = .{}, state: State = .{}, aligned: Map align(8) = .{}, };\n" ++
        "const a = Map{}; const b = std.array_hash_map.Auto(u32, u8){};\n" ++
        "const c: Map = Map{}; const d = @as(Map, .{}); const e = @as((State), (.{}),);\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 8), found.len);
    var typed_count: usize = 0;
    var state_count: usize = 0;
    for (found) |finding| {
        const replaced = source[finding.span.start..finding.span.end];
        if (std.mem.eql(u8, replaced, "{}")) typed_count += 1;
        if (std.mem.eql(u8, finding.fixes[0].edits[0].replacement, ".init")) state_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), typed_count);
    try std.testing.expectEqual(@as(usize, 2), state_count);
}

test "container modernization skips nonempty custom qualified and mutable default initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Map = std.AutoHashMapUnmanaged(u32, u8);\n" ++
        "const Custom = struct { size: usize = 0, const empty = @This(){}; };\n" ++
        "const a: Custom = .{}; const b = Custom{}; const c: Unknown = .{};\n" ++
        "const d: Map = .{ .size = 0 }; const e = Map{ .size = 0 }; const f = @as(Map, .{ .size = 0 });\n" ++
        "const pointer: *Map = .{}; const optional: ?Map = .{}; const array: [2]Map = .{};\n" ++
        "const Pointer = *const Map; const Optional = ?Map; const Maps = [2]Map;\n" ++
        "const aliased_pointer: Pointer = .{}; const aliased_optional: Optional = .{}; const aliased_array: Maps = .{};\n" ++
        "const managed: std.AutoHashMap(u32, u8) = .{}; const managed_strings: std.StringHashMap(u8) = .{};\n" ++
        "const inferred = .{}; const state = std.heap.ArenaAllocator.State{ .used_list = null };\n" ++
        "fn shadow() void { const Map = Custom; const a: Map = .{}; const b = Map{}; }\n" ++
        "fn mutable() void { comptime var library: type = std; library = Custom; const a: library.AutoHashMapUnmanaged(u32, u8) = .{};\n" ++
        "    comptime var Mutable: type = std.AutoHashMapUnmanaged(u32, u8); Mutable = Custom; const Alias = Mutable; const b: Alias = .{}; }\n" ++
        "fn root_shadow(std: type) void { const a: std.AutoHashMapUnmanaged(u32, u8) = .{}; }\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source, .enabled)).len);
}

test "container modernization default initializer comments suppression and opt in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\"); const Map = std.AutoHashMapUnmanaged(u32, u8);\n" ++
        "const a: Map = .{// preserve me\n}; const b = Map{// preserve me too\n};\n" ++
        "// zig-analyzer: disable-next-line modernize-container-init\n" ++
        "const c: Map = .{}; const d: std.heap.ArenaAllocator.State = .init;\n";
    const found = try findingsFor(arena.allocator(), source, .enabled);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    const unsuppressed: [:0]const u8 =
        "const std = @import(\"std\"); const a: std.AutoHashMapUnmanaged(u32, u8) = .{};\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), unsuppressed, .defaults)).len);
    try std.testing.expectEqual(@as(usize, 1), (try findingsFor(arena.allocator(), unsuppressed, .enabled)).len);
}

test "container modernization empty maps and initial arena state compile with Zig 0.17" {
    const Enum = enum { a, b };
    const maps = .{
        std.AutoHashMapUnmanaged(u32, u8),
        std.StringHashMapUnmanaged(u8),
        std.HashMapUnmanaged(u32, u8, std.hash_map.AutoContext(u32), 80),
        std.array_hash_map.Auto(u32, u8),
        std.array_hash_map.String(u8),
        std.array_hash_map.Custom(u32, u8, std.array_hash_map.AutoContext(u32), true),
        std.array_hash_map.Auto(u32, u8),
        std.array_hash_map.String(u8),
        std.array_hash_map.Custom(u32, u8, std.array_hash_map.AutoContext(u32), true),
        std.enums.EnumMap(Enum, u8),
    };
    inline for (maps) |Map| {
        const map: Map = .empty;
        try std.testing.expectEqual(@as(usize, 0), map.count());
    }
    const Owner = struct {
        map: std.AutoHashMapUnmanaged(u32, u8) = .empty,
        state: std.heap.ArenaAllocator.State = .init,
    };
    const owner: Owner = .{};
    try std.testing.expectEqual(@as(usize, 0), owner.map.count());
    try std.testing.expect(owner.state.used_list == null and owner.state.free_list == null);
    const typed = std.array_hash_map.Auto(u32, u8).empty;
    const converted = @as(std.heap.ArenaAllocator.State, .init);
    try std.testing.expectEqual(@as(usize, 0), typed.count());
    try std.testing.expect(converted.used_list == null);
}

const TestMode = enum { defaults, enabled };

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, mode: TestMode) ![]const types.Finding {
    const config = switch (mode) {
        .defaults => types.Configuration.defaults(),
        .enabled => support.only(&.{ .modernize_array_list_access, .modernize_container_init }, .information),
    };
    return support.findings(allocator, run, source, config);
}
