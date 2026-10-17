//! `catch` expressions that discard, lose or assert away the error.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const callExpressionStart = @import("../../syntax/tokens.zig").callExpressionStart;
const syntax_scope = @import("../../syntax/scope.zig");
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
        if (std.mem.trim(u8, body, &std.ascii.whitespace).len != 0) continue;
        // A deferred cleanup or a failure path has no caller left to tell.
        if (insideDefer(context, index) or onErrorPath(context, index) or bestEffortCall(context, index)) continue;
        if (context.explainedByComment(context.statementStart(index), opening + 1)) continue;
        try context.emit(.{
            .rule = .discarded_error,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.dupe(u8, "empty catch body discards the error without handling it"),
        });
    }
}

/// Whether the `catch` at `catch_index` runs while its function is already
/// failing: in the body of an enclosing `catch` or `else |err|`, or in a block
/// that ends by returning an error.
fn onErrorPath(context: RuleRun, catch_index: usize) bool {
    const tokens = context.tokens;
    const function_body = context.functionBodyHolding(catch_index) orelse return false;
    const block_end = context.enclosingScopeEnd(catch_index) orelse return false;
    if (block_end >= 5 and tokens[block_end - 1].tag == .semicolon and tokens[block_end - 2].tag == .identifier and
        tokens[block_end - 3].tag == .period and tokens[block_end - 4].tag == .keyword_error and
        tokens[block_end - 5].tag == .keyword_return) return true;
    var brace = context.enclosingOpeningBrace(catch_index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= function_body) return false;
        // 'catch {', 'catch |err| {' and 'else |err| {'
        const captured = opening >= 3 and tokens[opening - 1].tag == .pipe and tokens[opening - 3].tag == .pipe;
        const before = if (captured) opening - 3 else opening;
        if (before == 0) continue;
        if (tokens[before - 1].tag == .keyword_catch or captured and tokens[before - 1].tag == .keyword_else) return true;
    }
    return false;
}

/// Whether the operand of the `catch` at `catch_index` is a call whose
/// failure has nowhere useful to go: terminal styling, flushing, naming a
/// thread, cleanup that closes, deletes or cancels, a write to stderr, or the
/// std helpers that log an unexpected status and return it as an error.
fn bestEffortCall(context: RuleRun, catch_index: usize) bool {
    const tokens = context.tokens;
    if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return false;
    const opening = context.scopes.matchingToken(catch_index - 1) orelse return false;
    if (opening == 0 or tokens[opening - 1].tag != .identifier) return false;
    const name = context.tokenText(opening - 1);
    const best_effort = [_][]const u8{
        "setColor", "setAttribute", "flush", "setName", "unexpectedErrno", "unexpectedStatus", "unexpectedError", "errnoBug",
    };
    for (best_effort) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    const cleanup_verbs = [_][]const u8{ "close", "delete", "remove", "unlink", "kill", "cancel", "destroy" };
    for (cleanup_verbs) |verb| if (namesVerb(name, verb)) return true;
    const start = callExpressionStart(tokens, opening) orelse return false;
    for (tokens[start .. opening - 1], start..) |token, index| {
        if (token.tag == .identifier and std.mem.find(u8, context.tokenText(index), "stderr") != null) return true;
    }
    return false;
}

/// Whether the camelCase `name` starts with `verb` or holds it as a later word.
fn namesVerb(name: []const u8, verb: []const u8) bool {
    if (std.mem.startsWith(u8, name, verb)) return true;
    for (name[1..], 1..) |character, index| {
        if (character == std.ascii.toUpper(verb[0]) and std.mem.startsWith(u8, name[index + 1 ..], verb[1..])) return true;
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
    var test_only: ?syntax_scope.TestOnlyBodies = null;
    defer if (test_only) |*bodies| bodies.deinit(context.allocator);

    for (tokens, 0..) |token, catch_index| {
        if (token.tag != .keyword_catch) continue;
        const body_start = catchBodyStart(tokens, catch_index) orelse continue;
        if (unreachable_level != .off and tokens[body_start].tag == .keyword_unreachable and
            try catchExpressionIsKnownFallible(context, &functions, catch_index) and
            !try unreachableIsEstablished(context, &test_only, catch_index, body_start))
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
        if (remapKeepsTheFailure(context, catch_index, tokenText(source, remapped_error))) continue;
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

/// Whether the `catch unreachable` at `catch_index` states an established
/// invariant rather than an unchecked one: test code may assert its setup, a
/// compile-time failure is a compile error, a call with compile-time-known
/// arguments fails on every run or none, and a comment can give the reason.
fn unreachableIsEstablished(
    context: RuleRun,
    test_only: *?syntax_scope.TestOnlyBodies,
    catch_index: usize,
    unreachable_index: usize,
) !bool {
    const tokens = context.tokens;
    if (context.scopes.insideTestBlock(catch_index)) return true;
    const opening = context.scopes.matchingToken(catch_index - 1) orelse return false;
    const start = callExpressionStart(tokens, opening) orelse opening;
    if (context.comptimeEvaluated(start) or context.comptimeKnownCall(start, opening) or
        context.explainedByComment(context.statementStart(start), unreachable_index)) return true;
    if (test_only.* == null) test_only.* = try syntax_scope.testOnlyBodies(context.allocator, context.source, tokens);
    return test_only.*.?.contains(catch_index);
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

/// Whether the function whose body holds `index`, with no container
/// declaration between them, returns an error union.
fn enclosingFunctionReturnsErrorUnion(context: RuleRun, index: usize) bool {
    const body = context.functionBodyHolding(index) orelse return false;
    const keyword = context.scopes.functionKeyword(body) orelse return false;
    const parameters_end = context.scopes.matchingToken(keyword + 2) orelse return false;
    for (context.tokens[parameters_end + 1 .. body]) |return_token| {
        if (return_token.tag == .bang) return true;
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
/// statement or to a block one of them runs.
fn insideDefer(context: RuleRun, catch_index: usize) bool {
    const tokens = context.tokens;
    const function_body = context.functionBodyHolding(catch_index) orelse return false;
    var cursor = catch_index;
    while (true) {
        const start = context.statementStart(cursor);
        if (tokens[start].tag == .keyword_defer or tokens[start].tag == .keyword_errdefer) return true;
        const opening = context.enclosingOpeningBrace(cursor) orelse return false;
        if (opening <= function_body) return false;
        cursor = opening;
    }
}

/// Whether remapping the failure of the `catch` at `catch_index` to
/// `remapped` loses nothing: the operand can fail in only one way, and that
/// failure keeps its name, an overflow becomes a domain limit, or it becomes
/// the `WriteFailed` a `*std.Io.Writer` implementation must report (which an
/// allocating writer reports for `OutOfMemory`).
fn remapKeepsTheFailure(context: RuleRun, catch_index: usize, remapped: []const u8) bool {
    const only_error = context.operandOnlyError(catch_index) orelse return false;
    if (std.mem.eql(u8, only_error, remapped) or std.mem.eql(u8, only_error, "Overflow") or
        std.mem.eql(u8, remapped, "WriteFailed")) return true;
    return std.mem.eql(u8, only_error, "WriteFailed") and std.mem.eql(u8, remapped, "OutOfMemory");
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

test "discarded error accepts deferred cleanup and failure paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(store: *Store, output: *Writer) !void {\n" ++
        "    const first = try store.begin(.{});\n" ++
        "    errdefer store.end(first, .{}) catch {};\n" ++
        "    errdefer {\n" ++
        "        store.sync() catch {};\n" ++
        "    }\n" ++
        "    defer output.print(\"{d}\", .{first}) catch {};\n" ++
        "    defer {\n" ++
        "        if (first > 1) store.sync() catch {};\n" ++
        "    }\n" ++
        "    store.commit(first) catch |err| {\n" ++
        "        store.sync() catch {};\n" ++
        "        return err;\n" ++
        "    };\n" ++
        "    if (first == 0) {\n" ++
        "        store.sync() catch {};\n" ++
        "        return error.Empty;\n" ++
        "    }\n" ++
        "    store.sync() catch {};\n" ++
        "}\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "catch {};\n}").?, found[0].span.start);
}

test "discarded error accepts best-effort calls and explained catches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(t: *Terminal, dir: Dir, stderr: *Writer, writer: *Writer) void {\n" ++
        "    t.setColor(.dim) catch {};\n" ++
        "    dir.deleteFile(\"tmp\") catch {};\n" ++
        "    stderr.writeAll(\"failed\") catch {};\n" ++
        "    load() catch {}; // Retried on the next tick.\n" ++
        "    // A missing cache is rebuilt later.\n" ++
        "    load() catch {};\n" ++
        "    // TODO: report the failure.\n" ++
        "    load() catch {};\n" ++
        "    writer.writeAll(\"data\") catch {};\n" ++
        "}\n";
    const configuration = support.only(&.{.discarded_error}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "catch {};\n    writer").?, found[0].span.start);
    try std.testing.expectEqual(std.mem.find(u8, source, "catch {};\n}").?, found[1].span.start);
}

test "catch unreachable accepts tests, compile-time evaluation and stated invariants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const version = parse(\"1\") catch unreachable;\n" ++
        "fn run(text: []const u8) u32 {\n" ++
        "    const a = std.SemanticVersion.parse(\"1.2.3\") catch unreachable;\n" ++
        "    const b = comptime parse(\"3\") catch unreachable;\n" ++
        "    const c = parse(text) catch unreachable; // Validated by the caller.\n" ++
        "    return a + b + c + (parse(text) catch unreachable);\n" ++
        "}\n" ++
        "fn helper(text: []const u8) u32 {\n" ++
        "    return parse(text) catch unreachable;\n" ++
        "}\n" ++
        "test \"parse\" {\n" ++
        "    _ = parse(\"x\") catch unreachable;\n" ++
        "    _ = helper(\"4\");\n" ++
        "}\n";
    const configuration = support.only(&.{.unsafe_catch_unreachable}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, "unreachable);").?, found[0].span.start);
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
        "fn named() error{Failed}!void {\n" ++
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
    try std.testing.expectEqual(@as(usize, 3), unreachable_count);
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

test "lost error context ignores writer failures kept as WriteFailed or OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn list(writer: *std.Io.Writer, gpa: std.mem.Allocator, buf: []u8) !void {\n" ++
        "    var aw: std.Io.Writer.Allocating = .init(gpa);\n" ++
        "    const w = &aw.writer;\n" ++
        "    writer.print(\"{d}\", .{1}) catch return error.OutOfMemory;\n" ++
        "    w.writeAll(\", \") catch return error.OutOfMemory;\n" ++
        "    aw.writer.writeByte('x') catch return error.WriteFailed;\n" ++
        "    const rows = gpa.alloc(u8, 4) catch return error.WriteFailed;\n" ++
        "    _ = std.fmt.bufPrint(buf, \"{d}\", .{rows.len}) catch return error.WriteFailed;\n" ++
        "    render(writer) catch return error.OutOfMemory;\n" ++
        "    writer.writeAll(rows) catch return error.InvalidArtifact;\n" ++
        "    store(writer) catch return error.OutOfMemory;\n" ++
        "}\n" ++
        "fn render(writer: *std.Io.Writer) std.Io.Writer.Error!void {\n" ++
        "    try writer.writeAll(\"x\");\n" ++
        "}\n" ++
        "fn store(writer: *std.Io.Writer) !void {\n" ++
        "    try writer.writeAll(\"x\");\n" ++
        "}\n";
    const configuration = support.only(&.{.lost_error_context}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var reported: std.ArrayList(usize) = .empty;
    for (found) |finding| {
        try reported.append(arena.allocator(), std.mem.countScalar(u8, source[0..finding.span.start], '\n') + 1);
    }
    // WriteFailed renamed InvalidArtifact hides the write failure, and store's
    // inferred error set may hold more than one error.
    try std.testing.expectEqualSlices(usize, &.{ 11, 12 }, reported.items);
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
