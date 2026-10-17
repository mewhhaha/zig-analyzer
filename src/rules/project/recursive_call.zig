//! Direct and mutual recursion within each file, with unqualified calls resolved to the declarations they name.
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
const isComparison = tokens_util.isComparison;
const PathRange = tokens_util.Range;

pub const rules = [_]types.Rule{.recursive_call};

/// A call by an unqualified name, resolved to the declaration visible at the
/// call: the innermost enclosing container declaring the name.
const Call = struct {
    /// The name token of the called function's declaration in the same file.
    target: usize,
    arguments: usize,
};

const FunctionDeclaration = struct {
    file_index: usize,
    name: []const u8,
    span: std.zig.Token.Loc,
    name_token: usize,
    parameter_count: usize,
    /// `pub`, so callers in other files may pick its arguments.
    public: bool,
    calls: []const Call,
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

const DeclarationKey = struct { file_index: usize, name_token: usize };

/// Direct recursion that counts a parameter down to a check, reported unless
/// every caller starts the count from a constant.
const Countdown = struct {
    declaration: usize,
    /// The counter's parameter position and name.
    position: usize,
    counter: []const u8,
    /// Whether a caller starts the count from a constant, and none from
    /// anything else.
    constant_start: bool = false,
    other_start: bool = false,
};

pub fn find(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.recursive_call) == .off) return;
    var declarations: std.ArrayList(FunctionDeclaration) = .empty;
    defer {
        for (declarations.items) |decl| run.allocator.free(decl.calls);
        declarations.deinit(run.allocator);
    }
    var declaration_indices: std.AutoHashMapUnmanaged(DeclarationKey, usize) = .empty;
    defer declaration_indices.deinit(run.allocator);
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
            try declarations.append(run.allocator, .{
                .file_index = file_index,
                .name = tokenText(file.source, file.tokens[fn_index + 1]),
                .span = file.tokens[fn_index + 1].loc,
                .name_token = fn_index + 1,
                .parameter_count = listLength(file.tokens, fn_index + 2, parameters_end),
                .public = isPublic(file.tokens, fn_index),
                .calls = try collectCalledFunctions(run.allocator, file.source, scopes, opening + 1, closing),
                .inline_fn = fn_index > 0 and file.tokens[fn_index - 1].tag == .keyword_inline,
                .comptime_result = returnsComptimeOnlyType(file.source, file.tokens, parameters_end, opening),
                .comptime_parameters = parametersAreComptime(file.source, file.tokens, fn_index + 2, parameters_end),
                .parameters_open = fn_index + 2,
                .parameters_close = parameters_end,
                .body_open = opening,
                .body_close = closing,
            });
            try declaration_indices.put(run.allocator, .{ .file_index = file_index, .name_token = fn_index + 1 }, declarations.items.len - 1);
        }
    }
    // So may the private helpers only tests call.
    var test_only: TestOnlyFiles = .{ .run = run };
    defer test_only.deinit();
    var countdowns: std.ArrayList(Countdown) = .empty;
    defer countdowns.deinit(run.allocator);
    for (declarations.items, 0..) |declaration, declaration_index| {
        if (declaration.inline_fn or declaration.comptime_result or declaration.comptime_parameters or
            !callsDeclaration(declaration, declaration)) continue;
        const file = try FileScopes.at(run, declaration.file_index);
        if (try boundedRecursion(run.allocator, file, declaration, declaration, true) or
            recursesOverType(file, declaration) or recursesPastGuard(file, declaration) or
            try test_only.contains(declaration)) continue;
        if (countedDown(file, declaration)) |position| {
            try countdowns.append(run.allocator, .{
                .declaration = declaration_index,
                .position = position,
                .counter = parameterName(file, declaration, position).?,
            });
            continue;
        }
        try run.report(.{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try run.allocator.print("function '{s}' calls itself recursively; use an explicitly bounded worklist", .{declaration.name}),
        });
    }
    try checkCountdownStarts(run, declarations.items, countdowns.items);
    for (countdowns.items) |countdown| {
        if (countdown.constant_start and !countdown.other_start) continue;
        const declaration = declarations.items[countdown.declaration];
        try run.report(.{
            .file_index = declaration.file_index,
            .rule = .recursive_call,
            .span = declaration.span,
            .message = try run.allocator.print(
                "function '{s}' calls itself recursively, counting '{s}' down to its check, but its callers choose where the count starts; start it from a constant or use an explicitly bounded worklist",
                .{ declaration.name, countdown.counter },
            ),
        });
    }
    for (declarations.items, 0..) |left, left_index| {
        if (left.inline_fn or left.comptime_result) continue;
        for (left.calls) |call| {
            const right_index = declaration_indices.get(.{ .file_index = left.file_index, .name_token = call.target }) orelse continue;
            // A self-call is direct recursion, reported above.
            if (right_index <= left_index) continue;
            const right = declarations.items[right_index];
            if (call.arguments != right.parameter_count or right.inline_fn or right.comptime_result or
                (left.comptime_parameters and right.comptime_parameters) or !callsDeclaration(right, left)) continue;
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

/// The recursive calls in `declaration`'s own body: unqualified calls of its
/// name with its arity, outside nested functions and `comptime` blocks.
const RecursiveCalls = struct {
    file: FileScopes,
    declaration: FunctionDeclaration,
    index: usize,

    fn init(file: FileScopes, declaration: FunctionDeclaration) RecursiveCalls {
        return .{ .file = file, .declaration = declaration, .index = declaration.body_open + 1 };
    }

    /// The next call, from its name to its `)`.
    fn next(calls: *RecursiveCalls) ?PathRange {
        const limit = calls.declaration.body_close;
        while (calls.index < limit) {
            const index = calls.index;
            calls.index += 1;
            if (skipNested(calls.file.scopes, index, limit)) |skipped| {
                calls.index = skipped + 1;
                continue;
            }
            const close = callOf(calls.file, index, limit, calls.declaration.name) orelse continue;
            if (listLength(calls.file.tokens, index + 1, close) != calls.declaration.parameter_count) continue;
            return .{ .start = index, .end = close };
        }
        return null;
    }
};

/// Whether `declaration` recurses over a type rather than its input: every
/// recursive call sits in a prong of a `switch (@typeInfo(...))` other than
/// `.pointer` and dereferences nothing, so it works on a part of the value's
/// type (a field, element, payload or conversion) and the depth is the
/// type's nesting. Following a pointer could reach the same type again.
fn recursesOverType(file: FileScopes, declaration: FunctionDeclaration) bool {
    var calls: RecursiveCalls = .init(file, declaration);
    var saw_call = false;
    while (calls.next()) |call| {
        saw_call = true;
        for (file.tokens[call.start + 2 .. call.end]) |token| if (token.tag == .period_asterisk) return false;
        if (!inTypeProng(file, declaration, call.start)) return false;
    }
    return saw_call;
}

/// Whether `index` lies in a prong of a `switch (@typeInfo(...))` in
/// `declaration`'s body that cannot match a pointer type.
fn inTypeProng(file: FileScopes, declaration: FunctionDeclaration, index: usize) bool {
    const tokens = file.tokens;
    var brace = file.scopes.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = file.scopes.enclosingOpeningBrace(opening)) {
        if (opening <= declaration.body_open) return false;
        if (tokens[opening - 1].tag != .r_paren) continue;
        const subject = file.scopes.matchingToken(opening - 1) orelse continue;
        if (subject == 0 or tokens[subject - 1].tag != .keyword_switch or
            !tokenIs(file.source, tokens[subject + 1], "@typeInfo")) continue;
        const prong = prongItems(file, opening, index) orelse return false;
        var else_prong = false;
        for (tokens[prong.start..prong.end], prong.start..) |token, item| {
            if (token.tag == .keyword_else) else_prong = true;
            if (enumLiteral(file, item, "pointer")) return false;
        }
        // `else` covers pointers unless a prong of their own handles them.
        return !else_prong or switchNamesPointer(file, opening);
    }
    return false;
}

/// The items of the prong of the switch body opening at `opening` whose
/// result holds `index`, up to its `=>`.
fn prongItems(file: FileScopes, opening: usize, index: usize) ?PathRange {
    const tokens = file.tokens;
    var items_start = opening + 1;
    var arrow: ?usize = null;
    var in_items = true;
    var cursor = opening + 1;
    while (cursor < index) : (cursor += 1) switch (tokens[cursor].tag) {
        .l_paren, .l_bracket, .l_brace => {
            const closing = file.scopes.matchingToken(cursor) orelse return null;
            if (closing > index) break;
            cursor = closing;
        },
        .equal_angle_bracket_right => {
            arrow = cursor;
            in_items = false;
            // A capture such as `|value, tag|` has commas of its own.
            if (tokens[cursor + 1].tag == .pipe) {
                cursor += 2;
                while (cursor < index and tokens[cursor].tag != .pipe) cursor += 1;
            }
        },
        .comma => if (!in_items) {
            in_items = true;
            items_start = cursor + 1;
        },
        else => {},
    };
    if (in_items) return null;
    return .{ .start = items_start, .end = arrow.? };
}

/// Whether the switch body opening at `opening` has a `.pointer` prong.
fn switchNamesPointer(file: FileScopes, opening: usize) bool {
    const closing = file.scopes.matchingToken(opening) orelse return false;
    var cursor = opening + 1;
    while (cursor < closing) : (cursor += 1) switch (file.tokens[cursor].tag) {
        .l_paren, .l_bracket, .l_brace => cursor = file.scopes.matchingToken(cursor) orelse return false,
        .period => if (enumLiteral(file, cursor, "pointer") and
            (file.tokens[cursor - 1].tag == .l_brace or file.tokens[cursor - 1].tag == .comma)) return true,
        else => {},
    };
    return false;
}

/// Whether the `.` at `index` starts the enum literal `.name`.
fn enumLiteral(file: FileScopes, index: usize, name: []const u8) bool {
    return file.tokens[index].tag == .period and file.tokens[index + 1].tag == .identifier and
        tokenIs(file.source, file.tokens[index + 1], name) and switch (file.tokens[index - 1].tag) {
        .identifier, .r_paren, .r_bracket, .r_brace, .builtin => false,
        else => true,
    };
}

/// Whether every recursive call passes a parameter reduced below the guard
/// that leads to it, as `if (shift >= limb_bits)` then
/// `llshl(r, a, shift % limb_bits)`: the call it makes takes the other branch.
fn recursesPastGuard(file: FileScopes, declaration: FunctionDeclaration) bool {
    const tokens = file.tokens;
    var calls: RecursiveCalls = .init(file, declaration);
    var saw_call = false;
    while (calls.next()) |call| {
        saw_call = true;
        var position: usize = 0;
        var start = call.start + 2;
        const reduced = while (start < call.end) : (position += 1) {
            const end = topLevelComma(tokens, start, call.end) orelse call.end;
            if (end == start + 3 and tokens[start].tag == .identifier and tokens[start + 1].tag == .percent) {
                const parameter = parameterAt(file, declaration, position) orelse break false;
                const name = tokenText(file.source, tokens[parameter.name]);
                if (tokenIs(file.source, tokens[start], name) and
                    guardedBy(file, declaration, call.start, name, tokenText(file.source, tokens[start + 2]))) break true;
            }
            if (end == call.end) break false;
            start = end + 1;
        } else false;
        if (!reduced) return false;
    }
    return saw_call;
}

/// Whether `index` lies in the block of an `if (name >= bound)` (or
/// `bound <= name`, or a strict comparison) in `declaration`'s body.
fn guardedBy(file: FileScopes, declaration: FunctionDeclaration, index: usize, name: []const u8, bound: []const u8) bool {
    const tokens = file.tokens;
    var brace = file.scopes.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = file.scopes.enclosingOpeningBrace(opening)) {
        if (opening <= declaration.body_open) return false;
        if (tokens[opening - 1].tag != .r_paren) continue;
        const condition = file.scopes.matchingToken(opening - 1) orelse continue;
        if (condition == 0 or tokens[condition - 1].tag != .keyword_if or condition + 4 != opening - 1) continue;
        const left = tokenText(file.source, tokens[condition + 1]);
        const right = tokenText(file.source, tokens[condition + 3]);
        switch (tokens[condition + 2].tag) {
            .angle_bracket_right_equal, .angle_bracket_right => if (std.mem.eql(u8, left, name) and std.mem.eql(u8, right, bound)) return true,
            .angle_bracket_left_equal, .angle_bracket_left => if (std.mem.eql(u8, right, name) and std.mem.eql(u8, left, bound)) return true,
            else => {},
        }
    }
    return false;
}

/// The position of an integer parameter `declaration` checks before it
/// recurses and every recursive call passes decremented
/// (`if (remaining == 0) return null;` and `visit(..., remaining - 1)`).
fn countedDown(file: FileScopes, declaration: FunctionDeclaration) ?usize {
    const tokens = file.tokens;
    for (0..declaration.parameter_count) |position| {
        const parameter = parameterAt(file, declaration, position) orelse continue;
        if (parameter.comptime_parameter or parameter.type_start + 1 != parameter.type_end or
            !isIntegerType(tokenText(file.source, tokens[parameter.type_start]))) continue;
        const name = tokenText(file.source, tokens[parameter.name]);
        if (!guardsParameter(file, declaration, .{ .name = name, .comptime_parameter = false, .budget = false }, declaration.name)) continue;
        var calls: RecursiveCalls = .init(file, declaration);
        var saw_call = false;
        const decremented = while (calls.next()) |call| {
            saw_call = true;
            const argument = argumentAt(tokens, call.start + 1, call.end, position) orelse break false;
            if (argument.end < argument.start + 3 or !tokenIs(file.source, tokens[argument.start], name)) break false;
            switch (tokens[argument.start + 1].tag) {
                .minus, .minus_pipe, .minus_percent => {},
                else => break false,
            }
        } else saw_call;
        if (decremented) return position;
    }
    return null;
}

/// Records where the callers of each countdown start it. A public function's
/// callers in other files are unseen; within its file, a reference outside
/// its own body and tests starts it from a constant when it is an
/// unqualified call passing an integer literal or a container-level constant
/// as the counter. Each file with countdowns is scanned once.
fn checkCountdownStarts(run: ProjectRun, declarations: []const FunctionDeclaration, countdowns: []Countdown) !void {
    var group_start: usize = 0;
    while (group_start < countdowns.len) {
        const file_index = declarations[countdowns[group_start].declaration].file_index;
        var group_end = group_start + 1;
        while (group_end < countdowns.len and declarations[countdowns[group_end].declaration].file_index == file_index) group_end += 1;
        const group = countdowns[group_start..group_end];
        group_start = group_end;
        for (group) |*countdown| countdown.other_start = declarations[countdown.declaration].public;
        const file = try FileScopes.at(run, file_index);
        var test_end: usize = 0;
        for (file.tokens, 0..) |token, index| {
            if (index < test_end) continue;
            if (token.tag == .keyword_test) {
                test_end = tokens_util.testBlockEnd(file.tokens, index) orelse continue;
                continue;
            }
            if (token.tag != .identifier or index == 0) continue;
            for (group) |*countdown| {
                const declaration = declarations[countdown.declaration];
                if (countdown.other_start or index == declaration.name_token or
                    (index > declaration.body_open and index < declaration.body_close) or
                    !tokenIs(file.source, token, declaration.name)) continue;
                switch (countStart(file, declaration, countdown.position, index)) {
                    .unrelated => {},
                    .constant => countdown.constant_start = true,
                    .other => countdown.other_start = true,
                }
            }
        }
    }
}

/// Where the reference at `index`, spelled like `declaration`, starts its
/// counter at `position`. A qualified reference or one taken as a value is
/// not followed.
fn countStart(file: FileScopes, declaration: FunctionDeclaration, position: usize, index: usize) enum { unrelated, constant, other } {
    const tokens = file.tokens;
    // A field, parameter or label spelled like the function.
    if (tokens[index + 1].tag == .colon) return .unrelated;
    if (tokens[index - 1].tag == .period) return .other;
    const binding = file.scopes.findBinding(index) orelse return .unrelated;
    if (binding.token_index != declaration.name_token) return .unrelated;
    if (tokens[index + 1].tag != .l_paren) return .other;
    const close = file.scopes.matchingToken(index + 1) orelse return .other;
    const argument = argumentAt(tokens, index + 1, close, position) orelse return .other;
    if (argument.end != argument.start + 1) return .other;
    if (tokens[argument.start].tag == .number_literal) return .constant;
    if (tokens[argument.start].tag != .identifier) return .other;
    const constant = file.scopes.findBinding(argument.start) orelse return .other;
    return if (constant.token_index > 0 and tokens[constant.token_index - 1].tag == .keyword_const and
        !file.scopes.insideFunctionOrTestBody(constant.token_index)) .constant else .other;
}

const ParameterSpan = struct {
    name: usize,
    type_start: usize,
    type_end: usize,
    comptime_parameter: bool,
};

/// `declaration`'s parameter at `position`, if it is a plain `name: T`.
fn parameterAt(file: FileScopes, declaration: FunctionDeclaration, position: usize) ?ParameterSpan {
    const tokens = file.tokens;
    var start = declaration.parameters_open + 1;
    var current: usize = 0;
    while (start < declaration.parameters_close) : (current += 1) {
        const end = topLevelComma(tokens, start, declaration.parameters_close) orelse declaration.parameters_close;
        if (current == position) {
            var name = start;
            while (name < end and tokens[name].tag == .doc_comment) name += 1;
            const comptime_parameter = name < end and tokens[name].tag == .keyword_comptime;
            if (comptime_parameter or (name < end and tokens[name].tag == .keyword_noalias)) name += 1;
            if (name + 2 >= end or tokens[name].tag != .identifier or tokens[name + 1].tag != .colon) return null;
            return .{ .name = name, .type_start = name + 2, .type_end = end, .comptime_parameter = comptime_parameter };
        }
        if (end == declaration.parameters_close) return null;
        start = end + 1;
    }
    return null;
}

fn parameterName(file: FileScopes, declaration: FunctionDeclaration, position: usize) ?[]const u8 {
    const parameter = parameterAt(file, declaration, position) orelse return null;
    return tokenText(file.source, file.tokens[parameter.name]);
}

/// The tokens of argument `position` of the call whose `(` is `opening`.
fn argumentAt(tokens: []const std.zig.Token, opening: usize, closing: usize, position: usize) ?PathRange {
    var start = opening + 1;
    var current: usize = 0;
    while (start < closing) : (current += 1) {
        const end = topLevelComma(tokens, start, closing) orelse closing;
        if (current == position) return if (end > start) .{ .start = start, .end = end } else null;
        if (end == closing) return null;
        start = end + 1;
    }
    return null;
}

/// Whether `caller` calls `callee` with as many arguments as it takes; a call
/// of another arity cannot be to it (a branch comptime discards).
fn callsDeclaration(caller: FunctionDeclaration, callee: FunctionDeclaration) bool {
    if (caller.file_index != callee.file_index) return false;
    for (caller.calls) |call| {
        if (call.target == callee.name_token and call.arguments == callee.parameter_count) return true;
    }
    return false;
}

fn collectCalledFunctions(
    allocator: std.mem.Allocator,
    source: []const u8,
    scopes: *const syntax_scope.Index,
    body_start: usize,
    body_end: usize,
) ![]const Call {
    const tokens = scopes.tokens;
    var calls: std.ArrayList(Call) = .empty;
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
        const binding = scopes.findBindingNamed(tokenText(source, token), index) orelse continue;
        if (binding.kind != .callable) continue;
        const call_close = scopes.matchingToken(index + 1) orelse continue;
        const call: Call = .{ .target = binding.token_index, .arguments = listLength(tokens, index + 1, call_close) };
        const already_recorded = for (calls.items) |recorded| {
            if (recorded.target == call.target and recorded.arguments == call.arguments) break true;
        } else false;
        if (!already_recorded) try calls.append(allocator, call);
    }
    return try calls.toOwnedSlice(allocator);
}

/// The number of comma-separated entries between `opening` and its matching
/// `closing`, ignoring a trailing comma.
fn listLength(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    var count: usize = 0;
    var start = opening + 1;
    while (start < closing) {
        const end = topLevelComma(tokens, start, closing) orelse closing;
        if (end > start) count += 1;
        start = end + 1;
    }
    return count;
}

fn isPublic(tokens: []const std.zig.Token, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_pub => return true,
            .keyword_inline, .keyword_noinline, .keyword_export, .keyword_extern, .string_literal => {},
            else => return false,
        }
    }
    return false;
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

/// The source of each `recursive_call` finding's span.
fn reportedNames(allocator: std.mem.Allocator, files: []const project.SourceFile) ![]const []const u8 {
    const found = try project.findings(allocator, files, support.only(&.{.recursive_call}, .information));
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |finding| try names.append(allocator, files[finding.file_index].source[finding.finding.span.start..finding.finding.span.end]);
    return names.toOwnedSlice(allocator);
}

test "calls resolve to the declaration they name and take its arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{ .path = "src/format.zig", .source =
        \\const Type = struct {
        \\    fn format(data: Type, w: *Writer) !void { try w.print(data); }
        \\};
        \\const Metadata = struct {
        \\    next: ?*const Metadata,
        \\    fn format(data: Metadata, w: *Writer) !void { if (data.next) |next| try format(next.*, w); }
        \\};
        \\const PolyVec = struct {
        \\    fn useHint(v: PolyVec, hint: PolyVec) PolyVec { return polyUseHint(v, hint); }
        \\};
        \\fn useHint(rp: u32, hint: u32) u32 { return rp ^ hint; }
        \\fn polyUseHint(q: u32, hint: u32) u32 { return useHint(q, hint); }
        \\const Action = struct {
        \\    fn format(self: Action, writer: *Writer) !void {
        \\        if (comptime @sizeOf(Action) > 0) try writer.print(self) else try format(writer, "@{x}", .{@intFromPtr(&self)});
        \\    }
        \\};
    }};
    const names = try reportedNames(arena.allocator(), &files);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqual(std.mem.find(u8, files[0].source, "format(data: Metadata").?, names[0].ptr - files[0].source.ptr);
}

test "recursion over a type, past its guard or down from a constant is bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{ .path = "src/bounded.zig", .source =
        \\pub fn cast(comptime DestType: type, target: anytype) DestType {
        \\    switch (@typeInfo(DestType)) {
        \\        .bool => return cast(usize, target) != 0,
        \\        else => return @intCast(target),
        \\    }
        \\}
        \\pub fn hash(hasher: anytype, key: anytype) void {
        \\    switch (@typeInfo(@TypeOf(key))) {
        \\        .optional => if (key) |k| hash(hasher, k),
        \\        .@"struct" => |info| inline for (info.fields) |field| hash(hasher, @field(key, field.name)),
        \\        .pointer => hasher.update(@intFromPtr(key)),
        \\        else => hash(hasher, @as(u64, key)),
        \\    }
        \\}
        \\pub fn eql(a: anytype, b: @TypeOf(a)) bool {
        \\    switch (@typeInfo(@TypeOf(a))) {
        \\        .pointer => return eql(a.*, b.*),
        \\        else => return a == b,
        \\    }
        \\}
        \\pub fn shift(r: []u64, a: []const u64, bits: usize) usize {
        \\    if (bits >= 64) {
        \\        return shift(r[bits / 64 ..], a, bits % 64);
        \\    }
        \\    return a.len;
        \\}
        \\const max_depth = 8;
        \\pub fn analyze(units: []const u32, target: u32) ?u32 {
        \\    return visit(units, visit(units, target, 8) orelse 0, max_depth);
        \\}
        \\fn visit(units: []const u32, target: u32, remaining: usize) ?u32 {
        \\    if (remaining == 0) return null;
        \\    return if (target < units.len) visit(units, units[target], remaining - 1) else target;
        \\}
        \\pub fn exposed(units: []const u32, target: u32, remaining: usize) ?u32 {
        \\    if (remaining == 0) return null;
        \\    return if (target < units.len) exposed(units, units[target], remaining - 1) else target;
        \\}
        \\fn counted(units: []const u32, remaining: usize) usize {
        \\    if (remaining == 0) return 0;
        \\    return counted(units, remaining - 1);
        \\}
        \\pub fn count(units: []const u32) usize {
        \\    return counted(units, units.len);
        \\}
    }};
    const found = try project.findings(arena.allocator(), &files, support.only(&.{.recursive_call}, .information));
    const source = files[0].source;
    const expected = [_][]const u8{ "eql", "exposed", "counted" };
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |name, finding| try std.testing.expectEqualStrings(name, source[finding.finding.span.start..finding.finding.span.end]);
    try std.testing.expect(std.mem.find(u8, found[1].finding.message, "counting 'remaining' down to its check") != null);
}
