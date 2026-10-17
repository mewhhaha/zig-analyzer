//! Container-aware rules: member, switch-prong and struct-field proofs that share the container facts collected from the file and the compiler-resolved shapes. New unrelated rules do not belong here.
const std = @import("std");

const syntax_scope = @import("../../syntax/scope.zig");
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const identifierName = @import("../../syntax/tokens.zig").identifierName;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const lineIndentation = @import("../../syntax/tokens.zig").lineIndentation;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Fix = types.Fix;
const Edit = types.Edit;

pub const rules = [_]types.Rule{
    .unresolved_member,
    .missing_switch_prong,
    .missing_struct_field,
    .non_exhaustive_switch_else,
    .unknown_comptime_member,
    .non_exhaustive_error_switch,
};

pub fn run(context: RuleRun) !void {
    const allocator = context.allocator;
    var collected: std.ArrayList(Container) = .empty;
    defer {
        for (collected.items) |c| allocator.free(c.fields);
        collected.deinit(allocator);
    }
    const initial_containers = try collectContainers(context);
    defer allocator.free(initial_containers);
    try collected.appendSlice(allocator, initial_containers);
    if (context.resolved_shapes.len != 0) {
        // The names declared so far, the file's and the shapes' added before.
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        defer declared.deinit(allocator);
        for (collected.items) |container| try declared.put(allocator, identifierName(container.name), {});
        for (context.resolved_shapes) |shape| {
            if ((try declared.getOrPut(allocator, identifierName(shape.type_name))).found_existing) continue;
            const fields = try allocator.alloc(Field, shape.fields.len);
            for (shape.fields, fields) |name, *field| field.* = .{
                .name = name,
                .required = shape.kind != .structure,
            };
            try collected.append(allocator, .{
                .name = shape.type_name,
                .kind = switch (shape.kind) {
                    .enumeration => .enumeration,
                    .tagged_union => .tagged_union,
                    .structure => .structure,
                },
                .fields = fields,
                .scope = .{ .opening = null },
                .body = null,
                .resolved = true,
                .has_usingnamespace = false,
            });
        }
    }
    var containers: Containers = try .init(allocator, collected.items);
    defer containers.deinit(allocator);
    var declarations: Declarations = .{};
    defer declarations.deinit(allocator);
    try findUnresolvedMembers(context, &containers, &declarations);
    try findUnresolvedModuleMembers(context);
    try findRemovedTypeInfoMembers(context);
    try findComptimeReflectionIssues(context, &containers, &declarations);
    try findSwitches(context, &containers);
    try findStructInitializers(context, &containers);
}

const ContainerKind = enum { enumeration, tagged_union, structure, error_set };

pub const Field = struct {
    name: []const u8,
    required: bool,
};

/// The fields the `struct` body between `opening` and `closing` declares, in
/// order. Tuple fields are named `@"0"`, `@"1"`, and so on.
pub fn structFields(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    opening: usize,
    closing: usize,
) ![]Field {
    return collectContainerFields(allocator, source, tokens, opening, closing, .structure);
}

const Container = struct {
    name: []const u8,
    kind: ContainerKind,
    fields: []const Field,
    /// The block the declaration is visible in.
    scope: TokenScope,
    /// The opening brace of the container's own body, where its nested
    /// containers are declared; null for compiler-resolved shapes.
    body: ?usize,
    resolved: bool,
    has_usingnamespace: bool,
};

/// The block from the `{` at `opening` to its matching `}`, or to the end of
/// the file when it has none; null for the file itself.
const TokenScope = struct {
    opening: ?usize,
};

/// The file's containers, with each name's containers ordered by the block
/// that declares them, so a lookup visits only the containers of its name.
const Containers = struct {
    items: []const Container,
    /// `identifierName` of each name to its containers' positions in `items`,
    /// sorted by `scopeDepth` and then by position.
    by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,

    fn init(allocator: std.mem.Allocator, items: []const Container) !Containers {
        var containers: Containers = .{ .items = items };
        errdefer containers.deinit(allocator);
        for (items, 0..) |container, position| {
            const entry = try containers.by_name.getOrPut(allocator, identifierName(container.name));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, @intCast(position));
        }
        var lists = containers.by_name.valueIterator();
        while (lists.next()) |positions| std.mem.sort(u32, positions.items, items, struct {
            fn lessThan(all: []const Container, left: u32, right: u32) bool {
                const left_depth = scopeDepth(all[left].scope);
                const right_depth = scopeDepth(all[right].scope);
                return left_depth < right_depth or left_depth == right_depth and left < right;
            }
        }.lessThan);
        return containers;
    }

    fn deinit(containers: *Containers, allocator: std.mem.Allocator) void {
        var lists = containers.by_name.valueIterator();
        while (lists.next()) |positions| positions.deinit(allocator);
        containers.by_name.deinit(allocator);
    }

    /// The containers named `name`, ordered as `by_name` keeps them.
    fn named(containers: *const Containers, name: []const u8) []const u32 {
        return (containers.by_name.getPtr(identifierName(name)) orelse return &.{}).items;
    }

    /// The first of `positions` (a `named` list) whose scope depth is not
    /// below `depth`, or `positions.len`.
    fn firstAtDepth(containers: *const Containers, positions: []const u32, depth: usize) usize {
        var low: usize = 0;
        var high = positions.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (scopeDepth(containers.items[positions[middle]].scope) < depth) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// The first container named `name`, in `items` order, declared directly
    /// in the block whose `{` is at `opening`.
    fn declaredIn(containers: *const Containers, name: []const u8, opening: usize) ?Container {
        const positions = containers.named(name);
        const first = containers.firstAtDepth(positions, opening + 1);
        if (first == positions.len) return null;
        const container = containers.items[positions[first]];
        return if (container.scope.opening == opening) container else null;
    }

    /// The container named `name` whose scope most deeply contains the
    /// identifier at `use_index`, the first in `items` order on a tie. A
    /// scope runs from the `{` of the block holding the declaration to its
    /// matching `}` (or the end of the file), and the blocks that contain an
    /// identifier this way are exactly its chain of enclosing braces,
    /// innermost first; past them only the file-level containers (depth 0)
    /// remain, which contain every token.
    fn innermost(containers: *const Containers, scope_index: *const syntax_scope.Index, name: []const u8, use_index: usize) ?Container {
        const positions = containers.named(name);
        if (positions.len == 0) return null;
        var brace = scope_index.enclosingOpeningBrace(use_index);
        while (brace) |opening| : (brace = scope_index.enclosingOpeningBrace(opening)) {
            const first = containers.firstAtDepth(positions, opening + 1);
            if (first < positions.len and containers.items[positions[first]].scope.opening == opening) return containers.items[positions[first]];
            // No container of the name is declared in an enclosing block further out.
            if (first == 0 or containers.items[positions[first - 1]].scope.opening == null) break;
        }
        const outermost = containers.items[positions[0]];
        return if (outermost.scope.opening == null) outermost else null;
    }
};

fn findUnresolvedMembers(
    context: RuleRun,
    containers: *const Containers,
    declarations: *Declarations,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unresolved_member);
    if (level == .off) return;
    var guards: ReflectionGuards = .{};
    defer guards.deinit(context.allocator);
    for (tokens, 0..) |member_token, member_index| {
        if (member_token.tag != .identifier or member_index < 2 or tokens[member_index - 1].tag != .period or
            tokens[member_index - 2].tag != .identifier) continue;
        if (member_index >= 3 and tokens[member_index - 3].tag == .period) continue;
        const receiver_name = tokenText(source, tokens[member_index - 2]);
        const container = containerForReceiver(context, containers, receiver_name, member_index - 2) orelse continue;
        if (container.has_usingnamespace or container.resolved) continue;
        const member_name = tokenText(source, member_token);
        if (containerHasField(container, member_name) or
            try declarations.has(context, container.name, member_name, false) or
            try guards.tests(context, receiver_name, member_name) or
            try guards.tests(context, container.name, member_name)) continue;
        try context.emit(.{
            .rule = .unresolved_member,
            .level = level,
            .span = member_token.loc,
            .message = try context.allocator.print(
                "type '{s}' has no member named '{s}'",
                .{ container.name, member_name },
            ),
        });
    }
}

/// `module.name` where the caller resolved `module` to a file or container
/// whose complete member list is `context.module_members`.
pub fn findUnresolvedModuleMembers(context: RuleRun) !void {
    const level = context.level(.unresolved_member);
    if (level == .off or context.module_members.len == 0) return;
    const tokens = context.tokens;
    var guards: ReflectionGuards = .{};
    defer guards.deinit(context.allocator);
    for (tokens, 0..) |member_token, member_index| {
        if (member_token.tag != .identifier or member_index < 2 or
            tokens[member_index - 1].tag != .period or tokens[member_index - 2].tag != .identifier) continue;
        if (member_index >= 3 and tokens[member_index - 3].tag == .period) continue;
        const receiver = tokenText(context.source, tokens[member_index - 2]);
        const module = for (context.module_members) |candidate| {
            if (std.mem.eql(u8, candidate.receiver, receiver)) break candidate;
        } else continue;
        const member_name = tokenText(context.source, member_token);
        const exists = for (module.members) |name| {
            if (std.mem.eql(u8, name, member_name)) break true;
        } else false;
        if (exists or try guards.tests(context, receiver, member_name)) continue;
        try context.emit(.{
            .rule = .unresolved_member,
            .level = level,
            .span = member_token.loc,
            .message = try context.allocator.print(
                "module '{s}' has no public member named '{s}'",
                .{ receiver, member_name },
            ),
        });
    }
}

/// A payload of `std.lang.Type`: the union tag that selects it and every member
/// it has in the Zig release the analyzer is built for, fields and declarations.
const TypeInfoShape = struct {
    tag: []const u8,
    type_name: []const u8,
    members: []const []const u8,
};

// Verified against `std.lang.Type` in the Zig 0.17.0 standard library.
const type_info_shapes = [_]TypeInfoShape{
    .{ .tag = "int", .type_name = "Int", .members = &.{ "signedness", "bits" } },
    .{ .tag = "float", .type_name = "Float", .members = &.{"bits"} },
    .{ .tag = "pointer", .type_name = "Pointer", .members = &.{ "size", "attrs", "child", "sentinel_ptr", "sentinel", "Size", "Attributes" } },
    .{ .tag = "array", .type_name = "Array", .members = &.{ "len", "child", "sentinel_ptr", "sentinel" } },
    .{ .tag = "struct", .type_name = "Struct", .members = &.{ "is_tuple", "layout", "backing_integer", "field_names", "field_types", "field_attrs", "decl_names", "FieldAttributes" } },
    .{ .tag = "optional", .type_name = "Optional", .members = &.{"child"} },
    .{ .tag = "error_union", .type_name = "ErrorUnion", .members = &.{ "error_set", "payload" } },
    .{ .tag = "enum", .type_name = "Enum", .members = &.{ "tag_type", "mode", "field_names", "field_values", "decl_names", "Mode" } },
    .{ .tag = "union", .type_name = "Union", .members = &.{ "layout", "tag_type", "backing_integer", "field_names", "field_types", "field_attrs", "decl_names", "FieldAttributes" } },
    .{ .tag = "fn", .type_name = "Fn", .members = &.{ "attrs", "is_generic", "return_type", "param_types", "param_attrs", "ParamAttributes", "Attributes" } },
    .{ .tag = "opaque", .type_name = "Opaque", .members = &.{"decl_names"} },
    .{ .tag = "vector", .type_name = "Vector", .members = &.{ "len", "child" } },
};

/// What replaced a member that older releases' `std.builtin.Type` payloads had.
fn removedTypeInfoAdvice(type_name: []const u8, member: []const u8) ?[]const u8 {
    const Replacement = struct { type_name: []const u8, member: []const u8, advice: []const u8 };
    const replacements = [_]Replacement{
        .{ .type_name = "Struct", .member = "fields", .advice = "iterate field_names, field_types and field_attrs together" },
        .{ .type_name = "Union", .member = "fields", .advice = "iterate field_names, field_types and field_attrs together" },
        .{ .type_name = "Enum", .member = "fields", .advice = "iterate field_names and field_values together" },
        .{ .type_name = "Enum", .member = "is_exhaustive", .advice = "compare mode with .exhaustive" },
        .{ .type_name = "Fn", .member = "params", .advice = "use param_types and param_attrs" },
        .{ .type_name = "Fn", .member = "calling_convention", .advice = "use attrs.@\"callconv\"" },
        .{ .type_name = "Fn", .member = "is_var_args", .advice = "use attrs.varargs" },
        .{ .type_name = "Pointer", .member = "is_const", .advice = "use attrs.@\"const\"" },
        .{ .type_name = "Pointer", .member = "is_volatile", .advice = "use attrs.@\"volatile\"" },
        .{ .type_name = "Pointer", .member = "is_allowzero", .advice = "use attrs.@\"allowzero\"" },
        .{ .type_name = "Pointer", .member = "alignment", .advice = "use attrs.@\"align\"" },
        .{ .type_name = "Pointer", .member = "address_space", .advice = "use attrs.@\"addrspace\"" },
    };
    for (replacements) |entry| {
        if (std.mem.eql(u8, entry.type_name, type_name) and std.mem.eql(u8, entry.member, member)) return entry.advice;
    }
    if (std.mem.eql(u8, member, "decls")) return "use decl_names";
    return null;
}

/// `@typeInfo(T).@"struct".fields` and the other members `std.lang.Type`
/// payloads no longer have, read directly or through an untyped constant
/// holding `@typeInfo(T)` or one of its payloads. The payload shapes are fixed
/// by the Zig release, so these are compile errors. A file that tests for the
/// member's name with `@hasField`/`@hasDecl` or reads `zig_version` may keep
/// the old spelling in a branch comptime never analyzes, and is left alone.
fn findRemovedTypeInfoMembers(context: RuleRun) !void {
    const level = context.level(.unresolved_member);
    if (level == .off) return;
    const tokens = context.tokens;
    var aliases: std.ArrayList(TypeInfoAlias) = .empty;
    defer aliases.deinit(context.allocator);
    var guards: TypeInfoGuards = .{};
    defer guards.deinit(context.allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(context.source, token, "@typeInfo") or
            index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        const closing = context.scopes.matchingToken(index + 1) orelse continue;
        try checkTypeInfoMember(context, level, closing + 1, null, &guards);
        if (index >= 3 and tokens[index - 1].tag == .equal and tokens[index - 2].tag == .identifier and
            tokens[index - 3].tag == .keyword_const)
        {
            const end = context.scopes.statementEnd(index) orelse continue;
            if (end == closing + 1) {
                try aliases.append(context.allocator, .{ .name = index - 2, .shape = null });
            } else if (end == closing + 3 and tokens[closing + 1].tag == .period) {
                const shape = typeInfoShape(context, closing + 2) orelse continue;
                try aliases.append(context.allocator, .{ .name = index - 2, .shape = shape });
            }
        }
    }
    if (aliases.items.len == 0) return;
    // Each spelling's aliases in declaration order.
    var aliases_by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    defer {
        var lists = aliases_by_name.valueIterator();
        while (lists.next()) |positions| positions.deinit(context.allocator);
        aliases_by_name.deinit(context.allocator);
    }
    for (aliases.items, 0..) |alias, position| {
        const entry = try aliases_by_name.getOrPut(context.allocator, tokenText(context.source, tokens[alias.name]));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(context.allocator, @intCast(position));
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 1 >= tokens.len or tokens[index + 1].tag != .period or
            (index > 0 and tokens[index - 1].tag == .period)) continue;
        const positions = aliases_by_name.get(tokenText(context.source, token)) orelse continue;
        // Only the first alias spelled like the use, other than the use itself, is tried.
        const alias = for (positions.items) |position| {
            if (aliases.items[position].name != index) break aliases.items[position];
        } else continue;
        const binding = context.scopes.findBinding(index) orelse continue;
        if (binding.token_index != alias.name) continue;
        try checkTypeInfoMember(context, level, index + 1, alias.shape, &guards);
    }
}

const TypeInfoAlias = struct {
    /// The constant's name token.
    name: usize,
    /// The payload it holds, or null for the whole `@typeInfo` union.
    shape: ?*const TypeInfoShape,
};

fn typeInfoShape(context: RuleRun, tag_index: usize) ?*const TypeInfoShape {
    if (tag_index >= context.tokens.len or context.tokens[tag_index].tag != .identifier) return null;
    const tag = identifierName(tokenText(context.source, context.tokens[tag_index]));
    for (&type_info_shapes) |*shape| if (std.mem.eql(u8, shape.tag, tag)) return shape;
    return null;
}

/// Checks `.tag.member` (or `.member` when the payload is already `known`)
/// starting at the period `period`.
fn checkTypeInfoMember(context: RuleRun, level: types.Level, period: usize, known: ?*const TypeInfoShape, guards: *TypeInfoGuards) !void {
    const tokens = context.tokens;
    var cursor = period;
    const shape = known orelse shape: {
        if (cursor + 1 >= tokens.len or tokens[cursor].tag != .period) return;
        const shape = typeInfoShape(context, cursor + 1) orelse return;
        cursor += 2;
        break :shape shape;
    };
    if (cursor + 1 >= tokens.len or tokens[cursor].tag != .period or tokens[cursor + 1].tag != .identifier) return;
    const member_index = cursor + 1;
    const member = identifierName(tokenText(context.source, tokens[member_index]));
    for (shape.members) |name| if (std.mem.eql(u8, name, member)) return;
    if (try guards.covers(context, member)) return;
    const message = if (removedTypeInfoAdvice(shape.type_name, member)) |advice|
        try context.allocator.print("type 'std.lang.Type.{s}' has no member named '{s}' in Zig 0.17; {s}", .{ shape.type_name, member, advice })
    else
        try context.allocator.print("type 'std.lang.Type.{s}' has no member named '{s}'", .{ shape.type_name, member });
    try context.emit(.{
        .rule = .unresolved_member,
        .level = level,
        .span = tokens[member_index].loc,
        .message = message,
    });
}

/// What lets a file select between Zig releases at comptime: reading
/// `zig_version`, or `@hasField`/`@hasDecl` tests of a member name.
const TypeInfoGuards = struct {
    built: bool = false,
    zig_version: bool = false,
    tested: std.ArrayList([]const u8) = .empty,

    fn deinit(guards: *TypeInfoGuards, allocator: std.mem.Allocator) void {
        guards.tested.deinit(allocator);
    }

    fn covers(guards: *TypeInfoGuards, context: RuleRun, member: []const u8) !bool {
        if (!guards.built) {
            guards.built = true;
            const tokens = context.tokens;
            for (tokens, 0..) |token, index| switch (token.tag) {
                .identifier => if (tokenIs(context.source, token, "zig_version")) {
                    guards.zig_version = true;
                },
                .builtin => {
                    if ((!tokenIs(context.source, token, "@hasField") and !tokenIs(context.source, token, "@hasDecl")) or
                        index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
                    const closing = context.scopes.matchingToken(index + 1) orelse continue;
                    if (closing == 0 or tokens[closing - 1].tag != .string_literal) continue;
                    const literal = tokenText(context.source, tokens[closing - 1]);
                    if (literal.len >= 2) try guards.tested.append(context.allocator, literal[1 .. literal.len - 1]);
                },
                else => {},
            };
        }
        if (guards.zig_version) return true;
        for (guards.tested.items) |name| if (std.mem.eql(u8, name, member)) return true;
        return false;
    }
};

fn containerForReceiver(
    context: RuleRun,
    containers: *const Containers,
    receiver_name: []const u8,
    receiver_index: usize,
) ?Container {
    if (containerNamed(containers, context.scopes, receiver_name, receiver_index)) |container| return container;
    return bindingContainer(context, containers, receiver_index);
}

/// The container the binding visible at `use_index` holds when its
/// declaration says so: `name: T`, `name = T{ ... };`, or `name = f(...);`
/// (with `catch`) for a function declared to return `T` or `E!T`.
fn bindingContainer(context: RuleRun, containers: *const Containers, use_index: usize) ?Container {
    const tokens = context.tokens;
    const binding = context.scopes.findBinding(use_index) orelse return null;
    const index = binding.token_index;
    if (index + 3 >= tokens.len) return null;
    switch (tokens[index + 1].tag) {
        .colon => {
            const last = typePathEnd(tokens, index + 2) orelse return null;
            return containerAtPath(context, containers, index + 2, last);
        },
        .equal => {
            const value = index + 2;
            if (typePathEnd(tokens, value)) |last| {
                if (tokens[last + 1].tag != .l_brace) return null;
                const closing = context.matchingToken(last + 1, .l_brace, .r_brace) orelse return null;
                if (tokens[closing + 1].tag != .semicolon) return null;
                return containerAtPath(context, containers, value, last);
            }
            if (tokens[value].tag != .identifier or tokens[value + 1].tag != .l_paren) return null;
            const arguments_end = context.matchingToken(value + 1, .l_paren, .r_paren) orelse return null;
            switch (tokens[arguments_end + 1].tag) {
                .semicolon, .keyword_catch => return callResultContainer(context, containers, value),
                else => return null,
            }
        },
        else => return null,
    }
}

/// The container returned by the function a bare call at `callee_index`
/// names.
fn callResultContainer(context: RuleRun, containers: *const Containers, callee_index: usize) ?Container {
    const binding = context.scopes.findBinding(callee_index) orelse return null;
    const name_index = binding.token_index;
    if (name_index == 0 or context.tokens[name_index - 1].tag != .keyword_fn) return null;
    return returnContainer(context, containers, name_index);
}

/// The container the function named at `name_index` is declared to return,
/// or the payload of its error union, resolved where the function is
/// declared.
fn returnContainer(context: RuleRun, containers: *const Containers, name_index: usize) ?Container {
    const tokens = context.tokens;
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return null;
    const parameters_end = context.matchingToken(name_index + 1, .l_paren, .r_paren) orelse return null;
    var start = parameters_end + 1;
    if (start < tokens.len and tokens[start].tag == .bang) start += 1;
    var last = typePathEnd(tokens, start) orelse return null;
    if (tokens[last + 1].tag == .bang) {
        start = last + 2;
        last = typePathEnd(tokens, start) orelse return null;
    }
    return containerAtPath(context, containers, start, last);
}

/// The last identifier of the dotted type path (`T`, `Outer.Inner`) that
/// starts at `start`, or null when the path is called, as a type function's
/// result is (`std.ArrayList(u8)`).
fn typePathEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    if (start >= tokens.len or tokens[start].tag != .identifier) return null;
    var last = start;
    while (last + 2 < tokens.len and tokens[last + 1].tag == .period and tokens[last + 2].tag == .identifier) last += 2;
    if (last + 1 >= tokens.len or tokens[last + 1].tag == .l_paren) return null;
    return last;
}

/// The container the type path `first..last` names where it is written: its
/// first segment is resolved lexically, and every later one must be a
/// container declared directly in the one before. A path that leaves the
/// file's containers (`std.lang.Signedness`) names none.
fn containerAtPath(context: RuleRun, containers: *const Containers, first: usize, last: usize) ?Container {
    const source = context.source;
    const tokens = context.tokens;
    var container = containerNamed(containers, context.scopes, tokenText(source, tokens[first]), first) orelse return null;
    var segment = first + 2;
    while (segment <= last) : (segment += 2) {
        const body = container.body orelse return null;
        container = containers.declaredIn(tokenText(source, tokens[segment]), body) orelse return null;
    }
    return container;
}

fn tokensBeforeContain(
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
    expected: []const u8,
) bool {
    for (tokens[start..end]) |token| if (tokenIs(source, token, expected)) return true;
    return false;
}

fn collectContainers(context: RuleRun) ![]Container {
    const allocator = context.allocator;
    const source = context.source;
    const tokens = context.tokens;
    var containers: std.ArrayList(Container) = .empty;
    errdefer {
        for (containers.items) |container| allocator.free(container.fields);
        containers.deinit(allocator);
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .equal)
        {
            continue;
        }
        var kind: ContainerKind = undefined;
        var opening = index + 4;
        switch (tokens[index + 3].tag) {
            .keyword_enum => kind = .enumeration,
            .keyword_struct => kind = .structure,
            .keyword_error => kind = .error_set,
            .keyword_union => {
                if (index + 6 >= tokens.len or tokens[index + 4].tag != .l_paren or
                    tokens[index + 5].tag != .keyword_enum or tokens[index + 6].tag != .r_paren)
                {
                    continue;
                }
                kind = .tagged_union;
                opening = index + 7;
            },
            else => continue,
        }
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        // `error{A} || Other` has members this file does not list.
        if (closing + 1 >= tokens.len or tokens[closing + 1].tag != .semicolon) continue;
        const fields = try collectContainerFields(allocator, source, tokens, opening, closing, kind);
        errdefer allocator.free(fields);
        try containers.append(allocator, .{
            .name = tokenText(source, tokens[index + 1]),
            .kind = kind,
            .fields = fields,
            .scope = enclosingTokenScope(context, index),
            .body = opening,
            .resolved = false,
            .has_usingnamespace = tokensBeforeContain(source, tokens, opening + 1, closing, "usingnamespace"),
        });
    }
    return try containers.toOwnedSlice(allocator);
}

fn collectContainerFields(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    opening: usize,
    closing: usize,
    kind: ContainerKind,
) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    errdefer fields.deinit(allocator);
    var brace_depth: usize = 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var index = opening + 1;
    while (index < closing) : (index += 1) {
        switch (tokens[index].tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .identifier => {
                if (brace_depth != 1 or parenthesis_depth != 0 or bracket_depth != 0 or
                    index > opening + 1 and switch (tokens[index - 1].tag) {
                        .r_brace, .comma, .semicolon, .doc_comment, .container_doc_comment, .keyword_comptime => false,
                        else => true,
                    }) continue;
                if (kind == .structure and index + 1 < closing and tokens[index + 1].tag == .comma) {
                    try fields.append(allocator, .{
                        .name = try allocator.print("@\"{d}\"", .{fields.items.len}),
                        .required = true,
                    });
                    continue;
                }
                if (kind == .structure and (index + 1 >= closing or tokens[index + 1].tag != .colon)) continue;
                try fields.append(allocator, .{
                    .name = tokenText(source, tokens[index]),
                    .required = if (kind != .structure) true else fieldIsRequired(tokens, index + 1, closing),
                });
            },
            else => {},
        }
    }
    return try fields.toOwnedSlice(allocator);
}

fn fieldIsRequired(tokens: []const std.zig.Token, colon: usize, closing: usize) bool {
    var nested_depth: usize = 0;
    for (tokens[colon + 1 .. closing]) |token| {
        switch (token.tag) {
            .l_brace, .l_paren, .l_bracket => nested_depth += 1,
            .r_brace, .r_paren, .r_bracket => nested_depth -|= 1,
            .equal => if (nested_depth == 0) return false,
            .comma => if (nested_depth == 0) return true,
            else => {},
        }
    }
    return true;
}

fn findComptimeReflectionIssues(
    context: RuleRun,
    containers: *const Containers,
    declarations: *Declarations,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unknown_comptime_member);
    if (level == .off) return;
    for (tokens, 0..) |token, builtin_index| {
        if (token.tag != .builtin or
            (!tokenIs(source, token, "@field") and !tokenIs(source, token, "@hasField") and
                !tokenIs(source, token, "@hasDecl"))) continue;
        if (builtin_index + 5 >= tokens.len or tokens[builtin_index + 1].tag != .l_paren or
            tokens[builtin_index + 2].tag != .identifier or tokens[builtin_index + 3].tag != .comma or
            tokens[builtin_index + 4].tag != .string_literal or tokens[builtin_index + 5].tag != .r_paren) continue;
        const type_name = tokenText(source, tokens[builtin_index + 2]);
        const container = containerForReceiver(context, containers, type_name, builtin_index + 2) orelse continue;
        const literal = tokenText(source, tokens[builtin_index + 4]);
        if (literal.len < 2) continue;
        const member_name = literal[1 .. literal.len - 1];
        const field_lookup = tokenIs(source, token, "@field");
        const has_field = tokenIs(source, token, "@hasField") or field_lookup;
        // usingnamespace mixes in members this analysis cannot see.
        if (container.has_usingnamespace) continue;
        if (has_field and container.kind == .enumeration or !has_field and container.resolved) continue;
        const exists = if (has_field)
            containerHasField(container, member_name) or
                field_lookup and try declarations.has(context, container.name, member_name, false)
        else
            try declarations.has(context, container.name, member_name, true);
        if (exists) continue;
        const message = if (field_lookup)
            try context.allocator.print(
                "{s} cannot resolve member '{s}' on type '{s}' in this analyzed shape",
                .{ tokenText(source, token), member_name, container.name },
            )
        else if (!has_field)
            try context.allocator.print(
                "{s} is always false: type '{s}' has no public declaration named '{s}' in this analyzed shape",
                .{ tokenText(source, token), container.name, member_name },
            )
        else
            try context.allocator.print(
                "{s} is always false: type '{s}' has no member named '{s}' in this analyzed shape",
                .{ tokenText(source, token), container.name, member_name },
            );
        try context.emit(.{
            .rule = .unknown_comptime_member,
            .level = level,
            .span = tokens[builtin_index + 4].loc,
            .message = message,
        });
    }
}

fn containerHasField(container: Container, name: []const u8) bool {
    for (container.fields) |field| if (identifierNamesEqual(field.name, name)) return true;
    return false;
}

/// The names declared directly inside every `const Name = ... {` container of
/// the file, collected in one pass the first time a lookup needs them.
const Declarations = struct {
    names_by_container: std.StringHashMapUnmanaged(Names) = .empty,
    built: bool = false,

    const Names = struct {
        all: std.StringHashMapUnmanaged(void) = .empty,
        public: std.StringHashMapUnmanaged(void) = .empty,
    };

    fn deinit(declarations: *Declarations, allocator: std.mem.Allocator) void {
        var names = declarations.names_by_container.valueIterator();
        while (names.next()) |entry| {
            entry.all.deinit(allocator);
            entry.public.deinit(allocator);
        }
        declarations.names_by_container.deinit(allocator);
    }

    fn has(
        declarations: *Declarations,
        context: RuleRun,
        container_name: []const u8,
        declaration_name: []const u8,
        require_public: bool,
    ) !bool {
        if (!declarations.built) {
            try declarations.collect(context);
            declarations.built = true;
        }
        const names = declarations.names_by_container.get(identifierName(container_name)) orelse return false;
        return (if (require_public) names.public else names.all).contains(identifierName(declaration_name));
    }

    fn collect(declarations: *Declarations, context: RuleRun) !void {
        const source = context.source;
        const tokens = context.tokens;
        for (tokens, 0..) |token, index| {
            if (token.tag != .keyword_const or index + 4 >= tokens.len or tokens[index + 2].tag != .equal) continue;
            var opening = index + 4;
            if (tokens[index + 3].tag == .keyword_union and opening < tokens.len and tokens[opening].tag == .l_paren) {
                opening = (context.matchingToken(opening, .l_paren, .r_paren) orelse continue) + 1;
            }
            if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
            const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
            const entry = try declarations.names_by_container.getOrPut(context.allocator, identifierName(tokenText(source, tokens[index + 1])));
            if (!entry.found_existing) entry.value_ptr.* = .{};
            var depth: usize = 1;
            for (tokens[opening + 1 .. closing], opening + 1..) |member_token, member_index| {
                switch (member_token.tag) {
                    .l_brace => depth += 1,
                    .r_brace => depth -= 1,
                    .keyword_fn, .keyword_const, .keyword_var => if (depth == 1 and member_index + 1 < closing) {
                        const name = identifierName(tokenText(source, tokens[member_index + 1]));
                        try entry.value_ptr.all.put(context.allocator, name, {});
                        if (isPublicMember(tokens, opening + 1, member_index)) try entry.value_ptr.public.put(context.allocator, name, {});
                    },
                    else => {},
                }
            }
        }
    }
};

/// The `@hasDecl(T, "name")` and `@hasField(T, "name")` tests of the file,
/// collected the first time a lookup needs them. An access to a member the
/// file tests for may sit in a branch comptime never analyzes.
const ReflectionGuards = struct {
    tested: std.ArrayList(Tested) = .empty,
    built: bool = false,

    const Tested = struct {
        receiver: []const u8,
        member: []const u8,
    };

    fn deinit(guards: *ReflectionGuards, allocator: std.mem.Allocator) void {
        guards.tested.deinit(allocator);
    }

    fn tests(guards: *ReflectionGuards, context: RuleRun, receiver: []const u8, member: []const u8) !bool {
        if (!guards.built) {
            try guards.collect(context);
            guards.built = true;
        }
        for (guards.tested.items) |tested| {
            if (identifierNamesEqual(tested.receiver, receiver) and identifierNamesEqual(tested.member, member)) return true;
        }
        return false;
    }

    fn collect(guards: *ReflectionGuards, context: RuleRun) !void {
        const source = context.source;
        const tokens = context.tokens;
        for (tokens, 0..) |token, index| {
            if (token.tag != .builtin or index + 4 >= tokens.len or
                (!tokenIs(source, token, "@hasDecl") and !tokenIs(source, token, "@hasField")) or
                tokens[index + 1].tag != .l_paren or tokens[index + 2].tag != .identifier or
                tokens[index + 3].tag != .comma or tokens[index + 4].tag != .string_literal) continue;
            const literal = tokenText(source, tokens[index + 4]);
            if (literal.len < 2) continue;
            try guards.tested.append(context.allocator, .{
                .receiver = tokenText(source, tokens[index + 2]),
                .member = literal[1 .. literal.len - 1],
            });
        }
    }
};

/// Whether `pub` precedes the declaration keyword at `member_index`, possibly
/// after other modifiers.
fn isPublicMember(tokens: []const std.zig.Token, first: usize, member_index: usize) bool {
    var modifier_index = member_index;
    while (modifier_index > first) {
        modifier_index -= 1;
        switch (tokens[modifier_index].tag) {
            .keyword_pub => return true,
            .keyword_inline, .keyword_noinline, .keyword_extern, .keyword_export, .keyword_threadlocal => {},
            else => break,
        }
    }
    return false;
}

fn findSwitches(
    context: RuleRun,
    containers: *const Containers,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    if (context.level(.missing_switch_prong) == .off and
        context.level(.non_exhaustive_switch_else) == .off and
        context.level(.non_exhaustive_error_switch) == .off) return;
    for (tokens, 0..) |token, switch_index| {
        if (token.tag != .keyword_switch or switch_index + 4 >= tokens.len or tokens[switch_index + 1].tag != .l_paren) continue;
        const operand_end = context.matchingToken(switch_index + 1, .l_paren, .r_paren) orelse continue;
        if (tokens[switch_index + 2].tag != .identifier) continue;
        const opening = operand_end + 1;
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        const operand = switch_index + 2;
        const container = (if (operand_end == switch_index + 3)
            bindingContainer(context, containers, operand)
        else if (operand_end == switch_index + 5 and tokens[switch_index + 3].tag == .l_paren and
            tokens[switch_index + 4].tag == .r_paren)
            callResultContainer(context, containers, operand)
        else
            null) orelse continue;
        if (container.kind == .structure) continue;

        var cases = try switchCases(context, opening, closing, container.name) orelse continue;
        defer cases.deinit(context.allocator);
        const else_index = cases.else_index;
        var missing: std.ArrayList([]const u8) = .empty;
        defer missing.deinit(context.allocator);
        for (container.fields) |field| {
            // '_' marks a non-exhaustive enum, not a nameable case; '._ =>' does not compile.
            if (std.mem.eql(u8, field.name, "_")) continue;
            if (!cases.has(field.name)) try missing.append(context.allocator, field.name);
        }
        if (missing.items.len == 0) continue;
        // 'inline else' expands into every remaining case at comptime; the switch
        // is exhaustive by construction and the expansion is deliberate.
        if (else_index) |index| {
            if (index > opening and tokens[index - 1].tag == .keyword_inline) continue;
        }
        if (container.kind == .error_set) {
            const level = context.level(.non_exhaustive_error_switch);
            if (level == .off) continue;
            const fixes: []const Fix = if (else_index) |index| fixes: {
                if (!elseCaptureCanBePreserved(tokens, index, closing)) break :fixes &.{};
                const replacement = try errorCaseSelectorText(context.allocator, missing.items);
                const allocated = try Fix.single(context.allocator, .{
                    .title = "Expand else into remaining error cases",
                    .kind = .refactor_rewrite,
                    .span = tokens[index].loc,
                    .replacement = replacement,
                });
                break :fixes allocated;
            } else fixes: {
                const insertion = try errorSwitchProngText(context.allocator, source, tokens[closing].loc.start, missing.items);
                break :fixes try appendElementFixes(context.allocator, source, tokens, opening, closing, insertion, .{
                    .title = "Fill missing error switch prongs",
                });
            };
            try context.emit(.{
                .rule = .non_exhaustive_error_switch,
                .level = level,
                .span = if (else_index) |index| tokens[index].loc else token.loc,
                .message = try missingMessage(context.allocator, "switch does not name every error in", container.name, missing.items),
                .fixes = fixes,
            });
            continue;
        }
        if (else_index) |index| {
            const level = context.level(.non_exhaustive_switch_else);
            if (level == .off or missing.items.len > maximum_named_else_cases or
                elseIsDeliberate(context, switch_index, index)) continue;
            const fixes: []const Fix = if (elseCaptureCanBePreserved(tokens, index, closing)) fixes: {
                const replacement = try caseSelectorText(context.allocator, missing.items);
                const allocated = try Fix.single(context.allocator, .{
                    .title = "Expand else into remaining switch cases",
                    .kind = .refactor_rewrite,
                    .span = tokens[index].loc,
                    .replacement = replacement,
                });
                break :fixes allocated;
            } else &.{};
            try context.emit(.{
                .rule = .non_exhaustive_switch_else,
                .level = level,
                .span = tokens[index].loc,
                .message = try missingMessage(context.allocator, "switch uses else instead of explicit cases for type", container.name, missing.items),
                .fixes = fixes,
            });
            continue;
        }

        const level = context.level(.missing_switch_prong);
        if (level == .off) continue;
        const insertion = try switchProngText(context.allocator, source, tokens[closing].loc.start, missing.items);
        const fixes = try appendElementFixes(context.allocator, source, tokens, opening, closing, insertion, .{
            .title = "Fill missing switch prongs",
            .preferred = true,
        });
        try context.emit(.{
            .rule = .missing_switch_prong,
            .level = level,
            .span = token.loc,
            .message = try missingMessage(context.allocator, "switch is missing cases for type", container.name, missing.items),
            .fixes = fixes,
        });
    }
}

const maximum_named_else_cases = 8;

/// Whether the `else` prong at `else_index` of the switch at `switch_index`
/// is a deliberate catch-all: a `@compileError` for unsupported cases, or the
/// `true`/`false` answer of a predicate that returns the switch as its `bool`.
fn elseIsDeliberate(context: RuleRun, switch_index: usize, else_index: usize) bool {
    const tokens = context.tokens;
    if (else_index + 2 >= tokens.len or tokens[else_index + 1].tag != .equal_angle_bracket_right) return false;
    const value = else_index + 2;
    if (context.tokenIs(value, "@compileError")) return true;
    if (!context.tokenIs(value, "true") and !context.tokenIs(value, "false")) return false;
    if (tokens[value + 1].tag != .comma and tokens[value + 1].tag != .r_brace) return false;
    if (switch_index == 0 or tokens[switch_index - 1].tag != .keyword_return) return false;
    const body = context.functionBodyHolding(switch_index) orelse return false;
    return body > 0 and context.tokenIs(body - 1, "bool");
}

fn containerNamed(
    containers: *const Containers,
    scope_index: *const syntax_scope.Index,
    requested_name: []const u8,
    use_index: usize,
) ?Container {
    var name = requested_name;
    for (0..16) |_| {
        const selected = containers.innermost(scope_index, name, use_index);
        const visible_binding = scope_index.findBindingNamed(name, use_index);
        if (selected) |container| {
            if (visible_binding == null or scopeDepth(container.scope) >= visible_binding.?.scope_rank) return container;
        }
        const target = (visible_binding orelse return null).alias_target orelse return null;
        name = target;
    }
    return null;
}

fn enclosingTokenScope(context: RuleRun, index: usize) TokenScope {
    return .{ .opening = context.enclosingOpeningBrace(index) };
}

fn scopeDepth(scope: TokenScope) usize {
    return if (scope.opening) |opening| opening + 1 else 0;
}

/// The cases a switch body names by tag, and its `else` prong.
const SwitchCases = struct {
    named: std.ArrayList([]const u8) = .empty,
    else_index: ?usize = null,

    fn deinit(cases: *SwitchCases, allocator: std.mem.Allocator) void {
        cases.named.deinit(allocator);
    }

    fn has(cases: SwitchCases, name: []const u8) bool {
        for (cases.named.items) |case| if (identifierNamesEqual(case, name)) return true;
        return false;
    }
};

/// The prong items of the switch body between `opening` and `closing`, which
/// switches on `type_name`. Items may be tags (`.name`, `error.Name`, or
/// `T.name` with `T` the switched type), `else` and `_`; for any other item,
/// such as a comptime constant or a range, only evaluating it tells which
/// cases it covers, so there is no answer.
fn switchCases(context: RuleRun, opening: usize, closing: usize, type_name: []const u8) !?SwitchCases {
    const source = context.source;
    const tokens = context.tokens;
    var cases: SwitchCases = .{};
    errdefer cases.deinit(context.allocator);
    var cursor = opening + 1;
    while (cursor < closing) {
        // The prong's items, up to its `=>`.
        while (true) {
            if (tokens[cursor].tag == .keyword_inline) cursor += 1;
            switch (tokens[cursor].tag) {
                .keyword_else => cases.else_index = cursor,
                .period => {
                    cursor += 1;
                    if (tokens[cursor].tag != .identifier) return null;
                    try cases.named.append(context.allocator, tokenText(source, tokens[cursor]));
                },
                .identifier, .keyword_error => if (!tokenIs(source, tokens[cursor], "_")) {
                    if (tokens[cursor].tag == .identifier and
                        !identifierNamesEqual(tokenText(source, tokens[cursor]), type_name)) return null;
                    if (tokens[cursor + 1].tag != .period or tokens[cursor + 2].tag != .identifier) return null;
                    cursor += 2;
                    try cases.named.append(context.allocator, tokenText(source, tokens[cursor]));
                },
                else => return null,
            }
            cursor += 1;
            if (cursor < closing and tokens[cursor].tag == .comma) cursor += 1;
            if (cursor >= closing) return null;
            if (tokens[cursor].tag == .equal_angle_bracket_right) break;
            if (tokens[cursor - 1].tag != .comma) return null;
        }
        // The prong's body, up to the comma that ends it.
        cursor += 1;
        while (cursor < closing and tokens[cursor].tag != .comma) : (cursor += 1) {
            switch (tokens[cursor].tag) {
                .l_paren, .l_bracket, .l_brace => cursor = context.scopes.matchingToken(cursor) orelse return null,
                else => {},
            }
        }
        cursor += 1;
    }
    return cases;
}

fn elseCaptureCanBePreserved(tokens: []const std.zig.Token, else_index: usize, closing: usize) bool {
    var cursor = else_index + 1;
    while (cursor < closing and cursor < else_index + 8) : (cursor += 1) {
        if (tokens[cursor].tag == .pipe) return false;
        if (tokens[cursor].tag == .comma or tokens[cursor].tag == .semicolon) break;
    }
    return true;
}

fn caseSelectorText(allocator: std.mem.Allocator, missing: []const []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (missing, 0..) |name, index| {
        if (index != 0) try writer.writer.writeAll(", ");
        try writer.writer.print(".{s}", .{name});
    }
    return try writer.toOwnedSlice();
}

fn errorCaseSelectorText(allocator: std.mem.Allocator, missing: []const []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (missing, 0..) |name, index| {
        if (index != 0) try writer.writer.writeAll(", ");
        try writer.writer.print("error.{s}", .{name});
    }
    return try writer.toOwnedSlice();
}

/// A fix that appends the comma-terminated elements in `insertion` before the
/// closing brace at `closing`. A one-line body is rewritten with one element
/// per line, as `zig fmt` prints a body with a trailing comma; otherwise the
/// last existing element is terminated first when it has no trailing comma.
fn appendElementFixes(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    opening: usize,
    closing: usize,
    insertion: []const u8,
    spec: struct { title: []const u8, preferred: bool = false },
) ![]const Fix {
    const closing_start = tokens[closing].loc.start;
    const inline_body = source[tokens[opening].loc.end..closing_start];
    const one_line = insertion.len != 0 and insertion[0] == '\n' and
        std.mem.findScalar(u8, inline_body, '\n') == null and std.mem.find(u8, inline_body, "//") == null;
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);
    const previous = tokens[closing - 1];
    const unterminated = closing - 1 != opening and previous.tag != .comma;
    if (one_line) {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        const element_indentation = try std.mem.concat(allocator, u8, &.{ lineIndentation(source, closing_start), "    " });
        defer allocator.free(element_indentation);
        const arrow_separated = tokens[opening - 1].tag == .r_paren;
        var depth: usize = 0;
        var seen_arrow = false;
        var element_start: ?usize = null;
        for (tokens[opening + 1 .. closing], opening + 1..) |token, index| {
            switch (token.tag) {
                .l_paren, .l_bracket, .l_brace => depth += 1,
                .r_paren, .r_bracket, .r_brace => depth -|= 1,
                .equal_angle_bracket_right => if (depth == 0) {
                    seen_arrow = true;
                },
                else => {},
            }
            const separator = token.tag == .comma and depth == 0 and (seen_arrow or !arrow_separated);
            if (separator) {
                if (element_start) |first| {
                    try writer.writer.print("\n{s}{s},", .{ element_indentation, source[tokens[first].loc.start..tokens[index - 1].loc.end] });
                    element_start = null;
                    seen_arrow = false;
                }
            } else if (element_start == null) {
                element_start = index;
            }
        }
        if (element_start) |first| {
            try writer.writer.print("\n{s}{s},", .{ element_indentation, source[tokens[first].loc.start..tokens[closing - 1].loc.end] });
        }
        try writer.writer.writeAll(insertion);
        try edits.append(allocator, .{
            .span = .{ .start = tokens[opening].loc.end, .end = closing_start },
            .replacement = try writer.toOwnedSlice(),
        });
    } else {
        if (unterminated) try edits.append(allocator, .{ .span = .{ .start = previous.loc.end, .end = previous.loc.end }, .replacement = "," });
        try edits.append(allocator, .{ .span = .{ .start = closing_start, .end = closing_start }, .replacement = insertion });
    }
    const fixes = try allocator.alloc(Fix, 1);
    errdefer allocator.free(fixes);
    fixes[0] = .{
        .title = spec.title,
        .kind = .quickfix,
        .edits = try edits.toOwnedSlice(allocator),
        .preferred = spec.preferred,
    };
    return fixes;
}

fn switchProngText(
    allocator: std.mem.Allocator,
    source: []const u8,
    closing_offset: usize,
    missing: []const []const u8,
) ![]const u8 {
    const indentation = lineIndentation(source, closing_offset);
    const closing_is_inline = closing_offset > lineStart(source, closing_offset) + indentation.len;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    if (closing_is_inline) try writer.writer.writeByte('\n');
    for (missing, 0..) |name, index| {
        if (index != 0 or closing_is_inline) try writer.writer.writeAll(indentation);
        try writer.writer.print("    .{s} => @panic(\"TODO\"),\n", .{name});
    }
    try writer.writer.writeAll(indentation);
    return try writer.toOwnedSlice();
}

fn errorSwitchProngText(
    allocator: std.mem.Allocator,
    source: []const u8,
    closing_offset: usize,
    missing: []const []const u8,
) ![]const u8 {
    const indentation = lineIndentation(source, closing_offset);
    const closing_is_inline = closing_offset > lineStart(source, closing_offset) + indentation.len;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    if (closing_is_inline) try writer.writer.writeByte('\n');
    for (missing, 0..) |name, index| {
        if (index != 0 or closing_is_inline) try writer.writer.writeAll(indentation);
        try writer.writer.print("    error.{s} => @panic(\"TODO\"),\n", .{name});
    }
    try writer.writer.writeAll(indentation);
    return try writer.toOwnedSlice();
}

fn findStructInitializers(
    context: RuleRun,
    containers: *const Containers,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.missing_struct_field);
    if (level == .off) return;
    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const initializer = context.tree.fullStructInit(&buffer, node) orelse continue;
        const opening: usize = initializer.ast.lbrace;
        if (opening >= tokens.len) continue;
        const type_token_index = if (initializer.ast.type_expr.unwrap()) |type_expression| type: {
            if (context.tree.nodeTag(type_expression) != .identifier) continue;
            break :type @as(usize, context.tree.nodeMainToken(type_expression));
        } else type: {
            if (opening == 0 or tokens[opening - 1].tag != .period) continue;
            break :type directlyTypedInitializerType(tokens, opening - 1) orelse continue;
        };
        if (type_token_index >= tokens.len or tokens[type_token_index].tag != .identifier) continue;
        const type_name = tokenText(source, tokens[type_token_index]);
        const container = containerNamed(containers, context.scopes, type_name, type_token_index) orelse continue;
        if (container.kind != .structure) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        var missing: std.ArrayList([]const u8) = .empty;
        for (container.fields) |field| {
            if (!field.required or initializerContainsField(source, tokens, opening, closing, field.name)) continue;
            try missing.append(context.allocator, field.name);
        }
        if (missing.items.len == 0) continue;
        const insertion = try structFieldText(context.allocator, source, tokens[closing].loc.start, missing.items);
        const fixes = try appendElementFixes(context.allocator, source, tokens, opening, closing, insertion, .{
            .title = "Fill missing struct fields",
            .preferred = true,
        });
        try context.emit(.{
            .rule = .missing_struct_field,
            .level = level,
            .span = tokens[type_token_index].loc,
            .message = try missingMessage(context.allocator, "initializer is missing fields for type", container.name, missing.items),
            .fixes = fixes,
        });
    }
}

fn directlyTypedInitializerType(
    tokens: []const std.zig.Token,
    initializer_index: usize,
) ?usize {
    if (initializer_index < 4 or tokens[initializer_index - 1].tag != .equal or
        tokens[initializer_index - 2].tag != .identifier or tokens[initializer_index - 3].tag != .colon or
        tokens[initializer_index - 4].tag != .identifier)
    {
        return null;
    }
    if (initializer_index < 5 or switch (tokens[initializer_index - 5].tag) {
        .keyword_const, .keyword_var => false,
        else => true,
    }) return null;
    return initializer_index - 2;
}

fn initializerContainsField(
    source: []const u8,
    tokens: []const std.zig.Token,
    opening: usize,
    closing: usize,
    name: []const u8,
) bool {
    var nested_depth: usize = 0;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_brace, .l_paren, .l_bracket => {
                nested_depth += 1;
                continue;
            },
            .r_brace, .r_paren, .r_bracket => {
                nested_depth -|= 1;
                continue;
            },
            else => {},
        }
        if (nested_depth != 0 or token.tag != .period or index + 2 >= closing) continue;
        if (tokenIs(source, tokens[index + 1], name) and tokens[index + 2].tag == .equal) return true;
    }
    return false;
}

fn structFieldText(
    allocator: std.mem.Allocator,
    source: []const u8,
    closing_offset: usize,
    missing: []const []const u8,
) ![]const u8 {
    const indentation = lineIndentation(source, closing_offset);
    const closing_is_inline = closing_offset > lineStart(source, closing_offset) + indentation.len;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    if (closing_is_inline) try writer.writer.writeByte('\n');
    for (missing, 0..) |name, index| {
        if (index != 0 or closing_is_inline) try writer.writer.writeAll(indentation);
        try writer.writer.print("    .{s} = @panic(\"TODO\"),\n", .{name});
    }
    try writer.writer.writeAll(indentation);
    return try writer.toOwnedSlice();
}

fn missingMessage(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    type_name: []const u8,
    missing: []const []const u8,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("{s} '{s}': ", .{ prefix, type_name });
    for (missing[0..@min(missing.len, 3)], 0..) |name, index| {
        if (index != 0) try writer.writer.writeAll(", ");
        try writer.writer.print(".{s}", .{name});
    }
    if (missing.len > 3) try writer.writer.print(" and {d} more", .{missing.len - 3});
    return try writer.toOwnedSlice();
}

fn identifierNamesEqual(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, identifierName(left), identifierName(right));
}

test "struct findings ignore function return types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Generated = struct { step: u32, destination: []const u8 };\n" ++
        "const ReceiveBuffer = struct { buffer: []u8, state: u8 };\n" ++
        "const TypeMapping = struct { name: []const u8, visibility: enum { public, internal } = .public };\n" ++
        "fn generate(path: []const u8) *Generated { return create(.{ .path = path }); }\n" ++
        "fn receive(buffer: []u8) ReceiveBuffer { return .{ .buffer = buffer, .state = 0 }; }\n" ++
        "fn mapping() TypeMapping { return TypeMapping{ .name = \"value\" }; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_struct_field);
}

test "struct findings resolve the nearest lexical type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Iterator = struct { allocator: u8 };\n" ++
        "const AOF = struct {\n" ++
        "    const Iterator = struct {\n" ++
        "        io: u8,\n" ++
        "        offset: u64 = 0,\n" ++
        "        fn init(io: u8, allocator: u8) Iterator { _ = allocator; return Iterator{ .io = io }; }\n" ++
        "    };\n" ++
        "    fn validate() void { _ = Iterator{ .io = 1 }; }\n" ++
        "};\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_struct_field);
}

test "struct findings resolve directly typed inferred initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Options = struct { count: u32, enabled: bool = true };\n" ++
        "fn run() void { const options: Options = .{}; _ = options; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var missing_field_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_struct_field) {
        missing_field_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, ".count") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_field_count);
}

test "struct findings do not count nested initializer fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Child = struct { required: u8 };\n" ++
        "const Parent = struct { child: Child, required: u8 };\n" ++
        "fn run() void { _ = Parent{ .child = Child{ .required = 1 } }; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var missing_field_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_struct_field) {
        missing_field_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "Parent") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_field_count);
}

test "switch types resolve from function returns and inferred locals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn current() Mode { return .fast; }\n" ++
        "fn run() void {\n" ++
        "    const mode = current();\n" ++
        "    switch (mode) { .fast => {} }\n" ++
        "    switch (current()) { .fast => {} }\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), missing_switch_count);
}

test "a switch on a fallible call's result sees the error union payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Result = union(enum) { success, failure: u32 };\n" ++
        "const Error = error{ BadToken, Eof };\n" ++
        "fn parseWrite() Error!Result { return .success; }\n" ++
        "fn parse() !void {\n" ++
        "    const result = parseWrite() catch return;\n" ++
        "    switch (result) {\n" ++
        "        .success => {},\n" ++
        "        .failure => {},\n" ++
        "    }\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_switch_prong);
}

test "switch types follow qualified paths from where they are written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Cast = struct {\n" ++
        "    const Signedness = enum { unsigned, signed, unneeded };\n" ++
        "    fn fromStd(signedness: std.lang.Signedness) Signedness {\n" ++
        "        return switch (signedness) { .unsigned => .unsigned, .signed => .signed };\n" ++
        "    }\n" ++
        "};\n" ++
        "const Wrapper = struct {\n" ++
        "    const Signedness = enum { a, b, c };\n" ++
        "    fn standard() std.lang.Signedness { return .signed; }\n" ++
        "    fn viaReturn() u8 { return switch (standard()) { .unsigned => 0, .signed => 1 }; }\n" ++
        "};\n" ++
        "fn qualified(signedness: Cast.Signedness) u8 {\n" ++
        "    return switch (signedness) { .unsigned => 0, .signed => 1 };\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, ".unneeded") != null);
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "fn qualified").?);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_switch_count);
}

test "receivers resolve to the same-named container of the innermost enclosing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Outer = struct {\n" ++
        "    const Mode = enum { left, right };\n" ++
        "    fn turn() void { _ = Mode.left; _ = Mode.fast; }\n" ++
        "    const Inner = struct {\n" ++
        "        fn turn() void { _ = Mode.right; _ = Mode.safe; }\n" ++
        "    };\n" ++
        "};\n" ++
        "const Other = struct {\n" ++
        "    fn go() void { _ = Mode.fast; _ = Mode.left; }\n" ++
        "};\n" ++
        "fn pick(mode: Outer.Mode) void { switch (mode) { .left => {} } }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .unresolved_member, .missing_switch_prong }, .warning));
    try support.expectSpans(source, found, &.{ "fast", "safe", "left", "switch" });
    try std.testing.expect(std.mem.find(u8, found[3].message, ".right") != null);
}

test "a bare call's result type comes from the function visible at the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Kind = enum { a, b, c };\n" ++
        "const First = struct { fn kind() Kind { return .a; } };\n" ++
        "const Second = struct {\n" ++
        "    const Other = enum { x, y };\n" ++
        "    fn kind() Other { return .x; }\n" ++
        "    fn direct() u8 { return switch (kind()) { .x => 0, .y => 1 }; }\n" ++
        "    fn stored() u8 { const value = kind(); return switch (value) { .x => 0, .y => 1 }; }\n" ++
        "};\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_switch_prong);
}

test "switches with prong items other than tags are not judged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe, slow };\n" ++
        "const default_mode: Mode = .fast;\n" ++
        "fn constant(mode: Mode) u8 { return switch (mode) { default_mode => 0, .safe, .slow => 1 }; }\n" ++
        "fn qualified(mode: Mode) u8 { return switch (mode) { Mode.fast => 0, .safe => 1, Mode.slow => 2 }; }\n" ++
        "fn nested(mode: Mode, flag: bool) u8 { return switch (mode) { .fast => if (flag) 0 else 1, .safe => 2 }; }\n";
    const configuration = support.only(&.{.non_exhaustive_switch_else}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var missing_switch_count: usize = 0;
    for (found) |finding| {
        try std.testing.expect(finding.rule != .non_exhaustive_switch_else);
        if (finding.rule != .missing_switch_prong) continue;
        missing_switch_count += 1;
        // The `else` in a prong body is not an else prong.
        try std.testing.expect(std.mem.find(u8, finding.message, ".slow") != null);
        try std.testing.expect(finding.span.start > std.mem.find(u8, source, "fn nested").?);
    }
    try std.testing.expectEqual(@as(usize, 1), missing_switch_count);
}

test "members of merged error sets and comptime fields are not unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const ConnectError = error{Timeout} || std.Io.Cancelable;\n" ++
        "fn canceled() ConnectError!void { return ConnectError.Canceled; }\n" ++
        "const Tagged = struct { comptime tag: u8 = 1, value: u8 };\n" ++
        "fn tag(tagged: Tagged) u8 { return tagged.tag + tagged.value; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "members the file tests for with hasDecl or hasField are not judged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const options = @import(\"options.zig\");\n" ++
        "const Config = struct { enabled: bool };\n" ++
        "fn limit() u32 { if (@hasDecl(options, \"limit\")) return options.limit; return 0; }\n" ++
        "fn local(config: Config) u32 { if (@hasField(Config, \"count\")) return config.count; return 0; }\n" ++
        "fn missing() u32 { return options.absent; }\n";
    const modules = [_]types.ModuleMembers{.{ .receiver = "options", .members = &.{"enabled"} }};
    const found = try support.findingsWith(arena.allocator(), runWithModules, @as([]const types.ModuleMembers, &modules), source, Configuration.defaults());
    var unresolved_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        unresolved_count += 1;
        try std.testing.expectEqualStrings("absent", source[finding.span.start..finding.span.end]);
    }
    try std.testing.expectEqual(@as(usize, 1), unresolved_count);
}

test "hasDecl only sees public declarations while field lookup sees local declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32, const hidden = true; pub const visible = true; pub inline fn ready() bool { return true; } };\n" ++
        "fn inspect() void {\n" ++
        "    _ = @hasDecl(State, \"hidden\");\n" ++
        "    _ = @hasDecl(State, \"visible\");\n" ++
        "    _ = @hasDecl(State, \"ready\");\n" ++
        "    _ = @hasDecl(State, \"value\");\n" ++
        "    _ = @field(State, \"hidden\");\n" ++
        "    _ = @hasField(State, \"value\");\n" ++
        "}\n";
    const configuration = support.only(&.{.unknown_comptime_member}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unknown_comptime_member) continue;
        count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "no public declaration") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "switch analysis reads multiline multi-value prongs as present cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe, slow };\n" ++
        "fn run(mode: Mode) void {\n" ++
        "    switch (mode) {\n" ++
        "        .fast,\n" ++
        "        .safe,\n" ++
        "        => {},\n" ++
        "        .slow => {},\n" ++
        "    }\n" ++
        "    switch (mode) {\n" ++
        "        .fast,\n" ++
        "        .safe,\n" ++
        "        => {},\n" ++
        "    }\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, ".slow") != null);
        try std.testing.expect(std.mem.find(u8, finding.message, ".fast") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_switch_count);
}

test "switch prongs never propose the non-exhaustive '_' marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Tag = Factory();\n" ++
        "fn run(tag: Tag) void {\n" ++
        "    switch (tag) { .a => {} }\n" ++
        "}\n";
    const found = try support.findingsShaped(arena.allocator(), run, &.{.{
        .type_name = "Tag",
        .kind = .enumeration,
        .fields = &.{ "a", "b", "_" },
    }}, source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, ".b") != null);
        try std.testing.expect(std.mem.find(u8, finding.message, "._") == null);
        try std.testing.expect(std.mem.find(u8, finding.fixes[0].edits[0].replacement, "._") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_switch_count);
}

test "a resolved shape does not replace a container the file or an earlier shape declares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Local = enum { a, b };\n" ++
        "fn run(local: Local, remote: Remote) void {\n" ++
        "    switch (local) { .a => {}, .b => {} }\n" ++
        "    switch (remote) { .x => {} }\n" ++
        "}\n";
    const found = try support.findingsShaped(arena.allocator(), run, &.{
        .{ .type_name = "Local", .kind = .enumeration, .fields = &.{ "a", "b", "c" } },
        .{ .type_name = "Remote", .kind = .enumeration, .fields = &.{ "x", "y" } },
        .{ .type_name = "Remote", .kind = .enumeration, .fields = &.{"x"} },
    }, source, support.only(&.{.missing_switch_prong}, .warning));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("switch is missing cases for type 'Remote': .y", found[0].message);
}

test "inline else is exhaustive by construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe, slow };\n" ++
        "fn run(mode: Mode) usize {\n" ++
        "    return switch (mode) {\n" ++
        "        .fast => 0,\n" ++
        "        inline else => |m| @intFromEnum(m),\n" ++
        "    };\n" ++
        "}\n";
    const configuration = support.only(&.{.non_exhaustive_switch_else}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .non_exhaustive_switch_else);
}

test "switch else reports eight remaining cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { a, b, c, d, e, f, g, h, i };\n" ++
        "fn run(mode: Mode) usize {\n" ++
        "    return switch (mode) { .a => 0, else => 1 };\n" ++
        "}\n";
    const configuration = support.only(&.{.non_exhaustive_switch_else}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var finding_count: usize = 0;
    for (found) |finding| {
        if (finding.rule != .non_exhaustive_switch_else) continue;
        finding_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
    }
    try std.testing.expectEqual(@as(usize, 1), finding_count);
}

test "switch else permits fallback over nine remaining cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { a, b, c, d, e, f, g, h, i, j };\n" ++
        "fn run(mode: Mode) usize {\n" ++
        "    return switch (mode) { .a => 0, else => 1 };\n" ++
        "}\n";
    const configuration = support.only(&.{.non_exhaustive_switch_else}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .non_exhaustive_switch_else);
}

test "switch else accepts predicate answers and compile errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = enum { active, feeding, complete, idle };\n" ++
        "fn isComplete(state: State) bool {\n" ++
        "    return switch (state) { .complete => true, else => false };\n" ++
        "}\n" ++
        "fn weight(comptime state: State) u8 {\n" ++
        "    return switch (state) { .active => 1, else => @compileError(\"unsupported\") };\n" ++
        "}\n" ++
        "fn flag(state: State) bool {\n" ++
        "    const done = switch (state) { .complete => true, else => false };\n" ++
        "    return done;\n" ++
        "}\n";
    const configuration = support.only(&.{.non_exhaustive_switch_else}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].span.start > std.mem.find(u8, source, "fn flag").?);
}

test "missing members are reported only for proven local receiver shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Message = struct { value: u8, fn read(_: Message) void {} };\n" ++
        "fn use(message: Message, unknown: anytype) void { message.read(); _ = message.mssage; _ = Message.missing; unknown.missing(); }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_member) member_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), member_count);
}

fn runWithModules(context: RuleRun, modules: []const types.ModuleMembers) !void {
    var with_modules = context;
    with_modules.module_members = modules;
    try run(with_modules);
}

test "module members the caller resolved are the only ones that exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const catalog = @import(\"catalog.zig\");\n" ++
        "fn use() u32 { _ = catalog.limit; _ = catalog.missing; return other.anything; }\n" ++
        "// zig-analyzer: disable-next-line unresolved-member\n" ++
        "fn quiet() u32 { return catalog.ignored; }\n";
    const modules = [_]types.ModuleMembers{.{ .receiver = "catalog", .members = &.{"limit"} }};
    const found = try support.findingsWith(arena.allocator(), runWithModules, @as([]const types.ModuleMembers, &modules), source, Configuration.defaults());
    var missing: usize = 0;
    for (found) |finding| {
        if (finding.rule != .unresolved_member) continue;
        try std.testing.expect(std.mem.find(u8, finding.message, "'missing'") != null);
        missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), missing);
}

test "member inference follows the visible shadowing binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Kind = enum { child };\n" ++
        "const Entry = struct { kind: Kind, child: u8 };\n" ++
        "fn use(maybe: ?Entry) void { if (maybe) |*kind| _ = kind.child; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "void tagged union cases are resolved as members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Operation = union(enum) { read: u8, checkpoint }; fn use() void { _ = Operation.checkpoint; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "anonymous struct fields resolve by their numbered names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Event = struct { u8, bool, }; fn use(event: Event) void { _ = event.@\"0\"; _ = event.@\"1\"; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "type info shapes list exactly the members of the pinned std.lang.Type payloads" {
    inline for (type_info_shapes) |shape| {
        const Payload = @field(std.lang.Type, shape.type_name);
        try std.testing.expect(@hasField(std.lang.Type, shape.tag));
        inline for (shape.members) |member| try std.testing.expect(@hasField(Payload, member) or @hasDecl(Payload, member));
        inline for (@typeInfo(Payload).@"struct".field_names) |field| {
            const listed = for (shape.members) |member| {
                if (std.mem.eql(u8, member, field)) break true;
            } else false;
            try std.testing.expect(listed);
        }
    }
}

test "removed @typeInfo payload members are unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Item = struct { a: u8 };\n" ++
        "const fields = @typeInfo(Item).@\"struct\".fields;\n" ++
        "const enum_fields = @typeInfo(E).@\"enum\".fields;\n" ++
        "const decls = @typeInfo(Item).@\"struct\".decls;\n" ++
        "const is_const = @typeInfo(P).pointer.is_const;\n" ++
        "fn use(comptime T: type) void {\n" ++
        "    const info = @typeInfo(T).@\"union\";\n" ++
        "    _ = info.fields;\n" ++
        "    const whole = @typeInfo(T);\n" ++
        "    _ = whole.@\"fn\".params;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.unresolved_member}, .@"error"));
    var messages: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .unresolved_member) try messages.append(arena.allocator(), finding.message);
    try std.testing.expectEqual(@as(usize, 6), messages.items.len);
    try std.testing.expectEqualStrings(
        "type 'std.lang.Type.Struct' has no member named 'fields' in Zig 0.17; iterate field_names, field_types and field_attrs together",
        messages.items[0],
    );
    try std.testing.expectEqualStrings(
        "type 'std.lang.Type.Enum' has no member named 'fields' in Zig 0.17; iterate field_names and field_values together",
        messages.items[1],
    );
    try std.testing.expectEqualStrings("type 'std.lang.Type.Struct' has no member named 'decls' in Zig 0.17; use decl_names", messages.items[2]);
    try std.testing.expectEqualStrings("type 'std.lang.Type.Pointer' has no member named 'is_const' in Zig 0.17; use attrs.@\"const\"", messages.items[3]);
    try std.testing.expectEqualStrings(
        "type 'std.lang.Type.Union' has no member named 'fields' in Zig 0.17; iterate field_names, field_types and field_attrs together",
        messages.items[4],
    );
    try std.testing.expectEqualStrings("type 'std.lang.Type.Fn' has no member named 'params' in Zig 0.17; use param_types and param_attrs", messages.items[5]);
}

test "current @typeInfo members and version-guarded files are not reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const current: [:0]const u8 =
        "const names = @typeInfo(Item).@\"struct\".field_names;\n" ++
        "const bits = @typeInfo(u8).int.bits;\n" ++
        "const attrs = @typeInfo(P).pointer.attrs.@\"const\";\n" ++
        "const custom = item.@\"struct\".fields;\n" ++
        "fn use(comptime T: type) void { var info = @typeInfo(T).@\"struct\"; _ = info.fields; }\n";
    for (try support.findings(arena.allocator(), run, current, Configuration.defaults())) |finding| {
        try std.testing.expect(finding.rule != .unresolved_member);
    }
    const guarded: [:0]const u8 =
        "const builtin = @import(\"builtin\");\n" ++
        "const fields = if (builtin.zig_version.minor >= 16) @typeInfo(Item).@\"struct\".field_names else @typeInfo(Item).@\"struct\".fields;\n";
    for (try support.findings(arena.allocator(), run, guarded, Configuration.defaults())) |finding| {
        try std.testing.expect(finding.rule != .unresolved_member);
    }
}

test "quoted declarations resolve through their unquoted field syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const IntType = struct { const @\"i64\": IntType = .{}; }; fn use() void { _ = IntType.i64; }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "field reflection reports missing members on typed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Message = struct { value: u8 }; fn use(message: Message) void { _ = @field(message, \"value\"); _ = @field(message, \"missing\"); }\n";
    const configuration = support.only(&.{.unknown_comptime_member}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reflection_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unknown_comptime_member) reflection_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reflection_count);
}
