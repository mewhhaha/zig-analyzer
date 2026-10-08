//! Questions about names that only the compiler can answer. Rename must know
//! which occurrences of a spelling denote one declaration; for a local that is
//! lexical scoping, but for a container member (a field, a method, a
//! top-level declaration, an enum case) it depends on what types the receiver
//! of `x.name` has, which aliases, imports and comptime values say.
//!
//! This module reads one document's syntax and states each such occurrence as
//! a `Query`: the named containers that enclose it, how to evaluate the
//! receiver (a path of names, calls and indexes), and the name to resolve. It
//! knows nothing about the compiler; the compiler client sends the queries and
//! returns declarations.
const std = @import("std");

const document_module = @import("document.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Document = document_module.Document;
const Loc = std.zig.Token.Loc;

pub const StepKind = enum { scope, name, call, index, target };

pub const Step = struct {
    kind: StepKind,
    /// The container or member name; empty for `call` and `index`.
    name: []const u8 = "",
};

/// How to find the declaration one occurrence names: `scope` steps for the
/// enclosing named containers (outermost first), then `name`/`call`/`index`
/// steps evaluating the receiver, then the `target` name. Without a receiver
/// the target is looked up lexically through the scopes, unless
/// `declaration_site` says the occurrence declares it in the innermost one.
pub const Query = struct {
    declaration_site: bool = false,
    steps: []const Step,

    pub fn target(query: Query) []const u8 {
        return query.steps[query.steps.len - 1].name;
    }

    /// The same query asking for `name` instead.
    pub fn retargeted(query: Query, arena: std.mem.Allocator, name: []const u8) !Query {
        const steps = try arena.dupe(Step, query.steps);
        steps[steps.len - 1] = .{ .kind = .target, .name = name };
        return .{ .declaration_site = query.declaration_site, .steps = steps };
    }
};

pub const Role = union(enum) {
    /// A parameter, local, or capture: lexical scoping decides what it means.
    local,
    /// A container member. `null` when the syntax around the occurrence does
    /// not say where to look (an untyped local, an unnamed container).
    member: ?Query,
};

pub const Site = struct {
    /// What a rename replaces: the identifier, or the text inside the quotes of
    /// a reflection string such as `@field(x, "name")`.
    span: Loc,
    role: Role,
};

/// The site at `byte_offset`, whatever its role, or null when that is not an
/// identifier or reflection string this module classifies.
pub fn siteAt(arena: std.mem.Allocator, document: *const Document, byte_offset: usize) !?Site {
    const token_index = tokenIndexAt(document, byte_offset) orelse return null;
    var classifier = try Classifier.init(arena, document);
    return classifier.classify(token_index, null);
}

/// Every container-member occurrence of `name` in `document`, in source order.
pub fn memberSites(arena: std.mem.Allocator, document: *const Document, name: []const u8) ![]Site {
    var sites: std.ArrayList(Site) = .empty;
    if (std.mem.find(u8, document.source, name) == null) return sites.items;
    var classifier = try Classifier.init(arena, document);
    for (document.tokens, 0..) |token, token_index| {
        if (token.tag != .identifier and token.tag != .string_literal) continue;
        const site = try classifier.classify(token_index, name) orelse continue;
        switch (site.role) {
            .member => try sites.append(arena, site),
            .local => {},
        }
    }
    return sites.items;
}

fn tokenIndexAt(document: *const Document, byte_offset: usize) ?usize {
    var ending_at_offset: ?usize = null;
    for (document.tokens, 0..) |token, index| {
        if (token.tag == .eof or token.loc.start > byte_offset) return ending_at_offset;
        if (token.tag != .identifier and token.tag != .string_literal) continue;
        if (token.loc.start <= byte_offset and byte_offset < token.loc.end) return index;
        if (token.loc.end == byte_offset) ending_at_offset = index;
    }
    return ending_at_offset;
}

const Declaration = union(enum) {
    /// A `const`, `var`, or `fn` declared directly in a container or the file.
    member,
    /// A container field or enum case.
    field,
    parameter: ?Node.Index,
    local_variable: Node.Index,
    capture: Capture,
};

const Capture = struct {
    /// The expression the capture unwraps or iterates.
    source: Node.Index,
    kind: Kind,

    const Kind = enum {
        /// `if (optional) |value|`: the unwrapped value.
        payload,
        /// `for (items) |item|`: an element.
        element,
    };
};

const Container = struct {
    node: Node.Index,
    first_token: Ast.TokenIndex,
    last_token: Ast.TokenIndex,
};

/// Syntactic facts about one document, gathered in a single pass over its
/// nodes so classifying many tokens does not rescan it.
const Classifier = struct {
    arena: std.mem.Allocator,
    document: *const Document,
    tree: *const Ast,
    /// By name token.
    declarations: std.AutoHashMapUnmanaged(Ast.TokenIndex, Declaration) = .empty,
    /// Field name token to its `field_access` node.
    field_accesses: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    /// Identifier token to its `identifier` node.
    identifiers: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    /// Enum literal token to the switch operand or comparison operand its type
    /// comes from.
    literal_subjects: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    /// Field name token of `T{ .name = v }` to `T`.
    init_types: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    /// Field name tokens of `.{ .name = v }` to their initializer node, whose
    /// type the initializer itself does not give.
    anonymous_fields: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    /// Anonymous initializer to the type annotation of the variable it
    /// initializes.
    annotated_initializers: std.AutoHashMapUnmanaged(Node.Index, Node.Index) = .empty,
    /// Anonymous initializers that are returned.
    returned_initializers: std.AutoHashMapUnmanaged(Node.Index, void) = .empty,
    /// Function declarations, for the return type of what is returned.
    functions: std.ArrayList(Container) = .empty,
    /// String literal token of `@field(x, "name")` to `x`.
    reflections: std.AutoHashMapUnmanaged(Ast.TokenIndex, Node.Index) = .empty,
    containers: std.ArrayList(Container) = .empty,
    /// Member node (a declaration or field) to the container node holding it.
    member_of: std.AutoHashMapUnmanaged(Node.Index, Node.Index) = .empty,
    /// Container node to the declaration whose initializer it is.
    owners: std.AutoHashMapUnmanaged(Node.Index, Node.Index) = .empty,
    /// Prototype node to the `fn_decl` node declaring it.
    function_of: std.AutoHashMapUnmanaged(Node.Index, Node.Index) = .empty,

    fn init(arena: std.mem.Allocator, document: *const Document) !Classifier {
        var classifier: Classifier = .{ .arena = arena, .document = document, .tree = &document.tree };
        try classifier.scan();
        return classifier;
    }

    fn scan(classifier: *Classifier) !void {
        const arena = classifier.arena;
        const tree = classifier.tree;
        for (tree.rootDecls()) |member| try classifier.member_of.put(arena, member, .root);
        const node_count = tree.nodes.len;
        // Memberships first: whether a declaration is a member depends on the
        // containers found anywhere in the file.
        for (1..node_count) |raw| {
            const node: Node.Index = @fromBackingInt(@intCast(raw));
            var buffer: [2]Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, node)) |container| {
                try classifier.containers.append(arena, .{
                    .node = node,
                    .first_token = tree.firstToken(node),
                    .last_token = tree.lastToken(node),
                });
                for (container.ast.members) |member| try classifier.member_of.put(arena, member, node);
            }
            if (tree.nodeTag(node) == .fn_decl) {
                try classifier.function_of.put(arena, tree.nodeData(node).node_and_node[0], node);
            }
        }
        for (1..node_count) |raw| {
            const node: Node.Index = @fromBackingInt(@intCast(raw));
            try classifier.scanNode(node);
        }
    }

    fn scanNode(classifier: *Classifier, node: Node.Index) !void {
        const arena = classifier.arena;
        const tree = classifier.tree;
        switch (tree.nodeTag(node)) {
            .field_access => try classifier.field_accesses.put(arena, tree.nodeData(node).node_and_token[1], node),
            .identifier => try classifier.identifiers.put(arena, tree.nodeMainToken(node), node),
            .equal_equal, .bang_equal => {
                const left, const right = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(left) == .enum_literal) try classifier.literal_subjects.put(arena, tree.nodeMainToken(left), right);
                if (tree.nodeTag(right) == .enum_literal) try classifier.literal_subjects.put(arena, tree.nodeMainToken(right), left);
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                var buffer: [2]Node.Index = undefined;
                const parameters = tree.builtinCallParams(&buffer, node) orelse return;
                const builtin = tree.tokenSlice(tree.nodeMainToken(node));
                if (parameters.len != 2 or tree.nodeTag(parameters[1]) != .string_literal) return;
                if (!std.mem.eql(u8, builtin, "@field") and !std.mem.eql(u8, builtin, "@hasField") and
                    !std.mem.eql(u8, builtin, "@hasDecl")) return;
                try classifier.reflections.put(arena, tree.nodeMainToken(parameters[1]), parameters[0]);
            },
            .container_field_init, .container_field_align, .container_field => {
                const name_token = tree.nodeMainToken(node);
                if (tree.tokenTag(name_token) == .identifier) try classifier.declarations.put(arena, name_token, .field);
            },
            .@"switch", .switch_comma => {
                const full = tree.fullSwitch(node) orelse return;
                for (full.ast.cases) |case_node| {
                    const case = tree.fullSwitchCase(case_node) orelse continue;
                    for (case.ast.values) |value| {
                        if (tree.nodeTag(value) == .enum_literal) {
                            try classifier.literal_subjects.put(arena, tree.nodeMainToken(value), full.ast.condition);
                        }
                    }
                }
            },
            .@"if", .if_simple => if (tree.fullIf(node)) |full| {
                if (full.payload_token) |token| try classifier.addCapture(token, full.ast.cond_expr, .payload);
            },
            .@"while", .while_simple, .while_cont => if (tree.fullWhile(node)) |full| {
                if (full.payload_token) |token| try classifier.addCapture(token, full.ast.cond_expr, .payload);
            },
            .@"for", .for_simple => if (tree.fullFor(node)) |full| {
                var token = full.payload_token;
                for (full.ast.inputs) |input| {
                    if (tree.tokenTag(token) == .asterisk) token += 1;
                    if (tree.tokenTag(token) != .identifier) break;
                    try classifier.addCapture(token, input, .element);
                    token += 1;
                    if (tree.tokenTag(token) != .comma) break;
                    token += 1;
                }
            },
            .@"return" => if (tree.nodeData(node).opt_node.unwrap()) |operand| {
                try classifier.returned_initializers.put(arena, operand, {});
            },
            .fn_decl => try classifier.functions.append(arena, .{
                .node = tree.nodeData(node).node_and_node[0],
                .first_token = tree.firstToken(node),
                .last_token = tree.lastToken(node),
            }),
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
                var buffer: [1]Node.Index = undefined;
                const prototype = tree.fullFnProto(&buffer, node) orelse return;
                var parameters = prototype.iterate(tree);
                while (parameters.next()) |parameter| {
                    const name_token = parameter.name_token orelse continue;
                    try classifier.declarations.put(arena, name_token, .{ .parameter = parameter.type_expr });
                }
                if (prototype.name_token) |name_token| {
                    const declaring = classifier.function_of.get(node) orelse node;
                    try classifier.declarations.put(arena, name_token, if (classifier.member_of.contains(declaring)) .member else .{ .local_variable = node });
                }
            },
            .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma => {
                var buffer: [2]Node.Index = undefined;
                const full = tree.fullStructInit(&buffer, node) orelse return;
                for (full.ast.fields) |value| {
                    const first = tree.firstToken(value);
                    if (first < 2 or tree.tokenTag(first - 1) != .equal or tree.tokenTag(first - 2) != .identifier) continue;
                    if (full.ast.type_expr.unwrap()) |type_expr| {
                        try classifier.init_types.put(arena, first - 2, type_expr);
                    } else try classifier.anonymous_fields.put(arena, first - 2, node);
                }
            },
            else => {},
        }
        if (tree.fullVarDecl(node)) |declaration| {
            if (declaration.ast.init_node.unwrap()) |initializer| {
                var buffer: [2]Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, initializer) != null) try classifier.owners.put(arena, initializer, node);
            }
            if (declaration.ast.type_node.unwrap()) |type_node| {
                if (declaration.ast.init_node.unwrap()) |initializer| try classifier.annotated_initializers.put(arena, initializer, type_node);
            }
            const name_token = declaration.ast.mut_token + 1;
            if (tree.tokenTag(name_token) == .identifier) {
                try classifier.declarations.put(arena, name_token, if (classifier.member_of.contains(node)) .member else .{ .local_variable = node });
            }
        }
    }

    fn addCapture(classifier: *Classifier, payload_token: Ast.TokenIndex, source: Node.Index, kind: Capture.Kind) !void {
        var token = payload_token;
        if (classifier.tree.tokenTag(token) == .asterisk) token += 1;
        if (classifier.tree.tokenTag(token) != .identifier) return;
        try classifier.declarations.put(classifier.arena, token, .{ .capture = .{ .source = source, .kind = kind } });
    }

    // ---- classification ---------------------------------------------------

    /// The site the token at `token_index` is. With `only_name`, tokens spelled
    /// otherwise are not sites.
    fn classify(classifier: *Classifier, token_index: usize, only_name: ?[]const u8) !?Site {
        const tree = classifier.tree;
        const token = classifier.document.tokens[token_index];
        const index: Ast.TokenIndex = @intCast(token_index);
        const spelled = classifier.document.source[token.loc.start..token.loc.end];
        if (token.tag == .string_literal) {
            if (spelled.len < 2 or std.mem.findScalar(u8, spelled, '\\') != null) return null;
            const content = spelled[1 .. spelled.len - 1];
            if (only_name) |wanted| if (!std.mem.eql(u8, content, wanted)) return null;
            const subject = classifier.reflections.get(index) orelse return null;
            if (!std.zig.isValidId(content)) return null;
            const span: Loc = .{ .start = token.loc.start + 1, .end = token.loc.end - 1 };
            return .{ .span = span, .role = .{ .member = try classifier.memberQuery(index, subject, content) } };
        }
        if (spelled.len == 0 or spelled[0] == '@') return null;
        if (only_name) |wanted| if (!std.mem.eql(u8, spelled, wanted)) return null;

        if (classifier.declarations.get(index)) |declaration| switch (declaration) {
            .member, .field => {
                const chain = try classifier.scopeChain(index) orelse return .{ .span = token.loc, .role = .{ .member = null } };
                return .{ .span = token.loc, .role = .{ .member = try classifier.declarationQuery(chain, spelled) } };
            },
            .parameter, .local_variable, .capture => return .{ .span = token.loc, .role = .local },
        };
        if (classifier.identifiers.contains(index)) {
            if (classifier.document.scopes.resolve(index)) |binding| {
                if (classifier.declarations.get(@intCast(binding.token_index))) |declaration| switch (declaration) {
                    .member, .field => {},
                    else => return .{ .span = token.loc, .role = .local },
                } else return .{ .span = token.loc, .role = .local };
            }
            const chain = try classifier.scopeChain(index) orelse return .{ .span = token.loc, .role = .{ .member = null } };
            return .{ .span = token.loc, .role = .{ .member = try classifier.lexicalQuery(chain, spelled) } };
        }
        if (classifier.field_accesses.get(index)) |access| {
            return .{ .span = token.loc, .role = .{ .member = try classifier.memberQuery(index, tree.nodeData(access).node_and_token[0], spelled) } };
        }
        if (classifier.literal_subjects.get(index)) |subject| {
            return .{ .span = token.loc, .role = .{ .member = try classifier.memberQuery(index, subject, spelled) } };
        }
        if (classifier.anonymous_fields.get(index)) |initializer| {
            const type_node = classifier.annotated_initializers.get(initializer) orelse
                (if (classifier.returned_initializers.contains(initializer)) classifier.returnType(index) else null);
            const found = if (type_node) |known| try classifier.typeMemberQuery(index, known, spelled) else null;
            return .{ .span = token.loc, .role = .{ .member = found } };
        }
        if (classifier.init_types.get(index)) |type_expr| {
            return .{ .span = token.loc, .role = .{ .member = try classifier.typeMemberQuery(index, type_expr, spelled) } };
        }
        return null;
    }

    /// The return type expression of the innermost function around `token`.
    fn returnType(classifier: *Classifier, token: Ast.TokenIndex) ?Node.Index {
        var innermost: ?Container = null;
        for (classifier.functions.items) |function| {
            if (function.first_token > token or token > function.last_token) continue;
            if (innermost == null or function.first_token > innermost.?.first_token) innermost = function;
        }
        const function = innermost orelse return null;
        var buffer: [1]Node.Index = undefined;
        const prototype = classifier.tree.fullFnProto(&buffer, function.node) orelse return null;
        return prototype.ast.return_type.unwrap();
    }

    fn memberQuery(classifier: *Classifier, token: Ast.TokenIndex, receiver: Node.Index, name: []const u8) !?Query {
        const chain = try classifier.scopeChain(token) orelse return null;
        var budget: u8 = max_depth;
        const path = try classifier.pathOf(receiver, &budget) orelse return null;
        if (path.depth != 0) return null;
        return try classifier.receiverQuery(chain, path.steps, name);
    }

    fn typeMemberQuery(classifier: *Classifier, token: Ast.TokenIndex, type_expr: Node.Index, name: []const u8) !?Query {
        const chain = try classifier.scopeChain(token) orelse return null;
        var budget: u8 = max_depth;
        const path = try classifier.pathOfType(type_expr, &budget) orelse return null;
        if (path.depth != 0) return null;
        return try classifier.receiverQuery(chain, path.steps, name);
    }

    /// `name` declared in the innermost enclosing container.
    fn declarationQuery(classifier: *Classifier, chain: []const Step, name: []const u8) !Query {
        return classifier.build(chain, &.{}, name, .{ .declaration_site = true });
    }

    /// `name` looked up through the enclosing containers.
    fn lexicalQuery(classifier: *Classifier, chain: []const Step, name: []const u8) !Query {
        return classifier.build(chain, &.{}, name, .{});
    }

    /// `name` as a member of what `receiver` evaluates to.
    fn receiverQuery(classifier: *Classifier, chain: []const Step, receiver: []const Step, name: []const u8) !Query {
        return classifier.build(chain, receiver, name, .{});
    }

    fn build(classifier: *const Classifier, chain: []const Step, receiver: []const Step, name: []const u8, options: struct { declaration_site: bool = false }) !Query {
        var steps: std.ArrayList(Step) = .empty;
        try steps.appendSlice(classifier.arena, chain);
        try steps.appendSlice(classifier.arena, receiver);
        try steps.append(classifier.arena, .{ .kind = .target, .name = name });
        return .{ .declaration_site = options.declaration_site, .steps = steps.items };
    }

    /// `scope` steps for the containers enclosing `token`, or null when one of
    /// them cannot be named from the file's root (declared in a function body,
    /// returned by a function, anonymous).
    fn scopeChain(classifier: *Classifier, token: Ast.TokenIndex) !?[]const Step {
        var enclosing: std.ArrayList(Container) = .empty;
        for (classifier.containers.items) |container| {
            if (container.first_token <= token and token <= container.last_token) try enclosing.append(classifier.arena, container);
        }
        std.mem.sort(Container, enclosing.items, {}, struct {
            fn lessThan(_: void, left: Container, right: Container) bool {
                return left.first_token < right.first_token;
            }
        }.lessThan);
        var steps: std.ArrayList(Step) = .empty;
        var parent: Node.Index = .root;
        for (enclosing.items) |container| {
            const owner = classifier.owners.get(container.node) orelse return null;
            const holder = classifier.member_of.get(owner) orelse return null;
            if (holder != parent) return null;
            const declaration = classifier.tree.fullVarDecl(owner) orelse return null;
            const name_token = declaration.ast.mut_token + 1;
            if (classifier.tree.tokenTag(name_token) != .identifier) return null;
            const name = classifier.tree.tokenSlice(name_token);
            if (name[0] == '@') return null;
            try steps.append(classifier.arena, .{ .kind = .scope, .name = name });
            parent = container.node;
        }
        return steps.items;
    }

    // ---- receiver paths ---------------------------------------------------

    const max_depth = 16;

    /// How a receiver expression evaluates: names and calls, plus the number
    /// of array or slice layers a declared type adds (indexing removes one
    /// before the compiler ever sees the path).
    const Path = struct {
        steps: []const Step,
        depth: u8 = 0,
    };

    fn pathOf(classifier: *Classifier, node: Node.Index, budget: *u8) std.mem.Allocator.Error!?Path {
        if (budget.* == 0) return null;
        budget.* -= 1;
        const tree = classifier.tree;
        switch (tree.nodeTag(node)) {
            .identifier => return classifier.pathOfName(tree.nodeMainToken(node), budget),
            .field_access => {
                const lhs, const field_token = tree.nodeData(node).node_and_token;
                const base = try classifier.pathOf(lhs, budget) orelse return null;
                if (base.depth != 0) return null;
                return try classifier.extend(base, .{ .kind = .name, .name = tree.tokenSlice(field_token) });
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                var buffer: [1]Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse return null;
                const base = try classifier.pathOf(call.ast.fn_expr, budget) orelse return null;
                if (base.depth != 0) return null;
                return try classifier.extend(base, .{ .kind = .call });
            },
            .array_access => {
                const base = try classifier.pathOf(tree.nodeData(node).node_and_node[0], budget) orelse return null;
                if (base.depth != 0) return .{ .steps = base.steps, .depth = base.depth - 1 };
                return try classifier.extend(base, .{ .kind = .index });
            },
            .deref, .address_of, .@"try" => return classifier.pathOf(tree.nodeData(node).node, budget),
            .unwrap_optional, .grouped_expression => return classifier.pathOf(tree.nodeData(node).node_and_token[0], budget),
            .@"orelse", .@"catch" => return classifier.pathOf(tree.nodeData(node).node_and_node[0], budget),
            .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma => {
                var buffer: [2]Node.Index = undefined;
                const full = tree.fullStructInit(&buffer, node) orelse return null;
                return classifier.pathOfType(full.ast.type_expr.unwrap() orelse return null, budget);
            },
            else => return null,
        }
    }

    /// The path of a name, following a local binding to what it was declared
    /// or initialized as.
    fn pathOfName(classifier: *Classifier, token: Ast.TokenIndex, budget: *u8) std.mem.Allocator.Error!?Path {
        const tree = classifier.tree;
        const name = tree.tokenSlice(token);
        if (name.len == 0 or name[0] == '@') return null;
        const lexical: Path = .{ .steps = try classifier.arena.dupe(Step, &.{.{ .kind = .name, .name = name }}) };
        const binding = classifier.document.scopes.resolve(token) orelse return lexical;
        const declaration = classifier.declarations.get(@intCast(binding.token_index)) orelse return null;
        switch (declaration) {
            .member, .field => return lexical,
            .parameter => |type_expr| return classifier.pathOfType(type_expr orelse return null, budget),
            .local_variable => |node| {
                const variable = tree.fullVarDecl(node) orelse return null;
                if (variable.ast.type_node.unwrap()) |type_node| return classifier.pathOfType(type_node, budget);
                return classifier.pathOf(variable.ast.init_node.unwrap() orelse return null, budget);
            },
            .capture => |capture| {
                const base = try classifier.pathOf(capture.source, budget) orelse return null;
                if (capture.kind == .payload) return base;
                if (base.depth != 0) return .{ .steps = base.steps, .depth = base.depth - 1 };
                return try classifier.extend(base, .{ .kind = .index });
            },
        }
    }

    /// The path of the type a type expression names, counting array and slice
    /// layers. Pointers, optionals and error unions are looked through.
    fn pathOfType(classifier: *Classifier, node: Node.Index, budget: *u8) std.mem.Allocator.Error!?Path {
        if (budget.* == 0) return null;
        budget.* -= 1;
        const tree = classifier.tree;
        switch (tree.nodeTag(node)) {
            .identifier, .field_access => return classifier.pathOf(node, budget),
            .optional_type => return classifier.pathOfType(tree.nodeData(node).node, budget),
            .error_union => return classifier.pathOfType(tree.nodeData(node).node_and_node[1], budget),
            .grouped_expression => return classifier.pathOfType(tree.nodeData(node).node_and_token[0], budget),
            .array_type, .array_type_sentinel => {
                const array = tree.fullArrayType(node) orelse return null;
                return classifier.layered(try classifier.pathOfType(array.ast.elem_type, budget));
            },
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                const pointer = tree.fullPtrType(node) orelse return null;
                const child = try classifier.pathOfType(pointer.ast.child_type, budget);
                return if (pointer.size == .one) child else classifier.layered(child);
            },
            else => return null,
        }
    }

    fn layered(_: *Classifier, path: ?Path) ?Path {
        const inner = path orelse return null;
        return .{ .steps = inner.steps, .depth = inner.depth + 1 };
    }

    fn extend(classifier: *Classifier, base: Path, step: Step) !Path {
        const steps = try classifier.arena.alloc(Step, base.steps.len + 1);
        @memcpy(steps[0..base.steps.len], base.steps);
        steps[base.steps.len] = step;
        return .{ .steps = steps };
    }
};

// ---- tests ------------------------------------------------------------

const testing = std.testing;

fn testDocument(source: []const u8) !Document {
    return Document.open(testing.allocator, "file:///query.zig", 1, source);
}

fn expectQuery(query: ?Query, expected: []const u8) !void {
    const found = query orelse return error.MissingQuery;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    if (found.declaration_site) try writer.writeAll("decl ");
    for (found.steps) |step| switch (step.kind) {
        .scope => try writer.print("[{s}]", .{step.name}),
        .name => try writer.print(".{s}", .{step.name}),
        .call => try writer.writeAll("()"),
        .index => try writer.writeAll("[]"),
        .target => try writer.print(" -> {s}", .{step.name}),
    };
    try testing.expectEqualStrings(expected, buffer[0..writer.end]);
}

fn queryOf(arena: std.mem.Allocator, document: *const Document, source: []const u8, needle: []const u8, skip: usize) !?Query {
    const offset = (std.mem.find(u8, source, needle) orelse return error.MissingNeedle) + skip;
    const site = try siteAt(arena, document, offset) orelse return error.NoSite;
    return switch (site.role) {
        .member => |query| query,
        .local => error.LocalSite,
    };
}

test "field access paths follow declared types, aliases and calls" {
    const source =
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn make() Point { return .{ .x = 1 }; }
        \\    pub fn norm(self: *const Point) i32 { return self.x; }
        \\};
        \\fn run(p: Point, list: []const Point) i32 {
        \\    const q = Point.make();
        \\    var total = p.x + q.x;
        \\    for (list) |item| total += item.x;
        \\    return total + list[0].x;
        \\}
    ;
    var document = try testDocument(source);
    defer document.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectQuery(try queryOf(arena, &document, source, "x: i32", 0), "decl [Point] -> x");
    try expectQuery(try queryOf(arena, &document, source, "self.x", 5), "[Point].Point -> x");
    try expectQuery(try queryOf(arena, &document, source, "p.x +", 2), ".Point -> x");
    try expectQuery(try queryOf(arena, &document, source, "q.x;", 2), ".Point.make() -> x");
    try expectQuery(try queryOf(arena, &document, source, "item.x", 5), ".Point -> x");
    try expectQuery(try queryOf(arena, &document, source, "[0].x", 4), ".Point -> x");
}

test "declarations carry their enclosing containers and locals are local" {
    const source =
        \\const Outer = struct {
        \\    const Inner = struct { value: u8 };
        \\    fn use(a: u8) u8 { return a; }
        \\};
        \\fn make() type { return struct { hidden: u8 }; }
    ;
    var document = try testDocument(source);
    defer document.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectQuery(try queryOf(arena, &document, source, "value", 0), "decl [Outer][Inner] -> value");
    try expectQuery(try queryOf(arena, &document, source, "use", 0), "decl [Outer] -> use");
    try expectQuery(try queryOf(arena, &document, source, "Outer =", 0), "decl  -> Outer");
    try testing.expectError(error.LocalSite, queryOf(arena, &document, source, "a: u8", 0));
    try testing.expect(try queryOf(arena, &document, source, "hidden", 0) == null);
}

test "enum literals, initializer fields and reflection strings are member sites" {
    const source =
        \\const Mode = enum { fast, slow };
        \\const Config = struct { mode: Mode, name: []const u8 };
        \\fn make() !Config {
        \\    return .{ .mode = .slow, .name = "m" };
        \\}
        \\fn run(config: Config, mode: Mode) bool {
        \\    const typed: Config = .{ .mode = .fast, .name = "t" };
        \\    _ = typed;
        \\    const made = Config{ .mode = .fast, .name = "n" };
        \\    _ = made;
        \\    _ = @field(config, "name");
        \\    switch (mode) { .fast => {}, .slow => {} }
        \\    return config.mode == .slow;
        \\}
    ;
    var document = try testDocument(source);
    defer document.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectQuery(try queryOf(arena, &document, source, ".mode = .slow", 1), ".Config -> mode");
    try expectQuery(try queryOf(arena, &document, source, ".mode = .fast", 1), ".Config -> mode");
    try expectQuery(try queryOf(arena, &document, source, ".fast => ", 1), ".Mode -> fast");
    try expectQuery(try queryOf(arena, &document, source, ".slow => ", 1), ".Mode -> slow");
    try expectQuery(try queryOf(arena, &document, source, "== .slow", 4), ".Config.mode -> slow");
    try expectQuery(try queryOf(arena, &document, source, "\"name\"", 1), ".Config -> name");
    const sites = try memberSites(arena, &document, "name");
    try testing.expectEqual(@as(usize, 5), sites.len);
}

test "receivers the syntax cannot type have no query" {
    const source =
        \\fn run(anything: anytype) void {
        \\    _ = anything.field;
        \\    const made = anything.build();
        \\    _ = made.other;
        \\}
    ;
    var document = try testDocument(source);
    defer document.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try queryOf(arena, &document, source, "field", 0) == null);
    try testing.expect(try queryOf(arena, &document, source, "other", 0) == null);
}
