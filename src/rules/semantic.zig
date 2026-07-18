const std = @import("std");

const syntax_scope = @import("../syntax_scope.zig");
const allocation_lifecycle = @import("allocation_lifecycle.zig");
const configuration_parser = @import("configuration.zig");
const generated_source_detection = @import("generated_source.zig");
const rule_registry = @import("registry.zig");
const rule_types = @import("types.zig");

pub const Level = rule_types.Level;
pub const Rule = rule_types.Rule;
pub const Configuration = rule_types.Configuration;
pub const LintProfile = rule_types.LintProfile;
pub const Edit = rule_types.Edit;
pub const ActionKind = rule_types.ActionKind;
pub const Fix = rule_types.Fix;
pub const Finding = rule_types.Finding;
pub const RelatedSpan = rule_types.RelatedSpan;

pub const parseConfiguration = configuration_parser.parse;
pub const suppressionWarning = configuration_parser.suppressionWarning;
pub const isSuppressed = configuration_parser.isSuppressed;
pub const suppressionEdits = configuration_parser.suppressionEdits;

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

pub const ResolvedShape = struct {
    type_name: []const u8,
    kind: Kind,
    fields: []const []const u8,

    pub const Kind = enum { enumeration, tagged_union, structure };
};

pub fn findings(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: Configuration,
) ![]Finding {
    return try findingsWithShapes(allocator, source, configuration, &.{});
}

pub fn findingsWithTokens(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
) ![]Finding {
    return try findingsWithShapesAndTokens(allocator, source, tokens, configuration, &.{});
}

pub fn findingsWithShapes(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: Configuration,
    resolved_shapes: []const ResolvedShape,
) ![]Finding {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    return try findingsWithShapesAndTokens(allocator, source, tokens, configuration, resolved_shapes);
}

fn findingsWithShapesAndTokens(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    resolved_shapes: []const ResolvedShape,
) ![]Finding {
    if (generated_source_detection.isTranslateCOutput(source)) return &.{};
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var scope_index = try syntax_scope.Index.init(allocator, source, tokens);
    defer scope_index.deinit();
    var containers: std.ArrayList(Container) = .empty;
    try containers.appendSlice(allocator, try collectContainers(allocator, source, tokens));
    for (resolved_shapes) |shape| {
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
            .scope = .{ .opening = null, .closing = tokens.len },
            .resolved = true,
            .has_usingnamespace = false,
        });
    }
    var found: std.ArrayList(Finding) = .empty;
    const suppression_directives_present = configuration_parser.hasSuppressionDirectives(source);

    try findUnresolvedCalls(allocator, source, tokens, &scope_index, configuration, &found);
    try findUnresolvedIdentifiers(allocator, source, tokens, &tree, &scope_index, configuration, &found);
    try findUnresolvedMembers(allocator, source, tokens, containers.items, &scope_index, configuration, &found);
    try findUnresolvedLabels(allocator, source, tokens, configuration, &found);
    try findNeverMutatedVariables(allocator, source, tokens, configuration, &found);
    try findDiscardedErrors(allocator, source, tokens, configuration, &found);
    try findCatchDiagnostics(allocator, source, tokens, configuration, &found);
    try findMissingResourceCleanup(allocator, source, tokens, configuration, &found);
    try findUndefinedValueEscapes(allocator, source, tokens, &scope_index, configuration, &found);
    try findBooleanComparisons(allocator, source, tokens, &scope_index, configuration, &found);
    try findErrorValueComparisons(allocator, source, tokens, &tree, configuration, &found);
    try findMixedBitwiseArithmetic(allocator, source, tokens, &tree, configuration, &found);
    try findUnusedPrivateDeclarations(allocator, source, tokens, &tree, configuration, &found);
    try findComptimeReflectionIssues(allocator, source, tokens, containers.items, &scope_index, configuration, &found);
    try findConstantComptimeConditions(allocator, source, tokens, configuration, &found);
    try findSwitches(allocator, source, tokens, containers.items, &scope_index, configuration, &found);
    try findStructInitializers(allocator, source, tokens, &tree, containers.items, &scope_index, configuration, &found);
    // defer_cleanup_in_loop is intentionally inert: a defer in a loop body runs at the
    // end of each iteration, not at function exit, so the rule's premise was false.
    // The Rule enum entry remains so existing configurations still parse.
    try findNeedlessCasts(allocator, source, tokens, &scope_index, configuration, &found);
    try findNeedlessElse(allocator, source, tokens, configuration, &found);
    try findNonIdiomaticNames(allocator, source, tokens, &tree, resolved_shapes, configuration, &found);
    try findOfficialStyleIssues(allocator, source, tokens, configuration, &found);
    try findOptionalCaptureIdioms(allocator, source, tokens, configuration, &found);
    try findTryIdioms(allocator, source, tokens, configuration, &found);
    try findTestingIdioms(allocator, source, tokens, configuration, &found);
    try findPointerParameterIdioms(allocator, source, tokens, configuration, &found);
    try findComptimeIdioms(allocator, source, tokens, configuration, &found);
    try findTypeExpressionIdioms(allocator, source, tokens, configuration, &found);
    try findImportIssues(allocator, source, tokens, configuration, &found);
    try findUnsortedImports(allocator, source, tokens, configuration, &found);
    if (allocation_lifecycle.enabled(configuration)) {
        const allocation_findings = try allocation_lifecycle.warningsWithSyntax(
            allocator,
            source,
            &tree,
            tokens,
            &scope_index,
            configuration,
        );
        for (allocation_findings) |finding| try addFinding(allocator, source, configuration, &found, .{
            .rule = finding.rule,
            .level = configuration.level(finding.rule),
            .span = finding.span,
            .message = finding.message,
            .fixes = finding.fixes,
        });
    }
    try rule_registry.run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &found,
        .suppression_directives_present = suppression_directives_present,
    });

    if (suppression_directives_present) {
        var kept: usize = 0;
        for (found.items) |finding| {
            if (configuration_parser.isSuppressed(source, finding.rule, finding.span.start)) continue;
            found.items[kept] = finding;
            kept += 1;
        }
        found.shrinkRetainingCapacity(kept);
    }

    std.mem.sort(Finding, found.items, {}, struct {
        fn lessThan(_: void, left: Finding, right: Finding) bool {
            if (left.span.start != right.span.start) return left.span.start < right.span.start;
            return @intFromEnum(left.rule) < @intFromEnum(right.rule);
        }
    }.lessThan);
    return try found.toOwnedSlice(allocator);
}

pub fn fileNameFinding(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    path: []const u8,
    configuration: Configuration,
) !?Finding {
    const level = configuration.level(.non_idiomatic_file_name);
    if (level == .off) return null;
    const basename = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, basename, ".zig") or basename.len == ".zig".len) return null;
    const name = basename[0 .. basename.len - ".zig".len];
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var brace_depth: usize = 0;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var has_top_level_fields = false;
    for (tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .identifier => if (brace_depth == 0 and parenthesis_depth == 0 and bracket_depth == 0 and index + 1 < tokens.len and
                tokens[index + 1].tag == .colon and (index == 0 or switch (tokens[index - 1].tag) {
                .keyword_const, .keyword_var, .keyword_fn => false,
                else => true,
            })) {
                has_top_level_fields = true;
                break;
            },
            else => {},
        }
    }
    const idiomatic = if (has_top_level_fields) isTitleCase(name) else isSnakeCase(name);
    if (idiomatic) return null;
    return .{
        .rule = .non_idiomatic_file_name,
        .level = level,
        .span = .{ .start = 0, .end = @min(source.len, 1) },
        .message = try std.fmt.allocPrint(
            allocator,
            "file '{s}' represents {s} and should use a {s} name",
            .{
                basename,
                if (has_top_level_fields) "a type with fields" else "a namespace",
                if (has_top_level_fields) "TitleCase" else "snake_case",
            },
        ),
    };
}

fn addFinding(
    allocator: std.mem.Allocator,
    source: []const u8,
    _: Configuration,
    found: *std.ArrayList(Finding),
    finding: Finding,
) !void {
    _ = source;
    // Suppression directives are applied once over the collected findings in
    // findingsWithShapes; checking here would rescan the file per finding.
    if (finding.level == .off) return;
    try found.append(allocator, finding);
}

fn findUnresolvedCalls(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unresolved_call);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        if (index >= 2 and tokens[index - 1].tag == .colon and
            (tokens[index - 2].tag == .keyword_break or tokens[index - 2].tag == .keyword_continue)) continue;
        const name = tokenText(source, token);
        if (std.zig.isPrimitive(name)) continue;
        if (scope_index.findBinding(index)) |binding| {
            if (binding.kind != .non_callable) continue;
            try addFinding(allocator, source, configuration, found, .{
                .rule = .unresolved_call,
                .level = level,
                .span = token.loc,
                .message = try std.fmt.allocPrint(allocator, "binding '{s}' is not callable", .{name}),
            });
            continue;
        }
        if (scope_index.usingnamespaceMayProvideName(index)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .unresolved_call,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "call to unresolved function '{s}'", .{name}),
        });
    }
}

fn findUnresolvedIdentifiers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unresolved_identifier);
    if (level == .off) return;

    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .identifier) continue;
        const token_index: usize = tree.nodeMainToken(node);
        if (token_index >= tokens.len) continue;
        const token = tokens[token_index];
        const name = tokenText(source, token);
        if (std.mem.eql(u8, name, "_") or std.zig.isPrimitive(name) or
            scope_index.findBinding(token_index) != null or
            syntax_scope.isContainerFieldDeclaration(tokens, token_index) or
            containerHeaderResolvesToNestedDeclaration(source, tokens, token_index, name)) continue;
        // Field names and enum literals are resolved through their receiver or
        // result type. Calls retain the more specific unresolved-call finding.
        if (token_index > 0 and tokens[token_index - 1].tag == .period) continue;
        if (token_index + 1 < tokens.len and tokens[token_index + 1].tag == .l_paren) continue;
        if (scope_index.usingnamespaceMayProvideName(token_index)) continue;

        try addFinding(allocator, source, configuration, found, .{
            .rule = .unresolved_identifier,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "use of unresolved identifier '{s}'", .{name}),
        });
    }
}

fn containerHeaderResolvesToNestedDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
    name: []const u8,
) bool {
    var container_keyword: ?usize = null;
    var cursor = identifier_index;
    while (cursor > 0 and identifier_index - cursor < 32) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                container_keyword = cursor;
                break;
            },
            .semicolon, .l_brace, .r_brace, .equal => return false,
            else => {},
        }
    }
    if (container_keyword == null) return false;

    var opening = identifier_index + 1;
    while (opening < tokens.len and tokens[opening].tag != .l_brace) : (opening += 1) {
        if (tokens[opening].tag == .semicolon) return false;
    }
    if (opening == tokens.len) return false;
    const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse return false;

    var depth: usize = 0;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| {
        switch (token.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .keyword_const, .keyword_var, .keyword_fn => if (depth == 0 and index + 1 < closing and
                tokens[index + 1].tag == .identifier and tokenIs(source, tokens[index + 1], name)) return true,
            else => {},
        }
    }
    return false;
}

fn findUnresolvedMembers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unresolved_member);
    if (level == .off) return;
    for (tokens, 0..) |member_token, member_index| {
        if (member_token.tag != .identifier or member_index < 2 or tokens[member_index - 1].tag != .period or
            tokens[member_index - 2].tag != .identifier) continue;
        if (member_index >= 3 and tokens[member_index - 3].tag == .period) continue;
        const receiver_name = tokenText(source, tokens[member_index - 2]);
        const container = containerForReceiver(source, tokens, containers, scope_index, receiver_name, member_index - 2) orelse continue;
        if (container.has_usingnamespace or container.resolved) continue;
        const member_name = tokenText(source, member_token);
        if (containerHasField(container, member_name) or
            containerHasDeclaration(source, tokens, container.name, member_name)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .unresolved_member,
            .level = level,
            .span = member_token.loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "type '{s}' has no member named '{s}'",
                .{ container.name, member_name },
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

fn findUnresolvedLabels(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unresolved_label);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or tokens[index - 1].tag != .colon or
            (tokens[index - 2].tag != .keyword_break and tokens[index - 2].tag != .keyword_continue)) continue;
        const name = tokenText(source, token);
        if (labelIsVisible(source, tokens, name, index)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .unresolved_label,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "branch targets unresolved label '{s}'", .{name}),
        });
    }
}

fn labelIsVisible(source: []const u8, tokens: []const std.zig.Token, name: []const u8, use_index: usize) bool {
    for (tokens[0..use_index], 0..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, name) or index + 2 >= tokens.len or
            tokens[index + 1].tag != .colon) continue;
        const construct = index + 2;
        const valid_construct = tokens[construct].tag == .l_brace or switch (tokens[construct].tag) {
            .keyword_while, .keyword_for, .keyword_switch, .keyword_inline => true,
            else => false,
        };
        if (!valid_construct) continue;
        const end = labeledConstructEnd(tokens, construct) orelse continue;
        if (use_index > construct and use_index < end) return true;
    }
    return false;
}

fn labeledConstructEnd(tokens: []const std.zig.Token, construct: usize) ?usize {
    if (tokens[construct].tag == .l_brace) return matchingToken(tokens, construct, .l_brace, .r_brace);
    var cursor = construct + 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0)
                return matchingToken(tokens, cursor, .l_brace, .r_brace),
            .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0) return cursor,
            else => {},
        }
    }
    return null;
}

fn identifierIsCaptureBinding(tokens: []const std.zig.Token, index: usize) bool {
    var opening = index;
    while (opening > 0 and index - opening < 16) {
        opening -= 1;
        switch (tokens[opening].tag) {
            .pipe => break,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    } else return false;
    var closing = index + 1;
    while (closing < tokens.len and closing - index < 16) : (closing += 1) {
        switch (tokens[closing].tag) {
            .pipe => return true,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    }
    return false;
}

fn findNeverMutatedVariables(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.never_mutated_var);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_var or index + 1 >= tokens.len or tokens[index + 1].tag != .identifier) continue;
        if (!insideFunctionOrTestBody(tokens, index)) continue;
        const name_token = tokens[index + 1];
        const name = tokenText(source, name_token);
        if (std.mem.eql(u8, name, "_")) continue;
        if (declarationUsesUndefined(source, tokens, index + 2)) continue;
        const scope_end = enclosingScopeEnd(tokens, index) orelse continue;
        if (bindingIsMutated(source, tokens, name, index + 2, scope_end)) continue;
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{ .span = token.loc, .replacement = "const" };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(allocator, "Change '{s}' to const", .{name}),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .never_mutated_var,
            .level = level,
            .span = name_token.loc,
            .message = try std.fmt.allocPrint(allocator, "variable '{s}' is never mutated", .{name}),
            .fixes = fixes,
        });
    }
}

fn declarationUsesUndefined(source: []const u8, tokens: []const std.zig.Token, start: usize) bool {
    for (tokens[start..]) |token| {
        switch (token.tag) {
            .identifier => if (tokenIs(source, token, "undefined")) return true,
            .semicolon => return false,
            else => {},
        }
    }
    return false;
}

fn insideFunctionOrTestBody(tokens: []const std.zig.Token, declaration_index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = declaration_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn, .keyword_test => return true,
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn bindingIsMutated(
    source: []const u8,
    tokens: []const std.zig.Token,
    name: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], name)) continue;
        const shadows_binding = index > 0 and
            (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var) or
            identifierIsCaptureBinding(tokens, index);
        if (shadows_binding) {
            index = enclosingScopeEnd(tokens, index) orelse index;
            continue;
        }
        if (index > 0 and tokens[index - 1].tag == .ampersand) return true;
        if (usedByAssembly(tokens, index)) return true;
        if (usedByFieldMutation(source, tokens, index)) return true;
        if (usedByMutableOptionalCapture(tokens, index)) return true;
        if (usedByMutableSwitchCapture(tokens, index)) return true;
        if (index + 1 >= tokens.len) continue;
        // '@field(binding, ...)' can be an lvalue, just like 'binding.name'.
        if (index >= 2 and tokens[index - 1].tag == .l_paren and
            tokenIs(source, tokens[index - 2], "@field")) return true;
        if (tokens[index + 1].tag == .period or tokens[index + 1].tag == .l_bracket) return true;
        if (isAssignment(tokens[index + 1].tag)) return true;
        if (identifierIsDestructuredAssignmentTarget(tokens, index)) return true;
        var mutation_cursor = index + 1;
        while (mutation_cursor < tokens.len and mutation_cursor < index + 32) : (mutation_cursor += 1) {
            switch (tokens[mutation_cursor].tag) {
                .semicolon, .comma => break,
                else => if (isAssignment(tokens[mutation_cursor].tag)) return true,
            }
        }
    }
    return false;
}

fn identifierIsDestructuredAssignmentTarget(tokens: []const std.zig.Token, index: usize) bool {
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .comma) return false;
    var cursor = index + 1;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .comma, .identifier, .period, .l_bracket, .r_bracket, .number_literal => {},
            .equal => return true,
            else => return false,
        }
    }
    return false;
}

fn usedByAssembly(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_asm => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn isAssignment(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .equal,
        .plus_equal,
        .plus_percent_equal,
        .plus_pipe_equal,
        .minus_equal,
        .minus_percent_equal,
        .minus_pipe_equal,
        .asterisk_equal,
        .asterisk_percent_equal,
        .asterisk_pipe_equal,
        .slash_equal,
        .percent_equal,
        .ampersand_equal,
        .pipe_equal,
        .caret_equal,
        .angle_bracket_angle_bracket_left_equal,
        .angle_bracket_angle_bracket_left_pipe_equal,
        .angle_bracket_angle_bracket_right_equal,
        => true,
        else => false,
    };
}

fn usedByFieldMutation(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or tokens[use_index - 1].tag != .l_paren or
        !tokenIs(source, tokens[use_index - 2], "@field")) return false;
    const closing = matchingToken(tokens, use_index - 1, .l_paren, .r_paren) orelse return false;
    if (closing + 1 < tokens.len and isAssignment(tokens[closing + 1].tag)) return true;
    return use_index >= 3 and tokens[use_index - 3].tag == .ampersand;
}

fn usedByMutableOptionalCapture(tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or use_index + 5 >= tokens.len) return false;
    if (tokens[use_index - 1].tag != .l_paren or
        (tokens[use_index - 2].tag != .keyword_if and tokens[use_index - 2].tag != .keyword_while)) return false;
    return tokens[use_index + 1].tag == .r_paren and
        tokens[use_index + 2].tag == .pipe and
        tokens[use_index + 3].tag == .asterisk and
        tokens[use_index + 4].tag == .identifier and
        tokens[use_index + 5].tag == .pipe;
}

fn usedByMutableSwitchCapture(tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index == 0 or tokens[use_index - 1].tag != .l_paren) return false;
    var switch_index = use_index - 1;
    while (switch_index > 0 and use_index - switch_index < 16) {
        switch_index -= 1;
        if (tokens[switch_index].tag == .keyword_switch) break;
        if (tokens[switch_index].tag == .semicolon or tokens[switch_index].tag == .l_brace) return false;
    } else return false;
    const operand_end = matchingToken(tokens, use_index - 1, .l_paren, .r_paren) orelse return false;
    if (operand_end + 1 >= tokens.len or tokens[operand_end + 1].tag != .l_brace) return false;
    const switch_end = matchingToken(tokens, operand_end + 1, .l_brace, .r_brace) orelse return false;
    var index = operand_end + 2;
    while (index + 1 < switch_end) : (index += 1) {
        if (tokens[index].tag == .pipe and tokens[index + 1].tag == .asterisk) return true;
    }
    return false;
}

fn findDiscardedErrors(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.discarded_error);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_catch) continue;
        const opening = catchBodyStart(tokens, index) orelse continue;
        if (opening + 1 >= tokens.len or tokens[opening].tag != .l_brace or tokens[opening + 1].tag != .r_brace) continue;
        const body = source[tokens[opening].loc.end..tokens[opening + 1].loc.start];
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len != 0) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .discarded_error,
            .level = level,
            .span = token.loc,
            .message = try allocator.dupe(u8, "empty catch body discards the error without handling it"),
        });
    }
}

fn findCatchDiagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const unreachable_level = configuration.level(.unsafe_catch_unreachable);
    const context_level = configuration.level(.lost_error_context);
    if (unreachable_level == .off and context_level == .off) return;

    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch) continue;
        const body_start = catchBodyStart(tokens, catch_index) orelse continue;
        if (unreachable_level != .off and tokens[body_start].tag == .keyword_unreachable and
            catchExpressionIsKnownFallible(source, tokens, catch_index))
        {
            const fixes: []const Fix = fixes: {
                if (!enclosingFunctionReturnsErrorUnion(tokens, catch_index)) break :fixes &.{};
                const call_open = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse break :fixes &.{};
                const expression_start = callExpressionStart(tokens, call_open) orelse break :fixes &.{};
                const expression = std.mem.trim(u8, source[tokens[expression_start].loc.start..token.loc.start], " \t\r\n");
                const edits = try allocator.alloc(Edit, 1);
                edits[0] = .{
                    .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[body_start].loc.end },
                    .replacement = try std.fmt.allocPrint(allocator, "try {s}", .{expression}),
                };
                const allocated = try allocator.alloc(Fix, 1);
                allocated[0] = .{ .title = "Propagate the error with try", .kind = .quickfix, .edits = edits };
                break :fixes allocated;
            };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .unsafe_catch_unreachable,
                .level = unreachable_level,
                .span = tokens[body_start].loc,
                .message = try allocator.dupe(u8, "catch unreachable asserts that a proven fallible operation cannot fail"),
                .fixes = fixes,
            });
        }
        if (context_level == .off) continue;
        const remapped_error = remappedErrorToken(source, tokens, body_start) orelse continue;
        // A body that stores or logs the captured error keeps its identity.
        if (catchCaptureIsUsed(source, tokens, catch_index, body_start)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .lost_error_context,
            .level = context_level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "catch maps every failure to '{s}' and loses the original error identity",
                .{tokenText(source, remapped_error)},
            ),
        });
    }
}

fn catchCaptureIsUsed(
    source: []const u8,
    tokens: []const std.zig.Token,
    catch_index: usize,
    body_start: usize,
) bool {
    if (catch_index + 2 >= tokens.len or tokens[catch_index + 1].tag != .pipe or
        tokens[catch_index + 2].tag != .identifier) return false;
    const capture_name = tokenText(source, tokens[catch_index + 2]);
    if (std.mem.eql(u8, capture_name, "_")) return false;
    var limit = @min(tokens.len, body_start + 16);
    if (tokens[body_start].tag == .l_brace) {
        limit = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return false;
    }
    for (tokens[body_start..limit], body_start..) |token, index| {
        if (token.tag == .semicolon and tokens[body_start].tag != .l_brace) break;
        if (token.tag != .identifier or !tokenIs(source, token, capture_name)) continue;
        if (index > 0 and tokens[index - 1].tag == .period) continue;
        return true;
    }
    return false;
}

fn catchBodyStart(tokens: []const std.zig.Token, catch_index: usize) ?usize {
    var index = catch_index + 1;
    if (index >= tokens.len) return null;
    if (tokens[index].tag == .pipe) {
        index += 1;
        while (index < tokens.len and tokens[index].tag != .pipe) : (index += 1) {}
        if (index >= tokens.len) return null;
        index += 1;
    }
    return if (index < tokens.len) index else null;
}

fn enclosingFunctionReturnsErrorUnion(tokens: []const std.zig.Token, index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn => {
                            var parameters_open = signature_cursor + 1;
                            while (parameters_open < cursor and tokens[parameters_open].tag != .l_paren) : (parameters_open += 1) {}
                            if (parameters_open >= cursor) return false;
                            const parameters_end = matchingToken(tokens, parameters_open, .l_paren, .r_paren) orelse return false;
                            for (tokens[parameters_end + 1 .. cursor]) |return_token| {
                                if (return_token.tag == .bang) return true;
                            }
                            return false;
                        },
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn catchExpressionIsKnownFallible(source: []const u8, tokens: []const std.zig.Token, catch_index: usize) bool {
    if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return false;
    const opening = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse return false;
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return false;
    const callee_name = tokenText(source, tokens[opening - 1]);
    const known_fallible = [_][]const u8{
        "alloc",    "allocSentinel", "alignedAlloc", "dupe",            "dupeZ", "realloc", "create",
        "openFile", "createFile",    "openDir",      "openIterableDir", "read",  "write",   "parse",
    };
    for (known_fallible) |name| if (std.mem.eql(u8, callee_name, name)) return true;

    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 2 >= tokens.len or
            !tokenIs(source, tokens[index + 1], callee_name) or tokens[index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
        var return_index = parameters_end + 1;
        const return_limit = @min(tokens.len, parameters_end + 32);
        while (return_index < return_limit and tokens[return_index].tag != .semicolon and
            tokens[return_index].tag != .keyword_return) : (return_index += 1)
        {
            if (tokenIs(source, tokens[return_index], "!")) return true;
            if (tokens[return_index].tag != .l_brace) continue;
            if (return_index > parameters_end + 1 and tokenIs(source, tokens[return_index - 1], "error")) {
                return_index = matchingToken(tokens, return_index, .l_brace, .r_brace) orelse return false;
                continue;
            }
            return false;
        }
    }
    return false;
}

fn remappedErrorToken(
    source: []const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
) ?std.zig.Token {
    var index = body_start;
    var limit = @min(tokens.len, body_start + 16);
    const braced = tokens[body_start].tag == .l_brace;
    if (braced) {
        const closing = matchingToken(tokens, body_start, .l_brace, .r_brace) orelse return null;
        limit = closing;
        index += 1;
    }
    var remapped: ?std.zig.Token = null;
    while (index < limit) : (index += 1) {
        switch (tokens[index].tag) {
            // Branching means only some failures are remapped, not every one.
            .keyword_if, .keyword_switch => return null,
            .keyword_return => {
                if (remapped != null) return null;
                if (index + 3 >= limit or !tokenIs(source, tokens[index + 1], "error") or
                    tokens[index + 2].tag != .period or tokens[index + 3].tag != .identifier) return null;
                remapped = tokens[index + 3];
                index += 3;
            },
            .semicolon => if (!braced) break,
            else => {},
        }
    }
    return remapped;
}

const ResourcePair = struct {
    acquisition: []const u8,
    release: []const u8,
    alternative_release: ?[]const u8 = null,
};

fn findMissingResourceCleanup(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.missing_resource_cleanup);
    if (level == .off) return;
    const resource_pairs = [_]ResourcePair{
        .{ .acquisition = "openFile", .release = "close" },
        .{ .acquisition = "createFile", .release = "close" },
        .{ .acquisition = "openDir", .release = "close" },
        .{ .acquisition = "openIterableDir", .release = "close" },
        .{ .acquisition = "spawn", .release = "join", .alternative_release = "detach" },
        .{ .acquisition = "init", .release = "deinit" },
        .{ .acquisition = "initCapacity", .release = "deinit" },
    };

    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .equal) continue;
        if (!insideFunctionOrTestBody(tokens, declaration_index)) continue;
        const statement_end = statementEnd(tokens, declaration_index) orelse continue;
        var pair: ?ResourcePair = null;
        var acquisition_index: usize = declaration_index + 3;
        while (acquisition_index < statement_end) : (acquisition_index += 1) {
            switch (tokens[acquisition_index].tag) {
                // A type definition initializer: any init/openFile inside it is a
                // method declaration or nested body, not an acquisition by this binding.
                .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_fn => break,
                else => {},
            }
            if (tokens[acquisition_index].tag != .identifier or acquisition_index + 1 >= statement_end or
                tokens[acquisition_index + 1].tag != .l_paren) continue;
            const name = tokenText(source, tokens[acquisition_index]);
            for (resource_pairs) |candidate| if (std.mem.eql(u8, name, candidate.acquisition)) {
                if (std.mem.eql(u8, name, "spawn") and !tokensBeforeContain(source, tokens, declaration_index + 3, acquisition_index, "Thread")) continue;
                if ((std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "initCapacity")) and
                    !initializerNamesManagedResource(source, tokens, declaration_index + 3, acquisition_index)) continue;
                pair = candidate;
                break;
            };
            if (pair != null) break;
        }
        const resource = pair orelse continue;
        const scope_end = enclosingScopeEnd(tokens, declaration_index) orelse continue;
        const binding_name = tokenText(source, tokens[declaration_index + 1]);
        if (bindingHasRelease(source, tokens, binding_name, statement_end + 1, scope_end, resource.release, resource.alternative_release) or
            bindingObviouslyEscapes(source, tokens, binding_name, statement_end + 1, scope_end)) continue;
        const line_start = lineStart(source, tokens[declaration_index].loc.start);
        var indentation_end = line_start;
        while (indentation_end < source.len and (source[indentation_end] == ' ' or source[indentation_end] == '\t')) indentation_end += 1;
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{
            .span = .{ .start = tokens[statement_end].loc.end, .end = tokens[statement_end].loc.end },
            .replacement = try std.fmt.allocPrint(
                allocator,
                "\n{s}defer {s}.{s}();",
                .{ source[line_start..indentation_end], binding_name, resource.release },
            ),
        };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = try std.fmt.allocPrint(allocator, "Insert 'defer {s}.{s}()'", .{ binding_name, resource.release }),
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = tokens[declaration_index + 1].loc,
            .fixes = fixes,
            .message = try std.fmt.allocPrint(
                allocator,
                "resource '{s}' from {s} has no visible {s}{s} or ownership transfer",
                .{
                    binding_name,
                    resource.acquisition,
                    resource.release,
                    if (resource.alternative_release) |alternative| try std.fmt.allocPrint(allocator, "/{s}", .{alternative}) else "",
                },
            ),
        });
    }

    for (tokens, 0..) |token, lock_index| {
        if (!tokenIs(source, token, "lock") or lock_index < 2 or lock_index + 2 >= tokens.len or
            tokens[lock_index - 1].tag != .period or tokens[lock_index - 2].tag != .identifier or
            tokens[lock_index + 1].tag != .l_paren or tokens[lock_index + 2].tag != .r_paren) continue;
        // A bound result means this is a guard-style lock, not std's void-returning Mutex.lock.
        var receiver_start = lock_index - 2;
        while (receiver_start >= 2 and tokens[receiver_start - 1].tag == .period and
            tokens[receiver_start - 2].tag == .identifier) receiver_start -= 2;
        if (receiver_start > 0 and tokens[receiver_start - 1].tag == .equal) continue;
        const scope_end = enclosingScopeEnd(tokens, lock_index) orelse continue;
        const receiver = tokenText(source, tokens[lock_index - 2]);
        if (bindingHasRelease(source, tokens, receiver, lock_index + 3, scope_end, "unlock", null)) continue;
        const scope_opening = matchingOpeningToken(tokens, scope_end, .l_brace, .r_brace) orelse continue;
        if (bindingHasRelease(source, tokens, receiver, scope_opening + 1, lock_index, "unlock", null)) continue;
        if (lockCleanupIsPublicContract(source, tokens, lock_index, scope_end)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "mutex '{s}' is locked without a visible unlock before leaving this scope", .{receiver}),
        });
    }
}

fn lockCleanupIsPublicContract(source: []const u8, tokens: []const std.zig.Token, index: usize, scope_end: usize) bool {
    const closing = enclosingScopeEnd(tokens, index) orelse return false;
    const opening = matchingOpeningToken(tokens, closing, .l_brace, .r_brace) orelse return false;
    var cursor = opening;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_fn => {
                if (cursor == 0 or tokens[cursor - 1].tag != .keyword_pub or cursor + 1 >= tokens.len or
                    tokens[cursor + 1].tag != .identifier) return false;
                const function_name = tokenText(source, tokens[cursor + 1]);
                if (std.mem.startsWith(u8, function_name, "lock")) return true;
                for (tokens[index + 1 .. scope_end]) |token| if (token.tag == .keyword_return) return true;
                return false;
            },
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn initializerNamesManagedResource(
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
) bool {
    const managed_types = [_][]const u8{
        "ArrayList",
        "ArrayHashMap",
        "AutoHashMap",
        "StringHashMap",
        "ArenaAllocator",
        "GeneralPurposeAllocator",
    };
    for (managed_types) |type_name| {
        if (tokensBeforeContain(source, tokens, start, end, type_name)) return true;
    }
    return false;
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

fn bindingHasRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
    release: []const u8,
    alternative_release: ?[]const u8,
) bool {
    var index = start;
    while (index + 3 < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name) or tokens[index + 1].tag != .period or
            tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .l_paren) continue;
        const method = tokenText(source, tokens[index + 2]);
        if (std.mem.eql(u8, method, release)) return true;
        if (alternative_release) |alternative| if (std.mem.eql(u8, method, alternative)) return true;
    }
    return false;
}

fn bindingObviouslyEscapes(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return) {
            const return_end = statementEnd(tokens, index) orelse continue;
            for (tokens[index + 1 .. @min(return_end, end)]) |return_token| {
                if (tokenIs(source, return_token, binding_name)) return true;
            }
        }
        if (token.tag != .l_paren or index == 0) continue;
        const closing = matchingToken(tokens, index, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        for (tokens[index + 1 .. closing]) |argument_token| {
            if (tokenIs(source, argument_token, binding_name)) return true;
        }
    }
    var index = start;
    while (index < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name)) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_return) return true;
        if (index > 0 and tokens[index - 1].tag == .equal) return true;
    }
    return false;
}

fn findUndefinedValueEscapes(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.undefined_value_escape);
    if (level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier) continue;
        const statement_end = statementEnd(tokens, declaration_index) orelse continue;
        var undefined_index: ?usize = null;
        for (tokens[declaration_index + 2 .. statement_end], declaration_index + 2..) |initializer_token, index| {
            if (tokenIs(source, initializer_token, "undefined")) {
                undefined_index = index;
                break;
            }
        }
        if (undefined_index == null) continue;
        var type_contains_array = false;
        for (tokens[declaration_index + 2 .. undefined_index.?]) |type_token| {
            if (type_token.tag == .l_bracket) type_contains_array = true;
        }
        if (type_contains_array) continue;
        const binding_name = tokenText(source, tokens[declaration_index + 1]);
        const binding_index = declaration_index + 1;
        const scope_end = enclosingScopeEnd(tokens, declaration_index) orelse continue;
        var index = statement_end + 1;
        while (index < scope_end and index < tokens.len) : (index += 1) {
            if (!tokenIs(source, tokens[index], binding_name)) continue;
            if (index > 0 and tokens[index - 1].tag == .period) continue;
            const visible_binding = scope_index.findBinding(index) orelse continue;
            if (visible_binding.token_index != binding_index) continue;
            if (index > 0 and (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var) or
                identifierIsCaptureBinding(tokens, index))
            {
                index = enclosingScopeEnd(tokens, index) orelse index;
                continue;
            }
            if (usedByTypeQuery(source, tokens, index) or useBelongsToErrdefer(tokens, index)) continue;
            if (index + 1 < tokens.len and tokens[index + 1].tag == .equal) break;
            if (identifierIsDestructuredAssignmentTarget(tokens, index)) break;
            if (index > 0 and tokens[index - 1].tag == .ampersand or usedByAssembly(tokens, index)) break;
            if (usedByFieldMutation(source, tokens, index)) break;
            if (index + 2 < tokens.len and tokens[index + 1].tag == .period and
                tokens[index + 2].tag == .identifier) break;
            if (index + 3 < tokens.len and tokens[index + 1].tag == .period and
                tokens[index + 3].tag == .equal) break;
            if (index + 1 < tokens.len and tokens[index + 1].tag == .l_bracket) {
                const closing = matchingToken(tokens, index + 1, .l_bracket, .r_bracket) orelse continue;
                if (closing + 1 < tokens.len and tokens[closing + 1].tag == .equal) break;
                break;
            }
            try addFinding(allocator, source, configuration, found, .{
                .rule = .undefined_value_escape,
                .level = level,
                .span = tokens[index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "value '{s}' initialized with undefined is read or escapes before whole-value initialization",
                    .{binding_name},
                ),
            });
            break;
        }
    }
}

fn usedByTypeQuery(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index < 2 or tokens[use_index - 1].tag != .l_paren or tokens[use_index - 2].tag != .builtin) return false;
    return tokenIs(source, tokens[use_index - 2], "@TypeOf") or tokenIs(source, tokens[use_index - 2], "@typeInfo");
}

fn useBelongsToErrdefer(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    var braces: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => braces += 1,
            .l_brace => braces -|= 1,
            .keyword_errdefer => return true,
            .semicolon => if (braces == 0) return false,
            .keyword_fn, .keyword_test => return false,
            else => {},
        }
    }
    return false;
}

fn statementEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parentheses: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    for (tokens[start..], start..) |token, index| {
        switch (token.tag) {
            .l_paren => parentheses += 1,
            .r_paren => parentheses -|= 1,
            .l_bracket => brackets += 1,
            .r_bracket => brackets -|= 1,
            .l_brace => braces += 1,
            .r_brace => {
                if (braces == 0) return null;
                braces -= 1;
            },
            .semicolon => if (parentheses == 0 and brackets == 0 and braces == 0) return index,
            else => {},
        }
    }
    return null;
}

fn findBooleanComparisons(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.redundant_bool_comparison);
    if (level == .off) return;
    for (tokens, 0..) |operator, index| {
        if (index == 0 or index + 1 >= tokens.len) continue;
        if (operator.tag != .equal_equal and operator.tag != .bang_equal) continue;
        const left = tokens[index - 1];
        const right = tokens[index + 1];
        if (left.tag != .identifier or right.tag != .identifier) continue;
        const left_text = tokenText(source, left);
        const right_text = tokenText(source, right);
        const operand_index, const literal = if (isBooleanLiteral(right_text))
            .{ index - 1, right }
        else if (isBooleanLiteral(left_text))
            .{ index + 1, left }
        else
            continue;
        const operand = tokens[operand_index];
        const literal_text = tokenText(source, literal);
        const operand_name = tokenText(source, operand);
        if (!indexedBindingHasType(source, tokens, scope_index, operand_index, "bool")) continue;
        const equal_to_true = (operator.tag == .equal_equal) == std.mem.eql(u8, literal_text, "true");
        const replacement = if (equal_to_true)
            try allocator.dupe(u8, operand_name)
        else
            try std.fmt.allocPrint(allocator, "!{s}", .{operand_name});
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{ .span = .{ .start = left.loc.start, .end = right.loc.end }, .replacement = replacement };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = "Simplify boolean comparison",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .redundant_bool_comparison,
            .level = level,
            .span = operator.loc,
            .message = try std.fmt.allocPrint(allocator, "comparison of bool '{s}' with '{s}' is redundant", .{ operand_name, literal_text }),
            .fixes = fixes,
        });
    }
}

fn isBooleanLiteral(name: []const u8) bool {
    return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
}

fn findErrorValueComparisons(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.error_value_comparison);
    if (level == .off) return;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const tag = tree.nodeTag(node);
        if (tag != .equal_equal and tag != .bang_equal) continue;
        const left, const right = tree.nodeData(node).node_and_node;
        const error_value = if (tree.nodeTag(left) == .error_value)
            left
        else if (tree.nodeTag(right) == .error_value)
            right
        else
            continue;
        const operator_index: usize = tree.nodeMainToken(node);
        if (operator_index >= tokens.len) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .error_value_comparison,
            .level = level,
            .span = tokens[operator_index].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "comparison with '{s}' can widen the error set; use switch to preserve exhaustive checking",
                .{tree.getNodeSource(error_value)},
            ),
        });
    }
}

fn findMixedBitwiseArithmetic(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.mixed_bitwise_arithmetic);
    if (level == .off) return;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const parent_tag = tree.nodeTag(node);
        if (!isBitwiseOperator(parent_tag) and !isArithmeticOperator(parent_tag)) continue;
        const left, const right = tree.nodeData(node).node_and_node;
        for ([_]std.zig.Ast.Node.Index{ left, right }) |child| {
            const child_tag = tree.nodeTag(child);
            const mixes_families = isBitwiseOperator(parent_tag) and isArithmeticOperator(child_tag) or
                isArithmeticOperator(parent_tag) and isBitwiseOperator(child_tag);
            if (!mixes_families) continue;
            const first_token: usize = tree.firstToken(child);
            const last_token: usize = tree.lastToken(child);
            const operator_index: usize = tree.nodeMainToken(node);
            if (first_token >= tokens.len or last_token >= tokens.len or operator_index >= tokens.len) continue;
            const child_span = std.zig.Token.Loc{
                .start = tokens[first_token].loc.start,
                .end = tokens[last_token].loc.end,
            };
            const edits = try allocator.alloc(Edit, 1);
            edits[0] = .{
                .span = child_span,
                .replacement = try std.fmt.allocPrint(allocator, "({s})", .{source[child_span.start..child_span.end]}),
            };
            const fixes = try allocator.alloc(Fix, 1);
            fixes[0] = .{
                .title = "Parenthesize mixed operator expression",
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
            };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .mixed_bitwise_arithmetic,
                .level = level,
                .span = tokens[operator_index].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "bitwise operator '{s}' and arithmetic operator '{s}' are mixed without parentheses",
                    .{
                        if (isBitwiseOperator(parent_tag)) tree.tokenSlice(tree.nodeMainToken(node)) else tree.tokenSlice(tree.nodeMainToken(child)),
                        if (isArithmeticOperator(parent_tag)) tree.tokenSlice(tree.nodeMainToken(node)) else tree.tokenSlice(tree.nodeMainToken(child)),
                    },
                ),
                .fixes = fixes,
            });
        }
    }
}

fn isBitwiseOperator(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .shl, .shl_sat, .shr, .bit_xor, .bit_or, .bit_and => true,
        else => false,
    };
}

fn isArithmeticOperator(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .add,
        .add_sat,
        .add_wrap,
        .sub,
        .sub_sat,
        .sub_wrap,
        .mul,
        .mul_sat,
        .mul_wrap,
        .div,
        .mod,
        => true,
        else => false,
    };
}

const PrivateDeclaration = struct {
    name_index: usize,
    kind: enum { constant, function },
};

fn findUnusedPrivateDeclarations(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unused_private_declaration);
    if (level == .off) return;
    var declarations: std.ArrayList(PrivateDeclaration) = .empty;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.fullVarDecl(node)) |declaration| {
            const keyword_index: usize = declaration.ast.mut_token;
            if (keyword_index >= tokens.len or tokens[keyword_index].tag != .keyword_const or
                keyword_index + 1 >= tokens.len or tokens[keyword_index + 1].tag != .identifier or
                !declarationIsPrivate(tokens, keyword_index) or insideFunctionOrTestBody(tokens, keyword_index)) continue;
            try declarations.append(allocator, .{ .name_index = keyword_index + 1, .kind = .constant });
            continue;
        }
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        const keyword_index: usize = function.ast.fn_token;
        if (keyword_index + 1 >= tokens.len or tokens[keyword_index + 1].tag != .identifier or
            !declarationIsPrivate(tokens, keyword_index)) continue;
        try declarations.append(allocator, .{ .name_index = keyword_index + 1, .kind = .function });
    }
    if (declarations.items.len == 0) return;
    var occurrence_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer occurrence_counts.deinit(allocator);
    for (tokens) |token| {
        const entry = try occurrence_counts.getOrPutValue(allocator, tokenText(source, token), 0);
        entry.value_ptr.* += 1;
    }
    var reflected_names = try collectReflectedNames(allocator, source, tokens);
    defer reflected_names.names.deinit(allocator);
    if (reflected_names.wildcard) return;
    for (declarations.items) |declaration| {
        const name_token = tokens[declaration.name_index];
        const name = tokenText(source, name_token);
        if (std.mem.eql(u8, name, "_") or std.mem.startsWith(u8, name, "@\"") or
            isImplicitDeclarationName(name) or (occurrence_counts.get(name) orelse 0) != 1 or
            reflected_names.names.contains(name)) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .unused_private_declaration,
            .level = level,
            .span = name_token.loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "private {s} '{s}' is never referenced",
                .{ @tagName(declaration.kind), name },
            ),
            .fixes = try unusedDeclarationFixes(allocator, source, tokens, declaration),
        });
    }
}

fn unusedDeclarationFixes(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    declaration: PrivateDeclaration,
) ![]const Fix {
    const keyword_index = declaration.name_index - 1;
    var declaration_start = keyword_index;
    while (declaration_start > 0) {
        switch (tokens[declaration_start - 1].tag) {
            .keyword_inline, .keyword_noinline, .keyword_comptime, .keyword_threadlocal => declaration_start -= 1,
            else => break,
        }
    }
    const last_index: ?usize = switch (declaration.kind) {
        .constant => statementEnd(tokens, keyword_index),
        .function => end: {
            if (declaration.name_index + 1 >= tokens.len or tokens[declaration.name_index + 1].tag != .l_paren) break :end null;
            const parameters_end = matchingToken(tokens, declaration.name_index + 1, .l_paren, .r_paren) orelse break :end null;
            var body_open = parameters_end + 1;
            while (body_open < tokens.len and tokens[body_open].tag != .l_brace and tokens[body_open].tag != .semicolon) : (body_open += 1) {}
            if (body_open >= tokens.len or tokens[body_open].tag != .l_brace) break :end null;
            break :end matchingToken(tokens, body_open, .l_brace, .r_brace);
        },
    };
    const end_index = last_index orelse return &.{};
    const declaration_span = std.zig.Token.Loc{
        .start = lineStart(source, tokens[declaration_start].loc.start),
        .end = lineEnd(source, tokens[end_index].loc.end),
    };
    if (attachedCommentStart(source, declaration_span.start) != declaration_span.start) return &.{};
    const edits = try allocator.alloc(Edit, 1);
    edits[0] = .{ .span = declaration_span, .replacement = "" };
    const fixes = try allocator.alloc(Fix, 1);
    fixes[0] = .{ .title = "Remove unused declaration", .kind = .quickfix, .edits = edits };
    return fixes;
}

fn declarationIsPrivate(tokens: []const std.zig.Token, keyword_index: usize) bool {
    var cursor = keyword_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_pub, .keyword_export, .keyword_extern => return false,
            .keyword_inline,
            .keyword_noinline,
            .keyword_comptime,
            .keyword_threadlocal,
            .doc_comment,
            .container_doc_comment,
            => {},
            else => return true,
        }
    }
    return true;
}

fn isImplicitDeclarationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "main") or std.mem.eql(u8, name, "panic") or
        std.mem.eql(u8, name, "test_runner");
}

const ReflectedNames = struct {
    /// A reflection call whose name argument is not a plain string literal may
    /// reference any declaration.
    wildcard: bool,
    names: std.StringHashMapUnmanaged(void),
};

fn collectReflectedNames(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) !ReflectedNames {
    var collected: ReflectedNames = .{ .wildcard = false, .names = .empty };
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or
            (!tokenIs(source, token, "@field") and !tokenIs(source, token, "@hasDecl") and
                !tokenIs(source, token, "@hasField"))) continue;
        if (index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) {
            collected.wildcard = true;
            return collected;
        }
        const closing = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse {
            collected.wildcard = true;
            return collected;
        };
        var comma: ?usize = null;
        var depth: usize = 0;
        for (tokens[index + 2 .. closing], index + 2..) |argument_token, argument_index| {
            switch (argument_token.tag) {
                .l_paren, .l_brace, .l_bracket => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -|= 1,
                .comma => if (depth == 0) {
                    comma = argument_index;
                    break;
                },
                else => {},
            }
        }
        const name_index = (comma orelse {
            collected.wildcard = true;
            return collected;
        }) + 1;
        if (name_index >= closing or tokens[name_index].tag != .string_literal) {
            collected.wildcard = true;
            return collected;
        }
        const literal = tokenText(source, tokens[name_index]);
        if (literal.len >= 2) try collected.names.put(allocator, literal[1 .. literal.len - 1], {});
    }
    return collected;
}

fn indexedBindingHasType(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    receiver_index: usize,
    type_name: []const u8,
) bool {
    const visible_binding = scope_index.findBinding(receiver_index) orelse return false;
    const index = visible_binding.token_index;
    if (index + 2 >= tokens.len or tokens[index + 1].tag != .colon or
        !tokenIs(source, tokens[index + 2], type_name)) return false;
    return index + 3 >= tokens.len or tokens[index + 3].tag != .period;
}

fn collectContainers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
) ![]Container {
    var containers: std.ArrayList(Container) = .empty;
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
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unknown_comptime_member);
    if (level == .off) return;
    for (tokens, 0..) |token, builtin_index| {
        if (token.tag != .builtin or
            (!tokenIs(source, token, "@field") and !tokenIs(source, token, "@hasField") and
                !tokenIs(source, token, "@hasDecl"))) continue;
        if (builtin_index + 5 >= tokens.len or tokens[builtin_index + 1].tag != .l_paren or
            tokens[builtin_index + 2].tag != .identifier or tokens[builtin_index + 3].tag != .comma or
            tokens[builtin_index + 4].tag != .string_literal or tokens[builtin_index + 5].tag != .r_paren) continue;
        const type_name = tokenText(source, tokens[builtin_index + 2]);
        const container = containerForReceiver(source, tokens, containers, scope_index, type_name, builtin_index + 2) orelse continue;
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
                field_lookup and containerHasDeclaration(source, tokens, container.name, member_name)
        else
            containerHasDeclaration(source, tokens, container.name, member_name);
        if (exists) continue;
        const message = if (field_lookup)
            try std.fmt.allocPrint(
                allocator,
                "{s} cannot resolve member '{s}' on type '{s}' in this analyzed shape",
                .{ tokenText(source, token), member_name, container.name },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "{s} is always false: type '{s}' has no member named '{s}' in this analyzed shape",
                .{ tokenText(source, token), container.name, member_name },
            );
        try addFinding(allocator, source, configuration, found, .{
            .rule = .unknown_comptime_member,
            .level = level,
            .span = tokens[builtin_index + 4].loc,
            .message = message,
        });
    }
}

fn containerHasField(container: Container, name: []const u8) bool {
    for (container.fields) |field| if (std.mem.eql(u8, field.name, name)) return true;
    return false;
}

fn containerHasDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    container_name: []const u8,
    declaration_name: []const u8,
) bool {
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 4 >= tokens.len or
            !tokenIs(source, tokens[index + 1], container_name) or tokens[index + 2].tag != .equal) continue;
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
                    tokenIs(source, tokens[member_index + 1], declaration_name)) return true,
                else => {},
            }
        }
    }
    return false;
}

fn findConstantComptimeConditions(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.constant_comptime_condition);
    if (level == .off) return;
    for (tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 2 >= tokens.len or tokens[if_index + 1].tag != .l_paren) continue;
        const explicitly_comptime = if_index > 0 and tokens[if_index - 1].tag == .keyword_comptime;
        const condition_index = if (tokens[if_index + 2].tag == .keyword_comptime) if_index + 3 else if_index + 2;
        if (condition_index >= tokens.len or (!explicitly_comptime and tokens[if_index + 2].tag != .keyword_comptime)) continue;
        if (!tokenIs(source, tokens[condition_index], "true") and !tokenIs(source, tokens[condition_index], "false")) continue;
        try addFinding(allocator, source, configuration, found, .{
            .rule = .constant_comptime_condition,
            .level = level,
            .span = tokens[condition_index].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "comptime condition is always {s}; the other branch is inactive in this configuration",
                .{tokenText(source, tokens[condition_index])},
            ),
        });
    }
}

fn findSwitches(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    if (configuration.level(.missing_switch_prong) == .off and
        configuration.level(.non_exhaustive_switch_else) == .off and
        configuration.level(.non_exhaustive_error_switch) == .off) return;
    var declaration_sites = try collectBindingDeclarationSites(allocator, source, tokens);
    defer {
        var site_lists = declaration_sites.valueIterator();
        while (site_lists.next()) |list| list.deinit(allocator);
        declaration_sites.deinit(allocator);
    }
    var return_types = try collectFunctionReturnTypes(allocator, source, tokens);
    defer return_types.deinit(allocator);
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
        const container = containerNamed(containers, scope_index, type_name, switch_index) orelse continue;
        if (container.kind == .structure) continue;

        var missing: std.ArrayList([]const u8) = .empty;
        var else_index: ?usize = null;
        for (container.fields) |field| {
            // '_' marks a non-exhaustive enum, not a nameable case; '._ =>' does not compile.
            if (std.mem.eql(u8, field.name, "_")) continue;
            if (!switchContainsCase(source, tokens, opening, closing, field.name)) try missing.append(allocator, field.name);
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
            const level = configuration.level(.non_exhaustive_error_switch);
            if (level == .off) continue;
            const fixes: []const Fix = if (else_index) |index| fixes: {
                if (!elseCaptureCanBePreserved(tokens, index, closing)) break :fixes &.{};
                const replacement = try errorCaseSelectorText(allocator, missing.items);
                const edits = try allocator.alloc(Edit, 1);
                edits[0] = .{ .span = tokens[index].loc, .replacement = replacement };
                const allocated = try allocator.alloc(Fix, 1);
                allocated[0] = .{
                    .title = "Expand else into remaining error cases",
                    .kind = .refactor_rewrite,
                    .edits = edits,
                };
                break :fixes allocated;
            } else fixes: {
                const insertion = try errorSwitchProngText(allocator, source, tokens[closing].loc.start, missing.items);
                const edits = try allocator.alloc(Edit, 1);
                edits[0] = .{ .span = .{ .start = tokens[closing].loc.start, .end = tokens[closing].loc.start }, .replacement = insertion };
                const allocated = try allocator.alloc(Fix, 1);
                allocated[0] = .{
                    .title = "Fill missing error switch prongs",
                    .kind = .quickfix,
                    .edits = edits,
                };
                break :fixes allocated;
            };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .non_exhaustive_error_switch,
                .level = level,
                .span = if (else_index) |index| tokens[index].loc else token.loc,
                .message = try missingMessage(allocator, "switch does not name every error in", container.name, missing.items),
                .fixes = fixes,
            });
            continue;
        }
        if (else_index) |index| {
            const level = configuration.level(.non_exhaustive_switch_else);
            if (level == .off) continue;
            const fixes: []const Fix = if (elseCaptureCanBePreserved(tokens, index, closing)) fixes: {
                const replacement = try caseSelectorText(allocator, missing.items);
                const edits = try allocator.alloc(Edit, 1);
                edits[0] = .{ .span = tokens[index].loc, .replacement = replacement };
                const allocated = try allocator.alloc(Fix, 1);
                allocated[0] = .{
                    .title = "Expand else into remaining switch cases",
                    .kind = .refactor_rewrite,
                    .edits = edits,
                };
                break :fixes allocated;
            } else &.{};
            try addFinding(allocator, source, configuration, found, .{
                .rule = .non_exhaustive_switch_else,
                .level = level,
                .span = tokens[index].loc,
                .message = try missingMessage(allocator, "switch uses else instead of explicit cases for type", container.name, missing.items),
                .fixes = fixes,
            });
            continue;
        }

        const level = configuration.level(.missing_switch_prong);
        if (level == .off) continue;
        const insertion = try switchProngText(allocator, source, tokens[closing].loc.start, missing.items);
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{ .span = .{ .start = tokens[closing].loc.start, .end = tokens[closing].loc.start }, .replacement = insertion };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = "Fill missing switch prongs",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .missing_switch_prong,
            .level = level,
            .span = token.loc,
            .message = try missingMessage(allocator, "switch is missing cases for type", container.name, missing.items),
            .fixes = fixes,
        });
    }
}

const BindingDeclarationSites = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize));
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
            if (!std.mem.eql(u8, container.name, name) or !scopeContains(container.scope, use_index)) continue;
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
        if (std.mem.eql(u8, container.name, name)) return true;
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
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    containers: []const Container,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.missing_struct_field);
    if (level == .off) return;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const initializer = tree.fullStructInit(&buffer, node) orelse continue;
        const opening: usize = initializer.ast.lbrace;
        if (opening >= tokens.len) continue;
        const type_token_index = if (initializer.ast.type_expr.unwrap()) |type_expression| type: {
            if (tree.nodeTag(type_expression) != .identifier) continue;
            break :type @as(usize, tree.nodeMainToken(type_expression));
        } else type: {
            if (opening == 0 or tokens[opening - 1].tag != .period) continue;
            break :type directlyTypedInitializerType(tokens, opening - 1) orelse continue;
        };
        if (type_token_index >= tokens.len or tokens[type_token_index].tag != .identifier) continue;
        const type_name = tokenText(source, tokens[type_token_index]);
        const container = containerNamed(containers, scope_index, type_name, type_token_index) orelse continue;
        if (container.kind != .structure) continue;
        const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse continue;
        var missing: std.ArrayList([]const u8) = .empty;
        for (container.fields) |field| {
            if (!field.required or initializerContainsField(source, tokens, opening, closing, field.name)) continue;
            try missing.append(allocator, field.name);
        }
        if (missing.items.len == 0) continue;
        const insertion = try structFieldText(allocator, source, tokens[closing].loc.start, missing.items);
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{ .span = .{ .start = tokens[closing].loc.start, .end = tokens[closing].loc.start }, .replacement = insertion };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = "Fill missing struct fields",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .missing_struct_field,
            .level = level,
            .span = tokens[type_token_index].loc,
            .message = try missingMessage(allocator, "initializer is missing fields for type", container.name, missing.items),
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

fn findNeedlessCasts(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.needless_cast);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .builtin or !tokenIs(source, token, "@as") or index + 5 >= tokens.len) continue;
        if (tokens[index + 1].tag != .l_paren or tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .comma) continue;
        const outer_close = matchingToken(tokens, index + 1, .l_paren, .r_paren) orelse continue;
        const type_name = tokenText(source, tokens[index + 2]);
        var replacement: []const u8 = undefined;
        var message: []const u8 = undefined;
        if (tokenIs(source, tokens[index + 4], "@as") and tokens[index + 5].tag == .l_paren and index + 7 < tokens.len and
            tokens[index + 6].tag == .identifier and tokens[index + 7].tag == .comma and
            std.mem.eql(u8, type_name, tokenText(source, tokens[index + 6])))
        {
            const inner_close = matchingToken(tokens, index + 5, .l_paren, .r_paren) orelse continue;
            if (inner_close + 1 != outer_close) continue;
            replacement = source[tokens[index + 4].loc.start..tokens[inner_close].loc.end];
            message = try std.fmt.allocPrint(allocator, "nested cast to '{s}' repeats the same proven type", .{type_name});
        } else if (tokens[index + 4].tag == .identifier and index + 5 == outer_close and
            indexedBindingHasType(source, tokens, scope_index, index + 4, type_name))
        {
            replacement = tokenText(source, tokens[index + 4]);
            message = try std.fmt.allocPrint(
                allocator,
                "cast of '{s}' to its proven type '{s}' is unnecessary",
                .{ replacement, type_name },
            );
        } else continue;
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{
            .span = .{ .start = token.loc.start, .end = tokens[outer_close].loc.end },
            .replacement = replacement,
        };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Remove redundant cast", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .needless_cast,
            .level = level,
            .span = token.loc,
            .message = message,
            .fixes = fixes,
        });
    }
}

fn findNeedlessElse(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.needless_else_after_terminator);
    if (level == .off) return;
    for (tokens, 0..) |token, else_index| {
        if (token.tag != .keyword_else or else_index == 0 or else_index + 1 >= tokens.len or tokens[else_index + 1].tag != .l_brace) continue;
        if (tokens[else_index - 1].tag != .r_brace) continue;
        const preceding_open = matchingOpeningToken(tokens, else_index - 1, .l_brace, .r_brace) orelse continue;
        // A loop's else runs when the loop exits without break, so it is never removable.
        if (!precedingBlockIsIfStatement(tokens, preceding_open)) continue;
        if (blockBelongsToElseIf(tokens, preceding_open)) continue;
        if (!blockAlwaysTerminates(tokens, preceding_open, else_index - 1)) continue;
        const else_close = matchingToken(tokens, else_index + 1, .l_brace, .r_brace) orelse continue;
        const edits = try allocator.alloc(Edit, 2);
        edits[0] = .{ .span = .{ .start = token.loc.start, .end = tokens[else_index + 1].loc.end }, .replacement = "" };
        edits[1] = .{ .span = tokens[else_close].loc, .replacement = "" };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Flatten else after terminating branch", .kind = .quickfix, .edits = edits, .preferred = true };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .needless_else_after_terminator,
            .level = level,
            .span = token.loc,
            .message = try allocator.dupe(u8, "else is unnecessary because the preceding branch always terminates"),
            .fixes = fixes,
        });
    }
}

fn precedingBlockIsIfStatement(tokens: []const std.zig.Token, opening: usize) bool {
    const condition_open = ifConditionOpenForBlock(tokens, opening) orelse return false;
    if (condition_open < 2) return false;
    return switch (tokens[condition_open - 2].tag) {
        .l_brace, .r_brace, .semicolon => true,
        else => false,
    };
}

fn blockBelongsToElseIf(tokens: []const std.zig.Token, opening: usize) bool {
    const condition_open = ifConditionOpenForBlock(tokens, opening) orelse return false;
    return condition_open >= 2 and tokens[condition_open - 2].tag == .keyword_else;
}

fn ifConditionOpenForBlock(tokens: []const std.zig.Token, opening: usize) ?usize {
    var cursor = opening;
    if (cursor > 0 and tokens[cursor - 1].tag == .pipe) {
        cursor -= 1;
        while (cursor > 0 and tokens[cursor - 1].tag != .pipe) cursor -= 1;
        if (cursor == 0) return null;
        cursor -= 1;
    }
    if (cursor == 0 or tokens[cursor - 1].tag != .r_paren) return null;
    const condition_open = matchingOpeningToken(tokens, cursor - 1, .l_paren, .r_paren) orelse return null;
    if (condition_open == 0 or tokens[condition_open - 1].tag != .keyword_if) return null;
    return condition_open;
}

fn blockAlwaysTerminates(tokens: []const std.zig.Token, opening: usize, closing: usize) bool {
    // Only the last statement decides: a terminator earlier in the block (for
    // example 'orelse unreachable' in its first line) does not end the branch.
    if (closing <= opening + 1) return false;
    if (tokens[closing - 1].tag != .semicolon) return false;
    var depth: usize = 0;
    var cursor = closing - 1;
    var statement_start = opening + 1;
    while (cursor > opening + 1) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace, .r_paren, .r_bracket => depth += 1,
            .l_brace, .l_paren, .l_bracket => {
                if (depth == 0) {
                    statement_start = cursor + 1;
                    break;
                }
                depth -= 1;
            },
            .semicolon => if (depth == 0) {
                statement_start = cursor + 1;
                break;
            },
            else => {},
        }
    }
    return switch (tokens[statement_start].tag) {
        .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => true,
        else => false,
    };
}

fn findNonIdiomaticNames(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    tree: *const std.zig.Ast,
    resolved_shapes: []const ResolvedShape,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.non_idiomatic_name);
    if (level == .off) return;
    const foreign_binding_dominated = fileIsDominatedByForeignBindings(source, tokens);
    var type_declaring_names: std.StringHashMapUnmanaged(void) = .empty;
    defer type_declaring_names.deinit(allocator);
    var structural_type_declarations: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer structural_type_declarations.deinit(allocator);
    var value_declarations: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer value_declarations.deinit(allocator);
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const initializer = declaration.ast.init_node.unwrap() orelse continue;
        const keyword_index: usize = declaration.ast.mut_token;
        if (keyword_index + 1 >= tokens.len or tokens[keyword_index].tag != .keyword_const or
            tokens[keyword_index + 1].tag != .identifier) continue;
        if (nodeIsTypeExpression(tree, initializer)) {
            try structural_type_declarations.put(allocator, keyword_index + 1, {});
        } else if (nodeIsValueExpression(tree, initializer)) {
            try value_declarations.put(allocator, keyword_index + 1, {});
        }
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index == 0) continue;
        const declares_type = switch (tokens[index - 1].tag) {
            .keyword_const => declarationInitializesType(tokens, index),
            .keyword_fn => functionDeclarationReturnsType(source, tokens, index),
            else => false,
        };
        if (declares_type) try type_declaring_names.put(allocator, tokenText(source, token), {});
        if (tokens[index - 1].tag == .keyword_comptime and index + 2 < tokens.len and tokens[index + 1].tag == .colon and
            tokenIs(source, tokens[index + 2], "type"))
        {
            try type_declaring_names.put(allocator, tokenText(source, token), {});
        }
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index == 0) continue;
        const declaration_tag = tokens[index - 1].tag;
        if (declaration_tag != .keyword_fn and declaration_tag != .keyword_const and declaration_tag != .keyword_var) continue;
        if (!identifierIsDeclaration(tokens, index)) continue;
        if (index >= 2 and (tokens[index - 2].tag == .keyword_extern or tokens[index - 2].tag == .keyword_export)) continue;
        // 'extern "lib" fn name(...)' binds an ABI symbol whose name is fixed.
        if (index >= 3 and tokens[index - 2].tag == .string_literal and tokens[index - 3].tag == .keyword_extern) continue;
        if (declaration_tag == .keyword_const and declarationInitializedByExternBuiltin(source, tokens, index)) continue;
        if (foreign_binding_dominated and declaration_tag == .keyword_const and declarationHasLiteralInitializer(tokens, index)) continue;
        if (declaration_tag == .keyword_const and declarationIsSameNameAlias(source, tokens, index)) continue;
        const name = tokenText(source, token);
        if (std.mem.startsWith(u8, name, "@\"")) continue;
        const is_namespace = declaration_tag == .keyword_const and
            (declarationIsNamespace(tokens, index) or declarationIsBareImport(source, tokens, index));
        const is_type = declaration_tag == .keyword_const and
            (structural_type_declarations.contains(index) or
                (!insideFunctionOrTestBody(tokens, index) and resolvedShapeNamesType(name, resolved_shapes)) or
                declarationNamesType(source, tokens, index, &type_declaring_names));
        const type_function = declaration_tag == .keyword_fn and functionDeclarationReturnsType(source, tokens, index);
        if (declaration_tag == .keyword_const and !is_namespace and !is_type and
            !value_declarations.contains(index)) continue;
        const idiomatic = if (is_namespace)
            isSnakeCase(name) or isTitleCase(name)
        else if (type_function or is_type)
            isTitleCase(name)
        else if (declaration_tag == .keyword_fn)
            isCamelCase(name)
        else
            isSnakeCase(name);
        if (idiomatic) continue;
        const convention = if (is_namespace)
            "snake_case or TitleCase"
        else if (type_function or is_type)
            "TitleCase"
        else if (declaration_tag == .keyword_fn)
            "camelCase"
        else
            "snake_case";
        try addFinding(allocator, source, configuration, found, .{
            .rule = .non_idiomatic_name,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "declaration '{s}' does not follow Zig's {s} naming convention", .{ name, convention }),
        });
    }
}

fn nodeIsValueExpression(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .enum_literal,
        .string_literal,
        .multiline_string_literal,
        .error_value,
        .anyframe_literal,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => true,
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or
                std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined");
        },
        else => false,
    };
}

fn resolvedShapeNamesType(name: []const u8, resolved_shapes: []const ResolvedShape) bool {
    for (resolved_shapes) |shape| if (std.mem.eql(u8, name, shape.type_name)) return true;
    return false;
}

fn nodeIsTypeExpression(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .optional_type,
        .array_type,
        .array_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        .anyframe_type,
        .error_set_decl,
        .error_union,
        .merge_error_sets,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

fn declarationIsBareImport(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) bool {
    return identifier_index + 6 < tokens.len and tokens[identifier_index + 1].tag == .equal and
        tokens[identifier_index + 2].tag == .builtin and tokenIs(source, tokens[identifier_index + 2], "@import") and
        tokens[identifier_index + 3].tag == .l_paren and tokens[identifier_index + 4].tag == .string_literal and
        tokens[identifier_index + 5].tag == .r_paren and tokens[identifier_index + 6].tag == .semicolon;
}

fn declarationInitializedByExternBuiltin(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) bool {
    return identifier_index + 3 < tokens.len and tokens[identifier_index + 1].tag == .equal and
        tokens[identifier_index + 2].tag == .builtin and std.mem.eql(u8, tokenText(source, tokens[identifier_index + 2]), "@extern") and
        tokens[identifier_index + 3].tag == .l_paren;
}

fn declarationHasLiteralInitializer(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return false;
    return switch (tokens[identifier_index + 2].tag) {
        .number_literal, .string_literal, .char_literal => true,
        else => false,
    };
}

fn fileIsDominatedByForeignBindings(source: []const u8, tokens: []const std.zig.Token) bool {
    var declarations: usize = 0;
    var foreign_bindings: usize = 0;
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .keyword_fn, .keyword_const => if (brace_depth == 0 and index + 1 < tokens.len and
                tokens[index + 1].tag == .identifier and
                (token.tag != .keyword_const or (index + 2 < tokens.len and tokens[index + 2].tag == .equal)))
            {
                declarations += 1;
                const externally_named = (index > 0 and (tokens[index - 1].tag == .keyword_extern or tokens[index - 1].tag == .keyword_export)) or
                    (index > 1 and tokens[index - 1].tag == .string_literal and tokens[index - 2].tag == .keyword_extern) or
                    (token.tag == .keyword_const and index + 3 < tokens.len and tokens[index + 1].tag == .identifier and declarationInitializedByExternBuiltin(source, tokens, index + 1));
                if (externally_named) foreign_bindings += 1;
            },
            else => {},
        }
    }
    return declarations >= 10 and foreign_bindings * 5 >= declarations * 4;
}

fn declarationInitializesType(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return false;
    const initializer_index = if ((tokens[identifier_index + 2].tag == .keyword_extern or
        tokens[identifier_index + 2].tag == .keyword_packed) and identifier_index + 3 < tokens.len)
        identifier_index + 3
    else
        identifier_index + 2;
    return switch (tokens[initializer_index].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => type: {
            var opening = initializer_index + 1;
            while (opening < tokens.len and tokens[opening].tag != .l_brace and tokens[opening].tag != .semicolon) : (opening += 1) {}
            if (opening >= tokens.len or tokens[opening].tag != .l_brace) break :type false;
            const closing = matchingToken(tokens, opening, .l_brace, .r_brace) orelse break :type false;
            break :type closing + 1 < tokens.len and tokens[closing + 1].tag == .semicolon;
        },
        // 'error{...}' declares an error-set type; 'error.Name' is a value.
        .keyword_error => initializer_index + 1 < tokens.len and tokens[initializer_index + 1].tag == .l_brace,
        else => false,
    };
}

fn declarationNamesType(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
    type_declaring_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (declarationInitializesType(tokens, identifier_index)) return true;
    if (initializerMergesErrorSets(tokens, identifier_index)) return true;
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return false;
    const initializer_index = identifier_index + 2;
    if (tokens[initializer_index].tag == .asterisk and initializer_index + 2 < tokens.len and
        tokens[initializer_index + 1].tag == .keyword_const and tokens[initializer_index + 2].tag == .keyword_fn) return true;
    if (tokens[initializer_index].tag == .identifier) {
        const initializer = tokenText(source, tokens[initializer_index]);
        if (tokenNamesPrimitiveType(initializer)) return true;
    }
    if (identifier_index + 3 < tokens.len and tokens[identifier_index + 1].tag == .equal and
        tokens[identifier_index + 2].tag == .builtin and tokens[identifier_index + 3].tag == .l_paren)
    {
        const builtin_name = tokenText(source, tokens[identifier_index + 2]);
        const type_builtins = [_][]const u8{
            "@This", "@TypeOf", "@Type", "@Int", "@Enum", "@Union", "@Struct", "@Pointer", "@Array", "@Vector", "@Fn", "@Tuple", "@FieldType",
        };
        for (type_builtins) |name| if (std.mem.eql(u8, builtin_name, name)) return true;
        if (std.mem.eql(u8, builtin_name, "@import")) {
            const import_end = matchingToken(tokens, identifier_index + 3, .l_paren, .r_paren) orelse return false;
            var target_index = import_end;
            while (target_index + 2 < tokens.len and tokens[target_index + 1].tag == .period and
                tokens[target_index + 2].tag == .identifier)
            {
                target_index += 2;
            }
            if (target_index > import_end and target_index + 1 < tokens.len and isTitleCase(tokenText(source, tokens[target_index]))) {
                if (tokens[target_index + 1].tag == .semicolon) return true;
                if (tokens[target_index + 1].tag == .l_paren) {
                    const call_end = matchingToken(tokens, target_index + 1, .l_paren, .r_paren) orelse return false;
                    if (call_end + 1 < tokens.len and tokens[call_end + 1].tag == .semicolon) return true;
                }
            }
        }
    }
    const declaration_end = statementEnd(tokens, identifier_index) orelse return false;
    const declaration_name = tokenText(source, tokens[identifier_index]);
    const declares_error_type = std.mem.eql(u8, declaration_name, "Error") or std.mem.endsWith(u8, declaration_name, "Error");
    for (tokens[initializer_index..declaration_end], initializer_index..) |token, index| {
        const name = tokenText(source, token);
        if (std.mem.eql(u8, name, "error") and index + 1 < declaration_end and tokens[index + 1].tag == .l_brace) return true;
        if (declares_error_type and token.tag == .identifier and
            (std.mem.eql(u8, name, "Error") or std.mem.endsWith(u8, name, "Error"))) return true;
    }
    if (identifier_index + 3 < tokens.len and tokens[identifier_index + 1].tag == .equal and
        tokens[identifier_index + 2].tag == .builtin and
        tokenIs(source, tokens[identifier_index + 2], "@typeInfo"))
    {
        var cursor = identifier_index + 3;
        while (cursor < tokens.len and tokens[cursor].tag != .semicolon) : (cursor += 1) {
            if (tokens[cursor].tag != .identifier or cursor == 0 or tokens[cursor - 1].tag != .period) continue;
            const field_name = tokenText(source, tokens[cursor]);
            const type_fields = [_][]const u8{ "child", "payload", "error_set", "return_type", "tag_type" };
            for (type_fields) |type_field| if (std.mem.eql(u8, field_name, type_field)) return true;
        }
    }
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal or
        tokens[identifier_index + 2].tag != .identifier) return false;
    var target_index = identifier_index + 2;
    while (target_index + 2 < tokens.len and tokens[target_index + 1].tag == .period and
        tokens[target_index + 2].tag == .identifier)
    {
        target_index += 2;
    }
    if (target_index + 1 >= tokens.len) return false;
    const target = tokenText(source, tokens[target_index]);
    switch (tokens[target_index + 1].tag) {
        .semicolon => if (target_index != identifier_index + 2 and isTitleCase(target)) return true,
        .l_paren => {
            const call_end = matchingToken(tokens, target_index + 1, .l_paren, .r_paren) orelse return false;
            if (call_end + 1 >= tokens.len or tokens[call_end + 1].tag != .semicolon) return false;
            if (isTitleCase(target)) return true;
        },
        else => return false,
    }
    return type_declaring_names.contains(target);
}

/// '||' only merges error sets, so an initializer containing one at top level
/// declares an error-set type.
fn initializerMergesErrorSets(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return false;
    const end = statementEnd(tokens, identifier_index + 2) orelse return false;
    var depth: usize = 0;
    for (tokens[identifier_index + 2 .. end]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .pipe_pipe => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn tokenNamesPrimitiveType(name: []const u8) bool {
    const named = [_][]const u8{ "anyerror", "anyopaque", "bool", "comptime_float", "comptime_int", "f16", "f32", "f64", "f80", "f128", "isize", "noreturn", "type", "usize", "void" };
    for (named) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u')) return false;
    for (name[1..]) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

/// 'pub const _foreign_name = lib._foreign_name;' re-exports a declaration
/// under its original name, which this file does not get to choose.
fn declarationIsSameNameAlias(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return false;
    const end = statementEnd(tokens, identifier_index) orelse return false;
    if (end >= tokens.len or end < identifier_index + 4 or tokens[end - 1].tag != .identifier or
        tokens[end - 2].tag != .period) return false;
    const name = tokenText(source, tokens[identifier_index]);
    return std.mem.eql(u8, name, tokenText(source, tokens[end - 1]));
}

fn identifierIsDeclaration(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (identifier_index == 0 or identifier_index + 1 >= tokens.len) return false;
    return switch (tokens[identifier_index - 1].tag) {
        .keyword_fn => tokens[identifier_index + 1].tag == .l_paren,
        .keyword_const, .keyword_var => (tokens[identifier_index + 1].tag == .equal or tokens[identifier_index + 1].tag == .colon) and
            declarationKeywordStartsStatement(tokens, identifier_index - 1),
        else => false,
    };
}

fn declarationKeywordStartsStatement(tokens: []const std.zig.Token, keyword_index: usize) bool {
    if (keyword_index == 0) return true;
    return switch (tokens[keyword_index - 1].tag) {
        .l_brace,
        .r_brace,
        .semicolon,
        .doc_comment,
        .container_doc_comment,
        .keyword_pub,
        .keyword_export,
        .keyword_comptime,
        .keyword_threadlocal,
        => true,
        else => false,
    };
}

fn declarationIsNamespace(tokens: []const std.zig.Token, identifier_index: usize) bool {
    if (!declarationInitializesType(tokens, identifier_index)) return false;
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal or
        tokens[identifier_index + 2].tag != .keyword_struct or tokens[identifier_index + 3].tag != .l_brace) return false;
    const closing = matchingToken(tokens, identifier_index + 3, .l_brace, .r_brace) orelse return false;
    var brace_depth: usize = 1;
    var parenthesis_depth: usize = 0;
    for (tokens[identifier_index + 4 .. closing], identifier_index + 4..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .identifier => if (brace_depth == 1 and parenthesis_depth == 0 and index + 1 < closing and
                tokens[index + 1].tag == .colon) return false,
            else => {},
        }
    }
    return true;
}

fn functionDeclarationReturnsType(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
) bool {
    if (identifier_index + 1 >= tokens.len or tokens[identifier_index + 1].tag != .l_paren) return false;
    const parameters_end = matchingToken(tokens, identifier_index + 1, .l_paren, .r_paren) orelse return false;
    if (parameters_end + 1 >= tokens.len) return false;
    return tokenIs(source, tokens[parameters_end + 1], "type");
}

fn isCamelCase(name: []const u8) bool {
    return name.len != 0 and std.ascii.isLower(name[0]) and std.mem.indexOfScalar(u8, name, '_') == null;
}

fn isTitleCase(name: []const u8) bool {
    return name.len != 0 and std.ascii.isUpper(name[0]) and std.mem.indexOfScalar(u8, name, '_') == null;
}

fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_') return false;
    }
    return true;
}

fn findOfficialStyleIssues(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const vague_level = configuration.level(.vague_type_name);
    const qualified_level = configuration.level(.redundant_qualified_name);
    const underscore_level = configuration.level(.underscore_private_name);
    const docs_level = configuration.level(.doc_comment_style);
    const public_docs_level = configuration.level(.public_declaration_docs);

    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index == 0) continue;
        const declaration_tag = tokens[index - 1].tag;
        if (declaration_tag != .keyword_fn and declaration_tag != .keyword_const and declaration_tag != .keyword_var) continue;
        if (!identifierIsDeclaration(tokens, index)) continue;
        const name = tokenText(source, token);
        const externally_named = (index >= 2 and
            (tokens[index - 2].tag == .keyword_extern or tokens[index - 2].tag == .keyword_export)) or
            (index >= 3 and tokens[index - 2].tag == .string_literal and tokens[index - 3].tag == .keyword_extern) or
            (declaration_tag == .keyword_const and declarationIsSameNameAlias(source, tokens, index));
        if (underscore_level != .off and name.len > 1 and name[0] == '_' and !externally_named) {
            try addFinding(allocator, source, configuration, found, .{
                .rule = .underscore_private_name,
                .level = underscore_level,
                .span = token.loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "declaration '{s}' uses an underscore prefix even though Zig does not use names to express privacy",
                    .{name},
                ),
            });
        }
        const public_declaration = index >= 2 and tokens[index - 2].tag == .keyword_pub;
        if (vague_level != .off and public_declaration and declaration_tag == .keyword_const and declarationInitializesType(tokens, index)) {
            if (vagueTypeWord(name)) |word| {
                try addFinding(allocator, source, configuration, found, .{
                    .rule = .vague_type_name,
                    .level = vague_level,
                    .span = token.loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "type '{s}' contains the vague word '{s}', which does not describe its domain role",
                        .{ name, word },
                    ),
                });
            }
        }
        const doc_index: ?usize = if (index >= 2 and tokens[index - 2].tag == .doc_comment)
            index - 2
        else if (index >= 3 and tokens[index - 2].tag == .keyword_pub and tokens[index - 3].tag == .doc_comment)
            index - 3
        else
            null;
        if (docs_level != .off and doc_index != null) {
            var first_doc_index = doc_index.?;
            while (first_doc_index > 0 and tokens[first_doc_index - 1].tag == .doc_comment) first_doc_index -= 1;
            const raw_comment = tokenText(source, tokens[first_doc_index]);
            const comment = std.mem.trim(u8, raw_comment[@min(raw_comment.len, 3)..], " \t");
            if (commentStartsWithName(comment, name)) {
                try addFinding(allocator, source, configuration, found, .{
                    .rule = .doc_comment_style,
                    .level = docs_level,
                    .span = tokens[first_doc_index].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "documentation for '{s}' repeats information already provided by its name",
                        .{name},
                    ),
                });
            }
        }
    }

    if (qualified_level != .off) {
        for (tokens, 0..) |token, namespace_index| {
            if (token.tag != .keyword_const or namespace_index + 4 >= tokens.len or
                tokens[namespace_index + 1].tag != .identifier or tokens[namespace_index + 2].tag != .equal or
                tokens[namespace_index + 3].tag != .keyword_struct or tokens[namespace_index + 4].tag != .l_brace) continue;
            const namespace_name = tokenText(source, tokens[namespace_index + 1]);
            const closing = matchingToken(tokens, namespace_index + 4, .l_brace, .r_brace) orelse continue;
            var cursor = namespace_index + 5;
            while (cursor < closing) : (cursor += 1) {
                if (tokens[cursor].tag != .keyword_const or cursor + 3 >= closing or tokens[cursor + 1].tag != .identifier) continue;
                const declaration_name = tokenText(source, tokens[cursor + 1]);
                const suffix = redundantNamespaceSuffix(namespace_name, declaration_name) orelse continue;
                if (suffix.len == 0 or !declarationInitializesType(tokens, cursor + 1)) continue;
                try addFinding(allocator, source, configuration, found, .{
                    .rule = .redundant_qualified_name,
                    .level = qualified_level,
                    .span = tokens[cursor + 1].loc,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "type '{s}' repeats its containing namespace '{s}'; '{s}' is sufficient when qualified",
                        .{ declaration_name, namespace_name, suffix },
                    ),
                });
            }
        }
    }

    if (public_docs_level != .off) {
        for (tokens, 0..) |token, pub_index| {
            if (token.tag != .keyword_pub or pub_index + 2 >= tokens.len) continue;
            const declaration_tag = tokens[pub_index + 1].tag;
            if (declaration_tag != .keyword_fn and declaration_tag != .keyword_const and declaration_tag != .keyword_var) continue;
            if (tokens[pub_index + 2].tag != .identifier) continue;
            if (pub_index > 0 and tokens[pub_index - 1].tag == .doc_comment) continue;
            const declaration_name = tokenText(source, tokens[pub_index + 2]);
            try addFinding(allocator, source, configuration, found, .{
                .rule = .public_declaration_docs,
                .level = public_docs_level,
                .span = tokens[pub_index + 2].loc,
                .message = try std.fmt.allocPrint(allocator, "public declaration '{s}' has no doc comment", .{declaration_name}),
            });
        }
    }
}

fn vagueTypeWord(name: []const u8) ?[]const u8 {
    // Value/Context/State as a suffix names a role precisely (LookupContext,
    // CheckpointState); only the bare word says nothing about the domain.
    const exact_words = [_][]const u8{ "Value", "Context", "State" };
    for (exact_words) |word| {
        if (std.mem.eql(u8, name, word)) return word;
    }
    const suffix_words = [_][]const u8{ "Data", "Manager", "Utils", "Misc" };
    for (suffix_words) |word| {
        if (std.mem.eql(u8, name, word) or std.mem.endsWith(u8, name, word)) return word;
    }
    return null;
}

fn commentStartsWithName(comment: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, comment, name)) return false;
    if (comment.len == name.len) return true;
    return std.ascii.isWhitespace(comment[name.len]) or comment[name.len] == ':' or comment[name.len] == '-';
}

fn redundantNamespaceSuffix(namespace_name: []const u8, declaration_name: []const u8) ?[]const u8 {
    if (namespace_name.len == 0 or declaration_name.len <= namespace_name.len) return null;
    for (namespace_name, declaration_name[0..namespace_name.len]) |namespace_character, declaration_character| {
        if (std.ascii.toLower(namespace_character) != std.ascii.toLower(declaration_character)) return null;
    }
    if (!std.ascii.isUpper(declaration_name[namespace_name.len])) return null;
    return declaration_name[namespace_name.len..];
}

fn findOptionalCaptureIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.prefer_optional_capture);
    if (level == .off) return;
    for (tokens, 0..) |token, if_index| {
        if (token.tag != .keyword_if or if_index + 6 >= tokens.len or tokens[if_index + 1].tag != .l_paren or
            tokens[if_index + 2].tag != .identifier or tokens[if_index + 3].tag != .bang_equal or
            !tokenIs(source, tokens[if_index + 4], "null") or tokens[if_index + 5].tag != .r_paren) continue;
        const body_start = if_index + 6;
        const body_close = if (tokens[body_start].tag == .l_brace)
            matchingToken(tokens, body_start, .l_brace, .r_brace) orelse continue
        else
            statementEnd(tokens, body_start) orelse continue;
        const optional_name = tokenText(source, tokens[if_index + 2]);
        var unwraps: std.ArrayList(std.zig.Token.Loc) = .empty;
        var unsafe = false;
        for (tokens[body_start..body_close], body_start..) |body_token, body_index| {
            if (body_token.tag != .identifier or !tokenIs(source, body_token, optional_name)) continue;
            // A preceding period means this is a same-named field of another value.
            if (body_index > 0 and tokens[body_index - 1].tag == .period) continue;
            if (body_index + 1 < body_close and isAssignment(tokens[body_index + 1].tag)) {
                unsafe = true;
                break;
            }
            if (body_index + 2 < body_close and tokens[body_index + 1].tag == .period and
                tokenIs(source, tokens[body_index + 2], "?"))
            {
                if (body_index + 3 < body_close and isAssignment(tokens[body_index + 3].tag)) {
                    unsafe = true;
                    break;
                }
                try unwraps.append(allocator, .{ .start = body_token.loc.start, .end = tokens[body_index + 2].loc.end });
            }
        }
        if (unsafe or unwraps.items.len == 0) continue;
        const capture_name = try collisionFreeCaptureName(allocator, source, optional_name);
        const edits = try allocator.alloc(Edit, unwraps.items.len + 1);
        edits[0] = .{
            .span = .{ .start = tokens[if_index + 2].loc.start, .end = tokens[if_index + 5].loc.end },
            .replacement = try std.fmt.allocPrint(allocator, "{s}) |{s}|", .{ optional_name, capture_name }),
        };
        for (unwraps.items, edits[1..]) |span, *edit| edit.* = .{ .span = span, .replacement = capture_name };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Use an optional capture", .kind = .refactor_rewrite, .edits = edits };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .prefer_optional_capture,
            .level = level,
            .span = tokens[if_index + 3].loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "optional '{s}' is checked and then force-unwrapped; capture the payload in the if condition",
                .{optional_name},
            ),
            .fixes = fixes,
        });
    }
}

fn collisionFreeCaptureName(allocator: std.mem.Allocator, source: []const u8, optional_name: []const u8) ![]const u8 {
    if (!identifierAppears(source, "value")) return try allocator.dupe(u8, "value");
    const candidate = try std.fmt.allocPrint(allocator, "{s}_value", .{optional_name});
    if (!identifierAppears(source, candidate)) return candidate;
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const numbered = try std.fmt.allocPrint(allocator, "{s}_value_{d}", .{ optional_name, suffix });
        if (!identifierAppears(source, numbered)) return numbered;
    }
}

fn identifierAppears(source: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, name)) |offset| {
        const before_is_identifier = offset > 0 and isIdentifierCharacter(source[offset - 1]);
        const end = offset + name.len;
        const after_is_identifier = end < source.len and isIdentifierCharacter(source[end]);
        if (!before_is_identifier and !after_is_identifier) return true;
        start = end;
    }
    return false;
}

fn isIdentifierCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

fn findTryIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.prefer_try);
    if (level == .off) return;
    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch or catch_index < 2 or catch_index + 5 >= tokens.len or
            tokens[catch_index - 1].tag != .r_paren or tokens[catch_index + 1].tag != .pipe or
            tokens[catch_index + 2].tag != .identifier or tokens[catch_index + 3].tag != .pipe or
            tokens[catch_index + 4].tag != .keyword_return or tokens[catch_index + 5].tag != .identifier) continue;
        const error_name = tokenText(source, tokens[catch_index + 2]);
        if (!tokenIs(source, tokens[catch_index + 5], error_name)) continue;
        const call_open = matchingOpeningToken(tokens, catch_index - 1, .l_paren, .r_paren) orelse continue;
        const expression_start = callExpressionStart(tokens, call_open) orelse continue;
        const expression = std.mem.trim(u8, source[tokens[expression_start].loc.start..token.loc.start], " \t\r\n");
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{
            .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[catch_index + 5].loc.end },
            .replacement = try std.fmt.allocPrint(allocator, "try {s}", .{expression}),
        };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Propagate the error with try", .kind = .refactor_rewrite, .edits = edits };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .prefer_try,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(allocator, "caught error '{s}' is returned unchanged; use try to propagate it", .{error_name}),
            .fixes = fixes,
        });
    }
}

fn callExpressionStart(tokens: []const std.zig.Token, opening: usize) ?usize {
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return null;
    var start = opening - 1;
    while (start >= 2 and tokens[start - 1].tag == .period) {
        switch (tokens[start - 2].tag) {
            .identifier => start -= 2,
            .r_paren => {
                const group_open = matchingOpeningToken(tokens, start - 2, .l_paren, .r_paren) orelse return null;
                if (group_open == 0 or tokens[group_open - 1].tag != .identifier) return null;
                start = group_open - 1;
            },
            .r_bracket => {
                const group_open = matchingOpeningToken(tokens, start - 2, .l_bracket, .r_bracket) orelse return null;
                if (group_open == 0 or tokens[group_open - 1].tag != .identifier) return null;
                start = group_open - 1;
            },
            else => return null,
        }
    }
    return start;
}

fn findTestingIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.prefer_testing_expect_equal);
    if (level == .off) return;
    for (tokens, 0..) |token, expect_index| {
        if (token.tag != .identifier or !tokenIs(source, token, "expect") or expect_index + 5 >= tokens.len or
            tokens[expect_index + 1].tag != .l_paren or tokens[expect_index + 3].tag != .equal_equal or
            tokens[expect_index + 5].tag != .r_paren) continue;
        const left = tokens[expect_index + 2];
        const right = tokens[expect_index + 4];
        const left_literal = isSimpleLiteral(source, left);
        const right_literal = isSimpleLiteral(source, right);
        if (left_literal == right_literal) continue;
        const expected = if (left_literal) left else right;
        const actual = if (left_literal) right else left;
        if (actual.tag != .identifier) continue;
        const expression_start = callExpressionStart(tokens, expect_index + 1) orelse expect_index;
        const qualification = source[tokens[expression_start].loc.start..token.loc.start];
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{
            .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[expect_index + 5].loc.end },
            .replacement = try std.fmt.allocPrint(
                allocator,
                "{s}expectEqual({s}, {s})",
                .{ qualification, tokenText(source, expected), tokenText(source, actual) },
            ),
        };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{ .title = "Use expectEqual", .kind = .refactor_rewrite, .edits = edits };
        try addFinding(allocator, source, configuration, found, .{
            .rule = .prefer_testing_expect_equal,
            .level = level,
            .span = token.loc,
            .message = try std.fmt.allocPrint(
                allocator,
                "comparison of '{s}' with a literal produces a less useful test failure than expectEqual",
                .{tokenText(source, actual)},
            ),
            .fixes = fixes,
        });
    }
}

fn isSimpleLiteral(source: []const u8, token: std.zig.Token) bool {
    return switch (token.tag) {
        .number_literal, .string_literal, .char_literal => true,
        .identifier => tokenIs(source, token, "true") or tokenIs(source, token, "false") or tokenIs(source, token, "null"),
        else => false,
    };
}

fn findPointerParameterIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.mutable_pointer_parameter);
    if (level == .off) return;
    // A function passed around as a value (comparator, callback) has its
    // signature dictated by the receiving API, not by its body. One pass over
    // the file collects every identifier that appears without a call's '('.
    var value_referenced_names: std.StringHashMapUnmanaged(void) = .empty;
    defer value_referenced_names.deinit(allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        if (index + 1 < tokens.len and tokens[index + 1].tag == .l_paren) continue;
        try value_referenced_names.put(allocator, tokenText(source, token), {});
    }
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 3 >= tokens.len or tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
        var body_open = parameters_end + 1;
        while (body_open < tokens.len and tokens[body_open].tag != .l_brace and tokens[body_open].tag != .semicolon) : (body_open += 1) {}
        if (body_open >= tokens.len or tokens[body_open].tag != .l_brace) continue;
        const body_close = matchingToken(tokens, body_open, .l_brace, .r_brace) orelse continue;
        // deinit takes '*T' by convention: it invalidates the value even when its
        // body happens to only read through the pointer.
        if (tokens[fn_index + 1].tag == .identifier and tokenIs(source, tokens[fn_index + 1], "deinit")) continue;
        if (tokens[fn_index + 1].tag == .identifier and
            value_referenced_names.contains(tokenText(source, tokens[fn_index + 1]))) continue;
        var parameter_index = fn_index + 3;
        while (parameter_index + 3 < parameters_end) : (parameter_index += 1) {
            if (tokens[parameter_index].tag != .identifier or tokens[parameter_index + 1].tag != .colon or
                tokens[parameter_index + 2].tag != .asterisk or tokens[parameter_index + 3].tag != .identifier) continue;
            const parameter_name = tokenText(source, tokens[parameter_index]);
            if (!pointerParameterReadOnly(source, tokens, parameter_name, body_open, body_close)) continue;
            if (pointerParameterMayOwnMutableParameter(
                source,
                tokens,
                parameter_index,
                parameters_end,
                body_open,
                body_close,
            )) continue;
            const edits = try allocator.alloc(Edit, 1);
            edits[0] = .{ .span = tokens[parameter_index + 2].loc, .replacement = "*const " };
            const fixes = try allocator.alloc(Fix, 1);
            fixes[0] = .{ .title = "Make the pointee const", .kind = .refactor_rewrite, .edits = edits };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .mutable_pointer_parameter,
                .level = level,
                .span = tokens[parameter_index + 2].loc,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "parameter '{s}' is only read through this pointer; '*const' communicates that contract",
                    .{parameter_name},
                ),
                .fixes = fixes,
            });
        }
    }
}

fn pointerParameterMayOwnMutableParameter(
    source: []const u8,
    tokens: []const std.zig.Token,
    owner_parameter_index: usize,
    parameters_end: usize,
    body_open: usize,
    body_close: usize,
) bool {
    const owner_type = tokenText(source, tokens[owner_parameter_index + 3]);
    var parameter_index = owner_parameter_index + 4;
    while (parameter_index + 3 < parameters_end) : (parameter_index += 1) {
        if (tokens[parameter_index].tag != .identifier or tokens[parameter_index + 1].tag != .colon or
            tokens[parameter_index + 2].tag != .asterisk or tokens[parameter_index + 3].tag != .identifier) continue;
        const mutable_parameter_name = tokenText(source, tokens[parameter_index]);
        if (pointerParameterReadOnly(source, tokens, mutable_parameter_name, body_open, body_close)) continue;
        const mutable_parameter_type = tokenText(source, tokens[parameter_index + 3]);
        if (structContainsFieldType(source, tokens, owner_type, mutable_parameter_type)) return true;
    }
    return false;
}

fn structContainsFieldType(
    source: []const u8,
    tokens: []const std.zig.Token,
    owner_type: []const u8,
    field_type: []const u8,
) bool {
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, owner_type) or index == 0 or index + 3 >= tokens.len) continue;
        if (tokens[index - 1].tag != .keyword_const or tokens[index + 1].tag != .equal or
            tokens[index + 2].tag != .keyword_struct or tokens[index + 3].tag != .l_brace) continue;
        const body_close = matchingToken(tokens, index + 3, .l_brace, .r_brace) orelse return false;
        var depth: usize = 1;
        for (tokens[index + 4 .. body_close]) |field_token| {
            if (field_token.tag == .l_brace) depth += 1;
            if (field_token.tag == .r_brace) depth -= 1;
            if (depth == 1 and field_token.tag == .identifier and tokenIs(source, field_token, field_type)) return true;
        }
        return false;
    }
    return false;
}

fn pointerParameterReadOnly(
    source: []const u8,
    tokens: []const std.zig.Token,
    parameter_name: []const u8,
    body_open: usize,
    body_close: usize,
) bool {
    var uses: usize = 0;
    for (tokens[body_open + 1 .. body_close], body_open + 1..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, parameter_name)) continue;
        uses += 1;
        // '&param.field' escapes as a mutable pointer, which '*const' would forbid.
        if (index > 0 and tokens[index - 1].tag == .ampersand) return false;
        // Likewise '&@field(param, ...)'.
        if (index >= 3 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .builtin and
            tokens[index - 3].tag == .ampersand) return false;
        // 'switch (param.field)' with a '|*capture|' prong mutates through the operand.
        if (index >= 2 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .keyword_switch and
            switchHasPointerCapture(tokens, index - 1, body_close)) return false;
        const address_taken = index > body_open and tokens[index - 1].tag == .ampersand or
            index > body_open + 1 and tokens[index - 1].tag == .l_paren and tokens[index - 2].tag == .ampersand;
        if (address_taken) return false;
        if (usedByMutableSwitchCapture(tokens, index)) return false;
        if (parameterUseIsWithinLoop(tokens, index)) return false;
        var cursor = index + 1;
        while (cursor < body_close) {
            switch (tokens[cursor].tag) {
                .period_asterisk => cursor += 1,
                .period => {
                    if (cursor + 1 >= body_close or tokens[cursor + 1].tag != .identifier) return false;
                    cursor += 2;
                },
                .l_bracket => {
                    const subscript_close = matchingToken(tokens, cursor, .l_bracket, .r_bracket) orelse return false;
                    if (subscript_close >= body_close) return false;
                    // A range subscript produces a mutable slice of the pointee.
                    for (tokens[cursor + 1 .. subscript_close]) |subscript_token| {
                        if (subscript_token.tag == .ellipsis2) return false;
                    }
                    cursor = subscript_close + 1;
                },
                else => break,
            }
        }
        if (cursor + 3 < body_close and tokens[cursor].tag == .r_paren and
            tokens[cursor + 1].tag == .pipe and tokens[cursor + 2].tag == .asterisk and
            tokens[cursor + 3].tag == .identifier) return false;
        if (cursor == index + 1) return false;
        if (cursor < body_close and (isAssignment(tokens[cursor].tag) or tokens[cursor].tag == .l_paren)) return false;
    }
    return uses != 0;
}

fn switchHasPointerCapture(tokens: []const std.zig.Token, condition_open: usize, limit: usize) bool {
    const condition_close = matchingToken(tokens, condition_open, .l_paren, .r_paren) orelse return false;
    if (condition_close + 1 >= limit or tokens[condition_close + 1].tag != .l_brace) return false;
    const body_close = matchingToken(tokens, condition_close + 1, .l_brace, .r_brace) orelse return false;
    for (tokens[condition_close + 2 .. @min(body_close, limit)], condition_close + 2..) |token, index| {
        if (token.tag == .pipe and index + 1 < limit and tokens[index + 1].tag == .asterisk) return true;
    }
    return false;
}

fn parameterUseIsWithinLoop(tokens: []const std.zig.Token, use_index: usize) bool {
    var cursor = use_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .l_paren => if (cursor > 0 and tokens[cursor - 1].tag == .keyword_for) return true,
            .l_brace, .r_brace, .semicolon => return false,
            else => {},
        }
    }
    return false;
}

fn findComptimeIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const comptime_level = configuration.level(.redundant_comptime);
    const inline_level = configuration.level(.redundant_inline);
    if (comptime_level == .off and inline_level == .off) return;
    for (tokens, 0..) |token, index| {
        const is_redundant_comptime = token.tag == .keyword_comptime and comptime_level != .off and
            index + 1 < tokens.len and tokens[index + 1].tag != .l_brace and insideComptimeScope(tokens, index);
        const is_redundant_inline = token.tag == .keyword_inline and inline_level != .off and
            index + 1 < tokens.len and
            (tokens[index + 1].tag == .keyword_for or tokens[index + 1].tag == .keyword_while) and
            insideComptimeScope(tokens, index);
        if (!is_redundant_comptime and !is_redundant_inline) continue;
        const edits = try allocator.alloc(Edit, 1);
        edits[0] = .{ .span = .{ .start = token.loc.start, .end = tokens[index + 1].loc.start }, .replacement = "" };
        const fixes = try allocator.alloc(Fix, 1);
        fixes[0] = .{
            .title = if (is_redundant_comptime) "Remove redundant comptime" else "Remove redundant inline",
            .kind = .refactor_rewrite,
            .edits = edits,
        };
        try addFinding(allocator, source, configuration, found, .{
            .rule = if (is_redundant_comptime) .redundant_comptime else .redundant_inline,
            .level = if (is_redundant_comptime) comptime_level else inline_level,
            .span = token.loc,
            .message = try allocator.dupe(
                u8,
                if (is_redundant_comptime)
                    "expression is already evaluated inside a comptime block"
                else
                    "loop is already evaluated inside a comptime block; inline is redundant",
            ),
            .fixes = fixes,
        });
    }
}

fn insideComptimeScope(tokens: []const std.zig.Token, index: usize) bool {
    var cursor = index;
    var nested_closings: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) {
            nested_closings += 1;
            continue;
        }
        if (tokens[cursor].tag != .l_brace) continue;
        if (nested_closings != 0) {
            nested_closings -= 1;
            continue;
        }
        if (cursor > 0 and tokens[cursor - 1].tag == .keyword_comptime) return true;
    }
    return false;
}

fn findTypeExpressionIdioms(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const qualification_level = configuration.level(.redundant_type_qualification);
    const initializer_level = configuration.level(.prefer_anonymous_initializer);
    if (qualification_level == .off and initializer_level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 6 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .colon or
            tokens[declaration_index + 3].tag != .identifier or tokens[declaration_index + 4].tag != .equal or
            tokens[declaration_index + 5].tag != .identifier or
            !tokenIs(source, tokens[declaration_index + 3], tokenText(source, tokens[declaration_index + 5]))) continue;
        const type_name = tokenText(source, tokens[declaration_index + 3]);
        if (qualification_level != .off and declaration_index + 7 < tokens.len and
            tokens[declaration_index + 6].tag == .period and tokens[declaration_index + 7].tag == .identifier)
        {
            const edits = try allocator.alloc(Edit, 1);
            edits[0] = .{
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 7].loc.end },
                .replacement = try std.fmt.allocPrint(allocator, ".{s}", .{tokenText(source, tokens[declaration_index + 7])}),
            };
            const fixes = try allocator.alloc(Fix, 1);
            fixes[0] = .{ .title = "Use inferred enum literal", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .redundant_type_qualification,
                .level = qualification_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try std.fmt.allocPrint(allocator, "type '{s}' is already established by the result location", .{type_name}),
                .fixes = fixes,
            });
        } else if (initializer_level != .off and tokens[declaration_index + 6].tag == .l_brace) {
            const edits = try allocator.alloc(Edit, 1);
            edits[0] = .{
                .span = .{ .start = tokens[declaration_index + 5].loc.start, .end = tokens[declaration_index + 6].loc.end },
                .replacement = ".{",
            };
            const fixes = try allocator.alloc(Fix, 1);
            fixes[0] = .{ .title = "Use an anonymous initializer", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .prefer_anonymous_initializer,
                .level = initializer_level,
                .span = tokens[declaration_index + 5].loc,
                .message = try std.fmt.allocPrint(allocator, "initializer repeats result type '{s}'", .{type_name}),
                .fixes = fixes,
            });
        }
    }
}

fn findImportIssues(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const duplicate_level = configuration.level(.duplicate_import);
    const unused_level = configuration.level(.unused_import);
    const path_level = configuration.level(.redundant_import_path);
    if (duplicate_level == .off and unused_level == .off and path_level == .off) return;
    var seen_paths: std.StringHashMapUnmanaged(std.zig.Token.Loc) = .empty;
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .l_brace) brace_depth += 1;
        if (token.tag == .r_brace) brace_depth -|= 1;
        if (brace_depth != 0 or token.tag != .keyword_const or index + 7 >= tokens.len or
            tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            !tokenIs(source, tokens[index + 3], "@import") or tokens[index + 4].tag != .l_paren or
            tokens[index + 5].tag != .string_literal or tokens[index + 6].tag != .r_paren or
            tokens[index + 7].tag != .semicolon) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_pub) continue;
        const alias = tokenText(source, tokens[index + 1]);
        const raw_path = tokenText(source, tokens[index + 5]);
        const path = raw_path[1 .. raw_path.len - 1];
        const declaration_span = std.zig.Token.Loc{ .start = lineStart(source, token.loc.start), .end = lineEnd(source, tokens[index + 7].loc.end) };
        if (duplicate_level != .off) {
            if (seen_paths.get(path)) |first_span| {
                const fixes: []const Fix = if (attachedCommentStart(source, declaration_span.start) == declaration_span.start) fixes: {
                    const edits = try allocator.alloc(Edit, 1);
                    edits[0] = .{ .span = declaration_span, .replacement = "" };
                    const allocated = try allocator.alloc(Fix, 1);
                    allocated[0] = .{ .title = "Remove duplicate import", .kind = .quickfix, .edits = edits };
                    break :fixes allocated;
                } else &.{};
                const related = try allocator.alloc(RelatedSpan, 1);
                related[0] = .{ .span = first_span, .message = "the same module is imported here first" };
                try addFinding(allocator, source, configuration, found, .{
                    .rule = .duplicate_import,
                    .level = duplicate_level,
                    .span = tokens[index + 5].loc,
                    .message = try std.fmt.allocPrint(allocator, "module '{s}' is imported more than once", .{path}),
                    .related = related,
                    .fixes = fixes,
                });
            } else try seen_paths.put(allocator, path, tokens[index + 5].loc);
        }
        if (unused_level != .off and identifierUseCount(source, alias) == 1) {
            const fixes: []const Fix = if (attachedCommentStart(source, declaration_span.start) == declaration_span.start) fixes: {
                const edits = try allocator.alloc(Edit, 1);
                edits[0] = .{ .span = declaration_span, .replacement = "" };
                const allocated = try allocator.alloc(Fix, 1);
                allocated[0] = .{ .title = "Remove unused import", .kind = .quickfix, .edits = edits };
                break :fixes allocated;
            } else &.{};
            try addFinding(allocator, source, configuration, found, .{
                .rule = .unused_import,
                .level = unused_level,
                .span = tokens[index + 1].loc,
                .message = try std.fmt.allocPrint(allocator, "import alias '{s}' is never referenced", .{alias}),
                .fixes = fixes,
            });
        }
        if (path_level != .off and std.mem.startsWith(u8, path, "./") and path.len > 2) {
            const edits = try allocator.alloc(Edit, 1);
            edits[0] = .{
                .span = tokens[index + 5].loc,
                .replacement = try std.fmt.allocPrint(allocator, "\"{s}\"", .{path[2..]}),
            };
            const fixes = try allocator.alloc(Fix, 1);
            fixes[0] = .{ .title = "Normalize import path", .kind = .quickfix, .edits = edits, .preferred = true, .fix_all = true };
            try addFinding(allocator, source, configuration, found, .{
                .rule = .redundant_import_path,
                .level = path_level,
                .span = tokens[index + 5].loc,
                .message = try std.fmt.allocPrint(allocator, "relative import path '{s}' has a redundant './' segment", .{path}),
                .fixes = fixes,
            });
        }
    }
}

fn identifierUseCount(source: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, name)) |offset| {
        const before_is_identifier = offset > 0 and isIdentifierCharacter(source[offset - 1]);
        const end = offset + name.len;
        const after_is_identifier = end < source.len and isIdentifierCharacter(source[end]);
        if (!before_is_identifier and !after_is_identifier) count += 1;
        start = end;
    }
    return count;
}

const Import = struct {
    start: usize,
    end: usize,
    alias: []const u8,
    path: []const u8,
};

fn findUnsortedImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    configuration: Configuration,
    found: *std.ArrayList(Finding),
) !void {
    const level = configuration.level(.unsorted_imports);
    if (level == .off) return;
    var imports: std.ArrayList(Import) = .empty;
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .l_brace) {
            brace_depth += 1;
            continue;
        }
        if (token.tag == .r_brace) {
            brace_depth -|= 1;
            continue;
        }
        if (brace_depth != 0) continue;
        if (token.tag != .keyword_const or index + 7 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .equal or !tokenIs(source, tokens[index + 3], "@import") or
            tokens[index + 4].tag != .l_paren or tokens[index + 5].tag != .string_literal or
            tokens[index + 6].tag != .r_paren or tokens[index + 7].tag != .semicolon)
        {
            continue;
        }
        const raw_path = tokenText(source, tokens[index + 5]);
        const declaration_start = lineStart(source, token.loc.start);
        try imports.append(allocator, .{
            .start = attachedCommentStart(source, declaration_start),
            .end = lineEnd(source, tokens[index + 7].loc.end),
            .alias = tokenText(source, tokens[index + 1]),
            .path = raw_path[1 .. raw_path.len - 1],
        });
    }
    if (imports.items.len < 2 or !importsAreContiguous(source, imports.items) or importsAreSorted(imports.items)) return;
    const replacement = try sortedImportText(allocator, source, imports.items);
    const edits = try allocator.alloc(Edit, 1);
    edits[0] = .{ .span = .{ .start = imports.items[0].start, .end = imports.items[imports.items.len - 1].end }, .replacement = replacement };
    const fixes = try allocator.alloc(Fix, 1);
    fixes[0] = .{ .title = "Organize imports", .kind = .organize_imports, .edits = edits };
    try addFinding(allocator, source, configuration, found, .{
        .rule = .unsorted_imports,
        .level = level,
        .span = .{ .start = imports.items[0].start, .end = imports.items[imports.items.len - 1].end },
        .message = try allocator.dupe(u8, "top-level imports are not grouped and sorted by path"),
        .fixes = fixes,
    });
}

fn attachedCommentStart(source: []const u8, declaration_start: usize) usize {
    var start = declaration_start;
    while (start > 0) {
        const previous_end = start - 1;
        const previous_start = lineStart(source, previous_end);
        const previous_line = std.mem.trim(u8, source[previous_start..previous_end], " \t\r");
        if (!std.mem.startsWith(u8, previous_line, "//")) break;
        if (std.mem.startsWith(u8, previous_line, "//!")) break;
        start = previous_start;
    }
    return start;
}

fn importsAreContiguous(source: []const u8, imports: []const Import) bool {
    for (imports[1..], 1..) |current, index| {
        const between = std.mem.trim(u8, source[imports[index - 1].end..current.start], " \t\r\n");
        if (between.len != 0) return false;
    }
    return true;
}

fn importsAreSorted(imports: []const Import) bool {
    for (imports[1..], 1..) |current, index| {
        if (importLessThan(current, imports[index - 1])) return false;
    }
    return true;
}

fn importLessThan(left: Import, right: Import) bool {
    const left_group = importGroup(left.path);
    const right_group = importGroup(right.path);
    if (left_group != right_group) return left_group < right_group;
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    return std.mem.lessThan(u8, left.alias, right.alias);
}

fn importGroup(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin") or std.mem.eql(u8, path, "root")) return 0;
    if (std.mem.indexOfScalar(u8, path, '/') == null and !std.mem.endsWith(u8, path, ".zig")) return 1;
    return 2;
}

fn sortedImportText(allocator: std.mem.Allocator, source: []const u8, imports: []const Import) ![]const u8 {
    const sorted = try allocator.dupe(Import, imports);
    std.mem.sort(Import, sorted, {}, struct {
        fn lessThan(_: void, left: Import, right: Import) bool {
            return importLessThan(left, right);
        }
    }.lessThan);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var previous_group: ?u2 = null;
    for (sorted) |import| {
        const group = importGroup(import.path);
        if (previous_group) |previous| if (previous != group) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(source[import.start..import.end]);
        previous_group = group;
    }
    return try writer.toOwnedSlice();
}

fn lineIndentation(source: []const u8, offset: usize) []const u8 {
    const start = lineStart(source, offset);
    var end = start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) : (end += 1) {}
    return source[start..end];
}

fn lineStart(source: []const u8, offset: usize) usize {
    return (std.mem.lastIndexOfScalar(u8, source[0..@min(offset, source.len)], '\n') orelse return 0) + 1;
}

fn lineEnd(source: []const u8, offset: usize) usize {
    const relative = std.mem.indexOfScalar(u8, source[@min(offset, source.len)..], '\n') orelse return source.len;
    return @min(offset, source.len) + relative + 1;
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn tokenIs(source: []const u8, token: std.zig.Token, expected: []const u8) bool {
    return std.mem.eql(u8, tokenText(source, token), expected);
}

fn matchingToken(
    tokens: []const std.zig.Token,
    opening_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn matchingOpeningToken(
    tokens: []const std.zig.Token,
    closing_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    var cursor = closing_index + 1;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == closing_tag) depth += 1;
        if (tokens[cursor].tag != opening_tag) continue;
        depth -= 1;
        if (depth == 0) return cursor;
    }
    return null;
}

fn enclosingScopeEnd(tokens: []const std.zig.Token, index: usize) ?usize {
    var cursor = index;
    var opening: ?usize = null;
    var depth: usize = 0;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth == 0) {
            opening = cursor;
            break;
        }
        depth -= 1;
    }
    const scope_opening = opening orelse return null;
    return matchingToken(tokens, scope_opening, .l_brace, .r_brace);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    return try tokens.toOwnedSlice(allocator);
}

test "configuration applies tiers and per-rule overrides" {
    const configuration = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"correctness":"error","style":"hint","rules":{"discarded-error":"warning","mixed-bitwise-arithmetic":"information"}}}
    );
    try std.testing.expectEqual(Level.@"error", configuration.level(.unreleased_allocation));
    try std.testing.expectEqual(Level.hint, configuration.level(.unsorted_imports));
    try std.testing.expectEqual(Level.warning, configuration.level(.discarded_error));
    try std.testing.expectEqual(Level.information, configuration.level(.mixed_bitwise_arithmetic));
}

test "configuration reports unknown rules" {
    const configuration = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"rules":{"mystery-rule":"warning"}}}
    );
    defer std.testing.allocator.free(configuration.warning.?);
    try std.testing.expect(std.mem.indexOf(u8, configuration.warning.?, "mystery-rule") != null);
}

test "findings include switch struct and var fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32, enabled: bool = true };\n" ++
        "fn run(mode: Mode) void {\n" ++
        "    var count = 1;\n" ++
        "    _ = count;\n" ++
        "    _ = Options{};\n" ++
        "    switch (mode) { .fast => {} }\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var saw_switch = false;
    var saw_struct = false;
    var saw_var = false;
    for (found) |finding| {
        if (finding.rule == .missing_switch_prong) {
            saw_switch = true;
            try std.testing.expect(std.mem.startsWith(u8, finding.fixes[0].edits[0].replacement, "\n"));
        }
        if (finding.rule == .missing_struct_field) {
            saw_struct = true;
            try std.testing.expect(std.mem.startsWith(u8, finding.fixes[0].edits[0].replacement, "\n"));
        }
        if (finding.rule == .never_mutated_var) saw_var = true;
    }
    try std.testing.expect(saw_switch);
    try std.testing.expect(saw_struct);
    try std.testing.expect(saw_var);
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_struct_field);
}

test "struct findings resolve directly typed inferred initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Options = struct { count: u32, enabled: bool = true };\n" ++
        "fn run() void { const options: Options = .{}; _ = options; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var missing_field_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_struct_field) {
        missing_field_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, ".count") != null);
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var missing_field_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_struct_field) {
        missing_field_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "Parent") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_field_count);
}

test "suppression comments disable only named findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    // zig-analyzer: disable-next-line never-mutated-var\n" ++
        "    var value = 1;\n" ++
        "    _ = value;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "organize imports preserves directly attached comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// package docs\n" ++
        "const package = @import(\"package\");\n" ++
        "// standard library\n" ++
        "const std = @import(\"std\");\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unsorted_imports)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const replacement = found[0].fixes[0].edits[0].replacement;
    try std.testing.expect(std.mem.indexOf(u8, replacement, "// standard library\nconst std") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacement, "// package docs\nconst package") != null);
}

test "cleanup defer in a loop never fires because it runs each iteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn cleanup(allocator: anytype, values: []u8) void {\n" ++
        "    for (values) |value| defer allocator.free(value);\n" ++
        "    for (values) |value| { defer allocator.free(value); }\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .defer_cleanup_in_loop);
}

test "style findings require proven operands and expose safe fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "fn Bad_Function(mode: Mode, enabled: bool, value: u32, unknown: anytype) u32 {\n" ++
        "    _ = @as(u32, value);\n" ++
        "    _ = @as(u32, @as(u32, value));\n" ++
        "    _ = failing() catch {};\n" ++
        "    _ = unknown == true;\n" ++
        "    _ = switch (mode) { .fast => 1, else => 2 };\n" ++
        "    if (enabled == true) { return value; } else { return 0; }\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    for (std.enums.values(Rule)) |rule| if (rule.tier() == .style) {
        configuration.levels[@intFromEnum(rule)] = .warning;
    };
    const found = try findings(arena.allocator(), source, configuration);
    var saw_discarded_error = false;
    var saw_boolean = false;
    var saw_non_exhaustive = false;
    var saw_name = false;
    var cast_count: usize = 0;
    var saw_needless_else = false;
    for (found) |finding| switch (finding.rule) {
        .discarded_error => saw_discarded_error = true,
        .redundant_bool_comparison => {
            saw_boolean = true;
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        },
        .non_exhaustive_switch_else => saw_non_exhaustive = true,
        .non_idiomatic_name => saw_name = true,
        .needless_cast => cast_count += 1,
        .needless_else_after_terminator => saw_needless_else = true,
        else => {},
    };
    try std.testing.expect(saw_discarded_error);
    try std.testing.expect(saw_boolean);
    try std.testing.expect(saw_non_exhaustive);
    try std.testing.expect(saw_name);
    try std.testing.expect(cast_count >= 2);
    try std.testing.expect(saw_needless_else);
}

test "error comparisons and mixed operators report precise findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn classify(err: error{Missing}, value: u8) bool {\n" ++
        "    _ = 1 + value << 3;\n" ++
        "    return err == error.Missing;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mixed_bitwise_arithmetic)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var saw_error_comparison = false;
    var saw_mixed_operators = false;
    for (found) |finding| switch (finding.rule) {
        .error_value_comparison => saw_error_comparison = true,
        .mixed_bitwise_arithmetic => {
            saw_mixed_operators = true;
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            try std.testing.expect(std.mem.startsWith(u8, finding.fixes[0].edits[0].replacement, "("));
        },
        else => {},
    };
    try std.testing.expect(saw_error_comparison);
    try std.testing.expect(saw_mixed_operators);
}

test "unused private declarations omit public used and reflected names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const used = 1;\n" ++
        "const unused = 2;\n" ++
        "const reflected = 3;\n" ++
        "pub const public_unused = 4;\n" ++
        "fn private_unused() void {}\n" ++
        "pub fn run() void { _ = used; _ = @field(@This(), \"reflected\"); }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unused_private_declaration)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .unused_private_declaration) {
        try names.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("unused", names.items[0]);
    try std.testing.expectEqualStrings("private_unused", names.items[1]);
}

test "semantic findings understand captures mutations and shadowed switch operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const ExePathFormat = enum { elf, pe, macho, detect };\n" ++
        "const Flags = struct { enabled: bool };\n" ++
        "const Context = struct { value: u8 };\n" ++
        "const Result = union(enum) { done: u8, pending };\n" ++
        "fn run(callback: ?*const fn () void, exe_path_format: enum { detect, native }) void {\n" ++
        "    if (callback) |hook| hook();\n" ++
        "    var checksum: u64 = 0;\n" ++
        "    checksum +%= 1;\n" ++
        "    var flags: Flags = .{ .enabled = false };\n" ++
        "    @field(flags, \"enabled\") = true;\n" ++
        "    var result: Result = .{ .done = 1 };\n" ++
        "    _ = switch (result) { .done => |*value| value.*, .pending => 0 };\n" ++
        "    var storage = Context{ .value = 0 };\n" ++
        "    var context: *Context = context: { const context = &storage; break :context context; };\n" ++
        "    context.value = 1;\n" ++
        "    _ = switch (exe_path_format) { .detect => 1, .native => 2 };\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| switch (finding.rule) {
        .unresolved_call, .never_mutated_var, .missing_switch_prong => return error.TestUnexpectedResult,
        else => {},
    };
}

test "discarded error ignores an explanatory catch comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { failing() catch { // Best effort cleanup.\n" ++
        "}; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.discarded_error)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .discarded_error);
}

test "suppression parser reports malformed and unknown rules" {
    const malformed = try suppressionWarning(std.testing.allocator, "// zig-analyzer: ignore-next-line never-mutated-var\nconst x = 1;");
    defer std.testing.allocator.free(malformed.?);
    try std.testing.expect(std.mem.indexOf(u8, malformed.?, "malformed") != null);

    const unknown = try suppressionWarning(std.testing.allocator, "// zig-analyzer: disable-file unknown-rule\n");
    defer std.testing.allocator.free(unknown.?);
    try std.testing.expect(std.mem.indexOf(u8, unknown.?, "unknown-rule") != null);
}

test "line and scoped suppressions apply to semantic and modular rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(ready: bool) void {\n" ++
        "    var value = if (ready) true else false; // zig-analyzer: disable-line never-mutated-var, redundant-boolean-if\n" ++
        "    _ = value;\n" ++
        "    defer { _ = ready; } // zig-analyzer: disable-line needless-defer-block\n" ++
        "}";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.redundant_boolean_if)] = .information;
    configuration.levels[@intFromEnum(Rule.needless_defer_block)] = .information;
    const found = try findings(arena.allocator(), source, configuration);

    for (found) |finding| switch (finding.rule) {
        .never_mutated_var, .redundant_boolean_if, .needless_defer_block => return error.TestUnexpectedResult,
        else => {},
    };
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), missing_switch_count);
}

test "never-mutated analysis ignores mutations of a shadowing binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    var value = 1;\n" ++
        "    { var value = 2; value += 1; _ = value; }\n" ++
        "    _ = value;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .never_mutated_var) {
        warning_count += 1;
        try std.testing.expectEqualStrings("value", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "never-mutated analysis omits top-level state and possible mutable receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var global_state: u32 = 0;\n" ++
        "const State = struct { var namespace_state: u32 = 0; };\n" ++
        "fn run() void {\n" ++
        "    const LocalState = struct { var namespace_state: u32 = 0; };\n" ++
        "    var iterator = Iterator.init();\n" ++
        "    _ = iterator.next();\n" ++
        "    var output: u32 = undefined;\n" ++
        "    asm volatile (\"instruction\" : [value] \"=r\" (output));\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "never-mutated analysis recognizes mutable optional captures and nested assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(optional: ?Resource, root: *const Node) void {\n" ++
        "    var owned = optional;\n" ++
        "    defer if (owned) |*resource| resource.deinit();\n" ++
        "    var current = optional;\n" ++
        "    while (current) |*resource| { resource.advance(); break; }\n" ++
        "    var node = root;\n" ++
        "    var remaining: usize = 2;\n" ++
        "    while (true) {\n" ++
        "        switch (node.content) {\n" ++
        "            .leaf => |leaf| return leaf.bytes[remaining],\n" ++
        "            .branch => |branch| {\n" ++
        "                if (remaining < branch.count) {\n" ++
        "                    node = branch.left;\n" ++
        "                } else {\n" ++
        "                    remaining -= branch.count;\n" ++
        "                    node = branch.right;\n" ++
        "                }\n" ++
        "            },\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
}

test "scope-sensitive quick fixes are excluded from fix all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(enabled: bool) void {\n" ++
        "    var value = enabled;\n" ++
        "    _ = value;\n" ++
        "    if (enabled) { return; } else { consume(); }\n" ++
        "}\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"rules":{"needless-else-after-terminator":"information"}}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var checked: usize = 0;
    for (found) |finding| {
        if (finding.rule != .never_mutated_var and finding.rule != .needless_else_after_terminator) continue;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(!finding.fixes[0].fix_all);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
}

test "else after one terminating branch stays inside an else-if chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scan(first: bool, second: bool) void {\n" ++
        "    if (first) { consume(); } else if (second) { return; } else { consume(); }\n" ++
        "}\n" ++
        "fn simple(first: bool) void { if (first) { return; } else { consume(); } }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.needless_else_after_terminator)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_else_after_terminator) {
        warning_count += 1;
        try std.testing.expect(finding.span.start > std.mem.indexOf(u8, source, "fn simple").?);
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "configuration reports the removed formatting profile and still loads lints" {
    const configuration = try parseConfiguration(std.testing.allocator,
        \\{"format":{"profile":"analyzer","organizeImports":true},"lints":{"profile":"idiomatic"}}
    );
    defer std.testing.allocator.free(configuration.warning.?);
    try std.testing.expect(std.mem.indexOf(u8, configuration.warning.?, "always delegates to zig fmt") != null);
    try std.testing.expectEqual(LintProfile.idiomatic, configuration.lint_profile);
}

test "lint profiles enable official idiomatic and strict rules incrementally" {
    const official = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"official"}}
    );
    try std.testing.expectEqual(LintProfile.official, official.lint_profile);
    try std.testing.expectEqual(Level.information, official.level(.redundant_qualified_name));
    try std.testing.expectEqual(Level.off, official.level(.prefer_optional_capture));

    const idiomatic = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"idiomatic","rules":{"prefer-try":"warning"}}}
    );
    try std.testing.expectEqual(Level.information, idiomatic.level(.underscore_private_name));
    try std.testing.expectEqual(Level.warning, idiomatic.level(.prefer_try));
    try std.testing.expectEqual(Level.information, idiomatic.level(.redundant_boolean_if));
    try std.testing.expectEqual(Level.information, idiomatic.level(.needless_defer_block));
    try std.testing.expectEqual(Level.information, idiomatic.level(.needless_empty_else));
    try std.testing.expectEqual(Level.off, idiomatic.level(.unsafe_orelse_unreachable));
    try std.testing.expectEqual(Level.information, idiomatic.level(.redundant_optional_unwrap));
    try std.testing.expectEqual(Level.off, idiomatic.level(.public_declaration_docs));

    const strict = try parseConfiguration(std.testing.allocator,
        \\{"lints":{"profile":"strict"}}
    );
    try std.testing.expectEqual(Level.information, strict.level(.unsafe_orelse_unreachable));
    try std.testing.expectEqual(Level.information, strict.level(.lost_error_context));
    try std.testing.expectEqual(Level.information, strict.level(.error_collapsed_to_absence));
    try std.testing.expectEqual(Level.information, strict.level(.public_declaration_docs));
}

test "official style rules describe names namespaces and documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const json = struct { pub const JsonValue = union(enum) { string: []const u8 }; };\n" ++
        "pub const Data = struct {};\n" ++
        "const _internal = 1;\n" ++
        "/// runTask runs a task.\n" ++
        "pub fn runTask() void {}\n" ++
        "pub fn undocumented() void {}\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"profile":"strict"}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var qualified = false;
    var vague = false;
    var underscore = false;
    var repeated_docs = false;
    var missing_docs = false;
    for (found) |finding| switch (finding.rule) {
        .redundant_qualified_name => qualified = true,
        .vague_type_name => vague = true,
        .underscore_private_name => underscore = true,
        .doc_comment_style => repeated_docs = true,
        .public_declaration_docs => if (std.mem.indexOf(u8, finding.message, "undocumented") != null) {
            missing_docs = true;
        },
        else => {},
    };
    try std.testing.expect(qualified);
    try std.testing.expect(vague);
    try std.testing.expect(underscore);
    try std.testing.expect(repeated_docs);
    try std.testing.expect(missing_docs);
}

test "naming resolves type functions aliases and namespace structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Concrete = struct { value: u32 };\n" ++
        "const bad_alias = Concrete;\n" ++
        "const ReflectedType = @typeInfo(@TypeOf(generated_type)).@\"fn\".return_type.?;\n" ++
        "const ImportedType = @import(\"types.zig\").ImportedType;\n" ++
        "const parseConfiguration = semantic.parseConfiguration;\n" ++
        "const styleAt = struct { fn styleAt(_: usize) void {} }.styleAt;\n" ++
        "const BadNamespace = struct { pub const value = 1; };\n" ++
        "fn generated_type() type { return struct { value: u32 }; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .non_idiomatic_name) naming_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), naming_count);
}

test "structural type aliases and bare type imports keep TitleCase names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const StaticAllocator = @import(\"static_allocator.zig\");\n" ++
        "const ImportedGenerated = @import(\"generated.zig\").GeneratedType(u8);\n" ++
        "const Message = struct { value: u8 };\n" ++
        "const Messages = [4]?*Message;\n" ++
        "const Bytes = []const u8;\n" ++
        "const Callback = *const fn (Message) void;\n" ++
        "const Reflected = @FieldType(Message, \"value\");\n" ++
        "const Failure = error{Failed};\n" ++
        "const Result = Failure!Message;\n" ++
        "const MessageAlias = Message;\n" ++
        "fn Generic(comptime Source: type) type { const Alias = Source; return Alias; }\n" ++
        "const BadValue = 1;\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("BadValue", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "compiler-resolved type aliases require TitleCase names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const external_type = external_value;\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    const found = try findingsWithShapes(arena.allocator(), source, configuration, &.{.{
        .type_name = "external_type",
        .kind = .structure,
        .fields = &.{"value"},
    }});
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("external_type", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "idiomatic rewrites are offered only for mechanically bounded forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mode = enum { fast, safe };\n" ++
        "const Options = struct { count: u32 };\n" ++
        "fn load() !u32 { return 1; }\n" ++
        "fn inspect(optional: ?u32, actual: u32, pointer: *u32) !void {\n" ++
        "    if (optional != null) { _ = optional.?; }\n" ++
        "    const loaded = load() catch |err| return err;\n" ++
        "    try std.testing.expect(actual == 42);\n" ++
        "    const mode: Mode = Mode.fast;\n" ++
        "    const options: Options = Options{ .count = pointer.* };\n" ++
        "    _ = loaded; _ = mode; _ = options;\n" ++
        "}\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"profile":"idiomatic"}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var optional_capture = false;
    var prefer_try = false;
    var testing = false;
    var pointer_const = false;
    var qualification = false;
    var initializer = false;
    for (found) |finding| switch (finding.rule) {
        .prefer_optional_capture => {
            optional_capture = true;
            try std.testing.expectEqualStrings("optional) |value|", finding.fixes[0].edits[0].replacement);
        },
        .prefer_try => prefer_try = true,
        .prefer_testing_expect_equal => testing = true,
        .mutable_pointer_parameter => pointer_const = true,
        .redundant_type_qualification => qualification = true,
        .prefer_anonymous_initializer => initializer = true,
        else => {},
    };
    try std.testing.expect(optional_capture);
    try std.testing.expect(prefer_try);
    try std.testing.expect(testing);
    try std.testing.expect(pointer_const);
    try std.testing.expect(qualification);
    try std.testing.expect(initializer);
}

test "error switches and import rules provide conservative actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const first = @import(\"./module.zig\");\n" ++
        "const second = @import(\"./module.zig\");\n" ++
        "const Failure = error{ Missing, Denied };\n" ++
        "fn classify(err: Failure) void { _ = switch (err) { error.Missing => {} }; }\n";
    const configuration = try parseConfiguration(arena.allocator(),
        \\{"lints":{"profile":"idiomatic"}}
    );
    const found = try findings(arena.allocator(), source, configuration);
    var error_switch = false;
    var duplicate = false;
    var unused_count: usize = 0;
    var normalized_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .non_exhaustive_error_switch => {
            error_switch = true;
            try std.testing.expect(std.mem.indexOf(u8, finding.fixes[0].edits[0].replacement, "error.Denied") != null);
        },
        .duplicate_import => duplicate = true,
        .unused_import => unused_count += 1,
        .redundant_import_path => normalized_count += 1,
        else => {},
    };
    try std.testing.expect(error_switch);
    try std.testing.expect(duplicate);
    try std.testing.expectEqual(@as(usize, 2), unused_count);
    try std.testing.expectEqual(@as(usize, 2), normalized_count);
}

test "mutation through @field keeps a var mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn withStackAlign(cc: Convention, alignment: u64) Convention {\n" ++
        "    var result = cc;\n" ++
        "    @field(result, @tagName(cc)).incoming_stack_alignment = alignment;\n" ++
        "    return result;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .never_mutated_var);
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_switch_prong);
}

test "error-set types foreign symbols and re-exports keep their names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub const VerifyError = WeakError || IdentityError;\n" ++
        "const WeakError = error{Weak};\n" ++
        "const IdentityError = error{Identity};\n" ++
        "extern \"c\" fn dispatch_get_context(object: usize) ?*anyopaque;\n" ++
        "pub extern \"root\" fn _errnop() *i32;\n" ++
        "pub const _dyld_image_count = darwin._dyld_image_count;\n" ++
        "const darwin = @import(\"darwin.zig\");\n" ++
        "const BadValue = error.Oops;\n" ++
        "pub fn use() void { _ = dispatch_get_context(0); _ = VerifyError; _ = BadValue; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    configuration.levels[@intFromEnum(Rule.underscore_private_name)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var naming_count: usize = 0;
    var underscore_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .non_idiomatic_name => {
            naming_count += 1;
            // 'error.Oops' is a value, not an error-set type, so the TitleCase
            // binding is still reported.
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "'BadValue'") != null);
        },
        .underscore_private_name => underscore_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
    try std.testing.expectEqual(@as(usize, 0), underscore_count);
}

test "foreign-binding files preserve literal constants and extern builtin names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "extern fn One() void; extern fn Two() void; extern fn Three() void; extern fn Four() void;\n" ++
        "extern fn Five() void; extern fn Six() void; extern fn Seven() void; extern fn Eight() void;\n" ++
        "const GENERIC_READ = 1; const FILE_SHARE_WRITE = 2;\n" ++
        "const CreateIoCompletionPort = @extern(*const fn () callconv(.c) void, .{ .name = \"CreateIoCompletionPort\" });\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| {
        if (finding.rule == .non_idiomatic_name) std.debug.print("unexpected foreign naming finding: {s}\n", .{finding.message});
        try std.testing.expect(finding.rule != .non_idiomatic_name);
    }
}

test "translate-c output skips file-local diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub const __builtin_bswap16 = @import(\"std\").zig.c_builtins.__builtin_bswap16;\n" ++
        "pub const __builtin_bswap32 = @import(\"std\").zig.c_builtins.__builtin_bswap32;\n" ++
        "pub const __builtin_bswap64 = @import(\"std\").zig.c_builtins.__builtin_bswap64;\n" ++
        "fn generated() void { var value = 1; missing(value); }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a catch body that records the captured error keeps its context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn check(cache: *Cache) !void {\n" ++
        "    cache.file.lock() catch |err| {\n" ++
        "        cache.diagnostic = err;\n" ++
        "        return error.CacheCheckFailed;\n" ++
        "    };\n" ++
        "}\n" ++
        "fn remap(cache: *Cache) !void {\n" ++
        "    cache.file.lock() catch return error.CacheCheckFailed;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.lost_error_context)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var context_loss_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .lost_error_context) context_loss_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), context_loss_count);
}

test "file naming follows the implicit file struct shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_file_name)] = .information;
    const namespace_source: [:0]const u8 = "pub fn run() void {}\n";
    const type_source: [:0]const u8 = "value: u32,\n";
    try std.testing.expect((try fileNameFinding(arena.allocator(), namespace_source, "BadName.zig", configuration)) != null);
    try std.testing.expect((try fileNameFinding(arena.allocator(), type_source, "bad_name.zig", configuration)) != null);
    try std.testing.expect((try fileNameFinding(arena.allocator(), namespace_source, "good_name.zig", configuration)) == null);
    try std.testing.expect((try fileNameFinding(arena.allocator(), type_source, "GoodName.zig", configuration)) == null);
}

test "catch diagnostics distinguish unreachable assertions from error remapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fail() error{Failed}!void { return error.Failed; }\n" ++
        "fn run() error{Wrapped}!void {\n" ++
        "    fail() catch unreachable;\n" ++
        "    fail() catch return error.Wrapped;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unsafe_catch_unreachable)] = .warning;
    configuration.levels[@intFromEnum(Rule.lost_error_context)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var saw_unreachable = false;
    var saw_context_loss = false;
    for (found) |finding| switch (finding.rule) {
        .unsafe_catch_unreachable => saw_unreachable = true,
        .lost_error_context => saw_context_loss = true,
        else => {},
    };
    try std.testing.expect(saw_unreachable);
    try std.testing.expect(saw_context_loss);
}

test "resource diagnostics require visible close unlock or ownership transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    mutex.lock();\n" ++
        "}\n" ++
        "fn clean(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    defer file.close();\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    defer list.deinit(allocator);\n" ++
        "    mutex.lock();\n" ++
        "    defer mutex.unlock();\n" ++
        "}\n" ++
        "fn transfer(directory: anytype) !anytype {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    return file;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), warning_count);
}

test "public lock APIs and temporary unlock restoration do not require local cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn lockDemand(self: *State) void { self.mutex.lock(); }\n" ++
        "pub fn drain(self: *State) Iterator { self.mutex.lock(); return .{ .state = self }; }\n" ++
        "pub fn run(mutex: anytype) void { mutex.lock(); }\n" ++
        "fn restore(self: *State) void { self.mutex.unlock(); defer self.mutex.lock(); work(); }\n" ++
        "fn leak(mutex: anytype) void { mutex.lock(); }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), warning_count);
}

test "undefined escape warns only before whole-value initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak() u32 { var result: u32 = undefined; return result; }\n" ++
        "fn clean() u32 { var result: u32 = undefined; result = 42; return result; }\n" ++
        "fn initializedByPointer(fill: anytype) u32 { var result: u32 = undefined; fill(&result); return result; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .undefined_value_escape) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "undefined tracking ignores same-named members type queries and guarded errdefer cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn outputs(fill: anytype, buffer: anytype) !void {\n" ++
        "    var len: usize = undefined;\n" ++
        "    try fill(buffer.len, &len);\n" ++
        "    _ = len;\n" ++
        "}\n" ++
        "fn parse(fill: anytype) !void {\n" ++
        "    var value: struct { field: bool } = undefined;\n" ++
        "    try fill(@TypeOf(value), &value);\n" ++
        "    _ = value.field;\n" ++
        "}\n" ++
        "fn pipelines() !void {\n" ++
        "    var values: Pair = undefined;\n" ++
        "    errdefer if (initialized()) { @field(values, \"first\").deinit(); };\n" ++
        "    @field(values, \"first\") = try make();\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .undefined_value_escape);
}

test "comptime hints use proven container members and explicit constant conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = struct { value: u32, const enabled = true; };\n" ++
        "fn run() void {\n" ++
        "    _ = @hasField(State, \"value\");\n" ++
        "    _ = @hasField(State, \"missing\");\n" ++
        "    _ = @hasDecl(State, \"enabled\");\n" ++
        "    if (comptime true) {}\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unknown_comptime_member)] = .hint;
    configuration.levels[@intFromEnum(Rule.constant_comptime_condition)] = .hint;
    const found = try findings(arena.allocator(), source, configuration);
    var member_count: usize = 0;
    var condition_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .unknown_comptime_member => member_count += 1,
        .constant_comptime_condition => condition_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), member_count);
    try std.testing.expectEqual(@as(usize, 1), condition_count);

    const generated_source: [:0]const u8 =
        "const Generated = Factory();\n" ++
        "fn inspect() void { _ = @hasField(Generated, \"missing\"); }\n";
    const generated_findings = try findingsWithShapes(arena.allocator(), generated_source, configuration, &.{.{
        .type_name = "Generated",
        .kind = .structure,
        .fields = &.{ "name", "count" },
    }});
    var generated_member_count: usize = 0;
    for (generated_findings) |finding| switch (finding.rule) {
        .unknown_comptime_member => generated_member_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), generated_member_count);
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
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, ".slow") != null);
        try std.testing.expect(std.mem.indexOf(u8, finding.message, ".fast") == null);
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
    const found = try findingsWithShapes(arena.allocator(), source, Configuration.defaults(), &.{.{
        .type_name = "Tag",
        .kind = .enumeration,
        .fields = &.{ "a", "b", "_" },
    }});
    var missing_switch_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_switch_prong) {
        missing_switch_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, ".b") != null);
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "._") == null);
        try std.testing.expect(std.mem.indexOf(u8, finding.fixes[0].edits[0].replacement, "._") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), missing_switch_count);
}

test "pointer parameters mutated through nested members or subscripts stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Inner = struct { count: u32 };\n" ++
        "const State = struct { inner: Inner };\n" ++
        "const Buffer = struct { bytes: [4]u8 };\n" ++
        "fn touch(state: *State, buffer: *Buffer, counter: *u32) void {\n" ++
        "    state.inner.count = 1;\n" ++
        "    buffer.bytes[0] = 0;\n" ++
        "    counter.* += 1;\n" ++
        "}\n" ++
        "fn observe(state: *State) u32 {\n" ++
        "    return state.inner.count;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mutable_pointer_parameter)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| if (finding.rule == .mutable_pointer_parameter) {
        pointer_count += 1;
        try std.testing.expect(finding.span.start > std.mem.indexOf(u8, source, "fn observe").?);
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "pointer parameters mutated through captures or returned pointers stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const State = union(enum) { value: u32 };\n" ++
        "const Store = struct { values: []u32, state: State };\n" ++
        "fn update(store: *Store) void { switch (store.state) { .value => |*value| value.* += 1 } }\n" ++
        "fn clear(store: *Store) void { for (store.values) |*value| value.* = 0; }\n" ++
        "fn first(store: *Store) *u32 { return &store.values[0]; }\n" ++
        "fn observe(store: *Store) usize { return store.values.len; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mutable_pointer_parameter)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .mutable_pointer_parameter) pointer_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "pointer owner stays mutable when another parameter mutates its field type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const OwnedConfiguration = struct { compiled: bool };\n" ++
        "const Highlighter = struct {\n" ++
        "    configurations: []OwnedConfiguration,\n" ++
        "    fn compileConfiguration(self: *Highlighter, owned: *OwnedConfiguration) void {\n" ++
        "        _ = self.configurations.len;\n" ++
        "        owned.compiled = true;\n" ++
        "    }\n" ++
        "    fn count(self: *Highlighter) usize { return self.configurations.len; }\n" ++
        "};\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mutable_pointer_parameter)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var pointer_count: usize = 0;
    for (found) |finding| if (finding.rule == .mutable_pointer_parameter) {
        pointer_count += 1;
        try std.testing.expect(finding.span.start > std.mem.indexOf(u8, source, "fn count").?);
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
}

test "type aliases built from type-returning calls expect TitleCase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const MyList = std.ArrayList(u8);\n" ++
        "const bad_list = std.ArrayList(u8);\n" ++
        "fn run() void { const items = std.ArrayList(u8).init; _ = items; _ = MyList; _ = bad_list; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_name)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("bad_list", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "destructuring assignment counts as mutation of its targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn divmod(a: u32, b: u32) struct { u32, u32 } { return .{ a / b, a % b }; }\n" ++
        "fn run() void {\n" ++
        "    var quotient: u32 = 0;\n" ++
        "    var remainder: u32 = 0;\n" ++
        "    var untouched: u32 = 0;\n" ++
        "    quotient, remainder = divmod(1, 2);\n" ++
        "    _ = quotient; _ = remainder; _ = untouched;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var mutation_count: usize = 0;
    for (found) |finding| if (finding.rule == .never_mutated_var) {
        mutation_count += 1;
        try std.testing.expectEqualStrings("untouched", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), mutation_count);
}

test "undefined values initialized by destructuring do not escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn divmod(a: u32, b: u32) struct { u32, u32 } { return .{ a / b, a % b }; }\n" ++
        "fn run() u32 {\n" ++
        "    var quotient: u32 = undefined;\n" ++
        "    var remainder: u32 = undefined;\n" ++
        "    quotient, remainder = divmod(1, 2);\n" ++
        "    return quotient + remainder;\n" ++
        "}\n" ++
        "fn leak() u32 { var escaped: u32 = undefined; return escaped; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var escape_count: usize = 0;
    for (found) |finding| if (finding.rule == .undefined_value_escape) {
        escape_count += 1;
        try std.testing.expectEqualStrings("escaped", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), escape_count);
}

test "needless cast proof stays within the enclosing function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn widen(size: u32) u32 { return @as(u32, size); }\n" ++
        "fn narrow(size: u16) u32 { return @as(u32, size); }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.needless_cast)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var cast_count: usize = 0;
    for (found) |finding| if (finding.rule == .needless_cast) {
        cast_count += 1;
        try std.testing.expect(finding.span.start < std.mem.indexOf(u8, source, "fn narrow").?);
    };
    try std.testing.expectEqual(@as(usize, 1), cast_count);
}

test "organize imports leaves container doc comments in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "//! Module documentation.\n" ++
        "const zebra = @import(\"zebra.zig\");\n" ++
        "const apple = @import(\"apple.zig\");\n" ++
        "fn use() void { _ = zebra; _ = apple; }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unsorted_imports)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var import_count: usize = 0;
    for (found) |finding| if (finding.rule == .unsorted_imports) {
        import_count += 1;
        try std.testing.expectEqual(std.mem.indexOf(u8, source, "const zebra").?, finding.fixes[0].edits[0].span.start);
        try std.testing.expect(std.mem.indexOf(u8, finding.fixes[0].edits[0].replacement, "//!") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), import_count);
}

test "prefer try rewrites chained calls from the expression start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(stream: anytype, data: []const u8) !void {\n" ++
        "    const written = stream.getWriter().write(data) catch |err| return err;\n" ++
        "    _ = written;\n" ++
        "}\n" ++
        "fn opaque_receiver(data: []const u8) !void {\n" ++
        "    const written = (makeWriter()).write(data) catch |err| return err;\n" ++
        "    _ = written;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.prefer_try)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var try_count: usize = 0;
    for (found) |finding| if (finding.rule == .prefer_try) {
        try_count += 1;
        try std.testing.expectEqualStrings("try stream.getWriter().write(data)", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), try_count);
}

test "optional capture skips foreign fields and assigned unwraps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn read(y: ?u32, box: anytype) u32 {\n" ++
        "    if (y != null) { return y.? + box.y.?; }\n" ++
        "    return 0;\n" ++
        "}\n" ++
        "fn bump(count: ?u32) void {\n" ++
        "    var y = count;\n" ++
        "    if (y != null) { y.? += 1; }\n" ++
        "    _ = y;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.prefer_optional_capture)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var capture_count: usize = 0;
    for (found) |finding| if (finding.rule == .prefer_optional_capture) {
        capture_count += 1;
        try std.testing.expectEqual(@as(usize, 2), finding.fixes[0].edits.len);
        try std.testing.expectEqual(std.mem.indexOf(u8, source, "y.? + box").?, finding.fixes[0].edits[1].span.start);
    };
    try std.testing.expectEqual(@as(usize, 1), capture_count);
}

test "discarded error is reported even with an unused capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() !u32 { return 1; }\n" ++
        "fn run() void {\n" ++
        "    load() catch |err| {};\n" ++
        "    load() catch |err| { log(err); };\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.discarded_error)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var discard_count: usize = 0;
    for (found) |finding| if (finding.rule == .discarded_error) {
        discard_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), discard_count);
}

test "lost error context ignores conditional remaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() !u32 { return 1; }\n" ++
        "fn conditional() !u32 {\n" ++
        "    return load() catch |err| {\n" ++
        "        if (err == error.FileNotFound) return error.ConfigMissing;\n" ++
        "        return err;\n" ++
        "    };\n" ++
        "}\n" ++
        "fn unconditional() !u32 {\n" ++
        "    return load() catch { return error.LoadFailed; };\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.lost_error_context)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var context_count: usize = 0;
    for (found) |finding| if (finding.rule == .lost_error_context) {
        context_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "LoadFailed") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), context_count);
}

test "usingnamespace uncertainty stays within its container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Mixin = struct { pub const shared = 1; };\n" ++
        "const Widget = struct {\n" ++
        "    usingnamespace Mixin;\n" ++
        "    count: u32,\n" ++
        "};\n" ++
        "const Plain = struct { count: u32 };\n" ++
        "fn run() void {\n" ++
        "    _ = @hasDecl(Widget, \"shared\");\n" ++
        "    _ = @hasDecl(Plain, \"missing\");\n" ++
        "    borrowed();\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unknown_comptime_member)] = .hint;
    const found = try findings(arena.allocator(), source, configuration);
    var member_count: usize = 0;
    var call_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_call) call_count += 1;
        if (finding.rule == .unknown_comptime_member) {
            member_count += 1;
            try std.testing.expect(std.mem.indexOf(u8, finding.message, "'Plain'") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), member_count);
    try std.testing.expectEqual(@as(usize, 1), call_count);

    const control: [:0]const u8 = "fn run() void { borrowed(); }\n";
    const control_findings = try findings(arena.allocator(), control, configuration);
    var unresolved_count: usize = 0;
    for (control_findings) |finding| if (finding.rule == .unresolved_call) {
        unresolved_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), unresolved_count);
}

test "doc comment style checks the first line of a multi-line comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "/// Returns the parsed config.\n" ++
        "/// parse errors are returned verbatim.\n" ++
        "pub fn parse() void {}\n" ++
        "/// render draws the frame.\n" ++
        "/// Later lines may say anything.\n" ++
        "pub fn render() void {}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.doc_comment_style)] = .information;
    const found = try findings(arena.allocator(), source, configuration);
    var docs_count: usize = 0;
    for (found) |finding| if (finding.rule == .doc_comment_style) {
        docs_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "'render'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), docs_count);
}

test "top-level sentinel arrays do not make a file a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_idiomatic_file_name)] = .information;
    const source: [:0]const u8 = "pub const table = [_:0]u8{ 1, 2, 3 };\npub fn run() void {}\n";
    try std.testing.expect((try fileNameFinding(arena.allocator(), source, "tables.zig", configuration)) == null);
    try std.testing.expect((try fileNameFinding(arena.allocator(), source, "Tables.zig", configuration)) != null);
}

test "bound lock results are guards not mutex locks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guarded(db: anytype) void {\n" ++
        "    const guard = db.lock();\n" ++
        "    defer guard.deinit();\n" ++
        "}\n" ++
        "fn leaky(mutex: anytype) void {\n" ++
        "    mutex.lock();\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var lock_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        lock_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "'mutex'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), lock_count);
}

test "catch unreachable offers try only inside fallible functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn fail() !void { return error.Failed; }\n" ++
        "fn propagate() !void {\n" ++
        "    fail() catch unreachable;\n" ++
        "}\n" ++
        "fn swallow() void {\n" ++
        "    fail() catch unreachable;\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unsafe_catch_unreachable)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var unreachable_count: usize = 0;
    for (found) |finding| if (finding.rule == .unsafe_catch_unreachable) {
        unreachable_count += 1;
        if (finding.span.start < std.mem.indexOf(u8, source, "fn swallow").?) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            try std.testing.expectEqualStrings("try fail()", finding.fixes[0].edits[0].replacement);
        } else {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), unreachable_count);
}

test "unused private declarations offer whole declaration removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const unused = 2;\n" ++
        "// The comment blocks deletion.\n" ++
        "const commented = 3;\n" ++
        "fn orphan() void {}\n" ++
        "pub fn run() void {}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unused_private_declaration)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var declaration_count: usize = 0;
    for (found) |finding| if (finding.rule == .unused_private_declaration) {
        declaration_count += 1;
        const name = source[finding.span.start..finding.span.end];
        if (std.mem.eql(u8, name, "unused")) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            const span = finding.fixes[0].edits[0].span;
            try std.testing.expectEqualStrings("const unused = 2;\n", source[span.start..span.end]);
        } else if (std.mem.eql(u8, name, "commented")) {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        } else if (std.mem.eql(u8, name, "orphan")) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            const span = finding.fixes[0].edits[0].span;
            try std.testing.expectEqualStrings("fn orphan() void {}\n", source[span.start..span.end]);
        } else return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 3), declaration_count);
}

test "type definitions inside test bodies are not resource acquisitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"merge\" {\n" ++
        "    const T = struct {\n" ++
        "        output_buf: std.ArrayList(u8),\n" ++
        "        fn init(gpa: std.mem.Allocator) !@This() {\n" ++
        "            return .{ .output_buf = std.ArrayList(u8).init(gpa) };\n" ++
        "        }\n" ++
        "    };\n" ++
        "    _ = T;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "missing resource cleanup offers inserting a defer after the acquisition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(directory: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(!finding.fixes[0].fix_all);
        const edit = finding.fixes[0].edits[0];
        try std.testing.expectEqual(edit.span.start, edit.span.end);
        try std.testing.expectEqual(std.mem.indexOfScalar(u8, source, ';').? + 1, edit.span.start);
        try std.testing.expectEqualStrings("\n    defer file.close();", edit.replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "else stays when the branch terminator is not the last statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(stack: anytype, model: anytype, c: bool) !void {\n" ++
        "    if (c) {\n" ++
        "        const top = stack.peek() orelse unreachable;\n" ++
        "        try model.append(top);\n" ++
        "    } else {\n" ++
        "        model.clear();\n" ++
        "    }\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.needless_else_after_terminator)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
}

test "a loop else runs on normal exit and is never needless" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(values: []const u8) void {\n" ++
        "    for (values) |value| {\n" ++
        "        _ = value;\n" ++
        "        break;\n" ++
        "    } else {\n" ++
        "        mark();\n" ++
        "    }\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.needless_else_after_terminator)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
}

test "else in a switch prong remains part of the if expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(order: std.math.Order, found: bool) u8 {\n" ++
        "    return switch (order) {\n" ++
        "        .gt => if (found) { return 1; } else { return 2; },\n" ++
        "        else => 0,\n" ++
        "    };\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.needless_else_after_terminator)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .needless_else_after_terminator);
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
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.non_exhaustive_switch_else)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .non_exhaustive_switch_else);
}

test "pointer parameters that escape mutably stay mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Ring = struct { items: [4]u8, index: usize };\n" ++
        "fn itemPtr(ring: *Ring, index: usize) *u8 {\n" ++
        "    return &ring.items[index];\n" ++
        "}\n" ++
        "fn head(ring: *Ring) []u8 {\n" ++
        "    return ring.items[0..ring.index];\n" ++
        "}\n" ++
        "fn advance(ring: *Ring) void {\n" ++
        "    switch (ring.index) { else => |*value| value.* = 0 }\n" ++
        "}\n" ++
        "fn deinit(ring: *Ring) void {\n" ++
        "    _ = ring.items[0];\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mutable_pointer_parameter)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .mutable_pointer_parameter);
}

test "constrained signatures and field address escapes keep mutable pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Read = struct { ready_at: u64 };\n" ++
        "fn lessThan(_: void, a: *Read, b: *Read) bool {\n" ++
        "    return a.ready_at < b.ready_at;\n" ++
        "}\n" ++
        "const Queue = std.PriorityQueue(*Read, void, lessThan);\n" ++
        "const Forest = struct { grooves: u32 };\n" ++
        "fn groovePtr(forest: *Forest) *u32 {\n" ++
        "    return &@field(forest, \"grooves\");\n" ++
        "}\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.mutable_pointer_parameter)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .mutable_pointer_parameter);
}

test "compound Context and State names describe their role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const LookupContext = struct { key: u32 };\n" ++
        "const CheckpointState = struct { op: u64 };\n" ++
        "pub const Context = struct { key: u32 };\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.vague_type_name)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var vague_count: usize = 0;
    for (found) |finding| if (finding.rule == .vague_type_name) {
        vague_count += 1;
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "'Context'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), vague_count);
}

test "renamed declarations report their unresolved type references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const MessagePool = @import(\"message_pool\");\n" ++
        "const Mssage = MessagePool.Message;\n" ++
        "fn toMessage(target: *Message.Prepare) void { _ = target; }\n" ++
        "const Pending = struct { message: ?*Message.Request = null };\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var unresolved_count: usize = 0;
    for (found) |finding| if (finding.rule == .unresolved_identifier) {
        unresolved_count += 1;
        try std.testing.expectEqualStrings("Message", source[finding.span.start..finding.span.end]);
        try std.testing.expect(std.mem.indexOf(u8, finding.message, "unresolved identifier 'Message'") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), unresolved_count);
}

test "resolved bindings and qualified members do not report unresolved identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Entry = struct { value: u8 };\n" ++
        "fn read(entry: Entry, maybe: ?u8, pair: struct { u8, u8 }) !u8 {\n" ++
        "    const .{ first, second } = pair;\n" ++
        "    const third, const fourth = pair;\n" ++
        "    if (maybe) |value| return entry.value + value + first + second + third + fourth;\n" ++
        "    return error.Missing;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "container tags declared inside their container resolve in the header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Value = union(Key) { item: u8, pub const Key = enum { item } };\n" ++
        "const Handle = enum(Backing) { root, pub const Backing = u16 };\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "generic parameters remain visible after switch return types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Options = struct {};\n" ++
        "fn encode(data: anytype, opts: Options) switch (@TypeOf(data)) { []u8 => u8, else => void } {\n" ++
        "    _ = data;\n" ++
        "    _ = opts;\n" ++
        "}\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "unresolved calls keep their specific diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn run() void { missing(); }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var call_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .unresolved_call => call_count += 1,
        .unresolved_identifier => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), call_count);
}

test "unresolved identifier diagnostics honor source suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line unresolved-identifier\n" ++
        "const value: Missing = undefined;\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_identifier);
}

test "unresolved names respect lexical scopes and declaration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn first() void { _ = later; _ = foreign; const later = 1; }\n" ++
        "fn second() void { const foreign = 1; _ = foreign; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var unresolved_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_identifier) unresolved_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), unresolved_count);
}

test "obvious value bindings cannot be called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "const run = 1; fn main() void { run(); }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var non_callable_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_call and
            std.mem.indexOf(u8, finding.message, "not callable") != null) non_callable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), non_callable_count);
}

test "missing members are reported only for proven local receiver shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Message = struct { value: u8, fn read(_: Message) void {} };\n" ++
        "fn use(message: Message, unknown: anytype) void { message.read(); _ = message.mssage; _ = Message.missing; unknown.missing(); }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var member_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_member) member_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), member_count);
}

test "member inference follows the visible shadowing binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Kind = enum { child };\n" ++
        "const Entry = struct { kind: Kind, child: u8 };\n" ++
        "fn use(maybe: ?Entry) void { if (maybe) |*kind| _ = kind.child; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "void tagged union cases are resolved as members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Operation = union(enum) { read: u8, checkpoint }; fn use() void { _ = Operation.checkpoint; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .unresolved_member);
}

test "named branches require an enclosing label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { outer: for ([_]u8{ 1, 2 }) |_| { break :outer; } break :missing; }\n";
    const found = try findings(arena.allocator(), source, Configuration.defaults());
    var label_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unresolved_label) label_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), label_count);
}

test "field reflection reports missing members on typed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Message = struct { value: u8 }; fn use(message: Message) void { _ = @field(message, \"value\"); _ = @field(message, \"missing\"); }\n";
    var configuration = Configuration.defaults();
    configuration.levels[@intFromEnum(Rule.unknown_comptime_member)] = .warning;
    const found = try findings(arena.allocator(), source, configuration);
    var reflection_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .unknown_comptime_member) reflection_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reflection_count);
}
