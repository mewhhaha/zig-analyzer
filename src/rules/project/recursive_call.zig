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
const tokenIs = tokens_util.tokenIs;
const topLevelComma = tokens_util.topLevelComma;

pub const rules = [_]types.Rule{.recursive_call};

const FunctionDeclaration = struct {
    file_index: usize,
    name: []const u8,
    span: std.zig.Token.Loc,
    calls: []const []const u8,
    inline_fn: bool,
    /// Returns `type`, `comptime_int` or `comptime_float`, so every call to it
    /// runs at compile time.
    comptime_result: bool,
    /// Takes only comptime parameters, so no runtime argument sets the
    /// recursion depth.
    comptime_parameters: bool,
    /// The `(` and `)` of the parameter list and the `{` and `}` of the body.
    parameters_open: usize,
    parameters_close: usize,
    body_open: usize,
    body_close: usize,
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
        if (file.generated or run.levelFor(file_index, .recursive_call) == .off) continue;
        // Tests may recurse to build or walk fixtures; they are not held to
        // the production stack bound.
        var test_end: usize = 0;
        for (file.tokens, 0..) |token, fn_index| {
            if (fn_index < test_end) continue;
            if (token.tag == .keyword_test) {
                test_end = tokens_util.testBlockEnd(file.tokens, fn_index) orelse continue;
                continue;
            }
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const scopes = try run.scopes(file_index);
            const parameters_end = scopes.matchingToken(fn_index + 2) orelse continue;
            const opening = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const closing = scopes.matchingToken(opening) orelse continue;
            const name = tokenText(file.source, file.tokens[fn_index + 1]);
            try declarations.append(run.allocator, .{
                .file_index = file_index,
                .name = name,
                .span = file.tokens[fn_index + 1].loc,
                .calls = try collectCalledFunctions(run.allocator, file.source, scopes, opening + 1, closing),
                .inline_fn = fn_index > 0 and file.tokens[fn_index - 1].tag == .keyword_inline,
                .comptime_result = returnsComptimeOnlyType(file.source, file.tokens, parameters_end, opening),
                .comptime_parameters = parametersAreComptime(file.source, file.tokens, fn_index + 2, parameters_end),
                .parameters_open = fn_index + 2,
                .parameters_close = parameters_end,
                .body_open = opening,
                .body_close = closing,
            });
            const entry = try declarations_by_name.getOrPutValue(run.allocator, name, .empty);
            try entry.value_ptr.append(run.allocator, declarations.items.len - 1);
        }
    }
    // So may the private helpers only tests call.
    var test_only: TestOnlyFiles = .{ .run = run };
    defer test_only.deinit();
    for (declarations.items) |declaration| {
        if (declaration.inline_fn or declaration.comptime_result or declaration.comptime_parameters or
            !callsFunction(declaration, declaration.name)) continue;
        const file = try FileScopes.at(run, declaration.file_index);
        if (try boundedRecursion(run.allocator, file, declaration, declaration, true) or
            try test_only.contains(declaration)) continue;
        try run.report(.{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try run.allocator.print("function '{s}' calls itself recursively; use an explicitly bounded worklist", .{declaration.name}),
        });
    }
    for (declarations.items, 0..) |left, left_index| {
        if (left.inline_fn or left.comptime_result) continue;
        for (left.calls) |called_name| {
            const right_indices = declarations_by_name.get(called_name) orelse continue;
            for (right_indices.items) |right_index| {
                if (right_index <= left_index) continue;
                const right = declarations.items[right_index];
                // An unqualified call names a declaration of its own file;
                // a self-call is direct recursion, reported above.
                if (right.file_index != left.file_index or std.mem.eql(u8, left.name, right.name)) continue;
                if (right.inline_fn or right.comptime_result or (left.comptime_parameters and right.comptime_parameters) or
                    !callsFunction(right, left.name)) continue;
                const file = try FileScopes.at(run, left.file_index);
                if (try boundedRecursion(run.allocator, file, left, right, false) or
                    try boundedRecursion(run.allocator, file, right, left, false) or
                    try test_only.contains(left) or try test_only.contains(right)) continue;
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

/// The test-only bodies of each file, found when a file first reports.
const TestOnlyFiles = struct {
    run: ProjectRun,
    files: std.AutoHashMapUnmanaged(usize, syntax_scope.TestOnlyBodies) = .empty,

    fn deinit(test_only: *TestOnlyFiles) void {
        var bodies = test_only.files.valueIterator();
        while (bodies.next()) |file_bodies| file_bodies.deinit(test_only.run.allocator);
        test_only.files.deinit(test_only.run.allocator);
    }

    fn contains(test_only: *TestOnlyFiles, declaration: FunctionDeclaration) !bool {
        const entry = try test_only.files.getOrPut(test_only.run.allocator, declaration.file_index);
        if (!entry.found_existing) {
            const file = test_only.run.files[declaration.file_index];
            entry.value_ptr.* = syntax_scope.testOnlyBodies(test_only.run.allocator, file.source, file.tokens) catch |err| {
                test_only.files.removeByPtr(entry.key_ptr);
                return err;
            };
        }
        return entry.value_ptr.contains(declaration.body_open);
    }
};

/// A project file with its scope index, for the body scans below.
const FileScopes = struct {
    source: []const u8,
    tokens: []const std.zig.Token,
    scopes: *const syntax_scope.Index,

    fn at(run: ProjectRun, file_index: usize) !FileScopes {
        const file = run.files[file_index];
        return .{ .source = file.source, .tokens = file.tokens, .scopes = try run.scopes(file_index) };
    }
};

const Parameter = struct {
    name: []const u8,
    comptime_parameter: bool,
    /// A pointer the recursion charges (`budgetPointer`).
    budget: bool,
};

/// Whether `caller`'s recursion through `callee` cannot grow with its input:
/// `caller` checks a depth counter it advances on every call
/// (`if (depth >= 32) return`, then `callee(..., depth + 1)`) or a budget it
/// passes on (`try spend(budget)`, `if (budget.* == 0) return`), and `callee`
/// passes the same counter back.
fn boundedRecursion(
    allocator: std.mem.Allocator,
    file: FileScopes,
    caller: FunctionDeclaration,
    callee: FunctionDeclaration,
    direct: bool,
) !bool {
    var parameters: std.ArrayList(Parameter) = .empty;
    defer parameters.deinit(allocator);
    var start = caller.parameters_open + 1;
    while (start < caller.parameters_close) {
        const end = topLevelComma(file.tokens, start, caller.parameters_close) orelse caller.parameters_close;
        var name_index = start;
        while (name_index < end and file.tokens[name_index].tag == .doc_comment) name_index += 1;
        const comptime_parameter = name_index < end and file.tokens[name_index].tag == .keyword_comptime;
        if (comptime_parameter or (name_index < end and file.tokens[name_index].tag == .keyword_noalias)) name_index += 1;
        if (name_index + 2 < end and file.tokens[name_index].tag == .identifier and file.tokens[name_index + 1].tag == .colon) {
            const name = tokenText(file.source, file.tokens[name_index]);
            try parameters.append(allocator, .{
                .name = name,
                .comptime_parameter = comptime_parameter or tokenIs(file.source, file.tokens[name_index + 2], "type"),
                .budget = file.tokens[name_index + 2].tag == .asterisk and
                    budgetPointer(file, caller, name, name_index + 3, end),
            });
        } else {
            // A parameter without a name, such as `...`: nothing to prove.
            return false;
        }
        start = end + 1;
    }

    for (parameters.items) |parameter| {
        if (parameter.comptime_parameter or !guardsParameter(file, caller, parameter, callee.name)) continue;
        if (callsAdvance(file, caller, callee.name, parameter) and
            (direct or callsMention(file, callee, caller.name, parameter.name))) return true;
    }
    return false;
}

/// A pointer named or typed as a budget, or a counter the body counts down
/// (`remaining.* -= 1`); a counter counting up is a cursor into the input.
fn budgetPointer(file: FileScopes, caller: FunctionDeclaration, name: []const u8, type_start: usize, type_end: usize) bool {
    if (std.mem.find(u8, name, "budget") != null or std.mem.find(u8, name, "remaining") != null or
        std.mem.find(u8, name, "fuel") != null) return true;
    if (type_end <= type_start or file.tokens[type_end - 1].tag != .identifier) return false;
    const pointee = tokenText(file.source, file.tokens[type_end - 1]);
    if (std.mem.endsWith(u8, pointee, "Budget")) return true;
    if (type_end != type_start + 1 or !isIntegerType(pointee)) return false;
    const tokens = file.tokens;
    for (tokens[caller.body_open + 1 .. caller.body_close], caller.body_open + 1..) |token, index| {
        if (token.tag == .identifier and tokenIs(file.source, token, name) and tokens[index - 1].tag != .period and
            tokens[index + 1].tag == .period_asterisk and
            (tokens[index + 2].tag == .minus_equal or tokens[index + 2].tag == .minus_pipe_equal)) return true;
    }
    return false;
}

fn isIntegerType(name: []const u8) bool {
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return true;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
    for (name[1..]) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

/// Whether `caller`'s body checks `parameter` where failing the check leaves
/// the function: a comparison in an `if` that returns or breaks, in an
/// assertion, or under `try`; for a pointer budget also a call it is charged
/// through under `try` or `catch return`.
fn guardsParameter(file: FileScopes, caller: FunctionDeclaration, parameter: Parameter, recursive_name: []const u8) bool {
    const tokens = file.tokens;
    var index = caller.body_open + 1;
    while (index < caller.body_close) : (index += 1) {
        if (skipNested(file.scopes, index, caller.body_close)) |skipped| {
            index = skipped;
            continue;
        }
        if (tokens[index].tag != .identifier or !tokenIs(file.source, tokens[index], parameter.name) or
            tokens[index - 1].tag == .period) continue;
        const dereferenced = index + 1 < caller.body_close and tokens[index + 1].tag == .period_asterisk;
        if (dereferenced and !parameter.budget) continue;
        const after = if (dereferenced) index + 2 else index + 1;
        const compared = isComparison(tokens[after].tag) or isComparison(tokens[index - 1].tag);
        const charged = parameter.budget and
            ((tokens[index - 1].tag == .l_paren or tokens[index - 1].tag == .comma) and
                (tokens[index + 1].tag == .r_paren or tokens[index + 1].tag == .comma) or
                (index + 3 < caller.body_close and tokens[index + 1].tag == .period and
                    tokens[index + 2].tag == .identifier and tokens[index + 3].tag == .l_paren));
        if (!compared and !charged) continue;
        const statement = tokens_util.statementStart(tokens, index);
        const statement_end = statementEndBefore(tokens, index, caller.body_close);
        if (callsNamed(file, statement, statement_end, recursive_name)) continue;
        if (compared and exitingCondition(file, statement, index)) return true;
        if (tokens[statement].tag == .keyword_try) return true;
        if (charged and catchReturns(tokens, index, statement_end)) return true;
        if (compared and callsNamed(file, statement, statement_end, "assert")) return true;
    }
    return false;
}

/// Whether every call to `name` in `caller` passes `parameter` advanced
/// (`depth + 1`) or, for a pointer budget, passes it on.
fn callsAdvance(file: FileScopes, caller: FunctionDeclaration, name: []const u8, parameter: Parameter) bool {
    const tokens = file.tokens;
    var saw_call = false;
    var index = caller.body_open + 1;
    while (index < caller.body_close) : (index += 1) {
        if (skipNested(file.scopes, index, caller.body_close)) |skipped| {
            index = skipped;
            continue;
        }
        const call_close = callOf(file, index, caller.body_close, name) orelse continue;
        saw_call = true;
        var advanced = false;
        for (tokens[index + 2 .. call_close], index + 2..) |token, argument| {
            if (token.tag != .identifier or !tokenIs(file.source, token, parameter.name) or
                tokens[argument - 1].tag == .period) continue;
            const next = tokens[argument + 1].tag;
            if (parameter.budget) {
                if (next == .comma or next == .r_paren) advanced = true;
            } else if (next == .plus or next == .plus_pipe or next == .plus_percent) advanced = true;
        }
        if (!advanced) return false;
    }
    return saw_call;
}

/// Whether every call to `name` in `function` names `parameter_name` in its
/// arguments, handing the counter back.
fn callsMention(file: FileScopes, function: FunctionDeclaration, name: []const u8, parameter_name: []const u8) bool {
    const tokens = file.tokens;
    var saw_call = false;
    var index = function.body_open + 1;
    while (index < function.body_close) : (index += 1) {
        if (skipNested(file.scopes, index, function.body_close)) |skipped| {
            index = skipped;
            continue;
        }
        const call_close = callOf(file, index, function.body_close, name) orelse continue;
        saw_call = true;
        var mentioned = false;
        for (tokens[index + 2 .. call_close]) |token| {
            if (token.tag == .identifier and tokenIs(file.source, token, parameter_name)) mentioned = true;
        }
        if (!mentioned) return false;
    }
    return saw_call;
}

/// The `)` of an unqualified call to `name` at `index`.
fn callOf(file: FileScopes, index: usize, limit: usize, name: []const u8) ?usize {
    const tokens = file.tokens;
    if (tokens[index].tag != .identifier or index + 1 >= limit or tokens[index + 1].tag != .l_paren or
        tokens[index - 1].tag == .period or !tokenIs(file.source, tokens[index], name)) return null;
    const close = file.scopes.matchingToken(index + 1) orelse return null;
    return if (close < limit) close else null;
}

/// The `}` closing a nested function body or `comptime` block opening at
/// `index`, which the recursion analysis looks past as `collectCalledFunctions`
/// does.
fn skipNested(scopes: *const syntax_scope.Index, index: usize, limit: usize) ?usize {
    const tokens = scopes.tokens;
    if (tokens[index].tag == .keyword_comptime and index + 1 < limit and tokens[index + 1].tag == .l_brace) {
        const closing = scopes.matchingToken(index + 1) orelse return null;
        return if (closing < limit) closing else null;
    }
    if (tokens[index].tag != .keyword_fn or index + 2 >= limit or tokens[index + 1].tag != .identifier or
        tokens[index + 2].tag != .l_paren) return null;
    const parameters_end = scopes.matchingToken(index + 2) orelse return null;
    const opening = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse return null;
    const closing = scopes.matchingToken(opening) orelse return null;
    return if (closing < limit) closing else null;
}

fn statementEndBefore(tokens: []const std.zig.Token, index: usize, limit: usize) usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor < limit) : (cursor += 1) switch (tokens[cursor].tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) return cursor;
            depth -= 1;
        },
        .semicolon => if (depth == 0) return cursor,
        else => {},
    };
    return limit;
}

fn callsNamed(file: FileScopes, start: usize, end: usize, name: []const u8) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and file.tokens[index + 1].tag == .l_paren and
            tokenIs(file.source, token, name)) return true;
    }
    return false;
}

/// Whether the statement at `statement` is an `if` (or `else if`) whose
/// condition holds `index` and whose branch leaves the function.
fn exitingCondition(file: FileScopes, statement: usize, index: usize) bool {
    const tokens = file.tokens;
    var keyword = statement;
    if (tokens[keyword].tag == .keyword_else) keyword += 1;
    if (keyword + 1 >= index or tokens[keyword].tag != .keyword_if or tokens[keyword + 1].tag != .l_paren) return false;
    const condition_close = file.scopes.matchingToken(keyword + 1) orelse return false;
    if (condition_close < index or condition_close + 1 >= tokens.len) return false;
    var branch = condition_close + 1;
    if (tokens[branch].tag == .l_brace) branch += 1;
    return switch (tokens[branch].tag) {
        .keyword_return, .keyword_break, .keyword_unreachable => true,
        .builtin => tokenIs(file.source, tokens[branch], "@panic"),
        else => false,
    };
}

fn catchReturns(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_catch) continue;
        var branch = index + 1;
        if (branch < end and tokens[branch].tag == .pipe) {
            branch += 1;
            while (branch < end and tokens[branch].tag != .pipe) branch += 1;
            branch += 1;
        }
        if (branch < end and tokens[branch].tag == .keyword_return) return true;
    }
    return false;
}

fn isComparison(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .angle_bracket_left,
        .angle_bracket_left_equal,
        .angle_bracket_right,
        .angle_bracket_right_equal,
        .equal_equal,
        .bang_equal,
        => true,
        else => false,
    };
}

fn callsFunction(declaration: FunctionDeclaration, name: []const u8) bool {
    for (declaration.calls) |called_name| if (std.mem.eql(u8, called_name, name)) return true;
    return false;
}

fn collectCalledFunctions(
    allocator: std.mem.Allocator,
    source: []const u8,
    scopes: *const syntax_scope.Index,
    body_start: usize,
    body_end: usize,
) ![]const []const u8 {
    const tokens = scopes.tokens;
    var calls: std.ArrayList([]const u8) = .empty;
    errdefer calls.deinit(allocator);
    var index = body_start;
    while (index < body_end) : (index += 1) {
        const token = tokens[index];
        if (token.tag == .keyword_fn and index + 2 < body_end and
            tokens[index + 1].tag == .identifier and tokens[index + 2].tag == .l_paren)
        {
            const parameters_end = scopes.matchingToken(index + 2) orelse continue;
            const body_opening = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse continue;
            const body_closing = scopes.matchingToken(body_opening) orelse continue;
            if (body_closing < body_end) index = body_closing;
            continue;
        }
        // A call in a 'comptime' block or expression runs at compile time.
        if (token.tag == .keyword_comptime and index + 1 < body_end and tokens[index + 1].tag == .l_brace) {
            const block_closing = scopes.matchingToken(index + 1) orelse continue;
            if (block_closing < body_end) index = block_closing;
            continue;
        }
        if (token.tag != .identifier or index + 1 >= body_end or tokens[index + 1].tag != .l_paren or
            (index > body_start and (tokens[index - 1].tag == .period or tokens[index - 1].tag == .keyword_comptime))) continue;
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

/// Whether the return type between the parameter list and the body is one only
/// compile-time code can produce.
fn returnsComptimeOnlyType(source: []const u8, tokens: []const std.zig.Token, parameters_end: usize, body_opening: usize) bool {
    if (body_opening != parameters_end + 2 or tokens[parameters_end + 1].tag != .identifier) return false;
    const return_type = tokenText(source, tokens[parameters_end + 1]);
    return std.mem.eql(u8, return_type, "type") or std.mem.eql(u8, return_type, "comptime_int") or
        std.mem.eql(u8, return_type, "comptime_float");
}

/// Whether there is at least one parameter and each is `comptime` or a `type`.
fn parametersAreComptime(source: []const u8, tokens: []const std.zig.Token, opening: usize, closing: usize) bool {
    var start = opening + 1;
    if (start >= closing) return false;
    while (start < closing) {
        while (start < closing and tokens[start].tag == .doc_comment) start += 1;
        if (start >= closing) break;
        const end = topLevelComma(tokens, start, closing) orelse closing;
        const comptime_parameter = tokens[start].tag == .keyword_comptime or
            (end == start + 3 and tokens[start].tag == .identifier and tokens[start + 1].tag == .colon and
                tokens[start + 2].tag == .identifier and tokenIs(source, tokens[start + 2], "type"));
        if (!comptime_parameter) return false;
        start = end + 1;
    }
    return true;
}

test "comptime-only recursion, tests and non-production files are exempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.recursive_call}, .information);
    const recursive = "fn fact(n: u64) u64 { if (n == 0) return 1; return n * fact(n - 1); }";
    const files = [_]project.SourceFile{
        .{ .path = "src/types.zig", .source =
        \\fn Wrapped(comptime T: type, comptime depth: u8) type {
        \\    if (depth == 0) return T;
        \\    return Wrapped(?T, depth - 1);
        \\}
        \\fn pow10(comptime y: comptime_int) comptime_int {
        \\    return if (y == 0) 1 else 10 * pow10(y - 1);
        \\}
        \\fn tagOf(comptime T: type) u8 {
        \\    return switch (@typeInfo(T)) { .optional => |o| tagOf(o.child), else => 1 };
        \\}
        \\fn checked(n: u64) u64 {
        \\    comptime { _ = checked(1); }
        \\    return n + comptime checked(2);
        \\}
        \\fn runtimeLeft(comptime T: type) void { runtimeRight(@as(T, 0)); }
        \\fn runtimeRight(value: anytype) void { runtimeLeft(@TypeOf(value)); }
        \\test "walk" {
        \\    const Walker = struct { fn walk(n: u32) u32 { return if (n == 0) 0 else walk(n - 1); } };
        \\    _ = Walker.walk(3);
        \\}
        },
        .{ .path = "src/lsm/forest_fuzz.zig", .source = recursive },
        .{ .path = "tests/walk.zig", .source = recursive },
        .{ .path = "src/scripts/release.zig", .source = recursive },
        .{ .path = "src/main.zig", .source = recursive },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);
    var messages: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.finding.rule == .recursive_call) {
        try messages.append(arena.allocator(), finding.finding.message);
    };
    // Only the runtime cycle through a generic function and src/main.zig remain;
    // the four 'fact' functions do not form a mutual cycle with each other.
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[0], "'runtimeLeft -> runtimeRight -> runtimeLeft'") != null);
    try std.testing.expect(std.mem.find(u8, messages.items[1], "function 'fact'") != null);
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

test "recursion a checked depth counter or budget bounds is exempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.recursive_call}, .information);
    const files = [_]project.SourceFile{
        .{ .path = "src/walk.zig", .source =
        \\fn depthLimited(node: *const Node, depth: usize) bool {
        \\    if (depth >= 32) return false;
        \\    for (node.children) |child| if (!depthLimited(child, depth + 1)) return false;
        \\    return true;
        \\}
        \\fn budgeted(node: *const Node, remaining: *usize) error{Limit}!void {
        \\    try require(remaining.* != 0);
        \\    remaining.* -= 1;
        \\    for (node.children) |child| try budgeted(child, remaining);
        \\}
        \\fn charged(node: *const Node, budget: *Budget, depth: usize) bool {
        \\    budget.charge(depth) catch return false;
        \\    return node.leaf or charged(node.next, budget, depth + 1);
        \\}
        \\fn counted(node: *const Node, steps: *u32) bool {
        \\    if (steps.* == 0) return false;
        \\    steps.* -= 1;
        \\    return node.leaf or counted(node.next, steps);
        \\}
        \\fn parseNested(text: []const u8, offset: *usize) error{End}!void {
        \\    if (offset.* >= text.len) return error.End;
        \\    offset.* += 1;
        \\    if (text[offset.* - 1] == '[') try parseNested(text, offset);
        \\}
        \\fn fact(n: u64) u64 {
        \\    if (n == 0) return 1;
        \\    return n * fact(n - 1);
        \\}
        \\fn visit(self: *Visitor, node: *const Node) !void {
        \\    try self.enter(node);
        \\    for (node.children) |child| try visit(self, child);
        \\}
        \\fn unchecked(node: *const Node, depth: usize) void {
        \\    log(depth);
        \\    for (node.children) |child| unchecked(child, depth + 1);
        \\}
        \\fn scenario(node: *const Node) void {
        \\    for (node.children) |child| scenario(child);
        \\}
        \\test "scenario" {
        \\    scenario(&.{});
        \\}
        },
        // Unqualified calls name declarations of their own file, so these
        // two do not form a cycle with each other.
        .{ .path = "src/left.zig", .source = "fn target() void { module(); } fn module() void {}" },
        .{ .path = "src/right.zig", .source = "fn module() void { target(); } fn target() void {}" },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);
    var reported: std.ArrayList([]const u8) = .empty;
    for (found) |finding| if (finding.finding.rule == .recursive_call) {
        try reported.append(arena.allocator(), files[finding.file_index].source[finding.finding.span.start..finding.finding.span.end]);
    };
    const expected = [_][]const u8{ "parseNested", "fact", "visit", "unchecked" };
    try std.testing.expectEqual(expected.len, reported.items.len);
    for (expected, reported.items) |name, reported_name| try std.testing.expectEqualStrings(name, reported_name);
}
