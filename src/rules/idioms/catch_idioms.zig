//! `catch` expressions that discard, lose or assert away the error.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const callExpressionStart = @import("../../syntax/tokens.zig").callExpressionStart;
const statementStart = @import("../../syntax/tokens.zig").statementStart;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .discarded_error,
    .unsafe_catch_unreachable,
    .lost_error_context,
};

pub fn run(context: RuleRun) !void {
    try findDiscardedErrors(context);
    try findCatchDiagnostics(context);
}

fn findDiscardedErrors(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.discarded_error);
    if (level == .off) return;
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_catch) continue;
        const opening = catchBodyStart(tokens, index) orelse continue;
        if (opening + 1 >= tokens.len or tokens[opening].tag != .l_brace or tokens[opening + 1].tag != .r_brace) continue;
        const body = source[tokens[opening].loc.end..tokens[opening + 1].loc.start];
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len != 0 or insideErrdefer(context, index)) continue;
        try context.emit(.{
            .rule = .discarded_error,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "empty catch body discards the error without handling it"),
        });
    }
}

/// Whether the statement holding `index` is an `errdefer`: the function is
/// already returning an error, and a cleanup error cannot be returned too.
fn insideErrdefer(context: RuleRun, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_errdefer => return true,
            .keyword_defer, .semicolon => return false,
            .r_paren, .r_bracket, .r_brace => cursor = context.scopes.matchingToken(cursor) orelse return false,
            .l_brace => return cursor > 0 and context.tokens[cursor - 1].tag == .keyword_errdefer,
            else => {},
        }
    }
    return false;
}

fn findCatchDiagnostics(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const unreachable_level = context.level(.unsafe_catch_unreachable);
    const context_level = context.level(.lost_error_context);
    if (unreachable_level == .off and context_level == .off) return;
    var functions: FunctionsByName = .{};
    defer functions.deinit(context.allocator);

    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch) continue;
        const body_start = catchBodyStart(tokens, catch_index) orelse continue;
        if (unreachable_level != .off and tokens[body_start].tag == .keyword_unreachable and
            try catchExpressionIsKnownFallible(context, &functions, catch_index))
        {
            const fixes: []const Fix = fixes: {
                // A deferred expression cannot propagate an error with `try`.
                if (!enclosingFunctionReturnsErrorUnion(context, catch_index) or insideDefer(context, catch_index)) break :fixes &.{};
                const call_open = context.scopes.matchingToken(catch_index - 1) orelse break :fixes &.{};
                const expression_start = callExpressionStart(tokens, call_open) orelse break :fixes &.{};
                const expression = std.mem.trim(u8, source[tokens[expression_start].loc.start..token.loc.start], " \t\r\n");
                const allocated = try Fix.single(context.allocator, .{
                    .title = "Propagate the error with try",
                    .span = .{ .start = tokens[expression_start].loc.start, .end = tokens[body_start].loc.end },
                    .replacement = try context.allocator.print("try {s}", .{expression}),
                });
                break :fixes allocated;
            };
            try context.emit(.{
                .rule = .unsafe_catch_unreachable,
                .level = unreachable_level,
                .span = tokens[body_start].loc,
                .message = try context.allocator.dupe(u8, "catch unreachable asserts that a proven fallible operation cannot fail"),
                .fixes = fixes,
            });
        }
        if (context_level == .off) continue;
        const remapped_error = remappedErrorToken(context, body_start) orelse continue;
        // A body that stores or logs the captured error keeps its identity.
        if (catchCaptureIsUsed(context, catch_index, body_start)) continue;
        // An operation that can fail in one way loses nothing when that
        // failure keeps its name or an overflow becomes a domain limit.
        if (try operandFailsOnlyAs(context, &functions, catch_index, tokenText(source, remapped_error))) continue;
        try context.emit(.{
            .rule = .lost_error_context,
            .level = context_level,
            .span = token.loc,
            .message = try context.allocator.print(
                "catch maps every failure to '{s}' and loses the original error identity",
                .{tokenText(source, remapped_error)},
            ),
        });
    }
}

fn catchCaptureIsUsed(context: RuleRun, catch_index: usize, body_start: usize) bool {
    const source = context.source;
    const tokens = context.tokens;
    if (catch_index + 2 >= tokens.len or tokens[catch_index + 1].tag != .pipe or
        tokens[catch_index + 2].tag != .identifier) return false;
    const capture_name = tokenText(source, tokens[catch_index + 2]);
    if (std.mem.eql(u8, capture_name, "_")) return false;
    var limit = @min(tokens.len, body_start + 16);
    if (tokens[body_start].tag == .l_brace) {
        limit = context.matchingToken(body_start, .l_brace, .r_brace) orelse return false;
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

/// Whether the innermost enclosing block that a `fn` signature opens returns
/// an error union.
fn enclosingFunctionReturnsErrorUnion(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        var signature_cursor = opening;
        while (signature_cursor > 0) {
            signature_cursor -= 1;
            switch (tokens[signature_cursor].tag) {
                .keyword_fn => {
                    var parameters_open = signature_cursor + 1;
                    while (parameters_open < opening and tokens[parameters_open].tag != .l_paren) : (parameters_open += 1) {}
                    if (parameters_open >= opening) return false;
                    const parameters_end = context.matchingToken(parameters_open, .l_paren, .r_paren) orelse return false;
                    for (tokens[parameters_end + 1 .. opening]) |return_token| {
                        if (return_token.tag == .bang) return true;
                    }
                    return false;
                },
                .semicolon, .l_brace, .r_brace => break,
                else => {},
            }
        }
    }
    return false;
}

/// The `fn` tokens of the file by declared name, in source order; built on
/// first use so files without `catch unreachable` never pay for it.
const FunctionsByName = struct {
    built: bool = false,
    names: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,

    fn deinit(functions: *FunctionsByName, allocator: std.mem.Allocator) void {
        var lists = functions.names.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        functions.names.deinit(allocator);
    }

    fn named(functions: *FunctionsByName, context: RuleRun, name: []const u8) ![]const usize {
        if (!functions.built) {
            functions.built = true;
            const tokens = context.tokens;
            for (tokens, 0..) |token, index| {
                if (token.tag != .keyword_fn or index + 2 >= tokens.len or tokens[index + 2].tag != .l_paren) continue;
                const entry = try functions.names.getOrPut(context.allocator, tokenText(context.source, tokens[index + 1]));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(context.allocator, index);
            }
        }
        const found = functions.names.get(name) orelse return &.{};
        return found.items;
    }
};

fn catchExpressionIsKnownFallible(context: RuleRun, functions: *FunctionsByName, catch_index: usize) !bool {
    const source = context.source;
    const tokens = context.tokens;
    if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return false;
    const opening = context.scopes.matchingToken(catch_index - 1) orelse return false;
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return false;
    const callee_name = tokenText(source, tokens[opening - 1]);
    const known_fallible = [_][]const u8{
        "alloc",    "allocSentinel", "alignedAlloc", "dupe",            "dupeZ", "realloc", "create",
        "openFile", "createFile",    "openDir",      "openIterableDir", "read",  "write",   "parse",
    };
    for (known_fallible) |name| if (std.mem.eql(u8, callee_name, name)) return true;

    for (try functions.named(context, callee_name)) |index| {
        const parameters_end = context.matchingToken(index + 2, .l_paren, .r_paren) orelse continue;
        var return_index = parameters_end + 1;
        const return_limit = @min(tokens.len, parameters_end + 32);
        while (return_index < return_limit and tokens[return_index].tag != .semicolon and
            tokens[return_index].tag != .keyword_return) : (return_index += 1)
        {
            if (tokenIs(source, tokens[return_index], "!")) return true;
            if (tokens[return_index].tag != .l_brace) continue;
            if (return_index > parameters_end + 1 and tokenIs(source, tokens[return_index - 1], "error")) {
                return_index = context.matchingToken(return_index, .l_brace, .r_brace) orelse return false;
                continue;
            }
            return false;
        }
    }
    return false;
}

/// Whether the `catch` at `catch_index` belongs to a `defer` or `errdefer`
/// statement or block.
fn insideDefer(context: RuleRun, catch_index: usize) bool {
    const tokens = context.tokens;
    const start = statementStart(tokens, catch_index);
    if (tokens[start].tag == .keyword_defer or tokens[start].tag == .keyword_errdefer) return true;
    const function_body = context.scopes.enclosingFunctionBody(catch_index) orelse return false;
    var brace = context.enclosingOpeningBrace(catch_index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= function_body) return false;
        var before = opening;
        // 'errdefer |err| {'
        if (before >= 3 and tokens[before - 1].tag == .pipe and tokens[before - 3].tag == .pipe) before -= 3;
        if (before >= 1 and (tokens[before - 1].tag == .keyword_defer or tokens[before - 1].tag == .keyword_errdefer)) return true;
    }
    return false;
}

/// Whether the operand of the `catch` at `catch_index` can fail only with
/// `remapped`, or only with `error.Overflow` from checked arithmetic. The
/// operand's error set is known for `std.math` arithmetic, allocator
/// methods, and functions this file declares once with a one-error set.
fn operandFailsOnlyAs(context: RuleRun, functions: *FunctionsByName, catch_index: usize, remapped: []const u8) !bool {
    const tokens = context.tokens;
    if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return false;
    const opening = context.scopes.matchingToken(catch_index - 1) orelse return false;
    const start = callExpressionStart(tokens, opening) orelse return false;
    const callee = context.tokenText(opening - 1);
    if (opening >= start + 3 and context.tokenIs(opening - 3, "math")) {
        const checked_arithmetic = [_][]const u8{ "add", "sub", "mul", "negate", "shlExact" };
        for (checked_arithmetic) |name| if (std.mem.eql(u8, callee, name)) return true;
        return false;
    }
    if (std.mem.eql(u8, remapped, "OutOfMemory") and opening >= start + 3) {
        const allocating = [_][]const u8{ "alloc", "alignedAlloc", "allocSentinel", "allocWithOptions", "create", "dupe", "dupeZ", "realloc" };
        for (allocating) |name| if (std.mem.eql(u8, callee, name)) return true;
        const receiver = context.tokenText(opening - 3);
        if (std.mem.eql(u8, callee, "print") and std.mem.find(u8, receiver, "allocator") != null) return true;
    }
    // A call through `self` or no receiver names a declaration of this file.
    if (opening != start + 1 and (opening != start + 3 or !context.tokenIs(start, "self"))) return false;
    const declarations = try functions.named(context, callee);
    if (declarations.len != 1) return false;
    const only_error = declaredSingleError(context, declarations[0]) orelse return false;
    return std.mem.eql(u8, only_error, remapped);
}

/// The one error a function's declared return error set holds:
/// `Allocator.Error`, `error{Name}`, or a file-level alias of either.
fn declaredSingleError(context: RuleRun, fn_index: usize) ?[]const u8 {
    const tokens = context.tokens;
    const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse return null;
    var bang = parameters_end + 1;
    while (bang < tokens.len and bang < parameters_end + 16 and tokens[bang].tag != .bang) : (bang += 1) {
        switch (tokens[bang].tag) {
            .keyword_error => if (bang + 1 < tokens.len and tokens[bang + 1].tag == .l_brace) {
                bang = context.matchingToken(bang + 1, .l_brace, .r_brace) orelse return null;
            },
            .l_brace, .semicolon => return null,
            else => {},
        }
    }
    if (bang >= tokens.len or tokens[bang].tag != .bang) return null;
    return singleErrorOf(context, parameters_end + 1, bang, 0);
}

fn singleErrorOf(context: RuleRun, start: usize, end: usize, depth: u8) ?[]const u8 {
    const tokens = context.tokens;
    if (end == start + 4 and tokens[start].tag == .keyword_error and tokens[start + 1].tag == .l_brace and
        tokens[start + 2].tag == .identifier and tokens[start + 3].tag == .r_brace) return context.tokenText(start + 2);
    if (end >= start + 3 and context.tokenIs(end - 1, "Error") and tokens[end - 2].tag == .period and
        context.tokenIs(end - 3, "Allocator")) return "OutOfMemory";
    if (end != start + 1 or tokens[start].tag != .identifier or depth > 2) return null;
    const binding = context.scopes.findBinding(start) orelse return null;
    const name = binding.token_index;
    if (name + 2 >= tokens.len or tokens[name - 1].tag != .keyword_const or tokens[name + 1].tag != .equal) return null;
    const value_end = context.statementEnd(name + 2) orelse return null;
    return singleErrorOf(context, name + 2, value_end, depth + 1);
}

fn remappedErrorToken(context: RuleRun, body_start: usize) ?std.zig.Token {
    const source = context.source;
    const tokens = context.tokens;
    var index = body_start;
    var limit = @min(tokens.len, body_start + 16);
    const braced = tokens[body_start].tag == .l_brace;
    if (braced) {
        const closing = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
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

test "discarded error ignores an explanatory catch comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run() void { failing() catch { // Best effort cleanup.\n" ++
        "}; }\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .discarded_error);
}

test "discarded error accepts errdefer cleanup but not deferred cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(store: *Store, output: *Writer) !void {\n" ++
        "    const first = try store.begin(.{});\n" ++
        "    errdefer store.end(first, .{}) catch {};\n" ++
        "    errdefer {\n" ++
        "        store.sync() catch {};\n" ++
        "    }\n" ++
        "    defer output.flush() catch {};\n" ++
        "    try store.commit(first);\n" ++
        "}\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "catch {};\n    try").?, found[0].span.start);
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
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var context_loss_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .lost_error_context) context_loss_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), context_loss_count);
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
    const configuration = support.only(&.{ .unsafe_catch_unreachable, .lost_error_context }, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
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

test "discarded error is reported even with an unused capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load() !u32 { return 1; }\n" ++
        "fn run() void {\n" ++
        "    load() catch |err| {};\n" ++
        "    load() catch |err| { log(err); };\n" ++
        "}\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
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
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var context_count: usize = 0;
    for (found) |finding| if (finding.rule == .lost_error_context) {
        context_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "LoadFailed") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), context_count);
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
    const configuration = support.only(&.{.unsafe_catch_unreachable}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var unreachable_count: usize = 0;
    for (found) |finding| if (finding.rule == .unsafe_catch_unreachable) {
        unreachable_count += 1;
        if (finding.span.start < std.mem.find(u8, source, "fn swallow").?) {
            try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
            try std.testing.expectEqualStrings("try fail()", finding.fixes[0].edits[0].replacement);
        } else {
            try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), unreachable_count);
}

test "lost error context ignores single-error operands that keep or translate their failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Error = error{InvalidArtifact};\n" ++
        "fn grow(allocator: std.mem.Allocator, a: usize, b: usize) ![]u8 {\n" ++
        "    const total = std.math.add(usize, a, b) catch return error.ModuleTooLarge;\n" ++
        "    const message = allocator.print(\"{d}\", .{total}) catch return error.OutOfMemory;\n" ++
        "    _ = message;\n" ++
        "    check() catch return error.InvalidArtifact;\n" ++
        "    report() catch return error.OutOfMemory;\n" ++
        "    report() catch return error.InvalidArtifact;\n" ++
        "    return allocator.alloc(u8, total) catch return error.InvalidArtifact;\n" ++
        "}\n" ++
        "fn check() Error!void {}\n" ++
        "fn report() std.mem.Allocator.Error!void {}\n";
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList(usize) = .empty;
    for (found) |finding| if (finding.rule == .lost_error_context) {
        try reported.append(arena.allocator(), std.mem.countScalar(u8, source[0..finding.span.start], '\n') + 1);
    };
    // OutOfMemory renamed InvalidArtifact hides the allocation failure.
    try std.testing.expectEqualSlices(usize, &.{ 9, 10 }, reported.items);
}

test "catch unreachable in a defer offers no try" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn release() !void { return error.Failed; }\n" ++
        "fn run(owned: bool) !void {\n" ++
        "    defer if (owned) release() catch unreachable;\n" ++
        "    errdefer {\n" ++
        "        release() catch unreachable;\n" ++
        "    }\n" ++
        "    try release();\n" ++
        "}\n";
    const configuration = support.only(&.{.unsafe_catch_unreachable}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}
