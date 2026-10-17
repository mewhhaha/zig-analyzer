//! Local bindings that AstGen rejects for how they are used: a local
//! constant, variable, function parameter or capture that nothing references
//! ("unused local constant"), and `_ = x;` for a binding that is referenced
//! elsewhere ("pointless discard of local constant"). Both are compile errors,
//! so the findings use the compiler's wording and spans; an editor showing the
//! compiler's errors too merges the two.
//!
//! A binding counts as used when an identifier spelled the same, and not a
//! field or member name, follows it in its scope. That over-approximates the
//! uses, so an unused finding is only reported when no such spelling exists. A
//! pointless discard needs a use that the scope index resolves to the same
//! binding, since its fix deletes the discard.

const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const IdentifierTable = @import("../../syntax/scope.zig").IdentifierTable;

pub const rules = [_]types.Rule{ .unused_local, .pointless_discard };

const Kind = enum {
    constant,
    variable,
    parameter,
    capture,
    switch_tag_capture,

    fn unusedMessage(kind: Kind) []const u8 {
        return switch (kind) {
            .constant => "unused local constant",
            .variable => "unused local variable",
            .parameter => "unused function parameter",
            .capture => "unused capture",
            .switch_tag_capture => "unused switch tag capture",
        };
    }

    fn discardMessage(kind: Kind) []const u8 {
        return switch (kind) {
            .constant => "pointless discard of local constant",
            .variable => "pointless discard of local variable",
            .parameter => "pointless discard of function parameter",
            .capture, .switch_tag_capture => "pointless discard of capture",
        };
    }
};

/// How an unused capture can be silenced.
const CaptureFix = enum {
    /// `|value|` becomes `|_|`.
    rename,
    /// The whole `|err|` goes: `catch`, `else` and switch prong captures
    /// may not be discarded.
    remove,
    /// `|value, tag|` becomes `|value|`.
    remove_tag,
    /// The capture of an unbounded range cannot be discarded.
    none,
};

const Binding = struct {
    /// The name token.
    name: usize,
    kind: Kind,
    /// The last token of the binding's scope.
    scope_end: usize,
    /// For parameters, the opening brace of the function body; for locals,
    /// the `;` ending the declaration.
    anchor: usize,
    capture_fix: CaptureFix = .none,
};

pub fn run(context: RuleRun) !void {
    const unused_level = context.level(.unused_local);
    const discard_level = context.level(.pointless_discard);
    if (unused_level == .off and discard_level == .off) return;
    const tree = context.tree;
    if (tree.errors.len != 0) return;

    var discarded: std.StringHashMapUnmanaged(void) = .empty;
    defer discarded.deinit(context.allocator);
    if (discard_level != .off) {
        for (context.tokens, 0..) |token, index| {
            if (token.tag == .identifier and isDiscard(context, index)) try discarded.put(context.allocator, normalizedName(context, index), {});
        }
    }

    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(context.allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        try collectBindings(context, node, &bindings);
    }

    if (bindings.items.len == 0) return;
    const identifiers = try context.scopes.identifiers();
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(context.allocator);
    for (bindings.items) |binding| {
        const name = normalizedName(context, binding.name);
        if (std.mem.eql(u8, name, "_")) continue;
        quoted.clearRetainingCapacity();
        try quoted.appendSlice(context.allocator, "@\"");
        try quoted.appendSlice(context.allocator, name);
        try quoted.append(context.allocator, '"');
        const usage = scan(context, .init(identifiers, name, quoted.items, binding), binding, name, discarded.contains(name));
        if (!usage.loosely_used and usage.discard == null) {
            if (unused_level != .off) try reportUnused(context, unused_level, binding);
        } else if (usage.used and usage.discard != null) {
            if (discard_level != .off) try reportDiscard(context, discard_level, binding, usage);
        }
    }
}

/// Appends the local bindings `node` declares.
fn collectBindings(context: RuleRun, node: Ast.Node.Index, bindings: *std.ArrayList(Binding)) !void {
    const tree = context.tree;
    const tokens = context.tokens;
    const allocator = context.allocator;
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            const prototype_node, const body = tree.nodeData(node).node_and_node;
            var buffer: [1]Ast.Node.Index = undefined;
            const prototype = tree.fullFnProto(&buffer, prototype_node) orelse return;
            var parameters = prototype.iterate(tree);
            while (parameters.next()) |parameter| {
                const name = parameter.name_token orelse continue;
                try bindings.append(allocator, .{
                    .name = name,
                    .kind = .parameter,
                    .scope_end = tree.lastToken(body),
                    .anchor = tree.nodeMainToken(body),
                });
            }
        },
        .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
            const declaration = tree.fullVarDecl(node) orelse return;
            const keyword = declaration.ast.mut_token;
            if (!isLocal(context, keyword)) return;
            const scope_end = context.enclosingScopeEnd(keyword) orelse return;
            const statement_end = context.statementEnd(keyword) orelse return;
            try bindings.append(allocator, .{
                .name = keyword + 1,
                .kind = if (tokens[keyword].tag == .keyword_var) .variable else .constant,
                .scope_end = scope_end,
                .anchor = statement_end,
            });
        },
        .if_simple, .@"if" => {
            const statement = tree.fullIf(node).?;
            if (!isLocal(context, statement.ast.if_token)) return;
            const end = tree.lastToken(node);
            if (statement.payload_token) |payload| try appendCapture(context, bindings, payload, .capture, end, .rename);
            if (statement.error_token) |capture| try appendCapture(context, bindings, capture, .capture, end, .remove);
        },
        .while_simple, .while_cont, .@"while" => {
            const loop = tree.fullWhile(node).?;
            if (!isLocal(context, loop.ast.while_token)) return;
            const end = tree.lastToken(node);
            if (loop.payload_token) |payload| try appendCapture(context, bindings, payload, .capture, end, .rename);
            if (loop.error_token) |capture| try appendCapture(context, bindings, capture, .capture, end, .remove);
        },
        .for_simple, .@"for" => {
            const loop = tree.fullFor(node).?;
            if (!isLocal(context, loop.ast.for_token)) return;
            const end = tree.lastToken(node);
            var capture: usize = loop.payload_token;
            for (loop.ast.inputs) |input| {
                const unbounded = tree.nodeTag(input) == .for_range and tree.nodeData(input).node_and_opt_node[1] == .none;
                try appendCapture(context, bindings, capture, .capture, end, if (unbounded) .none else .rename);
                if (tokens[capture].tag == .asterisk) capture += 1;
                if (tokens[capture + 1].tag != .comma) break;
                capture += 2;
            }
        },
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
            const case = tree.fullSwitchCase(node).?;
            const payload = case.payload_token orelse return;
            if (!isLocal(context, payload)) return;
            const end = tree.lastToken(node);
            const name = if (tokens[payload].tag == .asterisk) payload + 1 else payload;
            // `|_, tag|` may discard the payload, a lone `|_|` may not.
            const tagged = tokens[name + 1].tag == .comma;
            try appendCapture(context, bindings, payload, .capture, end, if (tagged) .rename else .remove);
            if (tagged) try appendCapture(context, bindings, name + 2, .switch_tag_capture, end, .remove_tag);
        },
        .@"catch" => {
            const keyword = tree.nodeMainToken(node);
            if (tokens[keyword + 1].tag != .pipe or !isLocal(context, keyword)) return;
            try appendCapture(context, bindings, keyword + 2, .capture, tree.lastToken(node), .remove);
        },
        else => {},
    }
}

fn appendCapture(
    context: RuleRun,
    bindings: *std.ArrayList(Binding),
    payload: usize,
    kind: Kind,
    scope_end: usize,
    fix: CaptureFix,
) !void {
    const name = if (context.tokens[payload].tag == .asterisk) payload + 1 else payload;
    if (context.tokens[name].tag != .identifier) return;
    try bindings.append(context.allocator, .{ .name = name, .kind = kind, .scope_end = scope_end, .anchor = payload, .capture_fix = fix });
}

/// Whether the declaration or capture at `index` sits in a block rather than
/// directly in a container, where AstGen does not check use.
fn isLocal(context: RuleRun, index: usize) bool {
    const opening = context.enclosingOpeningBrace(index) orelse return false;
    return !context.opensContainer(opening);
}

/// The binding's name with `@"..."` quoting removed, so `@"x"` and `x` match.
fn normalizedName(context: RuleRun, index: usize) []const u8 {
    const text = context.tokenText(index);
    if (text.len >= 3 and text[0] == '@' and text[1] == '"' and std.mem.findScalar(u8, text, '\\') == null) return text[2 .. text.len - 1];
    return text;
}

/// Whether the identifier at `index` is the `x` of a `_ = x;` statement.
fn isDiscard(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    if (index < 3 or tokens[index - 1].tag != .equal or tokens[index + 1].tag != .semicolon or
        tokens[index - 2].tag != .identifier or !context.tokenIs(index - 2, "_")) return false;
    return switch (tokens[index - 3].tag) {
        .semicolon, .l_brace, .r_brace => true,
        else => false,
    };
}

const Usage = struct {
    /// Some identifier spelled like the binding could refer to it.
    loosely_used: bool = false,
    /// A use the scope index resolves to the binding.
    used: bool = false,
    /// The last `_ = name;` of the binding.
    discard: ?usize = null,
};

/// The identifiers after a binding in its scope that `normalizedName` can
/// give the binding's name: those spelled `name` and those spelled
/// `@"name"`, merged in token order.
const Spellings = struct {
    plain: []const u32,
    quoted: []const u32,

    fn init(identifiers: *const IdentifierTable, name: []const u8, quoted: []const u8, binding: Binding) Spellings {
        const start = binding.name + 1;
        const end = binding.scope_end + 1;
        return .{ .plain = identifiers.within(name, start, end), .quoted = identifiers.within(quoted, start, end) };
    }

    fn next(spellings: *Spellings) ?usize {
        const positions = if (spellings.quoted.len == 0 or spellings.plain.len != 0 and spellings.plain[0] < spellings.quoted[0])
            &spellings.plain
        else
            &spellings.quoted;
        if (positions.len == 0) return null;
        defer positions.* = positions.*[1..];
        return positions.*[0];
    }
};

fn scan(context: RuleRun, spellings: Spellings, binding: Binding, name: []const u8, has_discards: bool) Usage {
    const tokens = context.tokens;
    var usage: Usage = .{};
    var candidates = spellings;
    while (candidates.next()) |index| {
        if (tokens[index].tag != .identifier or tokens[index - 1].tag == .period or
            !std.mem.eql(u8, normalizedName(context, index), name)) continue;
        if (has_discards and isDiscard(context, index)) {
            // A discard the index places elsewhere still hides an unused report.
            if (resolvesTo(context, index, binding.name)) usage.discard = index else usage.loosely_used = true;
            continue;
        }
        usage.loosely_used = true;
        if (!has_discards) return usage;
        if (!usage.used and isReference(context, index) and resolvesTo(context, index, binding.name)) usage.used = true;
    }
    return usage;
}

fn resolvesTo(context: RuleRun, index: usize, declaration: usize) bool {
    const binding = context.scopes.findBinding(index) orelse return false;
    return binding.token_index == declaration;
}

/// Whether the identifier at `index` reads or writes a binding rather than
/// declaring one or naming a field or label.
fn isReference(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    // `name: T` declares a parameter or field, `name: while` a label, and
    // `break :name` uses one.
    if (tokens[index + 1].tag == .colon or tokens[index - 1].tag == .colon) return false;
    const declared = context.scopes.resolve(index) orelse return true;
    return declared.token_index != index;
}

fn reportUnused(context: RuleRun, level: types.Level, binding: Binding) !void {
    const tokens = context.tokens;
    const name = context.tokenText(binding.name);
    const fixes: []const types.Fix = switch (binding.kind) {
        .constant, .variable => try context.singleFix(.{
            .title = try context.allocator.print("Discard '{s}'", .{name}),
            .span = .{ .start = tokens[binding.anchor].loc.end, .end = tokens[binding.anchor].loc.end },
            .replacement = try context.allocator.print("\n{s}_ = {s}{s};", .{
                tokens_util.lineIndentation(context.source, tokens[binding.name - 1].loc.start),
                if (binding.kind == .variable) "&" else "",
                name,
            }),
        }),
        .parameter => try parameterDiscard(context, binding, name),
        .capture, .switch_tag_capture => try captureFix(context, binding),
    };
    try context.emit(.{
        .rule = .unused_local,
        .level = level,
        .span = tokens[binding.name].loc,
        .message = binding.kind.unusedMessage(),
        .fixes = fixes,
    });
}

/// `_ = name;` as the first statement of the function body.
fn parameterDiscard(context: RuleRun, binding: Binding, name: []const u8) ![]const types.Fix {
    const tokens = context.tokens;
    const opening = binding.anchor;
    const indentation = tokens_util.lineIndentation(context.source, tokens[opening].loc.start);
    const title = try context.allocator.print("Discard '{s}'", .{name});
    const after = tokens[opening].loc.end;
    if (tokens[opening + 1].tag == .r_brace) return context.singleFix(.{
        .title = title,
        .span = .{ .start = after, .end = tokens[opening + 1].loc.start },
        .replacement = try context.allocator.print("\n{s}    _ = {s};\n{s}", .{ indentation, name, indentation }),
    });
    const multiline = std.mem.findScalar(u8, context.source[after..tokens[opening + 1].loc.start], '\n') != null;
    return context.singleFix(.{
        .title = title,
        .span = .{ .start = after, .end = after },
        .replacement = if (multiline)
            try context.allocator.print("\n{s}    _ = {s};", .{ indentation, name })
        else
            try context.allocator.print(" _ = {s};", .{name}),
    });
}

fn captureFix(context: RuleRun, binding: Binding) ![]const types.Fix {
    const tokens = context.tokens;
    switch (binding.capture_fix) {
        .none => return &.{},
        .rename => return context.singleFix(.{
            .title = "Discard the capture",
            .span = .{ .start = tokens[binding.anchor].loc.start, .end = tokens[binding.name].loc.end },
            .replacement = "_",
        }),
        .remove_tag => return context.singleFix(.{
            .title = "Remove the tag capture",
            .span = .{ .start = tokens[binding.name - 1].loc.start, .end = tokens[binding.name].loc.end },
            .replacement = "",
        }),
        .remove => {
            const opening = binding.anchor - 1;
            var closing = binding.name + 1;
            if (tokens[closing].tag == .comma) closing += 2;
            if (tokens[opening].tag != .pipe or tokens[closing].tag != .pipe) return &.{};
            return context.singleFix(.{
                .title = "Remove the capture",
                .span = .{ .start = tokens[opening].loc.start, .end = tokens[closing + 1].loc.start },
                .replacement = "",
            });
        },
    }
}

fn reportDiscard(context: RuleRun, level: types.Level, binding: Binding, usage: Usage) !void {
    const discard = usage.discard.?;
    const source = context.source;
    const start = context.tokens[discard - 2].loc.start;
    const end = context.tokens[discard + 1].loc.end;
    // Deleting whole lines is only right when the statement has its line to itself.
    const alone = std.mem.trim(u8, source[tokens_util.lineStart(source, start)..start], " \t").len == 0 and
        std.mem.trim(u8, source[end..tokens_util.lineEnd(source, end)], " \t\r\n").len == 0;
    const fixes: []const types.Fix = if (alone) try context.singleFix(.{
        .title = try context.allocator.print("Remove the discard of '{s}'", .{context.tokenText(binding.name)}),
        .span = tokens_util.removedLinesSpan(source, start, end),
        .replacement = "",
        .preferred = true,
        .fix_all = true,
    }) else &.{};
    try context.emit(.{
        .rule = .pointless_discard,
        .level = level,
        .span = context.tokens[discard].loc,
        .message = binding.kind.discardMessage(),
        .fixes = fixes,
    });
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{ .unused_local, .pointless_discard }, .@"error"));
}

test "unused locals, parameters and captures report with the compiler's wording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn locals(flag: bool, unused: u8, items: []const u8) !void {
        \\    const answer = 42;
        \\    var count: u8 = 0;
        \\    if (flag) {
        \\        for (items, 0..) |item, index| {
        \\            _ = item;
        \\        }
        \\    }
        \\    const result = parse() catch |err| 0;
        \\    _ = result;
        \\}
        \\fn parse() !u8 {
        \\    return 1;
        \\}
        \\fn prong(value: union(enum) { a: u8, b: u8 }) void {
        \\    switch (value) {
        \\        .a => |inner| {},
        \\        .b => |inner, tag| {
        \\            _ = inner;
        \\        },
        \\    }
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "unused", "answer", "count", "index", "err", "inner", "tag" });
    const messages = [_][]const u8{
        "unused function parameter", "unused local constant", "unused local variable",     "unused capture",
        "unused capture",            "unused capture",        "unused switch tag capture",
    };
    for (found, messages) |finding, message| try std.testing.expectEqualStrings(message, finding.message);
    try std.testing.expectEqualStrings("\n    _ = unused;", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("\n    _ = answer;", found[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("\n    _ = &count;", found[2].fixes[0].edits[0].replacement);
    // `index` captures the unbounded range `0..`, which cannot be discarded.
    try std.testing.expectEqual(@as(usize, 0), found[3].fixes.len);
    try std.testing.expectEqualStrings("|err| ", source[found[4].fixes[0].edits[0].span.start..found[4].fixes[0].edits[0].span.end]);
    try std.testing.expectEqualStrings("|inner| ", source[found[5].fixes[0].edits[0].span.start..found[5].fixes[0].edits[0].span.end]);
    try std.testing.expectEqualStrings(", tag", source[found[6].fixes[0].edits[0].span.start..found[6].fixes[0].edits[0].span.end]);
}

test "referenced bindings, discards alone and container members stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const top = 1;
        \\const Shape = struct {
        \\    const member = 2;
        \\    width: u8,
        \\    fn area(self: Shape, comptime T: type, scale: T) T {
        \\        return @as(T, self.width) * scale;
        \\    }
        \\};
        \\fn sized(comptime n: usize) [n]u8 {
        \\    return @splat(0);
        \\}
        \\fn quoted(@"type": u8, value: u8) u8 {
        \\    _ = value;
        \\    _ = value;
        \\    return @"type";
        \\}
        \\fn mutated() u8 {
        \\    var total: u8 = 0;
        \\    total = 2;
        \\    const Inner = struct { total: u8 };
        \\    _ = Inner;
        \\    return total;
        \\}
        \\extern fn external(handle: u8) void;
        \\const Callback = *const fn (context: u8) void;
        \\comptime {
        \\    for (.{1}) |item| _ = item;
        \\}
        \\fn opaqueBody(o: ?*u8) void {
        \\    if (o) |*pointer| pointer.* = 1;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "a discard of a referenced binding is pointless" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\fn twice(value: u8, other: u8) u8 {
        \\    _ = value;
        \\    const local = other;
        \\    _ = local;
        \\    return value + local;
        \\}
        \\fn capture(maybe: ?u8) u8 {
        \\    if (maybe) |inner| {
        \\        _ = inner;
        \\        return inner;
        \\    }
        \\    return 0;
        \\}
        \\fn sibling(a: []const u8, b: []const u8) void {
        \\    for (a) |item| {
        \\        _ = item;
        \\    }
        \\    for (b) |item| {
        \\        _ = item;
        \\    }
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "value", "local", "inner" });
    try std.testing.expectEqualStrings("pointless discard of function parameter", found[0].message);
    try std.testing.expectEqualStrings("pointless discard of local constant", found[1].message);
    try std.testing.expectEqualStrings("pointless discard of capture", found[2].message);
    try std.testing.expectEqualStrings("    _ = value;\n", source[found[0].fixes[0].edits[0].span.start..found[0].fixes[0].edits[0].span.end]);
    try std.testing.expect(found[0].fixes[0].fix_all);
}
