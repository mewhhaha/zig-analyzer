//! Direct and mutual recursion across the project, matched by function name.
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const project = @import("../project.zig");
const support = @import("../test_support.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const matchingToken = tokens_util.matchingToken;

pub const rules = [_]types.Rule{.recursive_call};

const FunctionDeclaration = struct {
    file_index: usize,
    name: []const u8,
    span: std.zig.Token.Loc,
    calls: []const []const u8,
    inline_fn: bool,
};

const FunctionDeclarationsByName = std.StringHashMapUnmanaged(std.ArrayList(usize));

pub fn find(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.recursive_call) == .off) return;
    var declarations: std.ArrayList(FunctionDeclaration) = .empty;
    defer {
        for (declarations.items) |decl| run.allocator.free(decl.calls);
        declarations.deinit(run.allocator);
    }
    var declarations_by_name: FunctionDeclarationsByName = .empty;
    defer {
        var declaration_indices = declarations_by_name.valueIterator();
        while (declaration_indices.next()) |indices| indices.deinit(run.allocator);
        declarations_by_name.deinit(run.allocator);
    }
    for (run.files, 0..) |file, file_index| {
        if (file.generated) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
            const opening = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const closing = matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse continue;
            const name = tokenText(file.source, file.tokens[fn_index + 1]);
            try declarations.append(run.allocator, .{
                .file_index = file_index,
                .name = name,
                .span = file.tokens[fn_index + 1].loc,
                .calls = try collectCalledFunctions(run.allocator, file.source, file.tokens, opening + 1, closing),
                .inline_fn = fn_index > 0 and file.tokens[fn_index - 1].tag == .keyword_inline,
            });
            const entry = try declarations_by_name.getOrPutValue(run.allocator, name, .empty);
            try entry.value_ptr.append(run.allocator, declarations.items.len - 1);
        }
    }
    for (declarations.items) |declaration| {
        if (declaration.inline_fn or !callsFunction(declaration, declaration.name)) continue;
        try run.report(.{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try run.allocator.print("function '{s}' calls itself recursively; use an explicitly bounded worklist", .{declaration.name}),
        });
    }
    for (declarations.items, 0..) |left, left_index| {
        if (left.inline_fn) continue;
        for (left.calls) |called_name| {
            const right_indices = declarations_by_name.get(called_name) orelse continue;
            for (right_indices.items) |right_index| {
                if (right_index <= left_index) continue;
                const right = declarations.items[right_index];
                if (right.inline_fn or !callsFunction(right, left.name)) continue;
                try run.report(.{
                    .file_index = right.file_index,
                    .rule = .recursive_call,
                    .span = right.span,
                    .message = try run.allocator.print("mutual recursion cycle '{s} -> {s} -> {s}' has input-controlled stack depth", .{ left.name, right.name, left.name }),
                });
            }
        }
    }
}

fn callsFunction(declaration: FunctionDeclaration, name: []const u8) bool {
    for (declaration.calls) |called_name| if (std.mem.eql(u8, called_name, name)) return true;
    return false;
}

fn collectCalledFunctions(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
    body_end: usize,
) ![]const []const u8 {
    var calls: std.ArrayList([]const u8) = .empty;
    errdefer calls.deinit(allocator);
    var index = body_start;
    while (index < body_end) : (index += 1) {
        const token = tokens[index];
        if (token.tag == .keyword_fn and index + 2 < body_end and
            tokens[index + 1].tag == .identifier and tokens[index + 2].tag == .l_paren)
        {
            const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
            const body_opening = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse continue;
            const body_closing = matchingToken(tokens, body_opening, .l_brace, .r_brace) orelse continue;
            if (body_closing < body_end) index = body_closing;
            continue;
        }
        if (token.tag != .identifier or index + 1 >= body_end or tokens[index + 1].tag != .l_paren or
            (index > body_start and tokens[index - 1].tag == .period)) continue;
        const name = tokenText(source, token);
        var already_recorded = false;
        for (calls.items) |called_name| if (std.mem.eql(u8, called_name, name)) {
            already_recorded = true;
            break;
        };
        if (!already_recorded) try calls.append(allocator, name);
    }
    return try calls.toOwnedSlice(allocator);
}

test "recursive calls use the runtime body and stay inside nested functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.recursive_call}, .information);
    const files = [_]project.SourceFile{.{
        .path = "src/walk.zig",
        .source = "fn walk() error{Stop}!void { return walk(); } fn Factory() type { return struct { fn inner() void { inner(); } }; }",
    }};
    const found = try project.findings(arena.allocator(), &files, configuration);
    var recursive_count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule == .recursive_call) {
            recursive_count += 1;
            try std.testing.expect(std.mem.find(u8, finding.finding.message, "function 'Factory'") == null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), recursive_count);
}
