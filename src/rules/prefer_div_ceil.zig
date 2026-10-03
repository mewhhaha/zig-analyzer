const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const syntax_scope = @import("../syntax_scope.zig");
const Ast = std.zig.Ast;
const Node = Ast.Node.Index;

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_div_ceil);
    if (level == .off) return;
    var tree = try Ast.parse(context.allocator, context.source, .{ .mode = .zig });
    defer tree.deinit(context.allocator);
    if (tree.errors.len != 0) return;
    var scopes = try syntax_scope.Index.init(context.allocator, context.source, context.tokens);
    defer scopes.deinit();
    var evidence = try Evidence.init(context.allocator, &tree, &scopes);
    defer evidence.deinit(context.allocator);

    for (0..tree.nodes.len) |raw_node| {
        const node: Node = @fromBackingInt(@intCast(raw_node));
        var call_buffer: [1]Node = undefined;
        if (tree.fullCall(&call_buffer, node)) |call| {
            if (call.ast.params.len != 3 or evidence.mathSymbol(call.ast.fn_expr, 8) != .div_ceil) continue;
            try context.emit(.{
                .rule = .prefer_div_ceil,
                .level = level,
                .span = nodeSpan(&tree, call.ast.fn_expr),
                .message = "consider Zig 0.17's @divCeil when divisor and overflow preconditions are guaranteed; std.math.divCeil returns an error union while the builtin returns a value",
            });
        } else if (tree.nodeTag(node) == .div and evidence.manualCeilingDivision(node)) {
            try context.emit(.{
                .rule = .prefer_div_ceil,
                .level = level,
                .span = nodeSpan(&tree, node),
                .message = "rounding addition before unsigned division can overflow; consider @divCeil and review its divisor and result preconditions",
            });
        }
    }
}

const MathSymbol = enum { std_root, math, div_ceil };

const Evidence = struct {
    tree: *const Ast,
    scopes: *const syntax_scope.Index,
    declarations: std.AutoHashMapUnmanaged(usize, Node) = .empty,
    declared_types: std.AutoHashMapUnmanaged(usize, Node) = .empty,

    fn init(allocator: std.mem.Allocator, tree: *const Ast, scopes: *const syntax_scope.Index) !Evidence {
        var evidence: Evidence = .{ .tree = tree, .scopes = scopes };
        errdefer evidence.deinit(allocator);
        for (0..tree.nodes.len) |raw_node| {
            const node: Node = @fromBackingInt(@intCast(raw_node));
            if (tree.fullVarDecl(node)) |variable| {
                const name_token = variable.ast.mut_token + 1;
                try evidence.declarations.put(allocator, name_token, node);
                if (variable.ast.type_node.unwrap()) |type_node| {
                    try evidence.declared_types.put(allocator, name_token, type_node);
                }
            }
            var parameter_buffer: [1]Node = undefined;
            if (tree.fullFnProto(&parameter_buffer, node)) |prototype| {
                var parameters = prototype.iterate(tree);
                while (parameters.next()) |parameter| {
                    const name_token = parameter.name_token orelse continue;
                    const type_node = parameter.type_expr orelse continue;
                    try evidence.declared_types.put(allocator, name_token, type_node);
                }
            }
        }
        return evidence;
    }

    fn deinit(evidence: *Evidence, allocator: std.mem.Allocator) void {
        evidence.declarations.deinit(allocator);
        evidence.declared_types.deinit(allocator);
    }

    fn declaration(evidence: *const Evidence, node: Node) ?Ast.full.VarDecl {
        if (evidence.tree.nodeTag(node) != .identifier) return null;
        const binding = evidence.scopes.findBinding(evidence.tree.nodeMainToken(node)) orelse return null;
        const declaration_node = evidence.declarations.get(binding.token_index) orelse return null;
        return evidence.tree.fullVarDecl(declaration_node);
    }

    fn constantInitializer(evidence: *const Evidence, node: Node) ?Node {
        const variable = evidence.declaration(node) orelse return null;
        if (evidence.tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
        return variable.ast.init_node.unwrap();
    }

    // Resolve imports and immutable aliases through their lexical bindings, so a
    // local object or parameter named std/math/divCeil cannot impersonate std.math.
    fn mathSymbol(evidence: *const Evidence, raw_node: Node, budget: u8) ?MathSymbol {
        if (budget == 0) return null;
        const tree = evidence.tree;
        const node = ungroup(tree, raw_node);
        switch (tree.nodeTag(node)) {
            .identifier => return evidence.mathSymbol(evidence.constantInitializer(node) orelse return null, budget - 1),
            .field_access => {
                const receiver, const member = tree.nodeData(node).node_and_token;
                const root = evidence.mathSymbol(receiver, budget - 1) orelse return null;
                if (root == .std_root and std.mem.eql(u8, tree.tokenSlice(member), "math")) return .math;
                if (root == .math and std.mem.eql(u8, tree.tokenSlice(member), "divCeil")) return .div_ceil;
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
                var buffer: [2]Node = undefined;
                const parameters = tree.builtinCallParams(&buffer, node) orelse return null;
                if (parameters.len == 1 and tree.nodeTag(parameters[0]) == .string_literal and
                    std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parameters[0])), "\"std\"")) return .std_root;
            },
            else => {},
        }
        return null;
    }

    fn manualCeilingDivision(evidence: *const Evidence, node: Node) bool {
        const tree = evidence.tree;
        const numerator, const raw_denominator = tree.nodeData(node).node_and_node;
        const denominator = ungroup(tree, raw_denominator);
        const denominator_value = evidence.positiveConstant(denominator, 8) orelse return false;
        // Dividing by one is already exact; the spelling may be intentional arithmetic.
        if (denominator_value <= 1) return false;
        const rounding = ungroup(tree, numerator);
        const value, const repeated_denominator = switch (tree.nodeTag(rounding)) {
            .sub => parts: {
                const sum_node, const one = tree.nodeData(rounding).node_and_node;
                if (integerLiteral(tree, ungroup(tree, one)) != 1) return false;
                const sum = ungroup(tree, sum_node);
                if (tree.nodeTag(sum) != .add) return false;
                break :parts tree.nodeData(sum).node_and_node;
            },
            .add => parts: {
                const value_node, const adjustment_node = tree.nodeData(rounding).node_and_node;
                const adjustment = ungroup(tree, adjustment_node);
                if (tree.nodeTag(adjustment) != .sub) return false;
                const divisor_node, const one = tree.nodeData(adjustment).node_and_node;
                if (integerLiteral(tree, ungroup(tree, one)) != 1) return false;
                break :parts .{ value_node, divisor_node };
            },
            else => return false,
        };
        return evidence.sameOperand(repeated_denominator, denominator) and evidence.unsignedOperand(value, 8);
    }

    fn sameOperand(evidence: *const Evidence, raw_left: Node, raw_right: Node) bool {
        const tree = evidence.tree;
        const left = ungroup(tree, raw_left);
        const right = ungroup(tree, raw_right);
        if (tree.nodeTag(left) == .identifier and tree.nodeTag(right) == .identifier) {
            const left_binding = evidence.scopes.findBinding(tree.nodeMainToken(left)) orelse return false;
            const right_binding = evidence.scopes.findBinding(tree.nodeMainToken(right)) orelse return false;
            return left_binding.token_index == right_binding.token_index;
        }
        const left_literal = integerLiteral(tree, left) orelse return false;
        return left_literal == integerLiteral(tree, right);
    }

    fn unsignedType(evidence: *const Evidence, raw_node: Node, budget: u8) bool {
        if (budget == 0) return false;
        const tree = evidence.tree;
        const node = ungroup(tree, raw_node);
        if (tree.nodeTag(node) != .identifier) return false;
        if (evidence.scopes.findBinding(tree.nodeMainToken(node)) != null) {
            const initializer = evidence.constantInitializer(node) orelse return false;
            return evidence.unsignedType(initializer, budget - 1);
        }
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        if (std.mem.eql(u8, name, "usize")) return true;
        if (name.len < 2 or name[0] != 'u') return false;
        const bits = std.fmt.parseInt(u16, name[1..], 10) catch return false;
        return bits > 0;
    }

    fn unsignedOperand(evidence: *const Evidence, raw_node: Node, budget: u8) bool {
        if (budget == 0) return false;
        const tree = evidence.tree;
        const node = ungroup(tree, raw_node);
        if (tree.nodeTag(node) == .identifier) {
            const binding = evidence.scopes.findBinding(tree.nodeMainToken(node)) orelse return false;
            if (evidence.declared_types.get(binding.token_index)) |type_node| return evidence.unsignedType(type_node, 8);
            if (evidence.declaration(node)) |variable| {
                return evidence.unsignedOperand(variable.ast.init_node.unwrap() orelse return false, budget - 1);
            }
        }
        var buffer: [2]Node = undefined;
        const parameters = tree.builtinCallParams(&buffer, node) orelse return false;
        return parameters.len == 2 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as") and
            evidence.unsignedType(parameters[0], 8);
    }

    fn positiveConstant(evidence: *const Evidence, raw_node: Node, budget: u8) ?u128 {
        if (budget == 0) return null;
        const tree = evidence.tree;
        const node = ungroup(tree, raw_node);
        if (integerLiteral(tree, node)) |value| return if (value > 0) value else null;
        const variable = evidence.declaration(node) orelse return null;
        if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
        if (variable.ast.type_node.unwrap()) |type_node| {
            if (!evidence.unsignedType(type_node, 8)) return null;
        }
        return evidence.positiveConstant(variable.ast.init_node.unwrap() orelse return null, budget - 1);
    }
};

fn ungroup(tree: *const Ast, raw_node: Node) Node {
    var node = raw_node;
    while (tree.nodeTag(node) == .grouped_expression) node = tree.nodeData(node).node_and_token[0];
    return node;
}

fn integerLiteral(tree: *const Ast, node: Node) ?u128 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return std.fmt.parseInt(u128, tree.tokenSlice(tree.nodeMainToken(node)), 0) catch null;
}

fn nodeSpan(tree: *const Ast, node: Node) std.zig.Token.Loc {
    const start = tree.tokenStart(tree.firstToken(node));
    const last = tree.lastToken(node);
    return .{ .start = start, .end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)) };
}

test "prefer div ceil recognizes proven standard imports and aliases without fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "const std = @import(\"std\"); const math = std.math; const ceiling = math.divCeil;" ++
        "const renamed = @import(\"std\"); const direct = @import(\"std\").math;" ++
        "fn f(n: u32) !u32 { _ = try std.math.divCeil(u32, n, 8);" ++
        "_ = math.divCeil(u32, n, 8) catch 0; _ = try ceiling(u32, n, 8);" ++
        "_ = try renamed.math.divCeil(u32, n, 8); _ = try direct.divCeil(u32, n, 8);" ++
        "return @import(\"std\").math.divCeil(u32, n, 8); }", true);
    try std.testing.expectEqual(@as(usize, 6), found.len);
    for (found) |finding| {
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        try std.testing.expect(std.mem.find(u8, finding.message, "error union") != null);
    }
}

test "prefer div ceil rejects custom names mutable aliases and shadowed imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "const std = @import(\"std\"); const math = @import(\"custom.zig\");" ++
        "var mutable = std.math;" ++
        "fn a(std: Custom, n: u32) void { _ = std.math.divCeil(u32, n, 8); }" ++
        "fn b(math: Custom, n: u32) void { _ = math.divCeil(u32, n, 8); }" ++
        "fn c(n: u32) void { _ = math.divCeil(u32, n, 8); _ = mutable.divCeil(u32, n, 8);" ++
        "const std = Custom{}; _ = std.math.divCeil(u32, n, 8); }" ++
        "fn d(n: u32) void { _ = divCeil(u32, n, 8); _ = std.math.divFloor(u32, n, 8); }", true);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "prefer div ceil recognizes unsigned rounding arithmetic with positive constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "const Count = u32; const block_size: Count = 8; const width = block_size;" ++
        "fn f(n: Count) void { _ = (n + width - 1) / width;" ++
        "_ = (n + (block_size - 1)) / block_size; _ = ((n) + 8 - 1) / 0x8;" ++
        "const count = @as(usize, n); _ = (count + 16 - 1) / 16; }", true);
    try std.testing.expectEqual(@as(usize, 4), found.len);
    for (found) |finding| {
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        try std.testing.expect(std.mem.find(u8, finding.message, "can overflow") != null);
    }
}

test "prefer div ceil leaves signed unknown zero mutable and different divisors alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findingsFor(arena.allocator(), "fn f(signed: i32, unsigned: u32, unknown: anytype, divisor: u32) void {" ++
        "_ = (signed + 8 - 1) / 8; _ = (unknown + 8 - 1) / 8;" ++
        "_ = (unsigned + divisor - 1) / divisor; _ = (unsigned + 0 - 1) / 0;" ++
        "_ = (unsigned + 1 - 1) / 1; _ = (unsigned + 8 - 1) / 16;" ++
        "var width: u32 = 8; _ = (unsigned + width - 1) / width;" ++
        "const float_width = 8.0; _ = (unsigned + float_width - 1) / float_width;" ++
        "const signed_width: i32 = 8; _ = (unsigned + signed_width - 1) / signed_width;" ++
        "_ = (unsigned +% 8 - 1) / 8; _ = (getCount() + 8 - 1) / 8; }", true);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "prefer div ceil honors suppression and is off by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const suppressed = try findingsFor(arena.allocator(), "const std = @import(\"std\");\nfn f(n: u32) void {\n" ++
        "// zig-analyzer: disable-next-line prefer-div-ceil\n" ++
        "_ = std.math.divCeil(u32, n, 8);\n" ++
        "// zig-analyzer: disable-next-line prefer-div-ceil\n" ++
        "_ = (n + 8 - 1) / 8;\n}", true);
    try std.testing.expectEqual(@as(usize, 0), suppressed.len);
    const default_found = try findingsFor(arena.allocator(), "const std = @import(\"std\"); fn f(n: u32) void { _ = std.math.divCeil(u32, n, 8); _ = (n + 8 - 1) / 8; }", false);
    try std.testing.expectEqual(types.Level.off, types.Configuration.defaults().level(.prefer_div_ceil));
    try std.testing.expectEqual(@as(usize, 0), default_found.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8, enabled: bool) ![]const types.Finding {
    var tokenizer = std.zig.Tokenizer.init(source);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(allocator);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    errdefer found.deinit(allocator);
    var configuration = types.Configuration.defaults();
    if (enabled) configuration.levels[@backingInt(types.Rule.prefer_div_ceil)] = .warning;
    try run(.{ .allocator = allocator, .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    return found.toOwnedSlice(allocator);
}
