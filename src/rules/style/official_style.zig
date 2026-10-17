//! The Zig style guide: naming, file names, doc comments and public API documentation.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const foreignDeclaration = @import("../../syntax/tokens.zig").foreignDeclaration;
const syntax_scope = @import("../../syntax/scope.zig");
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const deprecated_declarations = @import("../modernize/deprecated_declarations.zig");
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
    var foreign_names: ForeignNames = try .init(context);
    defer foreign_names.deinit(context.allocator);
    try findNonIdiomaticNames(context, &foreign_names);
    try findOfficialStyleIssues(context, &foreign_names);
}

/// Declarations spelled as an external symbol, a name the Zig source does not
/// get to choose: `extern` and `export` declarations, functions with a calling
/// convention other than Zig's, which C or the linker call by name
/// (`callconv(.c)`, `callconv(lib.calling_conv)`), and declarations the file
/// exports with `@export(&name, ...)`.
const ForeignNames = struct {
    /// Name tokens of the declarations an `@export` in the file names.
    exported: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn init(context: RuleRun) !ForeignNames {
        var names: ForeignNames = .{};
        errdefer names.deinit(context.allocator);
        const tokens = context.tokens;
        for (tokens, 0..) |token, index| {
            if (token.tag != .builtin or index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren or
                !context.tokenIs(index, "@export")) continue;
            const target = if (tokens[index + 2].tag == .ampersand) index + 3 else index + 2;
            if (tokens[target].tag != .identifier or target + 1 >= tokens.len or tokens[target + 1].tag != .comma) continue;
            const binding = context.scopes.findBinding(target) orelse continue;
            try names.exported.put(context.allocator, binding.token_index, {});
        }
        return names;
    }

    fn deinit(names: *ForeignNames, allocator: std.mem.Allocator) void {
        names.exported.deinit(allocator);
    }

    /// Whether the declaration named at `identifier_index`, after its `fn`,
    /// `const` or `var` keyword, is spelled as an external symbol.
    fn contains(names: *const ForeignNames, scopes: *const syntax_scope.Index, identifier_index: usize) bool {
        const tokens = scopes.tokens;
        if (foreignDeclaration(tokens, identifier_index - 1)) return true;
        if (tokens[identifier_index - 1].tag == .keyword_fn and hasForeignCallingConvention(scopes, identifier_index)) return true;
        return names.exported.contains(identifier_index);
    }
};

/// Whether the function named at `name_index` declares a calling convention
/// other than Zig's own `.auto` and `.@"inline"`.
fn hasForeignCallingConvention(scopes: *const syntax_scope.Index, name_index: usize) bool {
    const tokens = scopes.tokens;
    if (name_index + 1 >= tokens.len or tokens[name_index + 1].tag != .l_paren) return false;
    var cursor = (scopes.matchingToken(name_index + 1) orelse return false) + 1;
    // 'align(4)', 'addrspace(.gs)' and 'linksection(".text")' come first.
    while (cursor + 1 < tokens.len and tokens[cursor + 1].tag == .l_paren) {
        const closing = scopes.matchingToken(cursor + 1) orelse return false;
        switch (tokens[cursor].tag) {
            .keyword_align, .keyword_addrspace, .keyword_linksection => cursor = closing + 1,
            .keyword_callconv => {
                if (closing != cursor + 4 or tokens[cursor + 2].tag != .period) return true;
                const convention = tokenText(scopes.source, tokens[cursor + 3]);
                return !std.mem.eql(u8, convention, "auto") and !std.mem.eql(u8, convention, "@\"inline\"");
            },
            else => return false,
        }
    }
    return false;
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

fn findNonIdiomaticNames(context: RuleRun, foreign_names: *const ForeignNames) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.non_idiomatic_name);
    if (level == .off) return;
    const foreign_binding_dominated = fileIsDominatedByForeignBindings(source, tokens);
    var type_declarations: TypeDeclarations = .{ .scopes = context.scopes };
    defer type_declarations.deinit(context.allocator);
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
            .keyword_const => declarationInitializesType(context.scopes, index),
            .keyword_fn => functionDeclarationReturnsType(context.scopes, index),
            else => false,
        };
        if (declares_type or (tokens[index - 1].tag == .keyword_comptime and index + 2 < tokens.len and
            tokens[index + 1].tag == .colon and tokenIs(source, tokens[index + 2], "type")))
        {
            try type_declarations.put(context.allocator, tokenText(source, token), index);
        }
    }
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index == 0) continue;
        const declaration_tag = tokens[index - 1].tag;
        if (declaration_tag != .keyword_fn and declaration_tag != .keyword_const and declaration_tag != .keyword_var) continue;
        if (!identifierIsDeclaration(tokens, index)) continue;
        if (foreign_names.contains(context.scopes, index)) continue;
        if (declaration_tag == .keyword_const and declarationInitializedByExternBuiltin(source, tokens, index)) continue;
        if (foreign_binding_dominated and declaration_tag == .keyword_const and declarationHasLiteralInitializer(tokens, index)) continue;
        if (declaration_tag == .keyword_const and declarationIsSameNameAlias(source, tokens, index)) continue;
        const name = tokenText(source, token);
        if (std.mem.startsWith(u8, name, "@\"")) continue;
        const is_namespace = declaration_tag == .keyword_const and
            (declarationIsNamespace(context.scopes, index) or declarationIsBareImport(source, tokens, index));
        const is_type = declaration_tag == .keyword_const and
            (structural_type_declarations.contains(index) or
                (!context.scopes.insideFunctionOrTestBody(index) and resolvedShapeNamesType(name, context.resolved_shapes)) or
                declarationNamesType(source, tokens, index, &type_declarations));
        const type_function = declaration_tag == .keyword_fn and functionDeclarationReturnsType(context.scopes, index);
        if (declaration_tag == .keyword_const and !is_namespace and !is_type and
            !value_declarations.contains(index)) continue;
        const function_case = context.configuration.function_case;
        const idiomatic = if (is_namespace)
            isSnakeCase(name) or isTitleCase(name)
        else if (type_function or is_type)
            isTitleCase(name)
        else if (declaration_tag == .keyword_fn) switch (function_case) {
            .camel_case => isCamelCase(name),
            .snake_case => isSnakeCase(name),
        } else isSnakeCase(name);
        if (idiomatic) continue;
        // 'const O_RDONLY = 0;' keeps the spelling of the C API or protocol
        // constant it mirrors, which readers search for verbatim.
        if (declaration_tag == .keyword_const and isConstantCase(name)) continue;
        // A deprecated declaration keeps its old name for existing callers.
        if (deprecated_declarations.deprecationAdvice(source, tokens, index) != null) continue;
        // A project that spells a kind of declaration another way by a strong
        // majority, as tigerbeetle does its snake_case functions, has made
        // that its convention; `minority-naming-style` holds names to it.
        const project = context.configuration.naming_conventions;
        const project_case = if (is_namespace)
            null
        else if (type_function or is_type)
            project.type_name
        else if (declaration_tag == .keyword_fn)
            // An explicit `function-case` is the project's own statement.
            (if (context.configuration.function_case_explicit) null else project.function)
        else
            project.constant;
        if (project_case) |case| if (followsCase(case, name)) continue;
        const convention = if (is_namespace)
            "snake_case or TitleCase"
        else if (type_function or is_type)
            "TitleCase"
        else if (declaration_tag == .keyword_fn)
            function_case.text()
        else
            "snake_case";
        const project_convention = if (project_case) |case| case.text() else convention;
        try context.emit(.{
            .rule = .non_idiomatic_name,
            .level = level,
            .span = token.loc,
            .message = if (std.mem.eql(u8, project_convention, convention))
                try context.allocator.print("declaration '{s}' does not follow Zig's {s} naming convention", .{ name, convention })
            else
                try context.allocator.print("declaration '{s}' follows neither Zig's {s} naming convention nor the project's {s}", .{ name, convention, project_convention }),
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
        .identifier => identifierIsLiteral(tree.tokenSlice(tree.nodeMainToken(node))),
        else => false,
    };
}

fn identifierIsLiteral(name: []const u8) bool {
    return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or
        std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined");
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

fn declarationInitializesType(scopes: *const syntax_scope.Index, identifier_index: usize) bool {
    const tokens = scopes.tokens;
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
            const closing = scopes.matchingToken(opening) orelse break :type false;
            break :type closing + 1 < tokens.len and tokens[closing + 1].tag == .semicolon;
        },
        // 'error{...}' declares an error-set type; 'error.Name' is a value.
        .keyword_error => initializer_index + 1 < tokens.len and tokens[initializer_index + 1].tag == .l_brace,
        else => false,
    };
}

/// Declarations that name a type: their tokens answer bare references, which
/// the scope index resolves, and their names answer member accesses
/// (`lib.Generic(u8)`), which no lexical scope resolves.
const TypeDeclarations = struct {
    scopes: *const syntax_scope.Index,
    names: std.StringHashMapUnmanaged(void) = .empty,
    tokens: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn deinit(declarations: *TypeDeclarations, allocator: std.mem.Allocator) void {
        declarations.names.deinit(allocator);
        declarations.tokens.deinit(allocator);
    }

    fn put(declarations: *TypeDeclarations, allocator: std.mem.Allocator, name: []const u8, token_index: usize) !void {
        try declarations.names.put(allocator, name, {});
        try declarations.tokens.put(allocator, token_index, {});
    }

    /// Whether the identifier at `use_index` names one of the declarations: the
    /// one in scope when unqualified, any of that name after a member access.
    fn named(declarations: *const TypeDeclarations, tokens: []const std.zig.Token, use_index: usize, name: []const u8) bool {
        if (use_index > 0 and tokens[use_index - 1].tag == .period) return declarations.names.contains(name);
        const binding = declarations.scopes.findBinding(use_index) orelse return false;
        return declarations.tokens.contains(binding.token_index);
    }
};

fn declarationNamesType(
    source: []const u8,
    tokens: []const std.zig.Token,
    identifier_index: usize,
    type_declarations: *const TypeDeclarations,
) bool {
    const scopes = type_declarations.scopes;
    if (declarationInitializesType(scopes, identifier_index)) return true;
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
            const call_end = scopes.matchingToken(identifier_index + 3) orelse return false;
            if (call_end + 1 < tokens.len and tokens[call_end + 1].tag == .l_brace) return false;
        }
        const type_builtins = [_][]const u8{
            "@This", "@TypeOf", "@Type", "@Int", "@Enum", "@Union", "@Struct", "@Pointer", "@Array", "@Vector", "@Fn", "@Tuple", "@FieldType",
        };
        for (type_builtins) |name| if (std.mem.eql(u8, builtin_name, name)) {
            // '@TypeOf(x) != void' compares the type and yields a bool.
            const call_end = scopes.matchingToken(identifier_index + 3) orelse return false;
            return call_end + 1 < tokens.len and
                (tokens[call_end + 1].tag == .semicolon or tokens[call_end + 1].tag == .period);
        };
        if (std.mem.eql(u8, builtin_name, "@import")) {
            const import_end = scopes.matchingToken(identifier_index + 3) orelse return false;
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
    // Only the initializer's own expression counts: an error set inside a
    // labeled block, a 'catch' body or a nested struct says nothing about it.
    var brace_depth: usize = 0;
    for (tokens[initializer_index..declaration_end], initializer_index..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => {},
        }
        if (brace_depth != 0) continue;
        const name = tokenText(source, token);
        if (std.mem.eql(u8, name, "error") and index + 1 < declaration_end and tokens[index + 1].tag == .l_brace) return true;
        if (declares_error_type and token.tag == .identifier and
            (std.mem.eql(u8, name, "Error") or std.mem.endsWith(u8, name, "Error"))) return true;
    }
    if (identifier_index + 3 < tokens.len and tokens[identifier_index + 1].tag == .equal and
        tokens[identifier_index + 2].tag == .builtin and
        tokenIs(source, tokens[identifier_index + 2], "@typeInfo"))
    {
        // '@typeInfo(p.child)' reflects on a value; only fields read from the
        // result ('@typeInfo(T).pointer.child') name a type.
        var cursor = scopes.matchingToken(identifier_index + 3) orelse return false;
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
        // 'std.c.EVFILT.READ' is a C-style constant, not a type.
        .semicolon => if (target_index != identifier_index + 2 and isTitleCase(target) and
            (target.len == 1 or !isConstantCase(target))) return true,
        .l_paren => {
            const call_end = scopes.matchingToken(target_index + 1) orelse return false;
            if (call_end + 1 >= tokens.len or tokens[call_end + 1].tag != .semicolon) return false;
            return type_declarations.named(tokens, target_index, target);
        },
        else => return false,
    }
    return type_declarations.named(tokens, target_index, target);
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

/// Whether an underscore-prefixed name keeps a spelling the Zig source does
/// not choose: `_` before a digit, which no name may start with (`_1011` in
/// an addition chain), a reserved C or ABI name (`__tls_base`, `_SC`,
/// `_DYNAMIC`), the linker's `_start`, a C-layout type mirroring a C tag
/// (`const _umtx_time = extern struct {...}`), or a constant selecting a
/// foreign symbol whose name starts with `_` too (`pub const _errno = private.__errno;`).
fn underscoreIsForeignSpelling(scopes: *const syntax_scope.Index, identifier_index: usize) bool {
    const tokens = scopes.tokens;
    const name = tokenText(scopes.source, tokens[identifier_index]);
    if (std.ascii.isDigit(name[1]) or name[1] == '_' or isConstantCase(name[1..]) or std.mem.eql(u8, name, "_start")) return true;
    if (tokens[identifier_index - 1].tag != .keyword_const or identifier_index + 2 >= tokens.len or
        tokens[identifier_index + 1].tag != .equal) return false;
    if (tokens[identifier_index + 2].tag == .keyword_extern) return true;
    const end = scopes.statementEnd(identifier_index + 2) orelse return false;
    for (tokens[identifier_index + 2 .. end], identifier_index + 2..) |token, index| {
        if (token.tag == .identifier and tokens[index - 1].tag == .period and
            tokenText(scopes.source, token)[0] == '_') return true;
    }
    return false;
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

fn declarationIsNamespace(scopes: *const syntax_scope.Index, identifier_index: usize) bool {
    const tokens = scopes.tokens;
    if (!declarationInitializesType(scopes, identifier_index)) return false;
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal or
        tokens[identifier_index + 2].tag != .keyword_struct or tokens[identifier_index + 3].tag != .l_brace) return false;
    const closing = scopes.matchingToken(identifier_index + 3) orelse return false;
    var brace_depth: usize = 1;
    var parenthesis_depth: usize = 0;
    for (tokens[identifier_index + 4 .. closing], identifier_index + 4..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            // 'var count: u32 = 0;' is a declaration with a type, not a field.
            .identifier => if (brace_depth == 1 and parenthesis_depth == 0 and index + 1 < closing and
                tokens[index + 1].tag == .colon and tokens[index - 1].tag != .keyword_const and
                tokens[index - 1].tag != .keyword_var) return false,
            else => {},
        }
    }
    return true;
}

fn functionDeclarationReturnsType(scopes: *const syntax_scope.Index, identifier_index: usize) bool {
    const tokens = scopes.tokens;
    if (identifier_index + 1 >= tokens.len or tokens[identifier_index + 1].tag != .l_paren) return false;
    const parameters_end = scopes.matchingToken(identifier_index + 1) orelse return false;
    if (parameters_end + 1 >= tokens.len) return false;
    return tokenIs(scopes.source, tokens[parameters_end + 1], "type");
}

/// Trailing underscores only tell a name apart from another (`type_`,
/// `Details_`), so the case is judged without them.
fn withoutTrailingUnderscores(name: []const u8) []const u8 {
    return std.mem.trimEnd(u8, name, "_");
}

/// Whether `name` is spelled in `case` as this rule judges it.
pub fn followsCase(case: types.NameCase, name: []const u8) bool {
    return switch (case) {
        .snake_case => isSnakeCase(name),
        .camel_case => isCamelCase(name),
        .title_case => isTitleCase(name),
    };
}

fn isCamelCase(full_name: []const u8) bool {
    const name = withoutTrailingUnderscores(full_name);
    return name.len != 0 and std.ascii.isLower(name[0]) and std.mem.findScalar(u8, name, '_') == null;
}

/// An underscore may separate digit groups, as in `Sha3_256` or `Aegis128L_256`.
fn isTitleCase(full_name: []const u8) bool {
    const name = withoutTrailingUnderscores(full_name);
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name, 0..) |character, index| {
        if (character == '_' and (index + 1 == name.len or !std.ascii.isDigit(name[index + 1]))) return false;
    }
    return true;
}

/// `^[A-Z][A-Z0-9_]*$`, the spelling of C and protocol constants.
fn isConstantCase(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isUpper(character) and !std.ascii.isDigit(character) and character != '_') return false;
    }
    return true;
}

fn isSnakeCase(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_') return false;
    }
    return true;
}

fn findOfficialStyleIssues(context: RuleRun, foreign_names: *const ForeignNames) !void {
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
        const externally_named = foreign_names.contains(context.scopes, index) or
            (declaration_tag == .keyword_const and declarationIsSameNameAlias(source, tokens, index));
        if (underscore_level != .off and name.len > 1 and name[0] == '_' and !externally_named and
            !underscoreIsForeignSpelling(context.scopes, index))
        {
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
        if (vague_level != .off and public_declaration and declaration_tag == .keyword_const and declarationInitializesType(context.scopes, index)) {
            if (isVagueTypeName(name)) {
                try context.emit(.{
                    .rule = .vague_type_name,
                    .level = vague_level,
                    .span = token.loc,
                    .message = try context.allocator.print(
                        "type '{s}' is named by a vague word, which does not describe its domain role",
                        .{name},
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
            if (commentRestatesName(source, tokens, first_doc_index, name)) {
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
            const closing = context.matchingToken(namespace_index + 4, .l_brace, .r_brace) orelse continue;
            var cursor = namespace_index + 5;
            while (cursor < closing) : (cursor += 1) {
                if (tokens[cursor].tag != .keyword_const or cursor + 3 >= closing or tokens[cursor + 1].tag != .identifier) continue;
                const declaration_name = tokenText(source, tokens[cursor + 1]);
                const suffix = redundantNamespaceSuffix(namespace_name, declaration_name) orelse continue;
                if (suffix.len == 0 or !declarationInitializesType(context.scopes, cursor + 1)) continue;
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

    if (public_docs_level != .off and context.module_exposure != .none) {
        var surface: PublicSurface = try .init(context);
        defer surface.deinit();
        var exemptions: DocumentationExemptions = try .init(context);
        defer exemptions.deinit(context.allocator);
        for (tokens, 0..) |token, pub_index| {
            if (token.tag != .keyword_pub or pub_index + 2 >= tokens.len) continue;
            const declaration_tag = tokens[pub_index + 1].tag;
            if (declaration_tag != .keyword_fn and declaration_tag != .keyword_const and declaration_tag != .keyword_var) continue;
            if (tokens[pub_index + 2].tag != .identifier) continue;
            if (pub_index > 0 and tokens[pub_index - 1].tag == .doc_comment) continue;
            const declaration_name = tokenText(source, tokens[pub_index + 2]);
            if (isProtocolName(declaration_name)) continue;
            if (declaration_tag == .keyword_fn and isBuildEntryPoint(context.scopes, pub_index + 2)) continue;
            if (exemptions.self_describing.contains(pub_index)) continue;
            if (exemptions.table_entries.get(pub_index)) |whole_table| {
                if (whole_table or surface.documentsTable(pub_index)) continue;
            }
            if (!surface.contains(pub_index)) continue;
            try context.emit(.{
                .rule = .public_declaration_docs,
                .level = public_docs_level,
                .span = tokens[pub_index + 2].loc,
                .message = try context.allocator.print("public declaration '{s}' has no doc comment", .{declaration_name}),
            });
        }
    }
}

/// Names whose meaning a language or std protocol fixes (`std.hash_map`
/// contexts, `std.fmt`, `std.json` hooks, `std.Options`, entry points), so a
/// doc comment would only restate the protocol.
fn isProtocolName(name: []const u8) bool {
    const protocol_names = [_][]const u8{
        "init",      "deinit",             "hash",  "eql",     "format",      "jsonStringify",
        "jsonParse", "jsonParseFromValue", "Error", "Options", "std_options", "main",
    };
    for (protocol_names) |protocol_name| if (std.mem.eql(u8, name, protocol_name)) return true;
    return false;
}

/// The `pub` constants that need no comment of their own, found in one pass
/// over the tree.
const DocumentationExemptions = struct {
    /// `pub` keywords of constants whose value tells what a comment would.
    self_describing: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// `pub` keywords of the constant-expression entries of constant tables,
    /// mapped to whether every member of their table is one.
    table_entries: std.AutoHashMapUnmanaged(usize, bool) = .empty,

    fn init(context: RuleRun) !DocumentationExemptions {
        const tree = context.tree;
        var exemptions: DocumentationExemptions = .{};
        errdefer exemptions.deinit(context.allocator);
        for (0..tree.nodes.len) |raw_node| {
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
            if (tree.fullVarDecl(node)) |declaration| {
                const pub_index = declaration.visib_token orelse continue;
                const initializer = declaration.ast.init_node.unwrap() orelse continue;
                if (context.tokens[declaration.ast.mut_token].tag == .keyword_const and valueDescribesItself(tree, initializer)) {
                    try exemptions.self_describing.put(context.allocator, pub_index, {});
                }
                continue;
            }
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, node) orelse continue;
            try exemptions.putTable(context, container.ast.members);
        }
        try exemptions.putTable(context, tree.rootDecls());
        return exemptions;
    }

    fn deinit(exemptions: *DocumentationExemptions, allocator: std.mem.Allocator) void {
        exemptions.self_describing.deinit(allocator);
        exemptions.table_entries.deinit(allocator);
    }

    /// Records the entries of `members` when they make a constant table: a
    /// namespace like `pub const SO = struct { pub const DEBUG = 1; ... };`
    /// holding constants alone, with no field, function or variable.
    fn putTable(exemptions: *DocumentationExemptions, context: RuleRun, members: []const std.zig.Ast.Node.Index) !void {
        const tree = context.tree;
        var whole_table = true;
        for (members) |member| {
            const declaration = tree.fullVarDecl(member) orelse return;
            const initializer = declaration.ast.init_node.unwrap() orelse return;
            if (context.tokens[declaration.ast.mut_token].tag != .keyword_const) return;
            if (!constantExpression(tree, initializer)) whole_table = false;
        }
        for (members) |member| {
            const declaration = tree.fullVarDecl(member).?;
            const pub_index = declaration.visib_token orelse continue;
            if (!constantExpression(tree, declaration.ast.init_node.unwrap().?)) continue;
            try exemptions.table_entries.put(context.allocator, pub_index, whole_table);
        }
    }
};

/// Whether a constant's value tells all a comment would: a literal or an
/// aggregate of literals, which the declaration shows in full, or an alias or
/// `@import` re-export, documented where its target is declared.
fn valueDescribesItself(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return declarationPath(tree, node) or literalValue(tree, node);
}

/// `name`, `a.b.C`, `@import("m.zig").M` or `@This()`.
fn declarationPath(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    var current = node;
    while (true) switch (tree.nodeTag(current)) {
        .identifier => return true,
        .field_access => current = tree.nodeData(current).node_and_token[0],
        .builtin_call_two, .builtin_call_two_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(current));
            return std.mem.eql(u8, builtin, "@import") or std.mem.eql(u8, builtin, "@This");
        },
        else => return false,
    };
}

/// A literal, possibly negated, cast with `@as` or pointed to (`&.{}`), or an
/// aggregate of them.
fn literalValue(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal, .error_value => return true,
        .identifier => return identifierIsLiteral(tree.tokenSlice(tree.nodeMainToken(node))),
        .negation, .bit_not, .address_of => return literalValue(tree, tree.nodeData(node).node),
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return false;
            const operand = tree.nodeData(node).opt_node_and_opt_node[1].unwrap() orelse return false;
            return literalValue(tree, operand);
        },
        else => {},
    }
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |aggregate| {
        for (aggregate.ast.fields) |field| if (!literalValue(tree, field)) return false;
        return true;
    }
    if (tree.fullArrayInit(&buffer, node)) |aggregate| {
        for (aggregate.ast.elements) |element| if (!literalValue(tree, element)) return false;
        return true;
    }
    return false;
}

/// Whether `node` computes a value from literals and other constants with
/// operators and casts alone, as the entries of C-mirror tables do
/// (`1 << 4`, `IN | OUT`, `~@as(u32, 0)`).
fn constantExpression(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .number_literal,
        .char_literal,
        .string_literal,
        .multiline_string_literal,
        .enum_literal,
        .error_value,
        .identifier,
        => return true,
        .field_access, .grouped_expression => return constantExpression(tree, tree.nodeData(node).node_and_token[0]),
        .negation, .negation_wrap, .bit_not, .bool_not => return constantExpression(tree, tree.nodeData(node).node),
        .add, .sub, .mul, .div, .mod, .add_wrap, .sub_wrap, .mul_wrap, .shl, .shr, .bit_and, .bit_or, .bit_xor => {
            const left, const right = tree.nodeData(node).node_and_node;
            return constantExpression(tree, left) and constantExpression(tree, right);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const builtin = tree.tokenSlice(tree.nodeMainToken(node));
            const casts = [_][]const u8{ "@as", "@intCast", "@bitCast", "@truncate", "@intFromEnum", "@sizeOf" };
            for (casts) |cast| {
                if (std.mem.eql(u8, builtin, cast)) break;
            } else return false;
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            for (tree.builtinCallParams(&buffer, node).?) |argument| if (!constantExpression(tree, argument)) return false;
            return true;
        },
        else => return false,
    }
}

/// The declarations reachable from the file's root through `pub`
/// declarations. A `pub` member of a private container is unreachable from
/// the file's root, and so from any module root, unless a `pub` alias in the
/// file re-exports the container.
const PublicSurface = struct {
    context: RuleRun,
    /// A private declaration's name token, mapped to the `pub` keyword of an
    /// alias that re-exports it: `pub const Api = Impl;`,
    /// `pub const Small = Generic(8);`, `pub const Handle = *Opaque;`, a
    /// branch of `pub const Native = switch (arch) { .x86 => X86, ... };`, or
    /// a public type function's `return Base(T);`.
    aliases: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    fn init(context: RuleRun) !PublicSurface {
        var surface: PublicSurface = .{ .context = context };
        errdefer surface.deinit();
        const tokens = context.tokens;
        for (tokens, 0..) |token, pub_index| {
            if (token.tag != .keyword_pub or pub_index + 4 >= tokens.len or tokens[pub_index + 2].tag != .identifier) continue;
            // A constant's initializer, or the body of a type function, which
            // may return another declaration: 'return Base(T, .{});'.
            var index = pub_index + 4;
            const end = switch (tokens[pub_index + 1].tag) {
                .keyword_const => if (tokens[pub_index + 3].tag == .equal)
                    context.scopes.statementEnd(index) orelse continue
                else
                    continue,
                .keyword_fn => end: {
                    if (tokens[pub_index + 3].tag != .l_paren) continue;
                    const parameters_end = context.scopes.matchingToken(pub_index + 3) orelse continue;
                    if (parameters_end + 2 >= tokens.len or !context.tokenIs(parameters_end + 1, "type") or
                        tokens[parameters_end + 2].tag != .l_brace) continue;
                    index = parameters_end + 3;
                    break :end context.scopes.matchingToken(parameters_end + 2) orelse continue;
                },
                else => continue,
            };
            // The expression itself: container bodies hold their own
            // declarations, which this loop reaches separately.
            while (index < end) : (index += 1) {
                switch (tokens[index].tag) {
                    .l_brace => if (containerStart(context, index) != null) {
                        index = context.scopes.matchingToken(index) orelse break;
                    },
                    .identifier => if (selectsDeclaration(tokens, index)) {
                        const target = context.scopes.findBinding(index) orelse continue;
                        const entry = try surface.aliases.getOrPut(context.allocator, target.token_index);
                        if (!entry.found_existing) entry.value_ptr.* = pub_index;
                    },
                    else => {},
                }
            }
        }
        return surface;
    }

    /// Whether the identifier at `index` is a whole branch of the initializer
    /// or returned type, or the callee or pointee of one, rather than part of
    /// a longer path.
    fn selectsDeclaration(tokens: []const std.zig.Token, index: usize) bool {
        if (index + 1 >= tokens.len) return false;
        switch (tokens[index - 1].tag) {
            .equal, .equal_angle_bracket_right, .keyword_else, .keyword_orelse, .keyword_return, .r_paren, .asterisk, .question_mark => {},
            .keyword_const => if (tokens[index - 2].tag != .asterisk) return false,
            else => return false,
        }
        return switch (tokens[index + 1].tag) {
            .semicolon, .comma, .r_brace, .keyword_else, .l_paren => true,
            else => false,
        };
    }

    fn deinit(surface: *PublicSurface) void {
        surface.aliases.deinit(surface.context.allocator);
    }

    /// Whether the `pub` declaration at `pub_index` is on the surface: each
    /// container around it is exposed by a declaration on the surface, up to
    /// a top-level declaration the module roots expose.
    fn contains(surface: *const PublicSurface, pub_index: usize) bool {
        var cursor = pub_index;
        // Aliases can point back into the containers they are declared in,
        // so the walk is bounded rather than trusted to reach the root.
        for (0..64) |_| {
            const opening = surface.context.scopes.enclosingOpeningBrace(cursor) orelse return surface.rootsExpose(cursor);
            cursor = surface.exposer(opening) orelse return false;
        }
        return false;
    }

    /// Whether the module roots expose the top-level declaration whose `pub`
    /// keyword, or field name, is at `index`.
    fn rootsExpose(surface: *const PublicSurface, index: usize) bool {
        const exposed = switch (surface.context.module_exposure) {
            .whole => return true,
            .none => return false,
            .declarations => |names| names,
        };
        const name_index = if (surface.context.tokens[index].tag == .keyword_pub) index + 2 else index;
        const name = surface.context.tokenText(name_index);
        for (exposed) |exposed_name| if (std.mem.eql(u8, name, exposed_name)) return true;
        return false;
    }

    /// Whether the container holding the `pub` declaration at `pub_index` is
    /// documented: by the comment of the declaration exposing it, or by the
    /// file's `//!` comment at the top level.
    fn documentsTable(surface: *const PublicSurface, pub_index: usize) bool {
        const tokens = surface.context.tokens;
        const opening = surface.context.scopes.enclosingOpeningBrace(pub_index) orelse
            return tokens[0].tag == .container_doc_comment;
        const exposing = surface.exposer(opening) orelse return false;
        return exposing > 0 and tokens[exposing - 1].tag == .doc_comment;
    }

    /// The `pub` keyword of the declaration, or the name of the field, that
    /// exposes the container opened at `opening`: `pub const Name = struct {`,
    /// possibly as a branch of the `if` or `switch` the declaration selects its
    /// type with, a `pub fn Name(...) type` returning it, an alias of either,
    /// or `field: struct {`. Null for private, local and anonymous containers.
    fn exposer(surface: *const PublicSurface, opening: usize) ?usize {
        const context = surface.context;
        const tokens = context.tokens;
        var cursor = containerStart(context, opening) orelse return null;
        // Each step moves to the start of an enclosing conditional expression,
        // so the walk is as long as the 'if'/'switch' nesting of one initializer.
        while (cursor >= 1) {
            switch (tokens[cursor - 1].tag) {
                .equal => {
                    // 'pub const Name = ' or 'pub const Name: type = '
                    if (cursor < 3) return null;
                    var name = cursor - 2;
                    if (name >= 2 and tokens[name].tag == .identifier and tokens[name - 1].tag == .colon) name -= 2;
                    if (name < 1 or tokens[name].tag != .identifier or
                        (tokens[name - 1].tag != .keyword_const and tokens[name - 1].tag != .keyword_var)) return null;
                    if (name >= 2 and tokens[name - 2].tag == .keyword_pub) return name - 2;
                    return surface.alias(name, opening);
                },
                .keyword_return => {
                    const body = context.scopes.enclosingFunctionBody(cursor - 1) orelse return null;
                    if (body < 4 or tokens[body - 2].tag != .r_paren or !context.tokenIs(body - 1, "type")) return null;
                    const parameters = context.scopes.matchingToken(body - 2) orelse return null;
                    if (parameters < 2 or tokens[parameters - 1].tag != .identifier or tokens[parameters - 2].tag != .keyword_fn) return null;
                    if (parameters >= 3 and tokens[parameters - 3].tag == .keyword_pub) return parameters - 3;
                    return surface.alias(parameters - 1, opening);
                },
                // '.linux => struct {': the prong's switch starts the expression.
                .equal_angle_bracket_right => {
                    const body = context.scopes.enclosingOpeningBrace(cursor - 1) orelse return null;
                    if (body < 2 or tokens[body - 1].tag != .r_paren) return null;
                    const operand = context.scopes.matchingToken(body - 1) orelse return null;
                    if (operand < 1 or tokens[operand - 1].tag != .keyword_switch) return null;
                    cursor = operand - 1;
                },
                // 'buffered: struct {': a field's type is reachable through the field.
                .colon => {
                    if (cursor < 3 or tokens[cursor - 2].tag != .identifier) return null;
                    switch (tokens[cursor - 3].tag) {
                        .l_brace, .r_brace, .semicolon, .comma, .doc_comment, .keyword_comptime => return cursor - 2,
                        else => return null,
                    }
                },
                // 'Override orelse if (c) enum {': the left operand starts the expression.
                .keyword_orelse => {
                    if (cursor < 2 or tokens[cursor - 2].tag != .identifier) return null;
                    var start = cursor - 2;
                    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
                    cursor = start;
                },
                // 'if (is_mips) struct {'
                .r_paren => {
                    const condition = context.scopes.matchingToken(cursor - 1) orelse return null;
                    if (condition < 1 or tokens[condition - 1].tag != .keyword_if) return null;
                    cursor = condition - 1;
                },
                // 'if (c) Name else struct {' and 'if (c) struct { ... } else struct {'
                .keyword_else => {
                    if (cursor < 3) return null;
                    var branch_start = switch (tokens[cursor - 2].tag) {
                        .identifier => cursor - 2,
                        .r_brace => containerStart(context, context.scopes.matchingToken(cursor - 2) orelse return null) orelse return null,
                        else => return null,
                    };
                    while (branch_start >= 2 and tokens[branch_start - 1].tag == .period and
                        tokens[branch_start - 2].tag == .identifier) branch_start -= 2;
                    if (branch_start < 1 or tokens[branch_start - 1].tag != .r_paren) return null;
                    const condition = context.scopes.matchingToken(branch_start - 1) orelse return null;
                    if (condition < 1 or tokens[condition - 1].tag != .keyword_if) return null;
                    cursor = condition - 1;
                },
                else => return null,
            }
        }
        return null;
    }

    /// The `pub` alias re-exporting the private declaration named at
    /// `name_index`, unless it sits inside the container opened at `opening`.
    fn alias(surface: *const PublicSurface, name_index: usize, opening: usize) ?usize {
        const alias_pub = surface.aliases.get(name_index) orelse return null;
        const closing = surface.context.scopes.matchingToken(opening) orelse return null;
        if (alias_pub > opening and alias_pub < closing) return null;
        return alias_pub;
    }
};

/// The first token of the container type whose body opens at `opening`,
/// counting `extern` or `packed` and the `(enum)`/`(u8)` argument; null when
/// the brace opens no container.
fn containerStart(context: RuleRun, opening: usize) ?usize {
    const tokens = context.tokens;
    if (opening < 1) return null;
    var keyword = opening - 1;
    // 'union(enum) {', 'enum(u8) {', 'packed struct(u32) {'
    if (tokens[keyword].tag == .r_paren) keyword = (context.scopes.matchingToken(keyword) orelse return null) -| 1;
    switch (tokens[keyword].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {},
        else => return null,
    }
    if (keyword > 0 and (tokens[keyword - 1].tag == .keyword_extern or tokens[keyword - 1].tag == .keyword_packed)) keyword -= 1;
    return keyword;
}

fn isBuildEntryPoint(scopes: *const syntax_scope.Index, name_index: usize) bool {
    const source = scopes.source;
    const tokens = scopes.tokens;
    if (!tokenIs(source, tokens[name_index], "build") or name_index + 1 >= tokens.len or
        tokens[name_index + 1].tag != .l_paren) return false;
    const parameters_end = scopes.matchingToken(name_index + 1) orelse return false;
    for (tokens[name_index + 2 .. parameters_end], name_index + 2..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, "Build") or index < 2) continue;
        if (tokens[index - 1].tag == .period and tokens[index - 2].tag == .identifier and
            tokenIs(source, tokens[index - 2], "std")) return true;
    }
    return false;
}

fn isVagueTypeName(name: []const u8) bool {
    // A vague word after a qualifier names a role precisely (CheckpointState,
    // ImageData, ResourceManager, often the spelling of a specification);
    // only the bare word says nothing about the domain. `Context` is the
    // protocol name of `std.hash_map` and `std.sort` contexts.
    const vague_words = [_][]const u8{ "Value", "State", "Data", "Manager", "Utils", "Misc" };
    for (vague_words) |word| if (std.mem.eql(u8, name, word)) return true;
    return false;
}

/// Whether the first sentence of the doc comment starting at `first_doc_index`
/// says no more than the name: the name, then at most a few words that are
/// filler or the name's own words (`/// EMCON`, `/// Parser type.`,
/// `/// renderFrame renders the frame.`). A sentence that goes on to say
/// anything else (`/// Shaper that uses Harfbuzz.`) is documentation.
fn commentRestatesName(source: []const u8, tokens: []const std.zig.Token, first_doc_index: usize, name: []const u8) bool {
    const max_restating_words = 5;
    var restating_words: usize = 0;
    var index = first_doc_index;
    while (index < tokens.len and tokens[index].tag == .doc_comment) : (index += 1) {
        const raw_line = tokenText(source, tokens[index]);
        const line = std.mem.trim(u8, raw_line[@min(raw_line.len, 3)..], " \t");
        // A blank line ends the first paragraph, and with it the sentence.
        if (line.len == 0) return index != first_doc_index;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        if (index == first_doc_index) {
            const first_word = words.next().?;
            if (!std.mem.startsWith(u8, first_word, name)) return false;
            const rest = first_word[name.len..];
            // 'render:' and 'render.' still name the declaration; 'render-based' does not.
            if (std.mem.trimEnd(u8, rest, ".,:;!?-").len != 0) return false;
            if (endsSentence(rest)) return true;
        }
        while (words.next()) |word| {
            const bare = std.mem.trim(u8, word, "`'\"()[],.:;!?-");
            if (bare.len != 0) {
                if (!isFillerWord(bare) and !isNameWord(bare, name)) return false;
                restating_words += 1;
                if (restating_words > max_restating_words) return false;
            }
            if (endsSentence(word)) return true;
        }
    }
    return true;
}

fn endsSentence(word: []const u8) bool {
    const end = std.mem.trimEnd(u8, word, "`'\")]");
    return end.len != 0 and (end[end.len - 1] == '.' or end[end.len - 1] == '!' or end[end.len - 1] == '?');
}

fn isFillerWord(word: []const u8) bool {
    const filler_words = [_][]const u8{
        "a",      "an",       "the",   "this",   "that",     "is",       "are",    "of",      "for",   "to",
        "and",    "or",       "it",    "its",    "returns",  "type",     "struct", "enum",    "union", "function",
        "method", "constant", "value", "values", "variable", "instance", "object", "wrapper", "field",
    };
    for (filler_words) |filler| if (std.ascii.eqlIgnoreCase(word, filler)) return true;
    return false;
}

/// Whether `word` is the name or one of its words, possibly inflected:
/// `renders` and `frame` for `renderFrame`, `parses` for `Parser`.
fn isNameWord(word: []const u8, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(word, name)) return true;
    const stem = if (word.len > 3 and word[word.len - 1] == 's') word[0 .. word.len - 1] else word;
    var start: usize = 0;
    for (name, 0..) |character, index| {
        const boundary = index + 1 == name.len or name[index + 1] == '_' or
            (std.ascii.isLower(character) and std.ascii.isUpper(name[index + 1]));
        if (!boundary) continue;
        const part = std.mem.trim(u8, name[start .. index + 1], "_");
        start = index + 1;
        if (part.len < 3) {
            if (std.ascii.eqlIgnoreCase(word, part)) return true;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(part, stem) and stem.len + 1 >= part.len) return true;
        if (std.ascii.startsWithIgnoreCase(word, part) and word.len <= part.len + 3) return true;
    }
    return false;
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

test "functions with a foreign calling convention or an @export keep their names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const lib = struct { pub const calling_conv: std.builtin.CallingConvention = .c; };\n" ++
        "pub fn row_cells_free(cells: u32) callconv(lib.calling_conv) void { _ = cells; }\n" ++
        "pub fn parse_x11(text: u32) callconv(.c) u32 { return text; }\n" ++
        "pub fn aligned_c(text: u32) align(4) callconv(.c) u32 { return text; }\n" ++
        "fn memset_impl() void {}\n" ++
        "comptime { @export(&memset_impl, .{ .name = \"memset\" }); }\n" ++
        "fn inline_helper() callconv(.@\"inline\") void {}\n" ++
        "fn auto_helper() callconv(.auto) void {}\n" ++
        "fn plain_helper() void {}\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    const expected = [_][]const u8{ "inline_helper", "auto_helper", "plain_helper" };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
}

test "underscore prefixes the source does not choose are not privacy markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const private = struct { extern \"c\" fn __errno() *c_int; extern \"c\" fn ___lwp_park60() c_int; };\n" ++
        "pub const _errno = switch (os) { .windows => private.__errno, else => {} };\n" ++
        "pub const _lwp_park = private.___lwp_park60;\n" ++
        "pub const _SC = enum(c_int) { PAGESIZE = 39 };\n" ++
        "pub const _umtx_time = extern struct { timeout: u64 };\n" ++
        "fn _start() callconv(.naked) noreturn { unreachable; }\n" ++
        "inline fn __get_stack_pointer() [*]u8 { return undefined; }\n" ++
        "fn _carry128(r: u128) u64 { return @truncate(r); }\n" ++
        "fn _exported() void {}\n" ++
        "comptime { @export(&_exported, .{ .name = \"exported\" }); }\n" ++
        "pub fn chain(p: u64) u64 {\n" ++
        "    const _10 = p *% 2;\n" ++
        "    const _1011 = _10 +% p;\n" ++
        "    const _helper = _1011;\n" ++
        "    _ = __get_stack_pointer();\n" ++
        "    return _helper +% _carry128(0);\n" ++
        "}\n";
    const configuration = support.only(&.{.underscore_private_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .underscore_private_name) {
        try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    const expected = [_][]const u8{ "_carry128", "_helper" };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
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

test "C-style constants, deprecated aliases, digit groups and trailing underscores keep their spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub const O_RDONLY = 0;\n" ++
        "const SIGINT: c_int = 2;\n" ++
        "pub const Sha3_256 = struct { state: u64 };\n" ++
        "pub const Aegis128L_256 = Sha3_256;\n" ++
        "const NewType = struct { x: u8 };\n" ++
        "/// Deprecated: use `NewType`.\n" ++
        "pub const old_type = NewType;\n" ++
        "/// Deprecated in favor of `newName`.\n" ++
        "pub fn old_name() void {}\n" ++
        "fn copy(details: anytype) void { const Details_ = @TypeOf(details); _ = Details_; }\n" ++
        "fn type_() void {}\n" ++
        "const Bad_Type = struct { x: u8 };\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("Bad_Type", source[finding.span.start..finding.span.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "names in the casing the project's majority chose follow its convention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn read_value() void {}\n" ++
        "pub fn readValue() void {}\n" ++
        "pub fn Read_Mixed() void {}\n" ++
        "const Bad_Type = struct { x: u8 };\n";
    var configuration = support.only(&.{.non_idiomatic_name}, .information);
    configuration.naming_conventions = .{ .function = .snake_case, .type_name = .title_case };
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try support.expectRules(found, &.{ .non_idiomatic_name, .non_idiomatic_name });
    try std.testing.expectEqualStrings("declaration 'Read_Mixed' follows neither Zig's camelCase naming convention nor the project's snake_case", found[0].message);
    try std.testing.expectEqualStrings("declaration 'Bad_Type' does not follow Zig's TitleCase naming convention", found[1].message);
}

test "an explicit function case outranks the project's majority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn read_value() void {}\n" ++
        "pub fn readValue() void {}\n" ++
        "const Bad_Type = struct { x: u8 };\n";
    var configuration = support.only(&.{.non_idiomatic_name}, .information);
    configuration.naming_conventions = .{ .function = .snake_case, .type_name = .title_case };
    configuration.function_case_explicit = true;
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try support.expectRules(found, &.{ .non_idiomatic_name, .non_idiomatic_name });
    try std.testing.expectEqualStrings("declaration 'read_value' does not follow Zig's camelCase naming convention", found[0].message);
    try std.testing.expectEqualStrings("declaration 'Bad_Type' does not follow Zig's TitleCase naming convention", found[1].message);
}

test "namespaces with typed declarations and expressions about types keep value names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub const cpu = struct { pub const generic: u32 = 1; };\n" ++
        "const have_flock = @TypeOf(std.posix.system.flock) != void;\n" ++
        "fn signals() void {\n" ++
        "    const global = struct { threadlocal var stack: [16]u8 = undefined; };\n" ++
        "    _ = &global.stack;\n" ++
        "}\n" ++
        "fn markSecret(ptr: anytype) void {\n" ++
        "    const p = @typeInfo(@TypeOf(ptr)).pointer;\n" ++
        "    const child = @typeInfo(p.child);\n" ++
        "    _ = child;\n" ++
        "}\n" ++
        "fn poll() void {\n" ++
        "    const filter = std.c.EVFILT.READ;\n" ++
        "    _ = filter;\n" ++
        "}\n" ++
        "fn reserve(page: anytype) void {\n" ++
        "    const cap = page.adjust() catch |err| capacity: {\n" ++
        "        comptime std.debug.assert(@TypeOf(err) == error{OutOfMemory});\n" ++
        "        break :capacity page.capacity;\n" ++
        "    };\n" ++
        "    _ = cap;\n" ++
        "}\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| {
        if (finding.rule == .non_idiomatic_name) std.debug.print("unexpected naming finding: {s}\n", .{finding.message});
        try std.testing.expect(finding.rule != .non_idiomatic_name);
    }
}

test "unqualified references resolve type declarations in scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn local() void {\n" ++
        "    const Inner = struct { fn Make() type { return u8; } };\n" ++
        "    _ = Inner;\n" ++
        "}\n" ++
        "fn Make() u32 { return 1; }\n" ++
        "fn caller() void {\n" ++
        "    const made = Make();\n" ++
        "    _ = made;\n" ++
        "}\n" ++
        "fn Generic(comptime T: type) type { return struct { value: T }; }\n" ++
        "const bad_alias = Generic(u8);\n";
    const configuration = support.only(&.{.non_idiomatic_name}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    // The value function 'Make' is misnamed; 'made' holds its value, not the
    // type the unrelated local 'Inner.Make' returns.
    try std.testing.expectEqual(@as(usize, 2), reported.items.len);
    try std.testing.expectEqualStrings("Make", reported.items[0]);
    try std.testing.expectEqualStrings("bad_alias", reported.items[1]);
}

test "functions follow the configured function case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn parse_header() void {}\n" ++
        "fn parseHeader() void {}\n" ++
        "fn Header(comptime T: type) type { return struct { value: T }; }\n";
    var configuration = support.only(&.{.non_idiomatic_name}, .information);
    configuration.function_case = .snake_case;
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var naming_count: usize = 0;
    for (found) |finding| if (finding.rule == .non_idiomatic_name) {
        naming_count += 1;
        try std.testing.expectEqualStrings("parseHeader", source[finding.span.start..finding.span.end]);
        try std.testing.expect(std.mem.find(u8, finding.message, "snake_case") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), naming_count);
}

test "protocol names and members of private containers need no API documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub const Error = error{Failed};\n" ++
        "pub const Options = struct { verbose: bool = false };\n" ++
        "/// A map.\n" ++
        "pub const Map = struct {\n" ++
        "    pub fn init() Map { return .{}; }\n" ++
        "    pub fn deinit(_: *Map) void {}\n" ++
        "    pub fn hash(_: Map) u64 { return 0; }\n" ++
        "    pub fn eql(_: Map, _: Map) bool { return true; }\n" ++
        "    pub fn format(_: Map, _: anytype) !void {}\n" ++
        "    pub fn jsonStringify(_: Map, _: anytype) !void {}\n" ++
        "    pub fn memberCount() void {}\n" ++
        "};\n" ++
        "const Private = struct {\n" ++
        "    pub fn hidden() void {}\n" ++
        "    pub const Nested = struct { pub fn deeper() void {} };\n" ++
        "};\n" ++
        "/// A generic list.\n" ++
        "pub fn List(comptime T: type) type {\n" ++
        "    return struct { pub fn first() ?T { return null; } };\n" ++
        "}\n" ++
        "fn PrivateList(comptime T: type) type {\n" ++
        "    return struct { pub fn last() ?T { return null; } };\n" ++
        "}\n" ++
        "/// A tag.\n" ++
        "pub const Tag = union(enum) { a: u8, pub fn tagName() void {} };\n" ++
        "/// Control names.\n" ++
        "pub const CTL = switch (os) {\n" ++
        "    .linux => struct { pub fn KERN() void {} },\n" ++
        "    else => if (bsd) struct { pub fn VM() void {} } else void,\n" ++
        "};\n" ++
        "/// Signal actions.\n" ++
        "pub const SA = if (mips) Legacy.SA else struct { pub fn ONSTACK() void {} };\n" ++
        "const Hidden = switch (os) { else => struct { pub fn NOT_API() void {} } };\n" ++
        "const Impl = struct { pub fn viaAlias() void {} };\n" ++
        "/// The implementation.\n" ++
        "pub const Api = Impl;\n" ++
        "fn Sized(comptime n: u8) type { return struct { pub fn bytes() u8 { return n; } }; }\n" ++
        "/// Eight bytes.\n" ++
        "pub const Small = Sized(8);\n" ++
        "const Cycle = struct { pub const Self = Cycle; pub fn looped() void {} };\n" ++
        "const X86 = extern struct { pub fn current() void {} };\n" ++
        "/// The native context.\n" ++
        "pub const Native = switch (arch) { .x86 => X86, else => void };\n" ++
        "const object_s = opaque { pub fn retain() void {} };\n" ++
        "/// An object.\n" ++
        "pub const object_t = *object_s;\n" ++
        "/// Compression state.\n" ++
        "pub const Compress = struct { buffered: struct { pub fn empty() void {} } };\n" ++
        "/// Permissions.\n" ++
        "pub const Permissions = Override orelse if (windows) enum(u32) { pub fn default_dir() void {} } else u32;\n" ++
        "fn Base(comptime T: type) type { return struct { pub fn based() ?T { return null; } }; }\n" ++
        "/// A wrapper.\n" ++
        "pub fn Wrapper(comptime T: type) type { return Base(T); }\n" ++
        "fn use() void { _ = Private; _ = PrivateList; _ = Hidden; _ = Cycle; }\n";
    const configuration = support.only(&.{.public_declaration_docs}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .public_declaration_docs) {
        try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    const expected = [_][]const u8{
        "memberCount", "first",  "tagName", "KERN",        "VM",    "ONSTACK", "viaAlias", "bytes",
        "current",     "retain", "empty",   "default_dir", "based",
    };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
}

test "self-describing constants and constant tables need no API documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const bits = @import(\"bits.zig\");\n" ++
        "pub const max_len = 0x40;\n" ++
        "pub const negative: i32 = -1;\n" ++
        "pub const all_bits = @as(u32, 0xffff);\n" ++
        "pub const name_text = \"probe\";\n" ++
        "pub const StaticBitSet = bits.StaticBitSet;\n" ++
        "pub const fd_t = c_int;\n" ++
        "pub const Thread = @import(\"Thread.zig\");\n" ++
        "pub const Treap = @import(\"treap.zig\").Treap;\n" ++
        "pub const empty: Pair = .{ .left = 0, .right = .none };\n" ++
        "pub const no_lines: []const u8 = &.{};\n" ++
        "pub const table = [_]u8{ 1, 2, 3 };\n" ++
        "pub const computed: Pair = .{ .left = std.math.maxInt(u8), .right = .none };\n" ++
        "pub const Small = Generic(8);\n" ++
        "pub var counter: u32 = 0;\n" ++
        "/// Socket options.\n" ++
        "pub const SO = struct {\n" ++
        "    pub const DEBUG = 1;\n" ++
        "    pub const COMBINED = DEBUG | 2;\n" ++
        "    pub const CALLED = compute(DEBUG);\n" ++
        "};\n" ++
        "pub const SC = struct { pub const ARG_MAX = 0; pub const CHILD_MAX = ARG_MAX + 1; pub const SHIFT = 1 << 4; };\n" ++
        "/// Sizes.\n" ++
        "pub const SZ = struct { pub const WORD = @sizeOf(usize) * 8; pub const LOW = @truncate(SHIFTED); };\n" ++
        "pub const S = struct { pub const IFMT = 0o170000; pub const MODE = IFMT & 0o777; pub fn isReg() void {} };\n" ++
        "const Pair = struct { left: u8, right: enum { none } };\n";
    const configuration = support.only(&.{.public_declaration_docs}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .public_declaration_docs) {
        try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
    };
    // A computed aggregate, a type instantiation, a variable, a call in a
    // documented table, undocumented namespaces and a namespace with a
    // function still need comments.
    const expected = [_][]const u8{ "computed", "Small", "counter", "CALLED", "SC", "S", "MODE", "isReg" };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
}

fn runWithExposure(context: RuleRun, exposure: types.ModuleExposure) !void {
    var exposed = context;
    exposed.module_exposure = exposure;
    try run(exposed);
}

test "only declarations the module roots expose need API documentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "/// The API.\n" ++
        "pub const Api = struct { pub fn call() void {} };\n" ++
        "const Impl = struct { pub fn viaAlias() void {} };\n" ++
        "/// An alias.\n" ++
        "pub const Alias = Impl;\n" ++
        "pub const Internal = struct { pub fn helper() void {} };\n" ++
        "pub fn internalHelper() void {}\n";
    const configuration = support.only(&.{.public_declaration_docs}, .information);
    const exposures = [_]struct { types.ModuleExposure, []const []const u8 }{
        .{ .whole, &.{ "call", "viaAlias", "Internal", "helper", "internalHelper" } },
        .{ .none, &.{} },
        .{ .{ .declarations = &.{ "Api", "Alias" } }, &.{ "call", "viaAlias" } },
    };
    for (exposures) |case| {
        const exposure, const expected = case;
        const found = try support.findingsWith(arena.allocator(), runWithExposure, exposure, source, configuration);
        var reported: std.ArrayList([]const u8) = .empty;
        for (found) |finding| if (finding.rule == .public_declaration_docs) {
            try reported.append(arena.allocator(), source[finding.span.start..finding.span.end]);
        };
        try std.testing.expectEqual(expected.len, reported.items.len);
        for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
    }
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

test "doc comment style reports first sentences that only restate the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "/// Returns the parsed config.\n" ++
        "/// parse errors are returned verbatim.\n" ++
        "pub fn parse() void {}\n" ++
        "/// renderFrame renders the frame.\n" ++
        "/// Later lines may say anything.\n" ++
        "pub fn renderFrame() void {}\n" ++
        "/// Shaper that uses Harfbuzz.\n" ++
        "pub const Shaper = struct {};\n" ++
        "/// Animation state for a single image. Heap-allocated.\n" ++
        "pub const Animation = struct {};\n" ++
        "/// EMCON\n" ++
        "pub const EMCON = 1;\n" ++
        "/// Parser type.\n" ++
        "pub const Parser = struct {};\n" ++
        "/// Mutex is a\n" ++
        "/// synchronization primitive.\n" ++
        "pub const Mutex = struct {};\n" ++
        "/// Index into `nodes`.\n" ++
        "pub const Index = u32;\n" ++
        "/// CAN: Controller Area Network\n" ++
        "pub const CAN = 2;\n" ++
        "/// Bar.\n" ++
        "pub const Bar = struct {};\n";
    const configuration = support.only(&.{.doc_comment_style}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.rule == .doc_comment_style) {
        const quoted = finding.message[std.mem.findScalar(u8, finding.message, '\'').? + 1 ..];
        try reported.append(arena.allocator(), quoted[0..std.mem.findScalar(u8, quoted, '\'').?]);
    };
    const expected = [_][]const u8{ "renderFrame", "EMCON", "Parser", "Bar" };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
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

test "only bare vague words are vague type names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub const LookupContext = struct { key: u32 };\n" ++
        "pub const CheckpointState = struct { op: u64 };\n" ++
        "pub const ModeData = extern struct { mode: u32 };\n" ++
        "pub const ResourceManager = struct { count: u32 };\n" ++
        "pub const Context = struct { pub fn hash(_: Context, key: u32) u64 { return key; } };\n" ++
        "pub const Data = struct { key: u32 };\n";
    const configuration = support.only(&.{.vague_type_name}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var vague_count: usize = 0;
    for (found) |finding| if (finding.rule == .vague_type_name) {
        vague_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "'Data'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), vague_count);
}
