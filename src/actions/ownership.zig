const std = @import("std");

const analysis = @import("../analysis.zig");
const tokens_util = @import("../syntax/tokens.zig");
const action_context = @import("context.zig");
const resources = analysis.resources;
const container_types = analysis.container_types;
const deinit_poison = analysis.deinit_poison;

const ActionRun = action_context.ActionRun;
const Ast = std.zig.Ast;

pub fn run(context: ActionRun) !void {
    try addOwnedSliceReturn(context);
    try addReturnedOwnershipTransfer(context);
    try addCheckedAllocationSize(context);
    try addPoisonAfterDeinit(context);
    try addDeinitReleases(context);
}

fn addOwnedSliceReturn(context: ActionRun) !void {
    for (context.tokens, 0..) |token, return_index| {
        if (token.tag != .keyword_return or return_index + 3 >= context.tokens.len or
            context.tokens[return_index + 1].tag != .identifier or context.tokens[return_index + 2].tag != .period or
            !context.tokenIs(return_index + 3, "items")) continue;
        const expression_span = std.zig.Token.Loc{
            .start = context.tokens[return_index + 1].loc.start,
            .end = context.tokens[return_index + 3].loc.end,
        };
        if (!context.selected(expression_span)) continue;
        const container = context.tokenText(return_index + 1);
        const function = action_context.containingFunction(context, return_index) orelse continue;
        const allocator = deinitAllocator(context, container, function.body_start, return_index) orelse continue;
        if (!isArrayListBinding(context, container, function.body_start, return_index)) continue;
        const prefix = if (function.returnsError(context)) "try " else "";
        const suffix = if (function.returnsError(context)) "" else " catch @panic(\"out of memory\")";
        try context.oneEdit(
            "Return owned container storage",
            .quickfix,
            expression_span,
            try context.allocator.print(
                "{s}{s}.toOwnedSlice({s}){s}",
                .{ prefix, container, allocator, suffix },
            ),
            .{},
        );
    }
}

fn isArrayListBinding(context: ActionRun, name: []const u8, lower: usize, before: usize) bool {
    var index = before;
    while (index > lower) {
        index -= 1;
        if (!context.tokenIs(index, name) or index == 0 or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var)) continue;
        const end = context.statementEnd(index - 1) orelse return false;
        for (context.tokens[index + 1 .. @min(end, before)], index + 1..) |token, declaration_index| {
            if (token.tag == .identifier and context.tokenIs(declaration_index, "ArrayList")) return true;
        }
        return false;
    }
    return false;
}

fn deinitAllocator(context: ActionRun, name: []const u8, lower: usize, before: usize) ?[]const u8 {
    for (context.tokens[lower..before], lower..) |token, index| {
        if (token.tag != .keyword_defer or index + 6 >= before or !context.tokenIs(index + 1, name) or
            context.tokens[index + 2].tag != .period or !context.tokenIs(index + 3, "deinit") or
            context.tokens[index + 4].tag != .l_paren or context.tokens[index + 5].tag != .identifier or
            context.tokens[index + 6].tag != .r_paren) continue;
        return context.tokenText(index + 5);
    }
    return null;
}

fn addReturnedOwnershipTransfer(context: ActionRun) !void {
    for (context.tokens, 0..) |token, defer_index| {
        if (token.tag != .keyword_defer or !context.selected(token.loc)) continue;
        if (defer_index + 1 >= context.tokens.len or context.tokens[defer_index + 1].tag == .l_brace) continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        const function = action_context.containingFunction(context, defer_index) orelse continue;
        if (!function.returnsError(context) or
            !everyReturnTransfersOwnership(context, binding, defer_end + 1, function.body_end)) continue;
        try context.oneEdit(
            try context.allocator.print("Transfer ownership of '{s}' on success", .{binding}),
            .refactor_rewrite,
            token.loc,
            "errdefer",
            .{},
        );
    }
}

fn cleanupBinding(context: ActionRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !resources.isReleaseMethod(context.tokenText(index))) continue;
        if (index >= 2 and context.tokens[index - 1].tag == .period and context.tokens[index - 2].tag == .identifier and
            (context.tokenIs(index, "close") or context.tokenIs(index, "deinit") or context.tokenIs(index, "join") or
                context.tokenIs(index, "detach"))) return context.tokenText(index - 2);
        if (index + 2 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        for (context.tokens[index + 2 .. end], index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) return context.tokenText(argument_index);
            if (argument.tag == .r_paren) break;
        }
    }
    return null;
}

fn everyReturnTransfersOwnership(context: ActionRun, name: []const u8, start: usize, end: usize) bool {
    var transfers = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_return) continue;
        if (index + 2 < end and context.tokenIs(index + 1, name) and
            context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .semicolon)
        {
            transfers = true;
            continue;
        }
        if (index + 3 < end and context.tokens[index + 1].tag == .keyword_error and
            context.tokens[index + 2].tag == .period and context.tokens[index + 3].tag == .identifier) continue;
        return false;
    }
    return transfers;
}

fn addCheckedAllocationSize(context: ActionRun) !void {
    for (context.tokens, 0..) |token, multiplication_index| {
        if (token.tag != .asterisk or multiplication_index == 0 or multiplication_index + 1 >= context.tokens.len) continue;
        const left = context.tokens[multiplication_index - 1];
        const right = context.tokens[multiplication_index + 1];
        if (!simpleOperand(left.tag) or !simpleOperand(right.tag)) continue;
        if (multiplication_index >= 2 and context.tokens[multiplication_index - 2].tag == .period) continue;
        if (multiplication_index + 2 < context.tokens.len and switch (context.tokens[multiplication_index + 2].tag) {
            .period, .l_bracket, .l_paren => true,
            else => false,
        }) continue;
        const product_span = std.zig.Token.Loc{ .start = left.loc.start, .end = right.loc.end };
        if (!context.selected(product_span) or !insideAllocationCall(context, multiplication_index)) continue;
        try context.oneEdit(
            "Check allocation size overflow",
            .refactor_rewrite,
            product_span,
            try context.allocator.print(
                "(@import(\"std\").math.mul(usize, {s}, {s}) catch @panic(\"allocation size overflow\"))",
                .{ context.tokenText(multiplication_index - 1), context.tokenText(multiplication_index + 1) },
            ),
            .{},
        );
    }
}

fn simpleOperand(tag: std.zig.Token.Tag) bool {
    return tag == .identifier or tag == .number_literal;
}

fn insideAllocationCall(context: ActionRun, index: usize) bool {
    var cursor = index;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth != 0) {
                    depth -= 1;
                    continue;
                }
                if (cursor == 0 or context.tokens[cursor - 1].tag != .identifier) return false;
                for (resources.sized_allocations) |allocation| if (context.tokenIs(cursor - 1, allocation.method)) return true;
                return false;
            },
            .semicolon => if (depth == 0) return false,
            else => {},
        }
    }
    return false;
}

fn addPoisonAfterDeinit(context: ActionRun) !void {
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn) continue;
        const name = deinit_poison.mutableReceiver(context.source, context.tokens, fn_index) orelse continue;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
        const body_start = deinit_poison.bodyAfterParameters(context.tokens, parameters_end) orelse continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        const function_span = std.zig.Token.Loc{ .start = token.loc.start, .end = context.tokens[body_end].loc.end };
        if (!context.selected(function_span)) continue;
        if (!deinit_poison.poisonable(context.source, context.tokens, name, body_start, body_end)) continue;
        const edit = try deinit_poison.poisonEdit(context.allocator, context.source, context.tokens, name, body_end);
        try context.oneEdit("Poison after deinit", .refactor_rewrite, edit.span, edit.replacement, .{});
    }
}

fn endsWithPoison(context: ActionRun, body_end: usize, receiver: []const u8) bool {
    if (body_end < 5) return false;
    return context.tokens[body_end - 5].tag == .identifier and context.tokenIs(body_end - 5, receiver) and
        context.tokens[body_end - 4].tag == .period_asterisk and
        context.tokens[body_end - 3].tag == .equal and context.tokenIs(body_end - 2, "undefined") and
        context.tokens[body_end - 1].tag == .semicolon;
}

/// How `deinit` releases one owned field.
const Release = enum {
    /// `self.field.deinit(allocator);`: unmanaged containers and nested owners
    /// whose `deinit` takes the allocator.
    deinit_with_allocator,
    /// `self.field.deinit();`: managed containers, arenas, nested owners.
    deinit,
    /// `allocator.free(self.field);`
    free,
    /// `allocator.destroy(self.field);`
    destroy,

    fn needsAllocator(release: Release) bool {
        return release != .deinit;
    }

    /// `free` and `destroy` take the field by value; a `deinit` method needs it
    /// through a mutable receiver.
    fn needsMutableReceiver(release: Release) bool {
        return release == .deinit or release == .deinit_with_allocator;
    }
};

/// What a field's type says about the resources it owns.
const FieldClass = union(enum) {
    none,
    allocator,
    arena,
    owned: Release,
    /// A slice or single pointer: owned only when the file stores an allocation in it.
    allocated: Release,
    /// An optional slice or pointer: when the file allocates into it, releasing
    /// it needs an unwrap the generated code does not write.
    optional_allocated: Release,
    /// Owns resources the generated code cannot release.
    unsupported,
};

const OwnedField = struct { name: []const u8, release: Release };

/// A struct's owned fields in declaration order, and the members a `deinit`
/// is placed after or merged into.
const Owner = struct {
    container: Ast.Node.Index,
    fields: []const OwnedField,
    allocator_field: ?[]const u8,
    last_field: Ast.Node.Index,
    init: ?Ast.Node.Index,
    deinit: ?Ast.Node.Index,
};

/// Generates `deinit` on a selected struct whose fields own resources, or adds
/// the releases an existing `deinit` omits. Each container is released in its
/// own allocator style (`list.deinit(allocator)` when unmanaged, `map.deinit()`
/// when managed); slices and pointers only when the file stores an allocation
/// in them, since a slice field may as well borrow. A struct with a field it
/// cannot release, or whose `deinit` hands the receiver elsewhere, gets nothing.
fn addDeinitReleases(context: ActionRun) !void {
    const trigger = deinitTrigger(context) orelse return;
    var tree = try Ast.parse(context.allocator, context.source, .{ .mode = .zig });
    defer tree.deinit(context.allocator);
    const container = switch (trigger) {
        .struct_keyword => |keyword| structAt(&tree, keyword),
        .deinit_name => |name| action_context.enclosingStruct(&tree, name),
    } orelse return;
    const owner = try ownedStruct(context, &tree, container) orelse return;
    if (owner.deinit) |deinit_node| return addMissingReleases(context, &tree, owner, deinit_node);
    if (trigger == .struct_keyword) try addGeneratedDeinit(context, &tree, owner);
}

const DeinitTrigger = union(enum) {
    /// The `struct` keyword of a selected `const Name = struct` header.
    struct_keyword: usize,
    /// The name of a selected `fn deinit`.
    deinit_name: usize,
};

fn deinitTrigger(context: ActionRun) ?DeinitTrigger {
    for (context.tokens, 0..) |token, index| {
        if (token.loc.start > context.selection.end) return null;
        if (!context.selected(token.loc)) continue;
        switch (token.tag) {
            .keyword_struct => return .{ .struct_keyword = index },
            .keyword_const, .keyword_var, .identifier => {
                const name = if (token.tag == .identifier) index else index + 1;
                if (name + 2 < context.tokens.len and context.tokens[name].tag == .identifier and
                    context.tokens[name + 1].tag == .equal and context.tokens[name + 2].tag == .keyword_struct)
                    return .{ .struct_keyword = name + 2 };
                if (token.tag == .identifier and index > 0 and context.tokens[index - 1].tag == .keyword_fn and
                    context.tokenIs(index, "deinit")) return .{ .deinit_name = index };
            },
            else => {},
        }
    }
    return null;
}

fn structAt(tree: *const Ast, keyword: usize) ?Ast.Node.Index {
    for (1..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        var buffer: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, node) orelse continue;
        if (container.ast.main_token == keyword) return node;
    }
    return null;
}

fn ownedStruct(context: ActionRun, tree: *const Ast, container: Ast.Node.Index) !?Owner {
    var buffer: [2]Ast.Node.Index = undefined;
    const members = tree.fullContainerDecl(&buffer, container).?.ast.members;
    var fields: std.ArrayList(OwnedField) = .empty;
    defer fields.deinit(context.allocator);
    var allocated: std.ArrayList(OwnedField) = .empty;
    defer allocated.deinit(context.allocator);
    var optional_allocated: std.ArrayList(OwnedField) = .empty;
    defer optional_allocated.deinit(context.allocator);
    var owner: Owner = .{
        .container = container,
        .fields = &.{},
        .allocator_field = null,
        .last_field = undefined,
        .init = null,
        .deinit = null,
    };
    var field_count: usize = 0;
    var arena = false;
    for (members) |member| {
        if (tree.nodeTag(member) == .fn_decl) {
            var prototype_buffer: [1]Ast.Node.Index = undefined;
            const prototype = tree.fullFnProto(&prototype_buffer, tree.nodeData(member).node_and_node[0]).?;
            const name = prototype.name_token orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(name), "init")) owner.init = member;
            if (std.mem.eql(u8, tree.tokenSlice(name), "deinit")) owner.deinit = member;
            continue;
        }
        const field = tree.fullContainerField(member) orelse continue;
        owner.last_field = member;
        field_count += 1;
        const name = tree.tokenSlice(field.ast.main_token);
        const type_node = field.ast.type_expr.unwrap() orelse return null;
        switch (classifyField(context, tree, type_node)) {
            .none => {},
            .allocator => if (owner.allocator_field == null) {
                owner.allocator_field = name;
            },
            .arena => {
                arena = true;
                try fields.append(context.allocator, .{ .name = name, .release = .deinit });
            },
            .owned => |release| try fields.append(context.allocator, .{ .name = name, .release = release }),
            .allocated => |release| try allocated.append(context.allocator, .{ .name = name, .release = release }),
            .optional_allocated => |release| try optional_allocated.append(context.allocator, .{ .name = name, .release = release }),
            .unsupported => return null,
        }
    }
    if (field_count == 0) return null;
    if (arena) {
        // Whatever the struct allocates from an arena it owns goes with the arena.
        var arenas: std.ArrayList(OwnedField) = .empty;
        errdefer arenas.deinit(context.allocator);
        for (members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            if (classifyField(context, tree, field.ast.type_expr.unwrap().?) != .arena) continue;
            try arenas.append(context.allocator, .{ .name = tree.tokenSlice(field.ast.main_token), .release = .deinit });
        }
        owner.fields = try arenas.toOwnedSlice(context.allocator);
        return owner;
    }
    const stored = try storedAllocations(context, tree, container, allocated.items, optional_allocated.items);
    for (stored.optional) |allocates| if (allocates) return null;
    for (allocated.items, stored.plain) |field, allocates| if (allocates) try fields.append(context.allocator, field);
    if (fields.items.len == 0) return null;
    const ordered = try context.allocator.alloc(OwnedField, fields.items.len);
    var write: usize = 0;
    for (members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        if (fieldIndex(fields.items, tree.tokenSlice(field.ast.main_token))) |index| {
            ordered[write] = fields.items[index];
            write += 1;
        }
    }
    owner.fields = ordered;
    return owner;
}

fn classifyField(context: ActionRun, tree: *const Ast, type_node: Ast.Node.Index) FieldClass {
    if (tree.nodeTag(type_node) == .optional_type) {
        return switch (classifyField(context, tree, tree.nodeData(type_node).node)) {
            .allocated => |release| .{ .optional_allocated = release },
            .owned, .arena, .unsupported, .optional_allocated => .unsupported,
            .none, .allocator => .none,
        };
    }
    if (tree.fullPtrType(type_node)) |pointer| return switch (pointer.size) {
        .slice => .{ .allocated = .free },
        .one => .{ .allocated = .destroy },
        .many, .c => .none,
    };
    const first = tree.firstToken(type_node);
    const end = tree.lastToken(type_node) + 1;
    var index: usize = first;
    // `@import("std").ArrayList(T)` names the container after the import.
    if (context.tokens[index].tag == .builtin and index + 1 < end and context.tokens[index + 1].tag == .l_paren) {
        index = (context.matchingToken(index + 1, .l_paren, .r_paren) orelse return .none) + 1;
        if (index + 1 >= end or context.tokens[index].tag != .period) return .none;
        index += 1;
    }
    while (index + 2 < end and context.tokens[index].tag == .identifier and context.tokens[index + 1].tag == .period) index += 2;
    if (context.tokens[index].tag != .identifier) return .none;
    const name = context.tokenText(index);
    if (index + 1 == end and std.mem.eql(u8, name, "Allocator")) return .allocator;
    if (std.mem.eql(u8, name, "ArenaAllocator")) return .arena;
    if (std.mem.eql(u8, name, "BufMap") or std.mem.eql(u8, name, "BufSet")) return .{ .owned = .deinit };
    if (container_types.kindOfToken(context.source, context.tokens, index)) |kind| return switch (kind) {
        .list => if (std.mem.eql(u8, name, "Managed") or std.mem.eql(u8, name, "AlignedManaged"))
            .{ .owned = .deinit }
        else
            .{ .owned = .deinit_with_allocator },
        .hash_map => if (std.mem.endsWith(u8, name, "Unmanaged")) .{ .owned = .deinit_with_allocator } else .{ .owned = .deinit },
        // `ArrayHashMap` was managed before Zig 0.15 and names the unmanaged `Custom` since.
        .array_hash_map => if (std.mem.endsWith(u8, name, "Unmanaged") or std.mem.eql(u8, name, "Auto") or
            std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Custom"))
            .{ .owned = .deinit_with_allocator }
        else
            .unsupported,
        .multi_array_list, .priority_queue => .{ .owned = .deinit_with_allocator },
        .segmented_list => .unsupported,
    };
    if (index == first and index + 1 == end) return nestedOwner(context, tree, name);
    return .none;
}

/// A field whose type is a top-level struct of this file with a `deinit` of
/// its own, released through it when it takes nothing or only an allocator.
fn nestedOwner(context: ActionRun, tree: *const Ast, type_name: []const u8) FieldClass {
    for (tree.rootDecls()) |declaration| {
        const variable = tree.fullVarDecl(declaration) orelse continue;
        if (!context.tokenIs(variable.ast.mut_token + 1, type_name)) continue;
        const initializer = variable.ast.init_node.unwrap() orelse return .none;
        var buffer: [2]Ast.Node.Index = undefined;
        const nested = tree.fullContainerDecl(&buffer, initializer) orelse return .none;
        for (nested.ast.members) |member| {
            if (tree.nodeTag(member) != .fn_decl) continue;
            var prototype_buffer: [1]Ast.Node.Index = undefined;
            const prototype = tree.fullFnProto(&prototype_buffer, tree.nodeData(member).node_and_node[0]).?;
            const name = prototype.name_token orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name), "deinit")) continue;
            var parameters = prototype.iterate(tree);
            _ = parameters.next() orelse return .unsupported;
            const allocator = parameters.next() orelse return .{ .owned = .deinit };
            if (parameters.next() != null) return .unsupported;
            const allocator_type = allocator.type_expr orelse return .unsupported;
            if (!std.mem.endsWith(u8, nodeText(context, tree, allocator_type), "Allocator")) return .unsupported;
            return .{ .owned = .deinit_with_allocator };
        }
        return .none;
    }
    return .none;
}

const StoredAllocations = struct { plain: []bool, optional: []bool };

/// For each slice or pointer field, whether the file stores an allocation in
/// it: an initializer `.name = try a.dupe(u8, s)` of the struct (`T{...}`,
/// `.{...}` returned from a function returning `T`, assigned to `self.*` in
/// its methods, or bound to `const x: T`) or an assignment `x.name = ...` in
/// its methods, directly or through a local initialized with the allocation.
/// One pass over the file.
fn storedAllocations(
    context: ActionRun,
    tree: *const Ast,
    container: Ast.Node.Index,
    plain: []const OwnedField,
    optional: []const OwnedField,
) !StoredAllocations {
    const stored: StoredAllocations = .{
        .plain = try context.allocator.alloc(bool, plain.len),
        .optional = try context.allocator.alloc(bool, optional.len),
    };
    @memset(stored.plain, false);
    @memset(stored.optional, false);
    if (plain.len + optional.len == 0) return stored;
    const functions = try functionRanges(context, tree);
    const body_start = tree.nodeMainToken(container);
    const body_end = tree.lastToken(container);
    for (context.tokens, 0..) |token, period| {
        if (token.tag != .period or period == 0 or period + 3 >= context.tokens.len or
            context.tokens[period + 1].tag != .identifier or context.tokens[period + 2].tag != .equal) continue;
        const name = context.tokenText(period + 1);
        const plain_index = fieldIndex(plain, name);
        const optional_index = fieldIndex(optional, name);
        if (plain_index == null and optional_index == null) continue;
        const inside = body_start < period and period < body_end;
        const ours = switch (context.tokens[period - 1].tag) {
            .identifier, .r_paren, .r_bracket => inside,
            .l_brace, .comma => initializesStruct(context, tree, container, functions, period, inside),
            else => false,
        };
        if (!ours) continue;
        const release = if (plain_index) |index| plain[index].release else optional[optional_index.?].release;
        if (!storesAllocationAt(context, functions, period + 3, release)) continue;
        if (plain_index) |index| stored.plain[index] = true;
        if (optional_index) |index| stored.optional[index] = true;
    }
    return stored;
}

fn fieldIndex(fields: []const OwnedField, name: []const u8) ?usize {
    for (fields, 0..) |field, index| if (std.mem.eql(u8, field.name, name)) return index;
    return null;
}

/// A function's return type and body by token positions.
const FunctionRange = struct { return_start: usize, body_start: usize, body_end: usize };

/// Every function of the file, gathered once so no site rescans the file
/// for the function around it.
fn functionRanges(context: ActionRun, tree: *const Ast) ![]const FunctionRange {
    var ranges: std.ArrayList(FunctionRange) = .empty;
    errdefer ranges.deinit(context.allocator);
    for (1..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, tree.nodeData(node).node_and_node[0]).?;
        const return_type = prototype.ast.return_type.unwrap() orelse continue;
        const body = tree.nodeData(node).node_and_node[1];
        try ranges.append(context.allocator, .{
            .return_start = tree.firstToken(return_type),
            .body_start = tree.firstToken(body),
            .body_end = tree.lastToken(body),
        });
    }
    return ranges.toOwnedSlice(context.allocator);
}

fn innermostFunction(functions: []const FunctionRange, index: usize) ?FunctionRange {
    var innermost: ?FunctionRange = null;
    for (functions) |function| {
        if (function.body_start >= index or index >= function.body_end) continue;
        if (innermost) |current| if (current.body_start > function.body_start) continue;
        innermost = function;
    }
    return innermost;
}

/// Whether the initializer holding the field at `period` builds `container`.
fn initializesStruct(
    context: ActionRun,
    tree: *const Ast,
    container: Ast.Node.Index,
    functions: []const FunctionRange,
    period: usize,
    inside: bool,
) bool {
    var depth: usize = 0;
    var opening = period;
    while (opening > 0) {
        opening -= 1;
        switch (context.tokens[opening].tag) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_paren, .l_bracket => depth -|= 1,
            .l_brace => {
                if (depth == 0) break;
                depth -= 1;
            },
            else => {},
        }
    } else return false;
    if (opening < 3) return false;
    switch (context.tokens[opening - 1].tag) {
        .identifier => return action_context.namesStruct(context, tree, container, context.tokenText(opening - 1)),
        .period => switch (context.tokens[opening - 2].tag) {
            .keyword_return => {
                const function = innermostFunction(functions, opening) orelse return false;
                for (context.tokens[function.return_start..function.body_start], function.return_start..) |token, index| {
                    if (token.tag == .identifier and action_context.namesStruct(context, tree, container, context.tokenText(index))) return true;
                }
                return false;
            },
            .equal => {
                if (context.tokens[opening - 3].tag == .period_asterisk) return inside;
                return opening >= 4 and context.tokens[opening - 4].tag == .colon and context.tokens[opening - 3].tag == .identifier and
                    action_context.namesStruct(context, tree, container, context.tokenText(opening - 3));
            },
            else => return false,
        },
        else => return false,
    }
}

/// Whether the value starting at `start` (up to its `,`, `;` or closing
/// delimiter) calls an allocator method released by `release`, or names a
/// local initialized with such a call.
fn storesAllocationAt(context: ActionRun, functions: []const FunctionRange, start: usize, release: Release) bool {
    const end = valueEnd(context, start);
    if (allocatesIn(context, start, end, release)) return true;
    var name = start;
    if (name < end and context.tokens[name].tag == .keyword_try) name += 1;
    if (name + 1 != end or context.tokens[name].tag != .identifier) return false;
    const function = innermostFunction(functions, start) orelse return false;
    var index = start;
    while (index > function.body_start + 1) {
        index -= 1;
        if (!context.tokenIs(index, context.tokenText(name)) or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var)) continue;
        const declaration_end = context.statementEnd(index - 1) orelse return false;
        return allocatesIn(context, index + 1, declaration_end, release);
    }
    return false;
}

fn valueEnd(context: ActionRun, start: usize) usize {
    var depth: usize = 0;
    for (context.tokens[start..], start..) |token, index| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) return index;
            depth -= 1;
        },
        .comma, .semicolon => if (depth == 0) return index,
        .eof => return index,
        else => {},
    };
    return context.tokens.len;
}

fn allocatesIn(context: ActionRun, start: usize, end: usize, release: Release) bool {
    const wanted = switch (release) {
        .free => "free",
        .destroy => "destroy",
        .deinit, .deinit_with_allocator => return false,
    };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index == 0 or context.tokens[index - 1].tag != .period or
            index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const method = context.tokenText(index);
        if (resources.uniqueAllocationRelease(method)) |found| if (std.mem.eql(u8, found, wanted)) return true;
        if (release == .free and (std.mem.eql(u8, method, "toOwnedSlice") or std.mem.eql(u8, method, "toOwnedSliceSentinel") or
            std.mem.eql(u8, method, "allocPrint") or std.mem.eql(u8, method, "allocPrintSentinel"))) return true;
    }
    return false;
}

fn releaseStatement(context: ActionRun, field: OwnedField, receiver: []const u8, allocator: []const u8) ![]const u8 {
    return switch (field.release) {
        .deinit_with_allocator => context.allocator.print("{s}.{s}.deinit({s});", .{ receiver, field.name, allocator }),
        .deinit => context.allocator.print("{s}.{s}.deinit();", .{ receiver, field.name }),
        .free => context.allocator.print("{s}.free({s}.{s});", .{ allocator, receiver, field.name }),
        .destroy => context.allocator.print("{s}.destroy({s}.{s});", .{ allocator, receiver, field.name }),
    };
}

fn addGeneratedDeinit(context: ActionRun, tree: *const Ast, owner: Owner) !void {
    if (lineOf(context, tree.nodeMainToken(owner.container)) == lineOf(context, tree.lastToken(owner.container))) return;
    var needs_allocator = false;
    for (owner.fields) |field| needs_allocator = needs_allocator or field.release.needsAllocator();
    var parameter: []const u8 = "";
    var allocator: []const u8 = "";
    if (needs_allocator) {
        if (owner.allocator_field) |field| {
            allocator = try context.allocator.print("self.{s}", .{field});
        } else {
            allocator = for ([_][]const u8{ "allocator", "gpa" }) |candidate| {
                if (!declaredInContainers(context, tree, owner.container, candidate)) break candidate;
            } else return;
            parameter = try context.allocator.print(", {s}: {s}", .{ allocator, allocatorType(context, tree, owner.container) });
        }
    }
    const type_name = if (action_context.structName(context, tree, owner.container)) |name_index|
        context.tokenText(name_index)
    else
        selfAlias(context, tree, owner.container) orelse "@This()";

    const indentation = context.lineIndentation(context.tokens[tree.firstToken(owner.last_field)].loc.start);
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    try writer.writer.print("\n\n{s}pub fn deinit(self: *{s}{s}) void {{\n", .{ indentation, type_name, parameter });
    for (owner.fields) |field| {
        try writer.writer.print("{s}    {s}\n", .{ indentation, try releaseStatement(context, field, "self", allocator) });
    }
    try writer.writer.print("{s}    self.* = undefined;\n{s}}}", .{ indentation, indentation });

    var edits: std.ArrayList(analysis.Edit) = .empty;
    errdefer edits.deinit(context.allocator);
    var anchor = tree.lastToken(owner.init orelse owner.last_field);
    if (owner.init == null) {
        if (context.tokens[anchor + 1].tag == .comma) {
            anchor += 1;
        } else {
            // The last field closed the struct without a comma; a member now follows it.
            const after = context.tokens[anchor].loc.end;
            try edits.append(context.allocator, .{ .span = .{ .start = after, .end = after }, .replacement = "," });
        }
    }
    // Before the line's newline, so a trailing comment stays with the member it follows.
    const line_end = tokens_util.lineEnd(context.source, context.tokens[anchor].loc.end) - 1;
    try edits.append(context.allocator, .{ .span = .{ .start = line_end, .end = line_end }, .replacement = try writer.toOwnedSlice() });
    try context.add("Generate deinit", .refactor_rewrite, try edits.toOwnedSlice(context.allocator), .{});
}

fn addMissingReleases(context: ActionRun, tree: *const Ast, owner: Owner, deinit_node: Ast.Node.Index) !void {
    var prototype_buffer: [1]Ast.Node.Index = undefined;
    const prototype = tree.fullFnProto(&prototype_buffer, tree.nodeData(deinit_node).node_and_node[0]).?;
    const body = tree.nodeData(deinit_node).node_and_node[1];
    const body_open = tree.firstToken(body);
    const body_close = tree.lastToken(body);
    if (lineOf(context, body_open) == lineOf(context, body_close)) return;
    var parameters = prototype.iterate(tree);
    const receiver_parameter = parameters.next() orelse return;
    const receiver = tree.tokenSlice(receiver_parameter.name_token orelse return);
    const receiver_type = receiver_parameter.type_expr orelse return;
    const mutable = if (tree.fullPtrType(receiver_type)) |pointer| pointer.const_token == null else false;
    var allocator: ?[]const u8 = null;
    while (parameters.next()) |parameter| {
        const name = parameter.name_token orelse continue;
        const parameter_type = parameter.type_expr orelse continue;
        if (std.mem.endsWith(u8, nodeText(context, tree, parameter_type), "Allocator")) allocator = tree.tokenSlice(name);
    }
    if (allocator == null) if (owner.allocator_field) |field| {
        allocator = try context.allocator.print("{s}.{s}", .{ receiver, field });
    };

    // Only field accesses and the final poison: a call that takes the receiver
    // or one of its methods may release anything.
    for (context.tokens[body_open + 1 .. body_close], body_open + 1..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, receiver) or context.tokens[index - 1].tag == .period) continue;
        if (context.tokens[index + 1].tag == .period_asterisk) continue;
        if (context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier) return;
        if (context.tokens[index + 3].tag == .l_paren) return;
    }
    var missing: std.ArrayList(OwnedField) = .empty;
    defer missing.deinit(context.allocator);
    for (owner.fields) |field| {
        if (mentionsField(context, body_open + 1, body_close, receiver, field.name)) continue;
        if (field.release.needsMutableReceiver() and !mutable) return;
        if (field.release.needsAllocator() and allocator == null) return;
        try missing.append(context.allocator, field);
    }
    if (missing.items.len == 0) return;

    const before = if (endsWithPoison(context, body_close, receiver)) body_close - 5 else body_close;
    const insert_at = tokens_util.lineStart(context.source, context.tokens[before].loc.start);
    const indentation = if (before == body_close)
        try context.allocator.print("{s}    ", .{context.lineIndentation(context.tokens[body_close].loc.start)})
    else
        context.lineIndentation(context.tokens[before].loc.start);
    var writer: std.Io.Writer.Allocating = .init(context.allocator);
    defer writer.deinit();
    for (missing.items) |field| {
        try writer.writer.print("{s}{s}\n", .{ indentation, try releaseStatement(context, field, receiver, allocator orelse "") });
    }
    try context.oneEdit(
        if (missing.items.len == 1)
            try context.allocator.print("Release '{s}' in deinit", .{missing.items[0].name})
        else
            try context.allocator.print("Release {d} missing owned fields in deinit", .{missing.items.len}),
        .refactor_rewrite,
        .{ .start = insert_at, .end = insert_at },
        try writer.toOwnedSlice(),
        .{},
    );
}

fn mentionsField(context: ActionRun, start: usize, end: usize, receiver: []const u8, field: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, receiver) and index + 2 < end and
            context.tokens[index + 1].tag == .period and context.tokenIs(index + 2, field)) return true;
    }
    return false;
}

/// Whether `name` is declared by the struct or the file's top level, where a
/// parameter of that name would be a shadowing error.
fn declaredInContainers(context: ActionRun, tree: *const Ast, container: Ast.Node.Index, name: []const u8) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    for ([_][]const Ast.Node.Index{ tree.rootDecls(), tree.fullContainerDecl(&buffer, container).?.ast.members }) |members| {
        for (members) |member| {
            if (tree.fullVarDecl(member)) |variable| if (context.tokenIs(variable.ast.mut_token + 1, name)) return true;
            if (tree.nodeTag(member) != .fn_decl) continue;
            var prototype_buffer: [1]Ast.Node.Index = undefined;
            const prototype = tree.fullFnProto(&prototype_buffer, tree.nodeData(member).node_and_node[0]).?;
            if (prototype.name_token) |token| if (std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
        }
    }
    return false;
}

/// How the file spells `std.mem.Allocator`: an `Allocator` declaration in
/// scope, the `std` import, or the import inline.
fn allocatorType(context: ActionRun, tree: *const Ast, container: Ast.Node.Index) []const u8 {
    if (declaredInContainers(context, tree, container, "Allocator")) return "Allocator";
    if (declaredInContainers(context, tree, container, "std")) return "std.mem.Allocator";
    return "@import(\"std\").mem.Allocator";
}

/// A member `const Self = @This();` name, for a struct bound to no name.
fn selfAlias(context: ActionRun, tree: *const Ast, container: Ast.Node.Index) ?[]const u8 {
    var buffer: [2]Ast.Node.Index = undefined;
    for (tree.fullContainerDecl(&buffer, container).?.ast.members) |member| {
        const variable = tree.fullVarDecl(member) orelse continue;
        const name = context.tokenText(variable.ast.mut_token + 1);
        if (action_context.namesStruct(context, tree, container, name)) return name;
    }
    return null;
}

fn lineOf(context: ActionRun, token: usize) usize {
    return tokens_util.lineStart(context.source, context.tokens[token].loc.start);
}

fn nodeText(context: ActionRun, tree: *const Ast, node: Ast.Node.Index) []const u8 {
    return context.source[context.tokens[tree.firstToken(node)].loc.start..context.tokens[tree.lastToken(node)].loc.end];
}

test "owned slices and successful ownership transfers are explicit" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn list(a: anytype) ![]u8 { var values = std.ArrayList(u8).empty; defer values.deinit(a); return values.items; } " ++
        "fn bytes(a: anytype) ![]u8 { const value = try a.alloc(u8, 1); defer a.free(value); return value; }";
    const items = std.mem.find(u8, source, "values.items") orelse unreachable;
    const owned = try registry.actions(arena.allocator(), source, .{ .start = items, .end = items + 12 }, &.{});
    try std.testing.expectEqualStrings("try values.toOwnedSlice(a)", owned[0].edits[0].replacement);
    const defer_start = std.mem.findLast(u8, source, "defer") orelse unreachable;
    const transfer = try registry.actions(arena.allocator(), source, .{ .start = defer_start, .end = defer_start + 5 }, &.{});
    try std.testing.expectEqualStrings("errdefer", transfer[0].edits[0].replacement);
}

test "allocation products get an overflow-checking refactor" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: anytype, count: usize) !void { _ = try a.alloc(u8, count * 4); }";
    const start = std.mem.find(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    const checked = onlyTitled(actions, "Check allocation size overflow").?;
    try std.testing.expect(std.mem.find(u8, checked.edits[0].replacement, "math.mul") != null);
}

test "checked allocation sizes keep trailing addends out of the catch" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize, header_len: usize) !void { _ = try a.alloc(u8, count * 4 + header_len); }";
    const start = std.mem.find(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    try std.testing.expectEqualStrings(
        "(@import(\"std\").math.mul(usize, count, 4) catch @panic(\"allocation size overflow\"))",
        onlyTitled(actions, "Check allocation size overflow").?.edits[0].replacement,
    );
}

test "field-access operands get no size check rewrite" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run(a: anytype, hdr: anytype) !void { _ = try a.alloc(u8, hdr.count * 4); }";
    const start = std.mem.find(u8, source, "count * 4") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = start, .end = start + 9 }, &.{});
    try std.testing.expect(onlyTitled(actions, "Check allocation size overflow") == null);
}

test "defer blocks and extra success returns keep their defer" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block_source: [:0]const u8 =
        "fn both(a: anytype) ![]u8 { const one = try a.dupe(u8, \"x\"); const two = try a.dupe(u8, \"y\"); " ++
        "defer { a.free(one); a.free(two); } return one; }";
    const block_defer = std.mem.find(u8, block_source, "defer") orelse unreachable;
    const block = try registry.actions(arena.allocator(), block_source, .{ .start = block_defer, .end = block_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), block.len);

    const branch_source: [:0]const u8 =
        "fn pick(a: anytype, flag: bool) ![]u8 { const value = try a.dupe(u8, \"x\"); defer a.free(value); " ++
        "if (flag) return try a.dupe(u8, \"y\"); return value; }";
    const branch_defer = std.mem.find(u8, branch_source, "defer") orelse unreachable;
    const branch = try registry.actions(arena.allocator(), branch_source, .{ .start = branch_defer, .end = branch_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), branch.len);

    const error_source: [:0]const u8 =
        "fn load(a: anytype, flag: bool) ![]u8 { const value = try a.dupe(u8, \"x\"); defer a.free(value); " ++
        "if (flag) return error.Missing; return value; }";
    const error_defer = std.mem.find(u8, error_source, "defer") orelse unreachable;
    const propagated = try registry.actions(arena.allocator(), error_source, .{ .start = error_defer, .end = error_defer + 5 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), propagated.len);
    try std.testing.expectEqualStrings("errdefer", propagated[0].edits[0].replacement);
}

test "owned slice returns ignore same-named lists in other functions" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn first(a: anytype) ![]u8 { var values = std.ArrayList(u8).empty; defer values.deinit(a); return values.items; } " ++
        "fn second() ![]u8 { return values.items; }";
    const items = std.mem.findLast(u8, source, "values.items") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = items, .end = items + 12 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "deinit methods offer poisoning self as their final statement" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Buffer = struct {\n" ++
        "    bytes: []u8,\n" ++
        "    fn deinit(self: *Buffer, a: anytype) void {\n" ++
        "        a.free(self.bytes);\n" ++
        "    }\n" ++
        "};";
    const name = std.mem.find(u8, source, "deinit") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = name, .end = name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Poison after deinit", actions[0].title);
    try std.testing.expectEqualStrings("        self.* = undefined;\n", actions[0].edits[0].replacement);
}

test "deinit stubs that discard self get no poison action" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Tight = struct { fn deinit(self: *Tight) void { _ = self; } };";
    const name = std.mem.find(u8, source, "deinit") orelse unreachable;
    const actions = try registry.actions(arena.allocator(), source, .{ .start = name, .end = name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "const-self and already-poisoned deinit methods get no poison action" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const const_source: [:0]const u8 =
        "const Buffer = struct { fn deinit(self: *const Buffer) void { _ = self; } };";
    const const_name = std.mem.find(u8, const_source, "deinit") orelse unreachable;
    const const_actions = try registry.actions(arena.allocator(), const_source, .{ .start = const_name, .end = const_name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), const_actions.len);

    const poisoned_source: [:0]const u8 =
        "const Buffer = struct { bytes: []u8, fn deinit(self: *Buffer, a: anytype) void { a.free(self.bytes); self.* = undefined; } };";
    const poisoned_name = std.mem.find(u8, poisoned_source, "deinit") orelse unreachable;
    const poisoned_actions = try registry.actions(arena.allocator(), poisoned_source, .{ .start = poisoned_name, .end = poisoned_name + 6 }, &.{});
    try std.testing.expectEqual(@as(usize, 0), poisoned_actions.len);
}

/// The one action titled `title`, or null when none is.
fn onlyTitled(actions: []const action_context.Candidate, title: []const u8) ?action_context.Candidate {
    var found: ?action_context.Candidate = null;
    for (actions) |action| if (std.mem.eql(u8, action.title, title)) {
        std.debug.assert(found == null);
        found = action;
    };
    return found;
}

/// The deinit actions offered with the cursor at `anchor`.
fn actionsAt(allocator: std.mem.Allocator, source: [:0]const u8, anchor: []const u8) ![]const action_context.Candidate {
    const registry = @import("registry.zig");
    const start = std.mem.find(u8, source, anchor).?;
    var deinit_actions: std.ArrayList(action_context.Candidate) = .empty;
    errdefer deinit_actions.deinit(allocator);
    for (try registry.actions(allocator, source, .{ .start = start, .end = start }, &.{})) |action| {
        if (std.mem.eql(u8, action.title, "Generate deinit") or std.mem.startsWith(u8, action.title, "Release ")) {
            try deinit_actions.append(allocator, action);
        }
    }
    return deinit_actions.toOwnedSlice(allocator);
}

fn applied(allocator: std.mem.Allocator, source: [:0]const u8, edits: []const analysis.Edit) ![]const u8 {
    return @import("../syntax/text_edits.zig").apply(allocator, source, edits);
}

test "structs owning containers and allocated slices get a generated deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\const Index = struct {
        \\    names: std.ArrayList([]const u8),
        \\    lookup: std.StringHashMapUnmanaged(u32),
        \\    seen: std.AutoHashMap(u32, void),
        \\    label: []u8,
        \\    borrowed: []const u8,
        \\    count: usize,
        \\
        \\    pub fn init(gpa: std.mem.Allocator, label: []const u8) !Index {
        \\        return .{
        \\            .names = .empty,
        \\            .lookup = .empty,
        \\            .seen = .init(gpa),
        \\            .label = try gpa.dupe(u8, label),
        \\            .borrowed = label,
        \\            .count = 0,
        \\        };
        \\    }
        \\};
    ;
    const actions = try actionsAt(arena.allocator(), source, "Index = struct");
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Generate deinit", actions[0].title);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const Index = struct {
        \\    names: std.ArrayList([]const u8),
        \\    lookup: std.StringHashMapUnmanaged(u32),
        \\    seen: std.AutoHashMap(u32, void),
        \\    label: []u8,
        \\    borrowed: []const u8,
        \\    count: usize,
        \\
        \\    pub fn init(gpa: std.mem.Allocator, label: []const u8) !Index {
        \\        return .{
        \\            .names = .empty,
        \\            .lookup = .empty,
        \\            .seen = .init(gpa),
        \\            .label = try gpa.dupe(u8, label),
        \\            .borrowed = label,
        \\            .count = 0,
        \\        };
        \\    }
        \\
        \\    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        \\        self.names.deinit(allocator);
        \\        self.lookup.deinit(allocator);
        \\        self.seen.deinit();
        \\        allocator.free(self.label);
        \\        self.* = undefined;
        \\    }
        \\};
    , try applied(arena.allocator(), source, actions[0].edits));
}

test "a stored allocator releases through the field and the deinit takes none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const Allocator = @import("std").mem.Allocator;
        \\
        \\const Node = struct { value: u8 };
        \\
        \\const Tree = struct {
        \\    allocator: Allocator,
        \\    root: *Node,
        \\    nodes: @import("std").ArrayList(Node)
        \\};
        \\
        \\fn plant(allocator: Allocator) !Tree {
        \\    const root = try allocator.create(Node);
        \\    return Tree{ .allocator = allocator, .root = root, .nodes = .empty };
        \\}
    ;
    const actions = try actionsAt(arena.allocator(), source, "Tree = struct");
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings(
        \\const Allocator = @import("std").mem.Allocator;
        \\
        \\const Node = struct { value: u8 };
        \\
        \\const Tree = struct {
        \\    allocator: Allocator,
        \\    root: *Node,
        \\    nodes: @import("std").ArrayList(Node),
        \\
        \\    pub fn deinit(self: *Tree) void {
        \\        self.allocator.destroy(self.root);
        \\        self.nodes.deinit(self.allocator);
        \\        self.* = undefined;
        \\    }
        \\};
        \\
        \\fn plant(allocator: Allocator) !Tree {
        \\    const root = try allocator.create(Node);
        \\    return Tree{ .allocator = allocator, .root = root, .nodes = .empty };
        \\}
    , try applied(arena.allocator(), source, actions[0].edits));
}

test "an existing deinit gets the releases it omits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\const Record = struct {
        \\    title: []u8,
        \\    payload: []u8,
        \\    allocator: std.mem.Allocator,
        \\
        \\    fn deinit(self: Record) void {
        \\        self.allocator.free(self.title);
        \\    }
        \\};
        \\
        \\fn makeRecord(allocator: std.mem.Allocator) !Record {
        \\    const title = try allocator.dupe(u8, "title");
        \\    const payload = try allocator.dupe(u8, "payload");
        \\    return .{ .title = title, .payload = payload, .allocator = allocator };
        \\}
    ;
    for ([_][]const u8{ "Record = struct", "deinit(self" }) |anchor| {
        const actions = try actionsAt(arena.allocator(), source, anchor);
        try std.testing.expectEqual(@as(usize, 1), actions.len);
        try std.testing.expectEqualStrings("Release 'payload' in deinit", actions[0].title);
        try std.testing.expectEqualStrings("        self.allocator.free(self.payload);\n", actions[0].edits[0].replacement);
        const fixed = try applied(arena.allocator(), source, actions[0].edits);
        try std.testing.expect(std.mem.find(u8, fixed, "free(self.title);\n        self.allocator.free(self.payload);\n    }") != null);
    }
}

test "existing deinit releases go before the final poison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\const Cache = struct {
        \\    keys: std.ArrayList(u32),
        \\    values: std.ArrayList(u32),
        \\
        \\    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        \\        cache.keys.deinit(gpa);
        \\        cache.* = undefined;
        \\    }
        \\};
    ;
    const actions = try actionsAt(arena.allocator(), source, "deinit(cache");
    const poison_line = std.mem.find(u8, source, "        cache.* = undefined;").?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("Release 'values' in deinit", actions[0].title);
    try std.testing.expectEqual(poison_line, actions[0].edits[0].span.start);
    try std.testing.expectEqualStrings("        cache.values.deinit(gpa);\n", actions[0].edits[0].replacement);
}

test "deinit generation declines what it cannot prove or release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][:0]const u8{
        // Slices with no stored allocation may borrow.
        "const View = struct {\n    bytes: []const u8,\n    rest: []const u8,\n};",
        // An optional owned container needs an unwrap.
        "const std = @import(\"std\");\nconst Maybe = struct {\n    list: ?std.ArrayList(u8),\n};",
        // A deinit that delegates may release anything.
        "const std = @import(\"std\");\nconst Pool = struct {\n    items: std.ArrayList(u8),\n    other: std.ArrayList(u8),\n" ++
            "    fn deinit(self: *Pool, gpa: std.mem.Allocator) void {\n        self.items.deinit(gpa);\n        self.clear();\n    }\n" ++
            "    fn clear(self: *Pool) void {\n        _ = self;\n    }\n};",
        // A value receiver cannot deinit a container field.
        "const std = @import(\"std\");\nconst Pair = struct {\n    left: std.ArrayList(u8),\n    right: std.ArrayList(u8),\n" ++
            "    fn deinit(self: Pair, gpa: std.mem.Allocator) void {\n        var left = self.left;\n        left.deinit(gpa);\n    }\n};",
        // Everything is already released.
        "const std = @import(\"std\");\nconst Done = struct {\n    items: std.ArrayList(u8),\n" ++
            "    fn deinit(self: *Done, gpa: std.mem.Allocator) void {\n        self.items.deinit(gpa);\n    }\n};",
        // A single-line struct has no line to put the method on.
        "const std = @import(\"std\");\nconst Tight = struct { items: std.ArrayList(u8) };",
    }) |source| {
        const anchor = std.mem.find(u8, source, " = struct").?;
        const actions = try actionsAt(allocator, source, source[anchor - 1 .. anchor]);
        errdefer std.debug.print("offered for: {s}\n", .{source});
        try std.testing.expectEqual(@as(usize, 0), actions.len);
    }
}

test "arena-owning structs release only the arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\const Parsed = struct {
        \\    arena: std.heap.ArenaAllocator,
        \\    names: std.ArrayList([]const u8),
        \\};
    ;
    const actions = try actionsAt(arena.allocator(), source, "Parsed = struct");
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expect(std.mem.find(u8, actions[0].edits[0].replacement, "pub fn deinit(self: *Parsed) void {\n        self.arena.deinit();\n        self.* = undefined;\n    }") != null);
}
