//! Buffered `std.Io` file and stream writers that are written but never
//! flushed. The interface keeps written bytes in its buffer until `flush` (or
//! the file writer's `end`), so a writer that goes out of scope first loses
//! them.
//!
//! A writer is handled once it is returned, stored, flushed in a `defer`, or
//! passed to a callee that flushes or keeps it, and otherwise needs a flush
//! after every write on every path: one inside a branch, or after an early
//! `return`, leaves the bytes behind on the paths that skip it. Callees in the
//! same file are read directly; project analysis re-runs the rule with
//! summaries to read callees in other files. A callee neither pass can read
//! keeps the writer quiet.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const reach = @import("reach.zig");
const summaries = @import("../summaries.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const Token = std.zig.Token;
const Range = tokens_util.Range;

pub const rules = [_]types.Rule{.unflushed_writer};

pub fn run(context: RuleRun) !void {
    try runInternal(context, null);
}

/// The project re-run: reports only the writers whose verdict needs a callee
/// in another file, which the file-local pass leaves alone.
pub fn runWithSummaries(context: RuleRun, summary_index: summaries.Index) !void {
    try runInternal(context, summary_index);
}

/// Whether `tokens` may create a writer this rule tracks, so that project
/// analysis can skip the re-run for every other file.
pub fn createsWriter(source: []const u8, tokens: []const Token) bool {
    for (tokens[0..tokens.len -| 1], 0..) |token, index| {
        if (token.tag != .identifier) continue;
        if (tokens[index + 1].tag == .l_paren and
            (tokens_util.tokenIs(source, token, "writer") or tokens_util.tokenIs(source, token, "writerStreaming"))) return true;
        if (index >= 2 and tokens_util.tokenIs(source, token, "Writer") and tokens_util.tokenIs(source, tokens[index - 2], "File")) return true;
    }
    return false;
}

fn runInternal(context: RuleRun, summary_index: ?summaries.Index) !void {
    const level = context.level(.unflushed_writer);
    if (level == .off) return;
    var analysis: Analysis = .{ .context = context, .summary_index = summary_index };
    defer analysis.effects.deinit(context.allocator);
    var timeline: Timeline = .{};
    defer timeline.deinit(context.allocator);
    const tokens = context.tokens;
    for (tokens, 0..) |token, method| {
        if (token.tag != .identifier or method < 2 or tokens[method - 1].tag != .period or
            tokens[method + 1].tag != .l_paren) continue;
        const creation = writerCreation(context.tokenText(method)) orelse continue;
        const declaration = bufferedWriterDeclaration(context, method, creation) orelse continue;
        if (!context.scopes.insideFunctionOrTestBody(declaration.name)) continue;
        const scope_end = context.enclosingScopeEnd(declaration.name) orelse continue;
        var names: Names = .{};
        _ = names.add(.{ .text = context.tokenText(declaration.name), .declaration = declaration.name });
        timeline.writes.clearRetainingCapacity();
        timeline.flushes.clearRetainingCapacity();
        var facts: Facts = .{ .timeline = &timeline };
        try analysis.scan(analysis.localFile(), &names, declaration.end, scope_end, 0, &facts);
        if (!facts.wrote or facts.flushed or facts.unknown) continue;
        if (summary_index != null and !facts.crossed_files) continue;
        const name = context.tokenText(declaration.name);
        if (timeline.flushes.items.len == 0) {
            try context.emit(.{
                .rule = .unflushed_writer,
                .level = level,
                .span = tokens[declaration.name].loc,
                .message = try context.allocator.print(
                    "buffered writer '{s}' is written but never flushed; the bytes left in its buffer are lost when it goes out of scope",
                    .{name},
                ),
            });
        } else if (timeline.uncoveredReturn(context, declaration.name, scope_end)) |exit| {
            try context.emit(.{
                .rule = .unflushed_writer,
                .level = level,
                .span = tokens[exit].loc,
                .message = try context.allocator.print(
                    "this 'return' leaves bytes written to buffered writer '{s}' unflushed; flush before returning or in a defer",
                    .{name},
                ),
            });
        } else if (timeline.uncoveredWrite(context)) |write| {
            const related = try context.allocator.alloc(types.RelatedSpan, 1);
            related[0] = .{ .span = tokens[write].loc, .message = "a path from this write reaches the end of the scope without a flush" };
            try context.emit(.{
                .rule = .unflushed_writer,
                .level = level,
                .span = tokens[declaration.name].loc,
                .related = related,
                .message = try context.allocator.print(
                    "buffered writer '{s}' is flushed only on some paths; the bytes left in its buffer are lost on the others",
                    .{name},
                ),
            });
        }
    }
}

/// Where the analyzed function writes to the writer and flushes it outside a
/// `defer`, in token order, for the path checks.
const Timeline = struct {
    writes: std.ArrayList(u32) = .empty,
    flushes: std.ArrayList(u32) = .empty,

    fn deinit(timeline: *Timeline, allocator: std.mem.Allocator) void {
        timeline.writes.deinit(allocator);
        timeline.flushes.deinit(allocator);
    }

    /// The first non-error `return` of the writer's function that a write
    /// reaches with no flush between them on every path.
    fn uncoveredReturn(timeline: *const Timeline, context: RuleRun, name: usize, scope_end: usize) ?usize {
        const tokens = context.tokens;
        const writes = timeline.writes.items;
        const function_body = context.scopes.enclosingFunctionBody(name) orelse return null;
        for (writes[0] + 1..scope_end) |exit| {
            if (tokens[exit].tag != .keyword_return or context.scopes.enclosingFunctionBody(exit) != function_body or
                errorExit(context, exit, function_body)) continue;
            // The last write that can run before this return.
            var position = std.sort.lowerBound(u32, writes, exit, orderPosition);
            const write = while (position > 0) {
                position -= 1;
                if (reach.mutationReaches(context, writes[position], exit)) break writes[position];
            } else continue;
            // `return stdout.flush();` flushes on its way out.
            const exit_end = context.statementEnd(exit) orelse continue;
            if (!timeline.flushedOnEveryPath(context, write, exit_end, exit)) return exit;
        }
        return null;
    }

    /// The first write some path from which leaves the scope with no flush.
    fn uncoveredWrite(timeline: *const Timeline, context: RuleRun) ?usize {
        for (timeline.writes.items) |write| {
            if (!timeline.flushedOnEveryPath(context, write, context.tokens.len, write)) return write;
        }
        return null;
    }

    /// Whether a flush in `(after, before)` runs on every path through the
    /// innermost block that holds both it and `point`.
    fn flushedOnEveryPath(timeline: *const Timeline, context: RuleRun, after: usize, before: usize, point: usize) bool {
        var tried: Tried = .{};
        var position = std.sort.upperBound(u32, timeline.flushes.items, after, orderPosition);
        while (position < timeline.flushes.items.len) : (position += 1) {
            const flush = timeline.flushes.items[position];
            if (flush >= before) break;
            const block = reach.commonBlock(context.scopes, flush, point) orelse continue;
            if (timeline.flushCovers(context, after, before, flush, block, &tried)) return true;
        }
        return false;
    }

    /// The branching statement `flushCovers` judged last, so the other
    /// flushes in it do not judge it again.
    const Tried = struct {
        keyword: usize = std.math.maxInt(usize),
        block: usize = std.math.maxInt(usize),
    };

    /// Whether the flush at `flush` runs on every path through the block
    /// opened at `block`, or the `if`/`else` chain or `switch` holding it does
    /// and flushes in every branch.
    fn flushCovers(timeline: *const Timeline, context: RuleRun, after: usize, before: usize, flush: usize, block: usize, tried: *Tried) bool {
        if (reach.runsWithin(context.tokens, context.scopes, flush, block)) return true;
        const keyword = branchingStatement(context, flush, block) orelse return false;
        if (tried.keyword == keyword and tried.block == block) return false;
        tried.* = .{ .keyword = keyword, .block = block };
        return timeline.everyBranchFlushes(context, after, before, keyword);
    }

    /// Whether a flush in `(after, before)` runs on every path through the
    /// block opened at `block`.
    fn blockFlushes(timeline: *const Timeline, context: RuleRun, after: usize, before: usize, block: usize) bool {
        const closing = context.scopes.matchingToken(block) orelse return false;
        var tried: Tried = .{};
        var position = std.sort.upperBound(u32, timeline.flushes.items, @max(after, block), orderPosition);
        while (position < timeline.flushes.items.len) : (position += 1) {
            const flush = timeline.flushes.items[position];
            if (flush >= @min(before, closing)) break;
            if (timeline.flushCovers(context, after, before, flush, block, &tried)) return true;
        }
        return false;
    }

    /// Whether every branch of the `if` chain, which must end in a plain
    /// `else`, or of the `switch` at `keyword` flushes on every path.
    fn everyBranchFlushes(timeline: *const Timeline, context: RuleRun, after: usize, before: usize, keyword: usize) bool {
        const tokens = context.tokens;
        if (tokens[keyword + 1].tag != .l_paren) return false;
        const condition_end = context.scopes.matchingToken(keyword + 1) orelse return false;
        if (tokens[keyword].tag == .keyword_switch) {
            const body = condition_end + 1;
            if (tokens[body].tag != .l_brace) return false;
            const body_end = context.scopes.matchingToken(body) orelse return false;
            var prong = body + 1;
            while (prong < body_end) {
                var arrow = prong;
                while (arrow < body_end and tokens[arrow].tag != .equal_angle_bracket_right) : (arrow += 1) {
                    if (context.scopes.matchingToken(arrow)) |closing| if (closing > arrow) {
                        arrow = closing;
                    };
                }
                if (arrow == body_end) return false;
                const start = skipCapture(tokens, arrow + 1);
                const end = branchEnd(context, start) orelse return false;
                if (!timeline.branchFlushes(context, after, before, start, end)) return false;
                prong = if (tokens[end].tag == .comma) end + 1 else end;
            }
            return true;
        }
        var condition_close = condition_end;
        while (true) {
            const start = skipCapture(tokens, condition_close + 1);
            const end = branchEnd(context, start) orelse return false;
            if (!timeline.branchFlushes(context, after, before, start, end)) return false;
            if (tokens[end].tag != .keyword_else) return false;
            const next = skipCapture(tokens, end + 1);
            if (tokens[next].tag != .keyword_if) {
                const last_end = branchEnd(context, next) orelse return false;
                return timeline.branchFlushes(context, after, before, next, last_end);
            }
            if (tokens[next + 1].tag != .l_paren) return false;
            condition_close = context.scopes.matchingToken(next + 1) orelse return false;
        }
    }

    /// Whether the branch `[start, end)` flushes on every path: a block
    /// that does, an expression whose flush nothing before it guards, or
    /// one that never finishes (`else => unreachable`).
    fn branchFlushes(timeline: *const Timeline, context: RuleRun, after: usize, before: usize, start: usize, end: usize) bool {
        const tokens = context.tokens;
        if (tokens[start].tag == .l_brace) return timeline.blockFlushes(context, after, before, start);
        if (tokens[start].tag == .keyword_unreachable or tokens[start].tag == .builtin and
            (context.tokenIs(start, "@panic") or context.tokenIs(start, "@trap"))) return true;
        var position = std.sort.upperBound(u32, timeline.flushes.items, @max(after, start -| 1), orderPosition);
        while (position < timeline.flushes.items.len) : (position += 1) {
            const flush = timeline.flushes.items[position];
            if (flush >= @min(before, end)) break;
            if (reach.unguarded(tokens, start, flush)) return true;
        }
        return false;
    }

    fn orderPosition(target: usize, position: u32) std.math.Order {
        return std.math.order(target, position);
    }
};

/// The `if` or `switch` keyword of the outermost `if`/`else` chain or
/// `switch` holding `flush` in the block opened at `block`, when that
/// statement runs whenever the block does.
fn branchingStatement(context: RuleRun, flush: usize, block: usize) ?usize {
    const tokens = context.tokens;
    var outermost: ?usize = null;
    var cursor = flush;
    while (true) {
        const head = statementHead(tokens, cursor);
        if (tokens[head].tag == .keyword_if or tokens[head].tag == .keyword_else) outermost = chainHead(context, head) orelse return null;
        const enclosing = context.scopes.enclosingOpeningBrace(cursor) orelse return null;
        if (enclosing == block) break;
        if (enclosing < block) return null;
        // A prong of `switch (x) {`.
        if (tokens[enclosing - 1].tag == .r_paren) if (context.scopes.matchingToken(enclosing - 1)) |condition| {
            if (condition > 0 and tokens[condition - 1].tag == .keyword_switch) outermost = condition - 1;
        };
        cursor = enclosing;
    }
    const keyword = outermost orelse return null;
    return if (reach.runsWithin(tokens, context.scopes, keyword, block)) keyword else null;
}

/// The first token of the statement holding `index`, past a label.
fn statementHead(tokens: []const Token, index: usize) usize {
    const start = tokens_util.statementStart(tokens, index);
    return if (start + 1 < index and tokens[start].tag == .identifier and tokens[start + 1].tag == .colon) start + 2 else start;
}

/// The `if` opening the chain whose `else` branch starts at `head`, or
/// `head` itself when it is an `if`; null for a loop's `else`.
fn chainHead(context: RuleRun, head: usize) ?usize {
    var cursor = head;
    while (context.tokens[cursor].tag == .keyword_else) {
        if (cursor == 0 or context.tokens[cursor - 1].tag != .r_brace) return null;
        const opening = context.scopes.matchingToken(cursor - 1) orelse return null;
        cursor = statementHead(context.tokens, opening);
    }
    return if (context.tokens[cursor].tag == .keyword_if) cursor else null;
}

/// The token after a `|capture|` at `index`, or `index`.
fn skipCapture(tokens: []const Token, index: usize) usize {
    if (tokens[index].tag != .pipe) return index;
    var cursor = index + 1;
    while (cursor < tokens.len and tokens[cursor].tag != .pipe) : (cursor += 1) {}
    return @min(cursor + 1, tokens.len - 1);
}

/// Just past the branch starting at `start`: its block, or its expression up
/// to the `else`, `,` or `;` after it. Null for an expression that branches
/// again, whose `else` this would misread.
fn branchEnd(context: RuleRun, start: usize) ?usize {
    const tokens = context.tokens;
    if (tokens[start].tag == .l_brace) return (context.scopes.matchingToken(start) orelse return null) + 1;
    var cursor = start;
    while (cursor < tokens.len) : (cursor += 1) switch (tokens[cursor].tag) {
        .keyword_else, .comma, .semicolon, .r_paren, .r_bracket, .r_brace, .eof => return cursor,
        .l_paren, .l_bracket, .l_brace => cursor = context.scopes.matchingToken(cursor) orelse return null,
        .keyword_if, .keyword_switch, .keyword_while, .keyword_for => return null,
        else => {},
    };
    return null;
}

/// Whether the `return` at `exit` leaves with an error: `return error.X`, or
/// a return inside a `catch` or `else |err|` handler.
fn errorExit(context: RuleRun, exit: usize, function_body: usize) bool {
    const tokens = context.tokens;
    if (tokens[exit + 1].tag == .keyword_error) return true;
    var cursor = exit;
    while (true) {
        const start = tokens_util.statementStart(tokens, cursor);
        for (tokens[start..cursor], start..) |token, index| switch (token.tag) {
            .keyword_catch => return true,
            .keyword_else => if (tokens[index + 1].tag == .pipe) return true,
            else => {},
        };
        const opening = context.enclosingOpeningBrace(cursor) orelse return false;
        if (opening <= function_body) return false;
        cursor = opening;
    }
}

const Creation = enum {
    /// `file.writer(io, &buffer)` and `writerStreaming`.
    method,
    /// `File.Writer.init(file, io, &buffer)`, `initStreaming` and `initDetect`.
    initializer,
};

fn writerCreation(name: []const u8) ?Creation {
    if (std.mem.eql(u8, name, "writer") or std.mem.eql(u8, name, "writerStreaming")) return .method;
    if (std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "initStreaming") or std.mem.eql(u8, name, "initDetect")) return .initializer;
    return null;
}

const Declaration = struct {
    /// The declared name.
    name: usize,
    /// The token after the declaration's `;`.
    end: usize,
};

/// The `const`/`var` declaration whose whole initializer is the writer call
/// at `method`, when the call takes an `Io` and a non-empty buffer.
fn bufferedWriterDeclaration(context: RuleRun, method: usize, creation: Creation) ?Declaration {
    const tokens = context.tokens;
    const opening = method + 1;
    const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse return null;
    if (tokens[closing + 1].tag != .semicolon) return null;
    const head = tokens_util.statementStart(tokens, method);
    if ((tokens[head].tag != .keyword_const and tokens[head].tag != .keyword_var) or tokens[head + 1].tag != .identifier) return null;
    const equal = tokens_util.findTag(tokens, head + 2, method, .equal) orelse return null;
    var value = equal + 1;
    if (tokens[value].tag == .keyword_try) value += 1;
    var arguments: [3]Range = undefined;
    const count = argumentRanges(tokens, opening, closing, &arguments) orelse return null;
    switch (creation) {
        .method => if (count != 2) return null,
        .initializer => {
            if (count != 3) return null;
            // `.init(..)` under a `File.Writer` annotation, or `File.Writer.init(..)` spelled out.
            const named = if (method == value + 1)
                equal >= head + 5 and context.tokenIs(equal - 1, "Writer") and tokens[equal - 2].tag == .period and
                    context.tokenIs(equal - 3, "File")
            else
                method >= 4 and context.tokenIs(method - 2, "Writer") and tokens[method - 3].tag == .period and
                    context.tokenIs(method - 4, "File");
            if (!named) return null;
        },
    }
    if (!argumentNamesIo(context, arguments[count - 2]) or emptyBuffer(tokens, arguments[count - 1])) return null;
    return .{ .name = head + 1, .end = closing + 2 };
}

/// Up to `out.len` top-level arguments between the parentheses at `opening`
/// and `closing`; null for more arguments or an empty one.
fn argumentRanges(tokens: []const Token, opening: usize, closing: usize, out: []Range) ?usize {
    const end = tokens_util.argumentsEnd(tokens, opening, closing) orelse return 0;
    var count: usize = 0;
    var start = opening + 1;
    while (true) {
        const comma = tokens_util.topLevelComma(tokens, start, end) orelse end;
        if (count == out.len or comma == start) return null;
        out[count] = .{ .start = start, .end = comma };
        count += 1;
        if (comma == end) return count;
        start = comma + 1;
    }
}

fn argumentNamesIo(context: RuleRun, range: Range) bool {
    for (range.start..range.end) |index| if (context.namesIo(index)) return true;
    return false;
}

/// `&.{}`: a writer with no buffer sends every write straight to its sink.
fn emptyBuffer(tokens: []const Token, range: Range) bool {
    const empty = [_]Token.Tag{ .ampersand, .period, .l_brace, .r_brace };
    if (range.end - range.start != empty.len) return false;
    for (tokens[range.start..range.end], empty) |token, tag| if (token.tag != tag) return false;
    return true;
}

/// A source the scan reads: the analyzed file, whose names resolve through
/// its scope index, or the file of a callee from the summaries.
const File = struct {
    source: []const u8,
    tokens: []const Token,
    local: bool,

    fn text(file: File, index: usize) []const u8 {
        return tokens_util.tokenText(file.source, file.tokens[index]);
    }

    fn is(file: File, index: usize, expected: []const u8) bool {
        return std.mem.eql(u8, file.text(index), expected);
    }
};

/// A name the writer is reachable through. Names with a declaration must
/// resolve to it; a callee's parameter is matched by spelling.
const Name = struct { text: []const u8, declaration: ?usize = null };

const Names = struct {
    items: [8]Name = undefined,
    len: usize = 0,

    fn add(names: *Names, name: Name) bool {
        if (names.len == names.items.len) return false;
        names.items[names.len] = name;
        names.len += 1;
        return true;
    }
};

/// What a scan learned about the writer.
const Facts = struct {
    wrote: bool = false,
    /// Flushed in a `defer`, kept, or flushed by a callee: quiet on every path.
    flushed: bool = false,
    /// Handed to a callee the scan could not read.
    unknown: bool = false,
    /// A callee in another file took part in the verdict.
    crossed_files: bool = false,
    /// Where the writer's own function writes and flushes; null in callees.
    timeline: ?*Timeline = null,

    fn effect(facts: Facts) Effect {
        if (facts.flushed) return .flush;
        if (facts.unknown) return .unknown;
        return if (facts.wrote) .write else .none;
    }
};

/// What a callee does with the writer it receives; `flush` includes keeping it.
const Effect = enum { none, write, flush, unknown };

const Remembered = struct { effect: Effect, crossed_files: bool };

const CalleeKey = struct { source: usize, body: usize, parameter: usize };

/// Callees deeper than this read as unknown.
const max_depth = 4;

const Receiver = union(enum) { none, path: Range, other };

const Argument = struct {
    /// The callee's name token.
    name: usize,
    receiver: Receiver,
    position: usize,
    count: usize,
};

const Use = union(enum) {
    ignored,
    write,
    flush,
    /// Returned, stored, or handed somewhere the scan does not follow.
    escape,
    /// `const stdout = &stdout_writer.interface;`: the declared name joins the writer's names.
    alias: usize,
    argument: Argument,
};

const Callee = struct {
    file: File,
    parameters: union(enum) {
        /// The parentheses around a local function's parameter list.
        list: Range,
        names: []const []const u8,
    },
    body_start: usize,
    body_end: usize,
    crossed_files: bool,

    /// The parameter receiving `argument`; a method call's receiver fills the first one.
    fn parameterFor(callee: Callee, argument: Argument) ?struct { name: []const u8, position: usize } {
        const count = callee.parameterCount();
        const position = if (count == argument.count)
            argument.position
        else if (count == argument.count + 1 and argument.receiver != .none)
            argument.position + 1
        else
            return null;
        const name = switch (callee.parameters) {
            .names => |names| names[position],
            .list => |list| listParameter(callee.file, list, position) orelse return null,
        };
        if (std.mem.eql(u8, name, "_")) return null;
        return .{ .name = name, .position = position };
    }

    fn parameterCount(callee: Callee) usize {
        return switch (callee.parameters) {
            .names => |names| names.len,
            .list => |list| listParameterCount(callee.file, list),
        };
    }
};

const Analysis = struct {
    context: RuleRun,
    summary_index: ?summaries.Index,
    effects: std.AutoHashMapUnmanaged(CalleeKey, Remembered) = .empty,

    fn localFile(analysis: *const Analysis) File {
        return .{ .source = analysis.context.source, .tokens = analysis.context.tokens, .local = true };
    }

    fn matches(analysis: *const Analysis, file: File, names: *const Names, index: usize) bool {
        const text = file.text(index);
        for (names.items[0..names.len]) |name| {
            if (!std.mem.eql(u8, name.text, text)) continue;
            const declaration = name.declaration orelse return true;
            const binding = analysis.context.scopes.resolve(index) orelse return true;
            if (binding.token_index == declaration) return true;
        }
        return false;
    }

    /// Records what the mentions of `names` in `[start, end)` do with the writer.
    fn scan(analysis: *Analysis, file: File, names: *Names, start: usize, end: usize, depth: usize, facts: *Facts) std.mem.Allocator.Error!void {
        // On unbalanced input a declaration can end past its scope's closer.
        if (start >= end) return;
        for (start..end) |index| {
            if (file.tokens[index].tag != .identifier or file.tokens[index - 1].tag == .period or
                !analysis.matches(file, names, index)) continue;
            switch (classify(file, index, end)) {
                .ignored => {},
                .write => {
                    facts.wrote = true;
                    if (facts.timeline) |timeline| try timeline.writes.append(analysis.context.allocator, @intCast(index));
                },
                .flush => {
                    if (facts.timeline) |timeline| if (reach.deferKeyword(analysis.context, index) == null) {
                        try timeline.flushes.append(analysis.context.allocator, @intCast(index));
                        continue;
                    };
                    facts.flushed = true;
                    return;
                },
                .escape => {
                    facts.flushed = true;
                    return;
                },
                .alias => |alias| {
                    const added = names.add(.{ .text = file.text(alias), .declaration = if (file.local) alias else null });
                    if (!added) facts.unknown = true;
                },
                .argument => |argument| {
                    const callee = try analysis.calleeEffect(file, argument, depth);
                    facts.crossed_files = facts.crossed_files or callee.crossed_files;
                    switch (callee.effect) {
                        .none => {},
                        .write => {
                            facts.wrote = true;
                            if (facts.timeline) |timeline| try timeline.writes.append(analysis.context.allocator, @intCast(index));
                        },
                        .flush => {
                            facts.flushed = true;
                            return;
                        },
                        .unknown => facts.unknown = true,
                    }
                },
            }
        }
    }

    fn calleeEffect(analysis: *Analysis, file: File, argument: Argument, depth: usize) std.mem.Allocator.Error!Remembered {
        const unknown: Remembered = .{ .effect = .unknown, .crossed_files = false };
        if (depth == max_depth) return unknown;
        const callee = analysis.resolve(file, argument) orelse return unknown;
        const parameter = callee.parameterFor(argument) orelse return unknown;
        const key: CalleeKey = .{ .source = @intFromPtr(callee.file.source.ptr), .body = callee.body_start, .parameter = parameter.position };
        if (analysis.effects.get(key)) |known| return known;
        // A recursive call reads as unknown until the body is scanned.
        try analysis.effects.put(analysis.context.allocator, key, unknown);
        var names: Names = .{};
        _ = names.add(.{ .text = parameter.name });
        var facts: Facts = .{ .crossed_files = callee.crossed_files };
        try analysis.scan(callee.file, &names, callee.body_start + 1, callee.body_end, depth + 1, &facts);
        const result: Remembered = .{ .effect = facts.effect(), .crossed_files = facts.crossed_files };
        try analysis.effects.put(analysis.context.allocator, key, result);
        return result;
    }

    fn resolve(analysis: *const Analysis, file: File, argument: Argument) ?Callee {
        if (file.local) switch (analysis.localCallee(argument)) {
            .function => |callee| return callee,
            .imported => {},
            .unknown => return null,
        };
        const index = analysis.summary_index orelse return null;
        const receiver: ?[]const u8 = switch (argument.receiver) {
            .none => null,
            .path => |path| file.source[file.tokens[path.start].loc.start..file.tokens[path.end - 1].loc.end],
            .other => return null,
        };
        const function = index.calledFunction(file.source, receiver, file.text(argument.name)) orelse return null;
        return .{
            .file = .{ .source = function.source, .tokens = function.tokens, .local = false },
            .parameters = .{ .names = function.parameter_names },
            .body_start = function.body_start,
            .body_end = function.body_end,
            .crossed_files = function.source.ptr != analysis.context.source.ptr,
        };
    }

    const Local = union(enum) { function: Callee, imported, unknown };

    /// The function of the analyzed file a call names, or whether the call
    /// goes through an import.
    fn localCallee(analysis: *const Analysis, argument: Argument) Local {
        const context = analysis.context;
        const function_name = switch (argument.receiver) {
            .other => return .unknown,
            .none => (context.scopes.findBinding(argument.name) orelse return .unknown).token_index,
            .path => |path| name: {
                if (importsFile(context, path.start)) return .imported;
                break :name uniqueFunctionName(context, argument.name) orelse return .unknown;
            },
        };
        if (function_name == 0 or context.tokens[function_name - 1].tag != .keyword_fn) return .unknown;
        const range = context.functionRange(function_name - 1) orelse return .unknown;
        return .{ .function = .{
            .file = analysis.localFile(),
            .parameters = .{ .list = .{ .start = range.parameters_start, .end = range.parameters_end } },
            .body_start = range.body_start,
            .body_end = range.body_end,
            .crossed_files = false,
        } };
    }
};

/// Whether the identifier at `index` names an `@import` of another file.
fn importsFile(context: RuleRun, index: usize) bool {
    const binding = context.scopes.findBinding(index) orelse return false;
    const declaration = binding.token_index;
    return context.tokens[declaration + 1].tag == .equal and context.tokens[declaration + 2].tag == .builtin and
        context.tokenIs(declaration + 2, "@import");
}

/// The name token of the only function the file declares with the name at `name`.
fn uniqueFunctionName(context: RuleRun, name: usize) ?usize {
    const bindings = context.scopes.bindings.get(context.tokenText(name)) orelse return null;
    var selected: ?usize = null;
    for (bindings.items) |binding| {
        if (binding.token_index == 0 or context.tokens[binding.token_index - 1].tag != .keyword_fn) continue;
        if (selected != null) return null;
        selected = binding.token_index;
    }
    return selected;
}

/// What the mention of a writer name at `index` does with the writer.
fn classify(file: File, index: usize, end: usize) Use {
    const tokens = file.tokens;
    var after = index + 1;
    if (after + 1 < end and tokens[after].tag == .period and tokens[after + 1].tag == .identifier) {
        if (tokens[after + 2].tag == .l_paren) return methodUse(file.text(after + 1));
        if (!file.is(after + 1, "interface")) return .ignored;
        after += 2;
        if (after + 1 < end and tokens[after].tag == .period and tokens[after + 1].tag == .identifier) {
            return if (tokens[after + 2].tag == .l_paren) methodUse(file.text(after + 1)) else .ignored;
        }
    }
    switch (tokens[after].tag) {
        .period, .period_asterisk => return .ignored,
        else => {},
    }
    const start = if (tokens[index - 1].tag == .ampersand) index - 1 else index;
    return expressionUse(file, start, after);
}

fn methodUse(name: []const u8) Use {
    if (resources.flushesWriter(name)) return .flush;
    const prefixes = [_][]const u8{ "write", "writable", "print", "splat", "send", "align" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return .write;
    return if (std.mem.eql(u8, name, "advance")) .write else .ignored;
}

/// What the expression `[start, end)` naming the writer does with it.
fn expressionUse(file: File, start: usize, end: usize) Use {
    const tokens = file.tokens;
    const before = tokens[start - 1].tag;
    const after = tokens[end].tag;
    if ((before == .l_paren or before == .comma) and (after == .r_paren or after == .comma)) return argumentUse(file, start, end);
    if (before != .equal) return .escape;
    const head = tokens_util.statementStart(tokens, start);
    if (head + 2 == start and file.is(head, "_")) return .ignored;
    if ((tokens[head].tag == .keyword_const or tokens[head].tag == .keyword_var) and
        tokens[head + 1].tag == .identifier and after == .semicolon) return .{ .alias = head + 1 };
    return .escape;
}

/// The call taking the expression `[start, end)` as an argument; any other
/// list (a tuple, a builtin's arguments) keeps the writer.
fn argumentUse(file: File, start: usize, end: usize) Use {
    const tokens = file.tokens;
    var position: usize = 0;
    var depth: usize = 0;
    var opening = start;
    while (true) {
        if (opening == 0) return .escape;
        opening -= 1;
        switch (tokens[opening].tag) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_paren, .l_bracket, .l_brace => {
                if (depth == 0) break;
                depth -= 1;
            },
            .comma => if (depth == 0) {
                position += 1;
            },
            .semicolon => return .escape,
            else => {},
        }
    }
    if (tokens[opening].tag != .l_paren or opening == 0 or tokens[opening - 1].tag != .identifier) return .escape;
    const name = opening - 1;
    if (name > 0 and tokens[name - 1].tag == .keyword_fn) return .escape;
    var count = position + 1;
    depth = 0;
    var closing = end;
    while (true) : (closing += 1) switch (tokens[closing].tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => {
            if (depth == 0) break;
            depth -= 1;
        },
        .comma => if (depth == 0) {
            count += 1;
        },
        .semicolon, .eof => return .escape,
        else => {},
    };
    if (tokens[closing - 1].tag == .comma) count -= 1;
    return .{ .argument = .{ .name = name, .receiver = receiverOf(tokens, name), .position = position, .count = count } };
}

fn receiverOf(tokens: []const Token, name: usize) Receiver {
    if (name < 2 or tokens[name - 1].tag != .period) return .none;
    if (tokens[name - 2].tag != .identifier) return .other;
    const path = tokens_util.pathBefore(tokens, name - 1) orelse return .other;
    // A call or index before the path (`make().reader.read(`) leaves the receiver opaque.
    if (path.start > 0 and tokens[path.start - 1].tag == .period) return .other;
    return .{ .path = path };
}

/// The name of the parameter at `position` in the list between the
/// parentheses at `list`.
fn listParameter(file: File, list: Range, position: usize) ?[]const u8 {
    var start = list.start + 1;
    var current: usize = 0;
    while (start < list.end) : (current += 1) {
        const comma = tokens_util.topLevelComma(file.tokens, start, list.end) orelse list.end;
        if (current == position) {
            for (start..comma) |index| {
                if (file.tokens[index].tag == .identifier and file.tokens[index + 1].tag == .colon) return file.text(index);
            }
            return null;
        }
        start = comma + 1;
    }
    return null;
}

fn listParameterCount(file: File, list: Range) usize {
    const end = tokens_util.argumentsEnd(file.tokens, list.start, list.end) orelse return 0;
    var count: usize = 1;
    var start = list.start + 1;
    while (tokens_util.topLevelComma(file.tokens, start, end)) |comma| : (start = comma + 1) count += 1;
    return count;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.unflushed_writer}, .warning));
}

test "a written stdout writer without flush reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn main(init: std.process.Init) !void {
        \\    var buffer: [256]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
        \\    const stdout = &stdout_writer.interface;
        \\    try stdout.print("{d}\n", .{1});
        \\}
        \\fn streaming(io: std.Io, file: std.Io.File) !void {
        \\    var buffer: [256]u8 = undefined;
        \\    var file_writer: std.Io.File.Writer = .initStreaming(file, io, &buffer);
        \\    try file_writer.interface.writeAll("x");
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "stdout_writer", "file_writer" });
}

test "a writer passed to a same-file helper that only writes reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    var buffer: [2048]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
        \\    const stdout = &stdout_writer.interface;
        \\    try genConfig(stdout);
        \\}
        \\fn genConfig(writer: *std.Io.Writer) !void {
        \\    try writer.writeAll("---\n");
        \\    try endBlock(writer);
        \\}
        \\fn endBlock(writer: *std.Io.Writer) !void {
        \\    try writer.writeAll("```\n");
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{"stdout_writer"});
}

test "flushed, ended, stored, returned and empty-buffer writers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn deferred(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    const stdout = &stdout_writer.interface;
        \\    defer stdout.flush() catch {};
        \\    try stdout.writeAll("x");
        \\}
        \\fn ended(io: std.Io, file: std.Io.File) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var file_writer = file.writer(io, &buffer);
        \\    try file_writer.interface.writeAll("x");
        \\    try file_writer.end();
        \\}
        \\fn served(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    var server: std.zig.Server = .{ .out = &stdout_writer.interface, .in = undefined };
        \\    try server.serveStringMessage(.zig_version, "0");
        \\}
        \\fn returned(io: std.Io, buffer: []u8) std.Io.File.Writer {
        \\    var stdout_writer = std.Io.File.stdout().writer(io, buffer);
        \\    stdout_writer.interface.writeAll("x") catch {};
        \\    return stdout_writer;
        \\}
        \\fn unbuffered(io: std.Io) !void {
        \\    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &.{});
        \\    try stdout_writer.interface.writeAll("x");
        \\}
        \\fn unwritten(io: std.Io) void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    _ = &stdout_writer;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "a helper that flushes, or one the file cannot read, keeps the writer quiet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const helpgen = @import("helpgen.zig");
        \\fn response(io: std.Io, file: std.Io.File, args: []const []const u8) !void {
        \\    var buf: [1024]u8 = undefined;
        \\    var rsp_fw = file.writer(io, &buf);
        \\    writeResponseFile(args, &rsp_fw.interface) catch |err| switch (err) {
        \\        error.WriteFailed => return rsp_fw.err.?,
        \\    };
        \\}
        \\fn writeResponseFile(args: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        \\    for (args) |arg| try w.writeAll(arg);
        \\    try w.flush();
        \\}
        \\fn imported(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try helpgen.generate(&stdout_writer.interface, .markdown);
        \\}
        \\const Printer = struct {
        \\    fn emit(printer: *Printer, out: *std.Io.Writer) !void {
        \\        _ = printer;
        \\        try out.writeAll("x");
        \\        try out.flush();
        \\    }
        \\};
        \\fn method(io: std.Io, printer: *Printer) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try printer.emit(&stdout_writer.interface);
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "shadowed names belong to their own declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn shadow(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var w = std.Io.File.stdout().writer(io, &buffer);
        \\    try w.interface.writeAll("x");
        \\    {
        \\        const flush_target = struct {
        \\            fn run(w: *std.Io.Writer) !void {
        \\                try w.flush();
        \\            }
        \\        };
        \\        _ = flush_target;
        \\    }
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{"w"});
}

test "an early return or a flush on only some paths reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn early(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var early_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    const out = &early_writer.interface;
        \\    try out.print("hi\n", .{});
        \\    if (flag) return;
        \\    try out.flush();
        \\}
        \\fn branch(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var branch_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try branch_writer.interface.print("hi\n", .{});
        \\    if (flag) try branch_writer.interface.flush();
        \\}
        \\fn tail(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var tail_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try tail_writer.interface.writeAll("a");
        \\    try tail_writer.interface.flush();
        \\    try tail_writer.interface.writeAll("b");
        \\}
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "return", "branch_writer", "tail_writer" });
    try std.testing.expectEqual(@as(usize, 1), found[1].related.len);
}

test "flushes that every path runs stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn usage(io: std.Io, help: bool) !u8 {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    const stdout = &stdout_writer.interface;
        \\    if (help) {
        \\        try stdout.writeAll("usage\n");
        \\        try stdout.flush();
        \\        return 0;
        \\    }
        \\    for (0..3) |index| {
        \\        try stdout.print("{d}\n", .{index});
        \\        if (index == 1) try stdout.flush();
        \\    }
        \\    {
        \\        try stdout.writeAll("done\n");
        \\    }
        \\    const parsed = std.fmt.parseInt(u8, "1", 10) catch return error.Invalid;
        \\    try stdout.flush();
        \\    return parsed;
        \\}
        \\fn returned(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var file_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try file_writer.interface.writeAll("x");
        \\    return file_writer.interface.flush();
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}

test "an if with an else or a switch that flushes in every branch covers the writes before it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const clean: [:0]const u8 =
        \\const std = @import("std");
        \\const Mode = enum { a, b, c };
        \\fn braced(io: std.Io, flag: bool, value: anyerror!u8) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var braced_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try braced_writer.interface.writeAll("a");
        \\    if (flag) {
        \\        try braced_writer.interface.writeAll("b");
        \\        try braced_writer.interface.flush();
        \\    } else if (value) |byte| {
        \\        _ = byte;
        \\        try braced_writer.interface.flush();
        \\    } else |err| {
        \\        _ = err;
        \\        try braced_writer.interface.flush();
        \\    }
        \\}
        \\fn unbraced(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var unbraced_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try unbraced_writer.interface.writeAll("a");
        \\    if (flag) try unbraced_writer.interface.flush() else try unbraced_writer.interface.flush();
        \\}
        \\fn switched(io: std.Io, mode: Mode, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var switched_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try switched_writer.interface.writeAll("a");
        \\    switch (mode) {
        \\        .a => try switched_writer.interface.flush(),
        \\        .b => |tag| {
        \\            _ = tag;
        \\            if (flag) {
        \\                try switched_writer.interface.flush();
        \\            } else {
        \\                try switched_writer.interface.flush();
        \\            }
        \\        },
        \\        else => unreachable,
        \\    }
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), clean)).len);
    const partial: [:0]const u8 =
        \\const std = @import("std");
        \\const Mode = enum { a, b, c };
        \\fn noElse(io: std.Io, flag: bool, other: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var else_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try else_writer.interface.writeAll("a");
        \\    if (flag) {
        \\        try else_writer.interface.flush();
        \\    } else if (other) {
        \\        try else_writer.interface.flush();
        \\    }
        \\}
        \\fn prong(io: std.Io, mode: Mode) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var prong_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try prong_writer.interface.writeAll("a");
        \\    switch (mode) {
        \\        .a, .c => try prong_writer.interface.flush(),
        \\        .b => {},
        \\    }
        \\}
        \\fn nested(io: std.Io, flag: bool, other: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var nested_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try nested_writer.interface.writeAll("a");
        \\    if (other) {
        \\        if (flag) try nested_writer.interface.flush() else try nested_writer.interface.flush();
        \\    }
        \\}
        \\fn guarded(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var guarded_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try guarded_writer.interface.writeAll("a");
        \\    if (flag) try guarded_writer.interface.flush() else other(flag) catch try guarded_writer.interface.flush();
        \\}
        \\fn later(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var later_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    if (flag) {
        \\        try later_writer.interface.flush();
        \\        try later_writer.interface.writeAll("a");
        \\    } else {
        \\        try later_writer.interface.flush();
        \\    }
        \\}
        \\fn returned(io: std.Io, flag: bool) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var returned_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try returned_writer.interface.writeAll("a");
        \\    if (flag) {
        \\        try returned_writer.interface.flush();
        \\    } else {
        \\        return;
        \\    }
        \\}
        \\fn other(flag: bool) !void {
        \\    if (flag) return error.Failed;
        \\}
    ;
    const found = try findingsFor(arena.allocator(), partial);
    try support.expectSpans(partial, found, &.{ "else_writer", "prong_writer", "nested_writer", "guarded_writer", "later_writer", "return" });
}

test "summaries read a callee in another file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const main_source: [:0]const u8 =
        \\const std = @import("std");
        \\const helpgen = @import("helpgen.zig");
        \\pub fn main(init: std.process.Init) !void {
        \\    var buffer: [2048]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
        \\    const stdout = &stdout_writer.interface;
        \\    try helpgen.generate(stdout, .markdown);
        \\}
        \\fn flushed(io: std.Io) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
        \\    try helpgen.generateFlushed(&stdout_writer.interface);
        \\}
    ;
    const helper_source: [:0]const u8 =
        \\const std = @import("std");
        \\pub fn generate(writer: *std.Io.Writer, format: enum { markdown }) !void {
        \\    _ = format;
        \\    try writer.writeAll("# actions\n");
        \\}
        \\pub fn generateFlushed(writer: *std.Io.Writer) !void {
        \\    try writer.writeAll("# actions\n");
        \\    try writer.flush();
        \\}
    ;
    const sources = [_]summaries.Source{
        .{ .file_index = 0, .path = "src/main.zig", .source = main_source, .tokens = try tokens_util.tokenize(allocator, main_source) },
        .{ .file_index = 1, .path = "src/helpgen.zig", .source = helper_source, .tokens = try tokens_util.tokenize(allocator, helper_source) },
    };
    const configuration = support.only(&.{.unflushed_writer}, .warning);
    var summary_index = try summaries.build(allocator, &sources, configuration);
    defer summary_index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(allocator, main_source)).len);
    const found = try support.findingsWith(allocator, runWithSummaries, summary_index, main_source, configuration);
    try support.expectSpans(main_source, found, &.{"stdout_writer"});
}
