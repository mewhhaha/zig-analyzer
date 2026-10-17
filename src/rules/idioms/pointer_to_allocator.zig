//! Function parameters and container fields typed as a single-item pointer to
//! `std.mem.Allocator`, which is already a pointer-sized interface value.
const std = @import("std");
const Ast = std.zig.Ast;
const isAssignment = @import("../../syntax/tokens.zig").isAssignment;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .pointer_to_allocator,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.pointer_to_allocator);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.fullContainerField(node)) |field| {
            if (field.ast.tuple_like) continue;
            try report(context, level, field.ast.type_expr.unwrap() orelse continue);
            continue;
        }
        // Parameters are judged with the body that uses them; prototypes
        // without one (function types, extern declarations) are left alone.
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        // An exported or C-convention function keeps its ABI-shaped parameters.
        if (function.extern_export_inline_token) |keyword| {
            if (context.tokens[keyword].tag != .keyword_inline) continue;
        }
        if (function.ast.callconv_expr != .none) continue;
        const body = tree.nodeData(node).node_and_node[1];
        var parameters = function.iterate(tree);
        while (parameters.next()) |parameter| {
            const name = parameter.name_token orelse continue;
            const type_node = parameter.type_expr orelse continue;
            if (!usedOnlyThroughMembers(context, name, tree.firstToken(body), tree.lastToken(body))) continue;
            try report(context, level, type_node);
        }
    }
}

/// Reports `type_node` when it is `*std.mem.Allocator` or `*const std.mem.Allocator`,
/// spelled through any `const` alias of the standard library's type.
fn report(context: RuleRun, level: types.Level, type_node: Ast.Node.Index) !void {
    const tree = context.tree;
    const pointer = tree.fullPtrType(type_node) orelse return;
    if (pointer.size != .one or pointer.ast.sentinel != .none or pointer.ast.align_node != .none or
        pointer.ast.addrspace_node != .none or pointer.volatile_token != null or pointer.allowzero_token != null) return;
    const asterisk = pointer.ast.main_token;
    if (context.tokens[asterisk].tag != .asterisk) return;
    const child = pointer.ast.child_type;
    const first = tree.firstToken(child);
    const last = tree.lastToken(child);
    if (!namesStdPath(context, first, last, &.{ "mem", "Allocator" }, 4)) return;
    // Changing the type breaks every caller that passes `&allocator`, so the
    // rewrite is offered, not applied by `check --fix`.
    const fixes = try context.singleFix(.{
        .title = try context.allocator.dupe(u8, "Pass 'Allocator' by value"),
        .span = .{ .start = context.tokens[asterisk].loc.start, .end = context.tokens[first].loc.start },
        .replacement = "",
        .preferred = true,
    });
    try context.emit(.{
        .rule = .pointer_to_allocator,
        .level = level,
        .span = .{ .start = context.tokens[asterisk].loc.start, .end = context.tokens[last].loc.end },
        .message = try context.allocator.dupe(u8, "std.mem.Allocator is an interface fat pointer and should be passed by value rather than by pointer"),
        .fixes = fixes,
    });
}

/// Whether every use of the parameter declared at `name` in the body
/// `[first, last]` reads a member or the pointee (`allocator.alloc(...)`,
/// `allocator.*`) without assigning through it. A bare use may depend on the
/// pointer's identity: it can be stored, cast to a context pointer or compared.
fn usedOnlyThroughMembers(context: RuleRun, name: Ast.TokenIndex, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    const tokens = context.tokens;
    const spelling = context.tokenText(name);
    for (first..last + 1) |index| {
        if (tokens[index].tag != .identifier or !context.tokenIs(index, spelling) or
            (index > 0 and tokens[index - 1].tag == .period)) continue;
        const binding = context.scopes.findBinding(index) orelse continue;
        if (binding.token_index != name) continue;
        const next = index + 1;
        if (next + 1 >= tokens.len) return false;
        switch (tokens[next].tag) {
            .period => if (tokens[next + 1].tag != .identifier or
                (next + 2 < tokens.len and isAssignment(tokens[next + 2].tag))) return false,
            .period_asterisk => if (isAssignment(tokens[next + 1].tag)) return false,
            // `_ = allocator;`
            .semicolon => if (index < 2 or tokens[index - 1].tag != .equal or !context.tokenIs(index - 2, "_")) return false,
            else => return false,
        }
    }
    return true;
}

/// Whether the dotted path `first..last` names `std.` followed by `suffix`,
/// directly or through untyped `const` aliases such as
/// `const Allocator = std.mem.Allocator;` or `const mem = @import("std").mem;`.
fn namesStdPath(context: RuleRun, first: usize, last: usize, suffix: []const []const u8, depth: usize) bool {
    const tokens = context.tokens;
    if (depth == 0 or last < first or (last - first) % 2 != 0) return false;
    const segments = (last - first) / 2 + 1;
    var cursor = first;
    while (cursor <= last) : (cursor += 2) {
        if (tokens[cursor].tag != .identifier or (cursor < last and tokens[cursor + 1].tag != .period)) return false;
    }
    if (segments > suffix.len + 1) return false;
    const tail = suffix[suffix.len - (segments - 1) ..];
    for (tail, 0..) |segment, offset| {
        if (!context.tokenIs(first + 2 + 2 * offset, segment)) return false;
    }
    const prefix = suffix[0 .. suffix.len - tail.len];
    const binding = context.scopes.findBinding(first) orelse
        // An unbound `std` in an incomplete snippet.
        return prefix.len == 0 and context.tokenIs(first, "std");
    const declaration = binding.token_index;
    if (declaration == 0 or tokens[declaration - 1].tag != .keyword_const or
        declaration + 2 >= tokens.len or tokens[declaration + 1].tag != .equal) return false;
    const end = context.scopes.statementEnd(declaration) orelse return false;
    const start = declaration + 2;
    if (context.tokenIs(start, "@import")) {
        if (start + 3 >= end or tokens[start + 1].tag != .l_paren or !context.tokenIs(start + 2, "\"std\"") or
            tokens[start + 3].tag != .r_paren) return false;
        // `@import("std")` followed by the remaining prefix.
        if (end - (start + 4) != 2 * prefix.len) return false;
        for (prefix, 0..) |segment, offset| {
            const member = start + 4 + 2 * offset;
            if (tokens[member].tag != .period or !context.tokenIs(member + 1, segment)) return false;
        }
        return true;
    }
    return end > start and namesStdPath(context, start, end - 1, prefix, depth - 1);
}

test "pointer to allocator detects pointers in parameters and fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Allocator = std.mem.Allocator;\n" ++
        "const mem = @import(\"std\").mem;\n" ++
        "const Context = struct {\n" ++
        "    alloc: *std.mem.Allocator,\n" ++
        "};\n" ++
        "fn run(allocator: *std.mem.Allocator, other: *const std.mem.Allocator, short: *Allocator, aliased: *mem.Allocator) !void {\n" ++
        "    _ = try allocator.alloc(u8, 1);\n" ++
        "    _ = other;\n" ++
        "    const copy = short.*;\n" ++
        "    _ = copy;\n" ++
        "    aliased.free(@as([]u8, &.{}));\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| {
        try std.testing.expectEqualStrings("", finding.fixes[0].edits[0].replacement);
        try std.testing.expect(!finding.fixes[0].fix_all);
    }
    try std.testing.expectEqualStrings("*const std.mem.Allocator", source[findings[2].span.start..findings[2].span.end]);
}

test "by-value allocator or concrete allocator pointer stays unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, gpa: *std.heap.GeneralPurposeAllocator(.{})) void {\n" ++
        "    _ = allocator;\n" ++
        "    _ = arena;\n" ++
        "    _ = gpa;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a local Allocator type or a pointer whose identity matters is not reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub const Allocator = struct {\n" ++
        "    parent: std.mem.Allocator,\n" ++
        "    pub fn interface(self: *Allocator) std.mem.Allocator {\n" ++
        "        return .{ .ptr = self, .vtable = undefined };\n" ++
        "    }\n" ++
        "    fn alloc(ctx: *anyopaque) void {\n" ++
        "        const self: *Allocator = @ptrCast(@alignCast(ctx));\n" ++
        "        _ = self;\n" ++
        "    }\n" ++
        "};\n" ++
        "const Wrapper = struct { ctx: *anyopaque };\n" ++
        "pub fn fromZig(zig_alloc: *const std.mem.Allocator) Wrapper {\n" ++
        "    return .{ .ctx = @ptrCast(@constCast(zig_alloc)) };\n" ++
        "}\n" ++
        "fn replace(slot: *std.mem.Allocator, next: std.mem.Allocator) void {\n" ++
        "    slot.* = next;\n" ++
        "}\n" ++
        "fn local(ctx: *anyopaque) void {\n" ++
        "    const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));\n" ++
        "    _ = zig_alloc;\n" ++
        "}\n" ++
        "export fn exported(allocator: *std.mem.Allocator) void {\n" ++
        "    _ = allocator;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.pointer_to_allocator}, .warning));
}
