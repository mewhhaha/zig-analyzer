//! The Zig style guide: naming, file names, doc comments and public API documentation.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Finding = types.Finding;
const ResolvedShape = types.ResolvedShape;

pub const rules = [_]types.Rule{
    .non_idiomatic_name,
    .vague_type_name,
    .redundant_qualified_name,
    .underscore_private_name,
    .non_idiomatic_file_name,
    .doc_comment_style,
    .public_declaration_docs,
};

pub fn run(context: RuleRun) !void {
    try findNonIdiomaticNames(context);
    try findOfficialStyleIssues(context);
}

pub fn fileNameFinding(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    path: []const u8,
    configuration: Configuration,
) !?Finding {
    const level = configuration.level(.non_idiomatic_file_name);
    if (level == .off) return null;
    const basename = std.Io.Dir.path.basename(path);
    if (!std.mem.endsWith(u8, basename, ".zig") or basename.len == ".zig".len) return null;
    if (std.mem.eql(u8, basename, "build.zig")) return null;
    const name = basename[0 .. basename.len - ".zig".len];
    var has_top_level_fields = false;
    for (tree.rootDecls()) |declaration| {
        switch (tree.nodeTag(declaration)) {
            .container_field, .container_field_align, .container_field_init => {
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
        .span = .{ .start = 0, .end = @min(tree.source.len, 1) },
        .message = try allocator.print(
            "file '{s}' represents {s} and should use a {s} name",
            .{
                basename,
                if (has_top_level_fields) "a type with fields" else "a namespace",
                if (has_top_level_fields) "TitleCase" else "snake_case",
            },
        ),
    };
}

fn findNonIdiomaticNames(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.non_idiomatic_name);
    if (level == .off) return;
    const foreign_binding_dominated = fileIsDominatedByForeignBindings(source, tokens);
    var type_declaring_names: std.StringHashMapUnmanaged(void) = .empty;
    defer type_declaring_names.deinit(context.allocator);
    var structural_type_declarations: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer structural_type_declarations.deinit(context.allocator);
    var value_declarations: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer value_declarations.deinit(context.allocator);
    for (0..context.tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const declaration = context.tree.fullVarDecl(node) orelse continue;
        const initializer = declaration.ast.init_node.unwrap() orelse continue;
        const keyword_index: usize = declaration.ast.mut_token;
        if (keyword_index + 1 >= tokens.len or tokens[keyword_index].tag != .keyword_const or
            tokens[keyword_index + 1].tag != .identifier) continue;
        if (nodeIsTypeExpression(context.tree, initializer)) {
            try structural_type_declarations.put(context.allocator, keyword_index + 1, {});
        } else if (nodeIsValueExpression(context.tree, initializer)) {
            try value_declarations.put(context.allocator, keyword_index + 1, {});
        }
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index == 0) continue;
        const declares_type = switch (tokens[index - 1].tag) {
            .keyword_const => declarationInitializesType(tokens, index),
            .keyword_fn => functionDeclarationReturnsType(source, tokens, index),
            else => false,
        };
        if (declares_type) try type_declaring_names.put(context.allocator, tokenText(source, token), {});
        if (tokens[index - 1].tag == .keyword_comptime and index + 2 < tokens.len and tokens[index + 1].tag == .colon and
            tokenIs(source, tokens[index + 2], "type"))
        {
            try type_declaring_names.put(context.allocator, tokenText(source, token), {});
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
                (!context.scopes.insideFunctionOrTestBody(index) and resolvedShapeNamesType(name, context.resolved_shapes)) or
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
        try context.emit(.{
            .rule = .non_idiomatic_name,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("declaration '{s}' does not follow Zig's {s} naming convention", .{ name, convention }),
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
        if (std.mem.eql(u8, builtin_name, "@Vector")) {
            const call_end = matchingToken(tokens, identifier_index + 3, .l_paren, .r_paren) orelse return false;
            if (call_end + 1 < tokens.len and tokens[call_end + 1].tag == .l_brace) return false;
        }
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
            return type_declaring_names.contains(target);
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
    return name.len != 0 and std.ascii.isLower(name[0]) and std.mem.findScalar(u8, name, '_') == null;
}

fn isTitleCase(name: []const u8) bool {
    return name.len != 0 and std.ascii.isUpper(name[0]) and std.mem.findScalar(u8, name, '_') == null;
}

fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_') return false;
    }
    return true;
}

fn findOfficialStyleIssues(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const vague_level = context.level(.vague_type_name);
    const qualified_level = context.level(.redundant_qualified_name);
    const underscore_level = context.level(.underscore_private_name);
    const docs_level = context.level(.doc_comment_style);
    const public_docs_level = context.level(.public_declaration_docs);

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
            try context.emit(.{
                .rule = .underscore_private_name,
                .level = underscore_level,
                .span = token.loc,
                .message = try context.allocator.print(
                    "declaration '{s}' uses an underscore prefix even though Zig does not use names to express privacy",
                    .{name},
                ),
            });
        }
        const public_declaration = index >= 2 and tokens[index - 2].tag == .keyword_pub;
        if (vague_level != .off and public_declaration and declaration_tag == .keyword_const and declarationInitializesType(tokens, index)) {
            if (vagueTypeWord(name)) |word| {
                try context.emit(.{
                    .rule = .vague_type_name,
                    .level = vague_level,
                    .span = token.loc,
                    .message = try context.allocator.print(
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
                try context.emit(.{
                    .rule = .doc_comment_style,
                    .level = docs_level,
                    .span = tokens[first_doc_index].loc,
                    .message = try context.allocator.print(
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
                try context.emit(.{
                    .rule = .redundant_qualified_name,
                    .level = qualified_level,
                    .span = tokens[cursor + 1].loc,
                    .message = try context.allocator.print(
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
            if (declaration_tag == .keyword_fn and std.mem.eql(u8, declaration_name, "main")) continue;
            if (declaration_tag == .keyword_fn and isBuildEntryPoint(source, tokens, pub_index + 2)) continue;
            try context.emit(.{
                .rule = .public_declaration_docs,
                .level = public_docs_level,
                .span = tokens[pub_index + 2].loc,
                .message = try context.allocator.print("public declaration '{s}' has no doc comment", .{declaration_name}),
            });
        }
    }
}

fn isBuildEntryPoint(source: []const u8, tokens: []const std.zig.Token, name_index: usize) bool {
    if (!tokenIs(source, tokens[name_index], "build") or name_index + 1 >= tokens.len or
        tokens[name_index + 1].tag != .l_paren) return false;
    const parameters_end = matchingToken(tokens, name_index + 1, .l_paren, .r_paren) orelse return false;
    for (tokens[name_index + 2 .. parameters_end], name_index + 2..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, "Build") or index < 2) continue;
        if (tokens[index - 1].tag == .period and tokens[index - 2].tag == .identifier and
            tokenIs(source, tokens[index - 2], "std")) return true;
    }
    return false;
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

fn fileNameFindingForSource(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    path: []const u8,
    configuration: Configuration,
) !?Finding {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    return try fileNameFinding(allocator, &tree, path, configuration);
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
    const configuration = try @import("../configuration.zig").parse(arena.allocator(),
        \\{"lints":{"profile":"strict"}}
    );
    const found = try support.findings(arena.allocator(), run, source, configuration);
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
        .public_declaration_docs => if (std.mem.find(u8, finding.message, "undocumented") != null) {
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
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
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
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
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
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findingsShaped(arena.allocator(), run, &.{.{
        .type_name = "external_type",
        .kind = .structure,
        .fields = &.{"value"},
    }}, source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("external_type", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
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
    const configuration = support.only(&.{ .non_idiomatic_name, .underscore_private_name }, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var naming_count: usize = 0;
    var underscore_count: usize = 0;
    for (found) |finding| switch (finding.rule) {
        .non_idiomatic_name => {
            naming_count += 1;
            // 'error.Oops' is a value, not an error-set type, so the TitleCase
            // binding is still reported.
            try std.testing.expect(std.mem.find(u8, finding.message, "'BadValue'") != null);
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
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| {
        if (finding.rule == .non_idiomatic_name) std.debug.print("unexpected foreign naming finding: {s}\n", .{finding.message});
        try std.testing.expect(finding.rule != .non_idiomatic_name);
    }
}

test "file naming follows the implicit file struct shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.non_idiomatic_file_name}, .information);
    const namespace_source: [:0]const u8 = "pub fn run() void {}\n";
    const type_source: [:0]const u8 = "value: u32,\n";
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), namespace_source, "BadName.zig", configuration)) != null);
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), type_source, "bad_name.zig", configuration)) != null);
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), namespace_source, "good_name.zig", configuration)) == null);
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), type_source, "GoodName.zig", configuration)) == null);
}

test "ambiguous calls do not determine whether a declaration names a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const MyList = std.ArrayList(u8);\n" ++
        "const bad_list = std.ArrayList(u8);\n" ++
        "fn run() void { const items = std.ArrayList(u8).init; _ = items; _ = MyList; _ = bad_list; }\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .non_idiomatic_name);
}

test "vector values use value naming while vector type aliases use type naming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const vector_value = @Vector(4, u8){ 1, 2, 3, 4 };\n" ++
        "const VectorType = @Vector(4, u8);\n" ++
        "const BadVectorValue = @Vector(4, u8){ 1, 2, 3, 4 };\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("BadVectorValue", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "main entry points do not require API documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "pub fn main() !void {}\n";
    const configuration = support.only(&.{.public_declaration_docs}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .public_declaration_docs);
}

test "build entry points do not require API documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn build(builder: *std.Build) void { _ = builder; }\n" ++
        "pub fn buildCache() void {}\n";
    const configuration = support.only(&.{.public_declaration_docs}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var docs_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .public_declaration_docs) docs_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), docs_count);
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
    const configuration = support.only(&.{.doc_comment_style}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var docs_count: usize = 0;
    for (found) |finding| if (finding.rule == .doc_comment_style) {
        docs_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "'render'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), docs_count);
}

test "top-level sentinel arrays do not make a file a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.non_idiomatic_file_name}, .information);
    const source: [:0]const u8 = "pub const table = [_:0]u8{ 1, 2, 3 };\npub fn run() void {}\n";
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), source, "tables.zig", configuration)) == null);
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), source, "Tables.zig", configuration)) != null);
}

test "build entrypoint keeps its conventional file name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.non_idiomatic_file_name}, .information);
    const source: [:0]const u8 = "pub fn build(b: *Build) void { _ = b; }\n";
    try std.testing.expect((try fileNameFindingForSource(arena.allocator(), source, "build.zig", configuration)) == null);
}

test "compound Context and State names describe their role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const LookupContext = struct { key: u32 };\n" ++
        "const CheckpointState = struct { op: u64 };\n" ++
        "pub const Context = struct { key: u32 };\n";
    const configuration = support.only(&.{.vague_type_name}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var vague_count: usize = 0;
    for (found) |finding| if (finding.rule == .vague_type_name) {
        vague_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "'Context'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), vague_count);
}
