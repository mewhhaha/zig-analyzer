//! Container-aware rules: member, switch-prong and struct-field proofs that share the container facts collected from the file and the compiler-resolved shapes. New unrelated rules do not belong here.
const std = @import("std");

const syntax_scope = @import("../../syntax/scope.zig");
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
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
    var containers: std.ArrayList(Container) = .empty;
    defer {
        for (containers.items) |c| allocator.free(c.fields);
        containers.deinit(allocator);
    }
    const initial_containers = try collectContainers(allocator, context.source, context.tokens);
    defer allocator.free(initial_containers);
    try containers.appendSlice(allocator, initial_containers);
    for (context.resolved_shapes) |shape| {
        if (containerDeclared(containers.items, shape.type_name)) continue;
        const fields = try allocator.alloc(Field, shape.fields.len);
        for (shape.fields, fields) |name, *field| field.* = .{
            .name = name,
            .required = shape.kind != .structure,
        };
        try containers.append(allocator, .{
            .name = shape.type_name,
            .kind = switch (shape.kind) {
                .enumeration => .enumeration,
                .tagged_union => .tagged_union,
                .structure => .structure,
            },
            .fields = fields,
            .scope = .{ .opening = null, .closing = context.tokens.len },
            .resolved = true,
            .has_usingnamespace = false,
        });
    }
    try findUnresolvedMembers(context, containers.items);
    try findUnresolvedModuleMembers(context);
    try findComptimeReflectionIssues(context, containers.items);
    try findSwitches(context, containers.items);
    try findStructInitializers(context, containers.items);
}

const ContainerKind = enum { enumeration, tagged_union, structure, error_set };

const Field = struct {
    name: []const u8,
    required: bool,
};

const Container = struct {
    name: []const u8,
    kind: ContainerKind,
    fields: []const Field,
    scope: TokenScope,
    resolved: bool,
    has_usingnamespace: bool,
};

const TokenScope = struct {
    opening: ?usize,
    closing: usize,
};

fn findUnresolvedMembers(
    context: RuleRun,
    containers: []const Container,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unresolved_member);
    if (level == .off) return;
    for (tokens, 0..) |member_token, member_index| {
        if (member_token.tag != .identifier or member_index < 2 or tokens[member_index - 1].tag != .period or
            tokens[member_index - 2].tag != .identifier) continue;
        if (member_index >= 3 and tokens[member_index - 3].tag == .period) continue;
        const receiver_name = tokenText(source, tokens[member_index - 2]);
        const container = containerForReceiver(source, tokens, containers, context.scopes, receiver_name, member_index - 2) orelse continue;
        if (container.has_usingnamespace or container.resolved) continue;
        const member_name = tokenText(source, member_token);
        if (containerHasField(container, member_name) or
            containerHasDeclaration(source, tokens, container.name, member_name, false)) continue;
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
        if (exists) continue;
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

fn containerForReceiver(
    source: []const u8,
    tokens: []const std.zig.Token,
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    receiver_name: []const u8,
    receiver_index: usize,
) ?Container {
    if (containerNamed(containers, scope_index, receiver_name, receiver_index)) |container| return container;
    const type_name = indexedBindingTypeName(source, tokens, scope_index, receiver_index) orelse return null;
    return containerNamed(containers, scope_index, type_name, receiver_index);
}

fn indexedBindingTypeName(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    receiver_index: usize,
) ?[]const u8 {
    const visible_binding = scope_index.findBinding(receiver_index) orelse return null;
    const index = visible_binding.token_index;
    if (index + 2 < tokens.len and tokens[index + 1].tag == .colon and tokens[index + 2].tag == .identifier and
        (index + 3 >= tokens.len or tokens[index + 3].tag != .period)) return tokenText(source, tokens[index + 2]);
    if (index + 3 < tokens.len and tokens[index + 1].tag == .equal and tokens[index + 2].tag == .identifier and
        tokens[index + 3].tag == .l_brace) return tokenText(source, tokens[index + 2]);
    return null;
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

fn collectContainers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) ![]Container {
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
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        const fields = try collectContainerFields(allocator, source, tokens, opening, closing, kind);
        errdefer allocator.free(fields);
        try containers.append(allocator, .{
            .name = tokenText(source, tokens[index + 1]),
            .kind = kind,
            .fields = fields,
            .scope = enclosingTokenScope(tokens, index),
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
                        .r_brace, .comma, .semicolon, .doc_comment, .container_doc_comment => false,
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
    containers: []const Container,
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
        const container = containerForReceiver(source, tokens, containers, context.scopes, type_name, builtin_index + 2) orelse continue;
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
                field_lookup and containerHasDeclaration(source, tokens, container.name, member_name, false)
        else
            containerHasDeclaration(source, tokens, container.name, member_name, true);
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

fn containerHasDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    container_name: []const u8,
    declaration_name: []const u8,
    require_public: bool,
) bool {
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= tokens.len or
            !identifierNamesEqual(tokenText(source, tokens[index + 1]), container_name) or tokens[index + 2].tag != .equal) continue;
        var opening = index + 4;
        if (tokens[index + 3].tag == .keyword_union and opening < tokens.len and tokens[opening].tag == .l_paren) {
            opening = (matchingToken(tokens, opening, .l_paren, .r_paren) orelse continue) + 1;
        }
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        var depth: usize = 1;
        for (tokens[opening + 1 .. closing], opening + 1..) |member_token, member_index| {
            switch (member_token.tag) {
                .l_brace => depth += 1,
                .r_brace => depth -= 1,
                .keyword_fn, .keyword_const, .keyword_var => if (depth == 1 and member_index + 1 < closing and
                    identifierNamesEqual(tokenText(source, tokens[member_index + 1]), declaration_name))
                {
                    if (!require_public) return true;
                    var modifier_index = member_index;
                    while (modifier_index > opening + 1) {
                        modifier_index -= 1;
                        switch (tokens[modifier_index].tag) {
                            .keyword_pub => return true,
                            .keyword_inline, .keyword_noinline, .keyword_extern, .keyword_export, .keyword_threadlocal => {},
                            else => break,
                        }
                    }
                },
                else => {},
            }
        }
    }
    return false;
}

fn findSwitches(
    context: RuleRun,
    containers: []const Container,
) !void {
    const source = context.source;
    const tokens = context.tokens;
    if (context.level(.missing_switch_prong) == .off and
        context.level(.non_exhaustive_switch_else) == .off and
        context.level(.non_exhaustive_error_switch) == .off) return;
    var declaration_sites = try collectBindingDeclarationSites(context.allocator, source, tokens);
    defer {
        var site_lists = declaration_sites.valueIterator();
        while (site_lists.next()) |list| list.deinit(context.allocator);
        declaration_sites.deinit(context.allocator);
    }
    var return_types = try collectFunctionReturnTypes(context.allocator, source, tokens);
    defer return_types.deinit(context.allocator);
    for (tokens, 0..) |token, switch_index| {
        if (token.tag != .keyword_switch or switch_index + 4 >= tokens.len or tokens[switch_index + 1].tag != .l_paren) continue;
        const operand_end = matchingToken(tokens, switch_index + 1, .l_paren, .r_paren) orelse continue;
        if (tokens[switch_index + 2].tag != .identifier) continue;
        const opening = operand_end + 1;
        if (opening >= tokens.len or tokens[opening].tag != .l_brace) continue;
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        const operand_name = tokenText(source, tokens[switch_index + 2]);
        const type_name = if (operand_end == switch_index + 3)
            bindingTypeName(source, tokens, &declaration_sites, &return_types, operand_name, switch_index) orelse continue
        else if (operand_end == switch_index + 5 and tokens[switch_index + 3].tag == .l_paren and
            tokens[switch_index + 4].tag == .r_paren)
            return_types.get(operand_name) orelse continue
        else
            continue;
        const container = containerNamed(containers, context.scopes, type_name, switch_index) orelse continue;
        if (container.kind == .structure) continue;

        var missing: std.ArrayList([]const u8) = .empty;
        var else_index: ?usize = null;
        for (container.fields) |field| {
            // '_' marks a non-exhaustive enum, not a nameable case; '._ =>' does not compile.
            if (std.mem.eql(u8, field.name, "_")) continue;
            if (!switchContainsCase(source, tokens, opening, closing, field.name)) try missing.append(context.allocator, field.name);
        }
        var cursor = opening + 1;
        while (cursor < closing) : (cursor += 1) {
            if (tokens[cursor].tag == .keyword_else) else_index = cursor;
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
            if (level == .off or missing.items.len > maximum_named_else_cases) continue;
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

const BindingDeclarationSites = std.StringHashMapUnmanaged(std.ArrayList(usize));

const FunctionReturnTypes = std.StringHashMapUnmanaged([]const u8);

/// Indexes every 'name:' and 'const/var name' site so switch analysis can find
/// a binding's declaration without rescanning the file per switch.
fn collectBindingDeclarationSites(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) !BindingDeclarationSites {
    var sites: BindingDeclarationSites = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        const is_typed_declaration = index + 1 < tokens.len and tokens[index + 1].tag == .colon;
        const is_local_declaration = index > 0 and
            (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var);
        if (!is_typed_declaration and !is_local_declaration) continue;
        const entry = try sites.getOrPutValue(allocator, tokenText(source, token), .empty);
        try entry.value_ptr.append(allocator, index);
    }
    return sites;
}

fn collectFunctionReturnTypes(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) !FunctionReturnTypes {
    var return_types: FunctionReturnTypes = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 3 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
        // A switch on the call's result sees the error union's payload type.
        var return_start = parameters_end + 1;
        if (return_start < tokens.len and tokens[return_start].tag == .bang) return_start += 1;
        if (return_start >= tokens.len or tokens[return_start].tag != .identifier) continue;
        var type_index = return_start;
        while (type_index + 2 < tokens.len and tokens[type_index + 1].tag == .period and
            tokens[type_index + 2].tag == .identifier)
        {
            type_index += 2;
        }
        if (type_index + 2 < tokens.len and tokens[type_index + 1].tag == .bang and
            tokens[type_index + 2].tag == .identifier)
        {
            type_index += 2;
            while (type_index + 2 < tokens.len and tokens[type_index + 1].tag == .period and
                tokens[type_index + 2].tag == .identifier)
            {
                type_index += 2;
            }
        }
        const entry = try return_types.getOrPut(allocator, tokenText(source, tokens[index + 1]));
        if (!entry.found_existing) entry.value_ptr.* = tokenText(source, tokens[type_index]);
    }
    return return_types;
}

fn bindingTypeName(
    source: []const u8,
    tokens: []const std.zig.Token,
    declaration_sites: *const BindingDeclarationSites,
    return_types: *const FunctionReturnTypes,
    binding_name: []const u8,
    before: usize,
) ?[]const u8 {
    const site_list = declaration_sites.get(binding_name) orelse return null;
    var remaining = site_list.items.len;
    while (remaining > 0) {
        remaining -= 1;
        const index = site_list.items[remaining];
        if (index >= before) continue;
        const is_typed_declaration = index + 1 < tokens.len and tokens[index + 1].tag == .colon;
        if (!bindingDeclarationContainsUse(tokens, index, before)) continue;
        if (is_typed_declaration) {
            if (index + 2 >= tokens.len or tokens[index + 2].tag != .identifier) return null;
            var type_index = index + 2;
            while (type_index + 2 < tokens.len and tokens[type_index + 1].tag == .period and
                tokens[type_index + 2].tag == .identifier)
            {
                type_index += 2;
            }
            return tokenText(source, tokens[type_index]);
        }
        if (index + 3 < tokens.len and tokens[index + 1].tag == .equal and tokens[index + 2].tag == .identifier and
            tokens[index + 3].tag == .l_paren and matchingToken(tokens, index + 3, .l_paren, .r_paren) != null)
        {
            return return_types.get(tokenText(source, tokens[index + 2]));
        }
        return null;
    }
    return null;
}

fn bindingDeclarationContainsUse(tokens: []const std.zig.Token, declaration_index: usize, use_index: usize) bool {
    if (declaration_index > 0 and
        (tokens[declaration_index - 1].tag == .keyword_const or tokens[declaration_index - 1].tag == .keyword_var))
    {
        return scopeContains(enclosingTokenScope(tokens, declaration_index), use_index);
    }
    const opening_parenthesis = enclosingOpeningParenthesis(tokens, declaration_index) orelse return false;
    const closing_parenthesis = matchingToken(tokens, opening_parenthesis, .l_paren, .r_paren) orelse return false;
    var body_opening = closing_parenthesis + 1;
    while (body_opening < tokens.len and tokens[body_opening].tag != .l_brace) : (body_opening += 1) {}
    if (body_opening == tokens.len) return false;
    const body_closing = matchingToken(tokens, body_opening, .l_brace, .r_brace) orelse return false;
    return use_index > body_opening and use_index < body_closing;
}

fn enclosingOpeningParenthesis(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            .l_brace, .semicolon => return null,
            else => {},
        }
    }
    return null;
}

fn containerNamed(
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    requested_name: []const u8,
    use_index: usize,
) ?Container {
    var name = requested_name;
    for (0..16) |_| {
        var selected: ?Container = null;
        for (containers) |container| {
            if (!identifierNamesEqual(container.name, name) or !scopeContains(container.scope, use_index)) continue;
            if (selected == null or scopeDepth(container.scope) > scopeDepth(selected.?.scope)) selected = container;
        }
        const visible_binding = scope_index.findBindingNamed(name, use_index);
        if (selected) |container| {
            if (visible_binding == null or scopeDepth(container.scope) >= visible_binding.?.scope_rank) return container;
        }
        const target = (visible_binding orelse return null).alias_target orelse return null;
        name = target;
    }
    return null;
}

fn containerDeclared(containers: []const Container, name: []const u8) bool {
    for (containers) |container| {
        if (identifierNamesEqual(container.name, name)) return true;
    }
    return false;
}

fn enclosingTokenScope(tokens: []const std.zig.Token, index: usize) TokenScope {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) {
                    const closing = matchingToken(tokens, cursor, .l_brace, .r_brace) orelse tokens.len;
                    return .{ .opening = cursor, .closing = closing };
                }
                depth -= 1;
            },
            else => {},
        }
    }
    return .{ .opening = null, .closing = tokens.len };
}

fn scopeContains(scope: TokenScope, index: usize) bool {
    if (index >= scope.closing) return false;
    return if (scope.opening) |opening| index > opening else true;
}

fn scopeDepth(scope: TokenScope) usize {
    return if (scope.opening) |opening| opening + 1 else 0;
}

fn switchContainsCase(
    source: []const u8,
    tokens: []const std.zig.Token,
    opening: usize,
    closing: usize,
    name: []const u8,
) bool {
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        if (token.tag != .period or index + 2 >= closing or !tokenIs(source, tokens[index + 1], name)) continue;
        var cursor = index + 2;
        while (cursor < closing) : (cursor += 1) {
            switch (tokens[cursor].tag) {
                .equal_angle_bracket_right => return true,
                .comma, .period, .identifier => {},
                else => break,
            }
        }
    }
    return false;
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
    containers: []const Container,
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
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
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

fn identifierName(spelling: []const u8) []const u8 {
    if (spelling.len >= 3 and std.mem.startsWith(u8, spelling, "@\"") and spelling[spelling.len - 1] == '"') {
        return spelling[2 .. spelling.len - 1];
    }
    return spelling;
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
