const std = @import("std");
const syntax_scope = @import("../../syntax/scope.zig");
const RuleRun = @import("../context.zig").RuleRun;
const container_types = @import("../container_types.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .returning_local_slice,
    .local_storage_escape,
};

pub fn run(context: RuleRun) !void {
    try findArrayViewEscapes(context);
    try findReturnedLocalPointers(context);
    try findRetainedLocalPointers(context);
}

/// Escapes of a view into a local array: a slice of it, a `bufPrint`-family
/// result formatted into it, the buffered bytes of a fixed `std.Io.Writer`
/// over it, or a binding or aggregate holding one of those. Returning such a
/// slice is `returning-local-slice`; returning an aggregate holding one,
/// storing one in module state or through an output parameter, and adding
/// one to an outliving container are `local-storage-escape`.
fn findArrayViewEscapes(context: RuleRun) !void {
    const slice_level = context.level(.returning_local_slice);
    const escape_level = context.level(.local_storage_escape);
    if (slice_level == .off and escape_level == .off) return;
    const tokens = context.tokens;
    var views: Views = .{ .array = "" };
    defer views.deinit(context.allocator);
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_var and token.tag != .keyword_const) or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or
            !context.scopes.insideFunctionOrTestBody(declaration_index)) continue;
        // A 'comptime var' array is interned into the binary; slices of it are
        // valid after the function returns.
        if (declaration_index > 0 and tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!declarationStoresArray(context, declaration_index, declaration_end)) continue;
        const function_scope = context.scopes.enclosingFunctionBody(declaration_index) orelse continue;
        if (token.tag == .keyword_const and !constArrayIsStackStorage(context, declaration_index, declaration_end, function_scope)) continue;
        // So is the storage of a `comptime { ... }` block.
        if (insideComptimeBlock(context, declaration_index, function_scope)) continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        // A function with only comptime parameters is evaluated from values
        // known during compilation, so its local result storage is promoted.
        const promoted_result = enclosingFunctionHasOnlyComptimeParameters(context, declaration_index);
        // The frame of `main` lives until the program exits, so module state
        // and containers may keep views into it.
        const store_level: types.Level = if (isMainBody(context, function_scope)) .off else escape_level;
        const array_name = context.tokenText(declaration_index + 1);
        views.reset(array_name);
        // The array's name is only visible in its own block; the rest of the
        // function matters once a binding declared outside holds a view.
        const block_end = context.enclosingScopeEnd(declaration_index) orelse function_end;

        var index = declaration_end + 1;
        while (index < (if (views.outer_alias) function_end else block_end)) : (index += 1) {
            switch (tokens[index].tag) {
                .keyword_const, .keyword_var => try views.noteDeclaration(context, index),
                .keyword_break => try views.noteBlockResult(context, index, function_scope),
                .keyword_return => {
                    if (promoted_result or context.scopes.enclosingFunctionBody(index) != function_scope) continue;
                    const return_end = context.statementEnd(index) orelse continue;
                    const kind = views.expression(context, index + 1, return_end) orelse continue;
                    const rule: types.Rule = if (kind == .slice) .returning_local_slice else .local_storage_escape;
                    const level = if (kind == .slice) slice_level else escape_level;
                    if (level == .off) continue;
                    try context.emit(.{
                        .rule = rule,
                        .level = level,
                        .span = tokens[index + 1].loc,
                        .message = if (kind == .slice)
                            try context.allocator.print(
                                "returned slice '{s}' refers to a local array whose storage expires when this function returns",
                                .{array_name},
                            )
                        else
                            try context.allocator.print(
                                "returned value holds a slice of local array '{s}', whose storage expires when the function returns",
                                .{array_name},
                            ),
                    });
                },
                .equal => try noteAssignment(context, &views, store_level, function_scope, index),
                .l_paren => {
                    if (store_level == .off or index < 3 or tokens[index - 1].tag != .identifier or
                        tokens[index - 2].tag != .period or !retainingMethod(context, index - 1)) continue;
                    const call_end = context.matchingToken(index, .l_paren, .r_paren) orelse continue;
                    const argument = views.argument(context, index, call_end) orelse continue;
                    if (!outlivingContainer(context, index - 1, function_scope)) continue;
                    // `try list.append(gpa, view); defer _ = list.pop();` within the array's lifetime.
                    if (index < block_end and deferredRemoval(context, index - 1, call_end)) continue;
                    try context.emit(.{
                        .rule = .local_storage_escape,
                        .level = store_level,
                        .span = tokens[argument].loc,
                        .message = try context.allocator.print(
                            "slice of local array '{s}' is retained by {s} beyond the array's lifetime",
                            .{ array_name, context.tokenText(index - 1) },
                        ),
                    });
                },
                else => {},
            }
        }
    }
}

/// An assignment at `equal_index`: a view stored in module state or through
/// an output parameter escapes; one assigned to a local now aliases the array.
fn noteAssignment(
    context: RuleRun,
    views: *Views,
    level: types.Level,
    function_scope: usize,
    equal_index: usize,
) !void {
    const tokens = context.tokens;
    if (equal_index < 3) return;
    // `output.* = view;`, also spelled `output. * = view;`.
    const output_index: ?usize = if (tokens[equal_index - 1].tag == .period_asterisk)
        equal_index - 2
    else if (tokens[equal_index - 1].tag == .asterisk and tokens[equal_index - 2].tag == .period)
        equal_index - 3
    else
        null;
    const destination = output_index orelse equal_index - 1;
    if (destination == 0 or tokens[destination].tag != .identifier) return;
    // A statement of its own, also as the body of `if (c)`, `else` or `|x|`.
    switch (tokens[destination - 1].tag) {
        .semicolon, .l_brace, .r_brace, .r_paren, .keyword_else, .pipe => {},
        else => return,
    }
    const statement_end = context.statementEnd(equal_index) orelse return;
    const destination_name = context.tokenText(destination);
    const kind = views.expression(context, equal_index + 1, statement_end) orelse {
        if (output_index == null) views.forget(destination_name);
        return;
    };
    if (output_index != null) {
        if (level == .off or !functionParameterExists(context, function_scope, destination_name)) return;
        try context.emit(.{
            .rule = .local_storage_escape,
            .level = level,
            .span = tokens[equal_index + 1].loc,
            .message = try context.allocator.print(
                "slice of local array '{s}' is stored through output parameter '{s}' and outlives its backing storage",
                .{ views.array, destination_name },
            ),
        });
        return;
    }
    if (!moduleBinding(context, destination)) {
        try views.aliases.append(context.allocator, .{ .name = destination_name, .kind = kind });
        views.outer_alias = true;
        return;
    }
    if (level == .off) return;
    try context.emit(.{
        .rule = .local_storage_escape,
        .level = level,
        .span = tokens[equal_index + 1].loc,
        .message = try context.allocator.print(
            "slice of local array '{s}' is stored in global binding '{s}' and outlives its backing storage",
            .{ views.array, destination_name },
        ),
    });
}

const ViewKind = enum {
    /// A slice of the array's bytes.
    slice,
    /// A struct or tuple holding such a slice.
    aggregate,
};

/// The bindings of one function that hold a view into one local array, in
/// the order the forward scan meets them.
const Views = struct {
    array: []const u8,
    aliases: std.ArrayList(Alias) = .empty,
    /// Bindings of a fixed `std.Io.Writer` over the array.
    writers: std.ArrayList([]const u8) = .empty,
    /// An alias may be declared outside the array's block: an assigned
    /// binding or a labeled block's result.
    outer_alias: bool = false,

    const Alias = struct { name: []const u8, kind: ViewKind };

    fn reset(views: *Views, array: []const u8) void {
        views.array = array;
        views.aliases.clearRetainingCapacity();
        views.writers.clearRetainingCapacity();
        views.outer_alias = false;
    }

    fn deinit(views: *Views, allocator: std.mem.Allocator) void {
        views.aliases.deinit(allocator);
        views.writers.deinit(allocator);
    }

    fn alias(views: *const Views, context: RuleRun, index: usize) ?ViewKind {
        for (views.aliases.items) |entry| if (context.tokenIs(index, entry.name)) return entry.kind;
        return null;
    }

    /// Drops `name` once it is rebound to a value that is not a view.
    fn forget(views: *Views, name: []const u8) void {
        var index: usize = 0;
        while (index < views.aliases.items.len) {
            if (std.mem.eql(u8, views.aliases.items[index].name, name)) {
                _ = views.aliases.orderedRemove(index);
            } else index += 1;
        }
    }

    fn isWriter(views: *const Views, context: RuleRun, index: usize) bool {
        for (views.writers.items) |writer| if (context.tokenIs(index, writer)) return true;
        return false;
    }

    /// Records the binding a `const`/`var` declaration at `declaration`
    /// introduces when its initializer is a view or a fixed writer.
    fn noteDeclaration(views: *Views, context: RuleRun, declaration: usize) !void {
        const tokens = context.tokens;
        if (declaration == 0 or declaration + 2 >= tokens.len or tokens[declaration + 1].tag != .identifier) return;
        // Not the `const` of a pointer or slice type such as `[]const u8`.
        switch (tokens[declaration - 1].tag) {
            .semicolon, .l_brace, .r_brace, .keyword_comptime => {},
            else => return,
        }
        const declaration_end = context.statementEnd(declaration) orelse return;
        const initializer = container_types.initializerStart(tokens, declaration, declaration_end) orelse return;
        const name = context.tokenText(declaration + 1);
        views.forget(name);
        if (views.fixedWriter(context, initializer, declaration_end)) {
            try views.writers.append(context.allocator, name);
            return;
        }
        const kind = views.expression(context, initializer, declaration_end) orelse return;
        try views.aliases.append(context.allocator, .{ .name = name, .kind = kind });
    }

    /// Records `name` for `const name = label: { ...; break :label view; };`,
    /// whose block may declare the array itself.
    fn noteBlockResult(views: *Views, context: RuleRun, break_index: usize, function_scope: usize) !void {
        const tokens = context.tokens;
        if (break_index + 3 >= tokens.len or tokens[break_index + 1].tag != .colon or
            tokens[break_index + 2].tag != .identifier) return;
        const value_end = context.statementEnd(break_index) orelse return;
        const kind = views.expression(context, break_index + 3, value_end) orelse return;
        const label = context.tokenText(break_index + 2);
        var brace = context.enclosingOpeningBrace(break_index);
        while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
            if (opening <= function_scope) return;
            if (opening < 3 or tokens[opening - 1].tag != .colon or !context.tokenIs(opening - 2, label)) continue;
            if (tokens[opening - 3].tag != .equal) return;
            const declaration = tokens_util.statementStart(tokens, opening - 3);
            if ((tokens[declaration].tag != .keyword_const and tokens[declaration].tag != .keyword_var) or
                tokens[declaration + 1].tag != .identifier) return;
            try views.aliases.append(context.allocator, .{ .name = context.tokenText(declaration + 1), .kind = kind });
            views.outer_alias = true;
            return;
        }
    }

    /// What the expression `[start, end)` evaluates to when it is a view into
    /// the array, looking through `try`, parentheses, the branches of an `if`
    /// and a `catch`/`orelse` fallback.
    fn expression(views: *const Views, context: RuleRun, start: usize, end: usize) ?ViewKind {
        const tokens = context.tokens;
        var cursor = start;
        while (cursor < end and tokens[cursor].tag == .keyword_try) cursor += 1;
        if (cursor >= end) return null;
        if (tokens[cursor].tag == .keyword_if) return views.conditional(context, cursor, end);
        const value_end = fallbackStart(context, cursor, end) orelse end;
        if (tokens[cursor].tag == .l_paren) {
            const closing = context.matchingToken(cursor, .l_paren, .r_paren) orelse return null;
            return if (closing + 1 == value_end) views.expression(context, cursor + 1, closing) else null;
        }
        if (literalOpening(context, cursor, value_end)) |opening| {
            const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse return null;
            return if (closing + 1 == value_end and views.literalHoldsView(context, opening, closing)) .aggregate else null;
        }
        if (views.streamOverArray(context, cursor, value_end)) return .aggregate;
        return views.path(context, cursor, value_end);
    }

    /// Whether `[start, end)` is a `file.writer(io, &array)`, `reader`,
    /// streaming or `.fixed(&array)` call, whose result keeps the array as its
    /// buffer.
    fn streamOverArray(views: *const Views, context: RuleRun, start: usize, end: usize) bool {
        const tokens = context.tokens;
        if (end < start + 4 or tokens[end - 1].tag != .r_paren) return false;
        const opening = context.scopes.matchingToken(end - 1) orelse return false;
        if (opening < start + 2 or tokens[opening - 2].tag != .period) return false;
        const method = context.tokenText(opening - 1);
        if (!container_types.isOneOf(method, &.{ "writer", "writerStreaming", "reader", "readerStreaming", "fixed" })) return false;
        var last = opening + 1;
        while (context.topLevelComma(last, end - 1)) |comma| last = comma + 1;
        return views.buffer(context, last, end - 1);
    }

    /// The view either branch of `if (c) a else b` at `if_index` yields.
    fn conditional(views: *const Views, context: RuleRun, if_index: usize, end: usize) ?ViewKind {
        const tokens = context.tokens;
        if (if_index + 1 >= end or tokens[if_index + 1].tag != .l_paren) return null;
        var branch = (context.matchingToken(if_index + 1, .l_paren, .r_paren) orelse return null) + 1;
        if (branch < end and tokens[branch].tag == .pipe) {
            branch = (tokens_util.nextTagBefore(tokens, branch + 1, .pipe, .semicolon) orelse return null) + 1;
        }
        var else_index = branch;
        while (else_index < end and tokens[else_index].tag != .keyword_else) : (else_index += 1) {
            switch (tokens[else_index].tag) {
                .l_paren, .l_bracket, .l_brace => else_index = context.scopes.matchingToken(else_index) orelse return null,
                else => {},
            }
        }
        if (else_index >= end) return null;
        var otherwise = else_index + 1;
        if (otherwise < end and tokens[otherwise].tag == .pipe) {
            otherwise = (tokens_util.nextTagBefore(tokens, otherwise + 1, .pipe, .semicolon) orelse return null) + 1;
        }
        if (branch >= else_index or otherwise >= end) return null;
        return views.expression(context, branch, else_index) orelse views.expression(context, otherwise, end);
    }

    /// Whether an element or field value of the struct or tuple literal
    /// between `opening` and `closing` is a view.
    fn literalHoldsView(views: *const Views, context: RuleRun, opening: usize, closing: usize) bool {
        const tokens = context.tokens;
        var element = opening + 1;
        while (element < closing) {
            const element_end = context.topLevelComma(element, closing) orelse closing;
            var value = element;
            if (value + 2 < element_end and tokens[value].tag == .period and tokens[value + 1].tag == .identifier and
                tokens[value + 2].tag == .equal) value += 3;
            if (value < element_end and views.expression(context, value, element_end) != null) return true;
            element = element_end + 1;
        }
        return false;
    }

    /// A slice of the array, of an alias or of a formatting result over the
    /// array; or an aggregate alias itself. Indexing an element, reading
    /// `.len` or dereferencing with `.*` yields a value instead.
    fn path(views: *const Views, context: RuleRun, start: usize, end: usize) ?ViewKind {
        const tokens = context.tokens;
        if (tokens[start].tag != .identifier) return null;
        var cursor = start + 1;
        var is_view = true;
        if (context.tokenIs(start, views.array)) {
            is_view = false;
        } else if (views.alias(context, start)) |kind| {
            if (kind == .aggregate) return if (cursor == end) .aggregate else null;
        } else if (views.isWriter(context, start)) {
            // `writer.buffered()`
            if (start + 5 > end or tokens[start + 1].tag != .period or !context.tokenIs(start + 2, "buffered") or
                tokens[start + 3].tag != .l_paren or tokens[start + 4].tag != .r_paren) return null;
            cursor = start + 5;
        } else {
            cursor = (views.formattingCall(context, start, end) orelse return null) + 1;
        }
        while (cursor < end) {
            switch (tokens[cursor].tag) {
                .l_bracket => {
                    const closing = context.matchingToken(cursor, .l_bracket, .r_bracket) orelse return null;
                    if (!subscriptIsRange(context, cursor, closing)) return null;
                    is_view = true;
                    cursor = closing + 1;
                },
                .period => {
                    if (!is_view or cursor + 1 >= end or !context.tokenIs(cursor + 1, "ptr")) return null;
                    cursor += 2;
                },
                else => return null,
            }
        }
        return if (is_view) .slice else null;
    }

    /// The `)` of a `std.fmt.bufPrint`-family or `std.mem.print` call starting
    /// at `start` that formats into the array; its result is a view of it.
    fn formattingCall(views: *const Views, context: RuleRun, start: usize, end: usize) ?usize {
        const tokens = context.tokens;
        var name = start;
        while (name + 2 < end and tokens[name + 1].tag == .period and tokens[name + 2].tag == .identifier) name += 2;
        if (name + 1 >= end or tokens[name + 1].tag != .l_paren) return null;
        const callee = context.tokenText(name);
        const formats = container_types.isOneOf(callee, &.{ "bufPrint", "bufPrintZ", "bufPrintSentinel" }) or
            (container_types.isOneOf(callee, &.{ "print", "printSentinel" }) and name >= start + 2 and context.tokenIs(name - 2, "mem"));
        if (!formats) return null;
        const closing = context.matchingToken(name + 1, .l_paren, .r_paren) orelse return null;
        if (closing >= end) return null;
        const buffer_end = context.topLevelComma(name + 2, closing) orelse closing;
        return if (views.buffer(context, name + 2, buffer_end)) closing else null;
    }

    /// Whether `[start, end)`, the buffer argument of a formatting call or a
    /// fixed writer, is the array's address or a slice of it.
    fn buffer(views: *const Views, context: RuleRun, start: usize, end: usize) bool {
        if (start + 2 == end and context.tokens[start].tag == .ampersand and context.tokenIs(start + 1, views.array)) return true;
        return start < end and views.path(context, start, end) == .slice;
    }

    /// Whether the initializer `[start, end)` is a `.fixed(buffer)` or
    /// `std.Io.Writer.fixed(buffer)` writer over the array.
    fn fixedWriter(views: *const Views, context: RuleRun, start: usize, end: usize) bool {
        const tokens = context.tokens;
        if (end < start + 4 or tokens[end - 1].tag != .r_paren) return false;
        const opening = context.scopes.matchingToken(end - 1) orelse return false;
        if (opening < start + 2 or !context.tokenIs(opening - 1, "fixed") or tokens[opening - 2].tag != .period) return false;
        return views.buffer(context, opening + 1, end - 1);
    }

    /// The first token of a call argument, or of a field value of a literal
    /// argument, that is a view.
    fn argument(views: *const Views, context: RuleRun, opening: usize, closing: usize) ?usize {
        var start = opening + 1;
        while (start < closing) {
            const argument_end = context.topLevelComma(start, closing) orelse closing;
            if (start < argument_end and views.expression(context, start, argument_end) != null) return start;
            start = argument_end + 1;
        }
        return null;
    }
};

/// Whether the retaining call whose method sits at `method_index` is undone
/// before its block ends: `try list.append(gpa, view); defer _ = list.pop();`
/// in one block, with no exit between them. The removal runs before the
/// array, declared in this block or an enclosing one, expires.
fn deferredRemoval(context: RuleRun, method_index: usize, call_end: usize) bool {
    const tokens = context.tokens;
    const receiver_start = context.pathStartBefore(method_index - 1) orelse return false;
    const receiver: tokens_util.Range = .{ .start = receiver_start, .end = method_index - 1 };
    // A statement of its own, so the removal pairs with it on every path.
    const head = if (receiver_start > 0 and tokens[receiver_start - 1].tag == .keyword_try) receiver_start - 1 else receiver_start;
    if (head == 0 or call_end + 1 >= tokens.len or tokens[call_end + 1].tag != .semicolon) return false;
    switch (tokens[head - 1].tag) {
        .semicolon, .l_brace, .r_brace => {},
        else => return false,
    }
    const block = context.enclosingOpeningBrace(method_index) orelse return false;
    const block_end = context.matchingToken(block, .l_brace, .r_brace) orelse return false;
    var cursor = call_end + 2;
    while (cursor < block_end) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .keyword_try, .keyword_return, .keyword_break, .keyword_continue => return false,
            .keyword_defer, .keyword_errdefer => {
                const statement_end = context.statementEnd(cursor) orelse return false;
                if (tokens[cursor].tag == .keyword_defer and context.enclosingOpeningBrace(cursor) == block and
                    removesRetained(context, receiver, method_index, call_end, cursor + 1, statement_end)) return true;
                cursor = statement_end;
            },
            else => {},
        }
    }
    return false;
}

/// Whether the deferred statement `[start, end)` removes what the retaining
/// call at `method_index` added to `receiver`: after an append, `pop()`, a
/// shrink or clear, `items.len -= n`, or `orderedRemove`/`swapRemove` of the
/// last element; after a `put`, a removal of the same key.
fn removesRetained(context: RuleRun, receiver: tokens_util.Range, method_index: usize, call_end: usize, start: usize, end: usize) bool {
    const tokens = context.tokens;
    var cursor = start;
    if (cursor + 1 < end and context.tokenIs(cursor, "_") and tokens[cursor + 1].tag == .equal) cursor += 2;
    const length = receiver.end - receiver.start;
    if (cursor + length + 2 >= end or !context.dottedPathsEqual(receiver.start, receiver.end, cursor, cursor + length) or
        tokens[cursor + length].tag != .period or tokens[cursor + length + 1].tag != .identifier) return false;
    const removal = cursor + length + 1;
    const appended = std.mem.startsWith(u8, context.tokenText(method_index), "append");
    if (appended and context.tokenIs(removal, "items")) {
        return removal + 4 < end and tokens[removal + 1].tag == .period and context.tokenIs(removal + 2, "len") and
            tokens[removal + 3].tag == .minus_equal;
    }
    if (tokens[removal + 1].tag != .l_paren) return false;
    const removal_end = context.matchingToken(removal + 1, .l_paren, .r_paren) orelse return false;
    if (removal_end + 1 != end) return false;
    const argument: tokens_util.Range = .{ .start = removal + 2, .end = removal_end };
    const name = context.tokenText(removal);
    if (appended) {
        if (container_types.isOneOf(name, &.{ "pop", "shrinkRetainingCapacity", "shrinkAndFree", "clearRetainingCapacity", "clearAndFree" })) return true;
        if (!container_types.isOneOf(name, &.{ "orderedRemove", "swapRemove" })) return false;
        // `list.items.len - 1`
        const last = argument.start + length;
        return argument.end == last + 6 and context.dottedPathsEqual(receiver.start, receiver.end, argument.start, last) and
            tokens[last].tag == .period and context.tokenIs(last + 1, "items") and tokens[last + 2].tag == .period and
            context.tokenIs(last + 3, "len") and tokens[last + 4].tag == .minus and context.tokenIs(last + 5, "1");
    }
    if (!std.mem.startsWith(u8, context.tokenText(method_index), "put") or argument.start >= argument.end or
        !container_types.isOneOf(name, &.{ "remove", "swapRemove", "orderedRemove", "fetchRemove", "fetchSwapRemove", "fetchOrderedRemove" })) return false;
    const key = putKey(context, method_index + 1, call_end) orelse return false;
    return std.mem.eql(u8, context.argumentSource(key), context.argumentSource(argument));
}

/// The key argument of a `put(gpa, key, value)` or `put(key, value)` call.
fn putKey(context: RuleRun, opening: usize, closing: usize) ?tokens_util.Range {
    var previous: ?tokens_util.Range = null;
    var current: ?tokens_util.Range = null;
    var start = opening + 1;
    while (start < closing) {
        const argument_end = context.topLevelComma(start, closing) orelse closing;
        previous = current;
        current = .{ .start = start, .end = argument_end };
        start = argument_end + 1;
    }
    return previous;
}

/// The `catch` or `orelse` that starts a fallback at the top level of
/// `[start, end)`.
fn fallbackStart(context: RuleRun, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => index = context.scopes.matchingToken(index) orelse return null,
            .keyword_catch, .keyword_orelse => return index,
            else => {},
        }
    }
    return null;
}

/// The `{` of a struct or tuple literal `.{...}` or `Type{...}` at `start`.
fn literalOpening(context: RuleRun, start: usize, end: usize) ?usize {
    const tokens = context.tokens;
    if (start + 1 < end and tokens[start].tag == .period and tokens[start + 1].tag == .l_brace) return start + 1;
    var cursor = start;
    while (cursor < end and tokens[cursor].tag == .identifier) {
        if (cursor + 1 < end and tokens[cursor + 1].tag == .l_brace) return cursor + 1;
        if (cursor + 2 >= end or tokens[cursor + 1].tag != .period) return null;
        cursor += 2;
    }
    return null;
}

fn subscriptIsRange(context: RuleRun, opening: usize, closing: usize) bool {
    var index = opening + 1;
    while (index < closing) : (index += 1) {
        switch (context.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => index = context.scopes.matchingToken(index) orelse return false,
            .ellipsis2 => return true,
            else => {},
        }
    }
    return false;
}

/// Whether the identifier at `index` refers to a container-level `var` or
/// `const`, whose value outlives every call.
fn moduleBinding(context: RuleRun, index: usize) bool {
    const binding = context.scopes.findBinding(index) orelse return false;
    const declaration = binding.token_index;
    if (declaration == 0) return false;
    const keyword = context.tokens[declaration - 1].tag;
    return (keyword == .keyword_var or keyword == .keyword_const) and
        !context.scopes.insideFunctionOrTestBody(declaration);
}

/// Whether the receiver of the method at `method_index` is a standard
/// container that outlives the function: a parameter or module binding
/// declared with a container type, or such a field of one.
fn outlivingContainer(context: RuleRun, method_index: usize, function_scope: usize) bool {
    const tokens = context.tokens;
    if (method_index < 2 or tokens[method_index - 2].tag != .identifier) return false;
    var root = method_index - 2;
    if (root >= 2 and tokens[root - 1].tag == .period and tokens[root - 2].tag == .identifier) root -= 2;
    if (root >= 1 and tokens[root - 1].tag == .period) return false;
    const binding = context.scopes.findBinding(root) orelse return false;
    const declaration = binding.token_index;
    if (declaration + 2 >= tokens.len or declaration == 0) return false;
    const keyword = tokens[declaration - 1].tag;
    const declared = keyword == .keyword_var or keyword == .keyword_const;
    const parameter = !declared and declaration < function_scope and tokens[declaration + 1].tag == .colon;
    if (!parameter and !(declared and !context.scopes.insideFunctionOrTestBody(declaration))) return false;
    const type_range = bindingType(context, declaration) orelse return false;
    if (root == method_index - 2) {
        if (container_types.kindOfTypeStart(context.source, tokens, type_range.start, type_range.end) != null) return true;
        if (!declared) return false;
        const declaration_end = context.statementEnd(declaration - 1) orelse return false;
        return container_types.declaredKind(context.source, tokens, declaration - 1, declaration_end) != null;
    }
    const field_type = structFieldType(context, type_range, context.tokenText(method_index - 2)) orelse return false;
    return container_types.kindOfTypeStart(context.source, tokens, field_type.start, field_type.end) != null;
}

/// The type annotation of the parameter or declaration named at `name_index`.
fn bindingType(context: RuleRun, name_index: usize) ?tokens_util.Range {
    const tokens = context.tokens;
    if (name_index + 2 >= tokens.len or tokens[name_index + 1].tag != .colon) return null;
    var end = name_index + 2;
    while (end < tokens.len) : (end += 1) {
        switch (tokens[end].tag) {
            .l_paren, .l_bracket, .l_brace => end = context.scopes.matchingToken(end) orelse return null,
            .comma, .r_paren, .equal, .semicolon => break,
            else => {},
        }
    }
    return .{ .start = name_index + 2, .end = end };
}

/// The declared type of field `field` in the struct the type `[start, end)`
/// names through `*`, `const` and `@This()`, when this file declares it.
fn structFieldType(context: RuleRun, type_range: tokens_util.Range, field: []const u8) ?tokens_util.Range {
    const tokens = context.tokens;
    var name = type_range.start;
    while (name < type_range.end and (tokens[name].tag == .asterisk or tokens[name].tag == .keyword_const)) name += 1;
    if (name + 1 != type_range.end or tokens[name].tag != .identifier) return null;
    const type_binding = context.scopes.findBinding(name) orelse return null;
    const declaration = type_binding.token_index;
    if (declaration == 0 or tokens[declaration - 1].tag != .keyword_const or declaration + 3 >= tokens.len or
        tokens[declaration + 1].tag != .equal) return null;
    var body_start: usize = 0;
    var body_end = tokens.len;
    if (context.tokenIs(declaration + 2, "@This")) {
        if (context.enclosingOpeningBrace(declaration)) |opening| {
            body_start = opening + 1;
            body_end = context.matchingToken(opening, .l_brace, .r_brace) orelse return null;
        }
    } else {
        var cursor = declaration + 2;
        if (tokens[cursor].tag == .keyword_extern or tokens[cursor].tag == .keyword_packed) cursor += 1;
        if (tokens[cursor].tag != .keyword_struct or cursor + 1 >= tokens.len or tokens[cursor + 1].tag != .l_brace) return null;
        body_start = cursor + 2;
        body_end = context.matchingToken(cursor + 1, .l_brace, .r_brace) orelse return null;
    }
    // Only the struct's own members: nested bodies are skipped whole.
    var index = body_start;
    while (index < body_end) : (index += 1) {
        switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => index = context.scopes.matchingToken(index) orelse return null,
            .identifier => {
                if (!context.tokenIs(index, field) or index + 2 >= body_end or tokens[index + 1].tag != .colon) continue;
                if (index > body_start) switch (tokens[index - 1].tag) {
                    .l_brace, .r_brace, .comma, .semicolon, .doc_comment, .container_doc_comment => {},
                    else => continue,
                };
                return bindingType(context, index);
            },
            else => {},
        }
    }
    return null;
}

/// Whether `index` sits in a `comptime { ... }` or `comptime label: { ... }`
/// block of the function body opening at `function_scope`.
fn insideComptimeBlock(context: RuleRun, index: usize, function_scope: usize) bool {
    const tokens = context.tokens;
    var brace = context.enclosingOpeningBrace(index);
    while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
        if (opening <= function_scope) return false;
        const block = if (opening >= 3 and tokens[opening - 1].tag == .colon and tokens[opening - 2].tag == .identifier) opening - 2 else opening;
        if (block > 0 and tokens[block - 1].tag == .keyword_comptime) return true;
    }
    return false;
}

fn findReturnedLocalPointers(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    var functions: FunctionAddresses = .{};
    defer functions.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag == .keyword_fn and context.isNamedFunction(declaration_index)) {
            try findReturnedParameterAddresses(context, &functions, level, declaration_index);
            continue;
        }
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !context.scopes.insideFunctionOrTestBody(declaration_index)) continue;
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declarationStoresPointer(context, declaration_index, declaration_end)) continue;
        const function_scope = context.scopes.enclosingFunctionBody(declaration_index) orelse continue;
        if (insideComptimeBlock(context, declaration_index, function_scope)) continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        const returns = try functions.of(context, function_scope, function_end, collectReturnedAddresses);
        for (returns.named(binding_name)) |returned| {
            if (returned.site <= declaration_end) continue;
            const address_index = returned.address;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[address_index + 1].loc,
                .message = try context.allocator.print(
                    "returned value stores a pointer to local binding '{s}', whose storage expires when the function returns",
                    .{binding_name},
                ),
            });
        }
    }
}

/// `return &value;` or `return .{ .ptr = &value };` for a runtime parameter:
/// the parameter is the callee's own copy, which expires when it returns. A
/// projection such as `&value.field` is left out, since through a pointer
/// type it addresses the caller's memory instead.
fn findReturnedParameterAddresses(
    context: RuleRun,
    functions: *FunctionAddresses,
    level: types.Level,
    fn_index: usize,
) !void {
    const tokens = context.tokens;
    const function = context.functionRange(fn_index) orelse return;
    if (context.scopes.enclosingFunctionBody(function.body_start + 1) != function.body_start) return;
    var returns: ?*const FunctionAddresses.Addresses = null;
    var depth: usize = 0;
    for (tokens[function.parameters_start + 1 .. function.parameters_end], function.parameters_start + 1..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        }
        if (depth != 0 or token.tag != .identifier or tokens[index + 1].tag != .colon) continue;
        // A `comptime` parameter is a compile-time value, not stack storage.
        switch (tokens[index - 1].tag) {
            .l_paren, .comma, .keyword_noalias => {},
            else => continue,
        }
        const name = context.tokenText(index);
        const addresses = returns orelse try functions.of(context, function.body_start, function.body_end, collectReturnedAddresses);
        returns = addresses;
        for (addresses.named(name)) |returned| {
            const after = returned.address + 2;
            if (after < tokens.len and (tokens[after].tag == .period or tokens[after].tag == .l_bracket or
                tokens[after].tag == .period_asterisk)) continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = tokens[returned.address + 1].loc,
                .message = try context.allocator.print(
                    "returned value holds the address of parameter '{s}', a copy that expires when the function returns",
                    .{name},
                ),
            });
        }
    }
}

fn findRetainedLocalPointers(context: RuleRun) !void {
    const level = context.level(.local_storage_escape);
    if (level == .off) return;
    var functions: FunctionAddresses = .{};
    defer functions.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 1 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            !context.scopes.insideFunctionOrTestBody(declaration_index)) continue;
        if (declaration_index > 0 and context.tokens[declaration_index - 1].tag == .keyword_comptime) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (declarationStoresPointer(context, declaration_index, declaration_end)) continue;
        const function_scope = context.scopes.enclosingFunctionBody(declaration_index) orelse continue;
        const function_end = context.matchingToken(function_scope, .l_brace, .r_brace) orelse continue;
        const local_name = context.tokenText(declaration_index + 1);
        const retaining = try functions.of(context, function_scope, function_end, collectRetainedAddresses);
        for (retaining.named(local_name)) |retained| {
            const method_index = retained.site;
            if (method_index <= declaration_end) continue;
            const address_index = retained.address;
            const call_end = context.scopes.matchingToken(method_index + 1).?;
            if (deferredRemovalOfBinding(context, local_name, function_scope, call_end + 1, function_end)) continue;
            try context.emit(.{
                .rule = .local_storage_escape,
                .level = level,
                .span = context.tokens[address_index + 1].loc,
                .message = try context.allocator.print(
                    "pointer to local binding '{s}' is retained by {s} beyond the binding's lifetime",
                    .{ local_name, context.tokenText(method_index) },
                ),
            });
            break;
        }
    }
}

/// Per function body, where it hands on the address of a binding: the first
/// `&name` per name in each `return` (`returnedAddressOfBinding`), or in each
/// call that retains it beyond the function (`argumentAddressOfBinding`).
/// Built once per body, so a binding's checks look up its own name instead of
/// rescanning the rest of the function.
const FunctionAddresses = struct {
    bodies: std.AutoHashMapUnmanaged(usize, Addresses) = .empty,

    /// A `return` or retaining call at `site` handing on the binding whose
    /// name follows the `&` at `address`.
    const Address = struct { site: usize, address: usize };

    const Addresses = struct {
        by_name: std.StringHashMapUnmanaged(std.ArrayList(Address)) = .empty,

        fn named(addresses: *const Addresses, name: []const u8) []const Address {
            return if (addresses.by_name.get(name)) |list| list.items else &.{};
        }

        fn add(addresses: *Addresses, allocator: std.mem.Allocator, name: []const u8, found: Address) !void {
            const entry = try addresses.by_name.getOrPut(allocator, name);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(allocator, found);
        }
    };

    fn deinit(functions: *FunctionAddresses, allocator: std.mem.Allocator) void {
        var bodies = functions.bodies.valueIterator();
        while (bodies.next()) |addresses| {
            var lists = addresses.by_name.valueIterator();
            while (lists.next()) |list| list.deinit(allocator);
            addresses.by_name.deinit(allocator);
        }
        functions.bodies.deinit(allocator);
    }

    fn of(
        functions: *FunctionAddresses,
        context: RuleRun,
        function_scope: usize,
        function_end: usize,
        comptime collect: fn (RuleRun, usize, usize, *Addresses) anyerror!void,
    ) !*const Addresses {
        const entry = try functions.bodies.getOrPut(context.allocator, function_scope);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
            try collect(context, function_scope, function_end, entry.value_ptr);
        }
        return entry.value_ptr;
    }
};

/// The returns of the function body `function_scope` itself, in order, with
/// the address each returns per name, as `returnedAddressOfBinding` finds it.
fn collectReturnedAddresses(
    context: RuleRun,
    function_scope: usize,
    function_end: usize,
    addresses: *FunctionAddresses.Addresses,
) !void {
    const tokens = context.tokens;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(context.allocator);
    // Every `return` asks for its statement's end, and each prong of a long
    // `switch` scans the rest of it; once the scans have read the body's
    // length, the ends of the whole body are found in one pass.
    var statement_ends: ?syntax_scope.StatementEnds = null;
    defer if (statement_ends) |*ends| ends.deinit(context.allocator);
    var scanned: usize = 0;
    for (tokens[function_scope + 1 .. function_end], function_scope + 1..) |candidate, return_index| {
        if (candidate.tag != .keyword_return or context.scopes.enclosingFunctionBody(return_index) != function_scope) continue;
        if (statement_ends == null and scanned > function_end - function_scope) {
            statement_ends = try context.scopes.statementEndsIn(context.allocator, function_scope);
        }
        const found_end = if (statement_ends) |ends| ends.at(context.scopes, return_index) else context.statementEnd(return_index);
        if (statement_ends == null) scanned += (found_end orelse function_end) -| return_index;
        const return_end = found_end orelse continue;
        const start = return_index + 1;
        names.clearRetainingCapacity();
        if (start + 1 < return_end and tokens[start].tag == .ampersand) {
            try names.append(context.allocator, context.tokenText(start + 1));
            try addresses.add(context.allocator, context.tokenText(start + 1), .{ .site = return_index, .address = start });
        }
        var saw_initializer = false;
        var parenthesis_depth: usize = 0;
        for (tokens[start..return_end], start..) |token, index| {
            if (token.tag == .l_brace) saw_initializer = true;
            if (token.tag == .l_paren) {
                if (!saw_initializer) break;
                parenthesis_depth += 1;
            }
            if (token.tag == .r_paren) parenthesis_depth -|= 1;
            if (!saw_initializer or parenthesis_depth != 0 or token.tag != .ampersand or index + 1 >= return_end) continue;
            const name = context.tokenText(index + 1);
            if (containsName(names.items, name)) continue;
            try names.append(context.allocator, name);
            try addresses.add(context.allocator, name, .{ .site = return_index, .address = index });
        }
    }
}

/// The calls in `function_scope` that retain an argument in a parameter or
/// module container with no deferred removal, in order, with the address
/// each passes per name, as `argumentAddressOfBinding` finds it.
fn collectRetainedAddresses(
    context: RuleRun,
    function_scope: usize,
    function_end: usize,
    addresses: *FunctionAddresses.Addresses,
) !void {
    const tokens = context.tokens;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(context.allocator);
    for (tokens[function_scope + 1 .. function_end], function_scope + 1..) |candidate, method_index| {
        if (candidate.tag != .identifier or method_index < 2 or tokens[method_index - 1].tag != .period or
            tokens[method_index + 1].tag != .l_paren or !retainingMethod(context, method_index)) continue;
        if (context.tokenIs(method_index - 2, "self")) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        const receiver_root = callReceiverRoot(context, method_index) orelse continue;
        const retained_outside_scope = functionParameterExists(context, function_scope, context.tokenText(receiver_root)) or
            moduleBinding(context, receiver_root);
        if (!retained_outside_scope or deferredRemoval(context, method_index, call_end)) continue;
        names.clearRetainingCapacity();
        const start = method_index + 2;
        var index = start;
        while (index < call_end) : (index += 1) {
            const token = tokens[index];
            if (token.tag == .l_paren and index > start) switch (tokens[index - 1].tag) {
                .identifier, .r_paren, .r_bracket => {
                    index = context.matchingToken(index, .l_paren, .r_paren) orelse break;
                    continue;
                },
                else => {},
            };
            if (token.tag != .ampersand or index + 1 >= call_end) continue;
            const name = context.tokenText(index + 1);
            if (containsName(names.items, name)) continue;
            try names.append(context.allocator, name);
            try addresses.add(context.allocator, name, .{ .site = method_index, .address = index });
        }
    }
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

fn declarationStoresPointer(context: RuleRun, declaration_index: usize, declaration_end: usize) bool {
    if (declaration_index + 2 < declaration_end and context.tokens[declaration_index + 2].tag == .colon) {
        for (context.tokens[declaration_index + 3 .. declaration_end]) |token| {
            if (token.tag == .equal) break;
            if (token.tag == .asterisk) return true;
        }
    }
    return initializedByAllocatorCreate(context, declaration_index, declaration_end);
}

fn initializedByAllocatorCreate(context: RuleRun, declaration_index: usize, declaration_end: usize) bool {
    for (context.tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |token, create_index| {
        if (token.tag == .identifier and context.tokenIs(create_index, "create") and
            create_index > declaration_index + 2 and context.tokens[create_index - 1].tag == .period and
            context.tokens[create_index - 2].tag == .identifier and create_index + 1 < declaration_end and
            context.tokens[create_index + 1].tag == .l_paren)
        {
            const receiver = context.tokenText(create_index - 2);
            if (std.ascii.findIgnoreCase(receiver, "alloc") != null or
                std.ascii.findIgnoreCase(receiver, "arena") != null or
                std.mem.eql(u8, receiver, "gpa")) return true;
        }
    }
    return false;
}

fn deferredRemovalOfBinding(context: RuleRun, name: []const u8, scope: usize, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer or context.enclosingOpeningBrace(defer_index) != scope) continue;
        const statement_end = context.statementEnd(defer_index) orelse continue;
        if (statement_end > end) continue;
        for (context.tokens[defer_index + 1 .. statement_end], defer_index + 1..) |candidate, remove_index| {
            if (candidate.tag != .identifier or !context.tokenIs(remove_index, "remove") or
                remove_index + 1 >= statement_end or context.tokens[remove_index + 1].tag != .l_paren) continue;
            const call_end = context.matchingToken(remove_index + 1, .l_paren, .r_paren) orelse continue;
            if (call_end <= statement_end and addressOfBinding(context, name, remove_index + 2, call_end) != null) return true;
        }
    }
    return false;
}

fn retainingMethod(context: RuleRun, method_index: usize) bool {
    const methods = [_][]const u8{
        "append",
        "appendAssumeCapacity",
        "insert",
        "insertAssumeCapacity",
        "put",
        "putNoClobber",
        "putAssumeCapacity",
        "putAssumeCapacityNoClobber",
    };
    for (methods) |method| if (context.tokenIs(method_index, method)) return true;
    return false;
}

fn callReceiverRoot(context: RuleRun, method_index: usize) ?usize {
    if (method_index < 2 or context.tokens[method_index - 1].tag != .period or
        context.tokens[method_index - 2].tag != .identifier) return null;
    var root_index = method_index - 2;
    while (root_index >= 2 and context.tokens[root_index - 1].tag == .period and
        context.tokens[root_index - 2].tag == .identifier) root_index -= 2;
    return root_index;
}

fn addressOfBinding(context: RuleRun, name: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .ampersand and index + 1 < end and context.tokenIs(index + 1, name)) return index;
    }
    return null;
}

/// Like `addressOfBinding`, but skips the arguments of nested calls: the
/// pointer is that call's input, and what reaches the outer call is its
/// result, such as the copy `bufPrint` returns a view of.
fn argumentAddressOfBinding(context: RuleRun, name: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        const token = context.tokens[index];
        if (token.tag == .l_paren and index > start) switch (context.tokens[index - 1].tag) {
            .identifier, .r_paren, .r_bracket => {
                index = context.matchingToken(index, .l_paren, .r_paren) orelse return null;
                continue;
            },
            else => {},
        };
        if (token.tag == .ampersand and index + 1 < end and context.tokenIs(index + 1, name)) return index;
    }
    return null;
}

fn isMainBody(context: RuleRun, body_opening: usize) bool {
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => return context.tokenIs(function_index + 1, "main"),
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn functionParameterExists(context: RuleRun, body_opening: usize, name: []const u8) bool {
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    } else return false;
    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    for (context.tokens[parameters_opening + 1 .. parameters_closing], parameters_opening + 1..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and
            index + 1 < parameters_closing and context.tokens[index + 1].tag == .colon) return true;
    }
    return false;
}

fn returnedAddressOfBinding(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    if (start + 1 < end and context.tokens[start].tag == .ampersand and context.tokenIs(start + 1, binding)) return start;
    var saw_initializer = false;
    var parenthesis_depth: usize = 0;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .l_brace) saw_initializer = true;
        if (token.tag == .l_paren) {
            if (!saw_initializer) return null;
            parenthesis_depth += 1;
        }
        if (token.tag == .r_paren) parenthesis_depth -|= 1;
        if (saw_initializer and parenthesis_depth == 0 and token.tag == .ampersand and
            index + 1 < end and context.tokenIs(index + 1, binding)) return index;
    }
    return null;
}

fn enclosingFunctionHasOnlyComptimeParameters(context: RuleRun, declaration_index: usize) bool {
    const body_opening = context.enclosingOpeningBrace(declaration_index) orelse return false;
    const function_index = context.scopes.functionKeyword(body_opening) orelse return false;

    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    if (parameters_closing == parameters_opening + 1) return false;

    var saw_parameter = false;
    var segment_has_comptime = false;
    var nested: usize = 0;
    for (context.tokens[parameters_opening + 1 .. parameters_closing]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => nested += 1,
            .r_paren, .r_bracket, .r_brace => nested -|= 1,
            .keyword_comptime => {
                if (nested == 0) segment_has_comptime = true;
            },
            .comma => if (nested == 0) {
                if (!segment_has_comptime) return false;
                saw_parameter = true;
                segment_has_comptime = false;
            },
            else => {},
        }
    }
    if (!segment_has_comptime) return false;
    return saw_parameter or segment_has_comptime;
}

fn constArrayIsStackStorage(
    context: RuleRun,
    declaration_index: usize,
    declaration_end: usize,
    function_scope: usize,
) bool {
    var init_index = declaration_index + 2;
    while (init_index < declaration_end and context.tokens[init_index].tag != .equal) : (init_index += 1) {}
    if (init_index >= declaration_end) return false;
    if (init_index + 1 < declaration_end and context.tokenIs(init_index + 1, "undefined")) return true;

    var brace_open = init_index + 1;
    while (brace_open < declaration_end and context.tokens[brace_open].tag != .l_brace) : (brace_open += 1) {}
    if (brace_open >= declaration_end) return false;
    const brace_close = context.matchingToken(brace_open, .l_brace, .r_brace) orelse return false;

    for (context.tokens[brace_open + 1 .. brace_close], brace_open + 1..) |tok, idx| {
        if (tok.tag == .l_paren and idx > brace_open + 1 and
            (context.tokens[idx - 1].tag == .identifier or context.tokens[idx - 1].tag == .r_paren))
        {
            return true;
        }
        if (tok.tag == .identifier) {
            const name = context.tokenText(idx);
            if (context.tokenIs(idx, "undefined")) return true;
            if (functionParameterExists(context, function_scope, name) and !isComptimeParameter(context, function_scope, name)) {
                return true;
            }
            if (context.rangeDeclaresName(name, function_scope + 1, declaration_index)) {
                return true;
            }
        }
    }
    return false;
}

fn isComptimeParameter(context: RuleRun, body_opening: usize, name: []const u8) bool {
    var function_index = body_opening;
    while (function_index > 0) {
        function_index -= 1;
        switch (context.tokens[function_index].tag) {
            .keyword_fn => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    } else return false;
    var parameters_opening = function_index + 1;
    while (parameters_opening < body_opening and context.tokens[parameters_opening].tag != .l_paren) : (parameters_opening += 1) {}
    if (parameters_opening == body_opening) return false;
    const parameters_closing = context.matchingToken(parameters_opening, .l_paren, .r_paren) orelse return false;
    for (context.tokens[parameters_opening + 1 .. parameters_closing], parameters_opening + 1..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) {
            if (index > parameters_opening + 1 and context.tokens[index - 1].tag == .keyword_comptime) return true;
        }
    }
    return false;
}

fn declarationStoresArray(context: RuleRun, declaration_index: usize, declaration_end: usize) bool {
    var index = declaration_index + 2;
    while (index < declaration_end) : (index += 1) {
        if (context.tokens[index].tag == .colon and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
        if (context.tokens[index].tag == .equal and index + 2 < declaration_end and
            context.tokens[index + 1].tag == .l_bracket and arrayLengthToken(context.tokens[index + 2].tag)) return true;
    }
    return false;
}

fn arrayLengthToken(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .number_literal, .identifier => true,
        else => false,
    };
}

test "returning a slice of a local array expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn bytes() []u8 { var local = [_]u8{ 1, 2 }; return local[0..]; }";
    const enabled = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), enabled.len);

    const disabled = try support.findings(arena.allocator(), run, source, support.only(&.{.returning_local_slice}, .off));
    try std.testing.expectEqual(@as(usize, 0), disabled.len);
}

test "labeled block aliases and returned interface pointers expire local storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn label(input: []const u8) []const u8 { const result = blk: { var scratch: [8]u8 = undefined; " ++
        "@memcpy(scratch[0..input.len], input); break :blk scratch[0..input.len]; }; return result; }\n" ++
        "fn interface() Interface { var local = Reader{}; return .{ .context = &local }; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqual(types.Rule.returning_local_slice, findings[0].rule);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings[1].rule);
}

test "passing a local pointer into a returned call result does not prove storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn completion() Result { var analyser = init(); defer analyser.deinit(); return .{ .list = build(&analyser) }; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "storing a local slice globally expires its backing array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var saved: []const u8 = &.{}; fn retain() void { var scratch = [_]u8{ 1, 2 }; saved = scratch[0..]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings[0].rule);
}

test "storing a local slice through an output parameter expires its backing array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn retain(output: *?[]const u8) void { var local: [8]u8 = undefined; output.* = local[1..]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings[0].rule);
}

test "retaining a local pointer in a parameter container expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn schedule(scheduler: *Scheduler) !void { var local = Context{};" ++
        "try scheduler.tasks.append(scheduler.allocator, .{ .context = &local }); }" ++
        "fn localOnly(allocator: anytype) !void { var local = Context{}; var tasks = Tasks.empty;" ++
        "try tasks.append(allocator, .{ .context = &local }); use(tasks); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings[0].rule);
}

test "fields of heap pointers and direct methods stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn field(self: *Owner, allocator: anytype) !*Value { var value: *Value = try allocator.create(Value); self.nodes.append(&value.node); return &value.payload; }" ++
        "fn inferred(allocator: anytype) !*Pragma { var pragma = try allocator.create(Owner); return &pragma.value; }" ++
        "fn edit(self: *Editor) !void { var cursor: Cursor = .{}; _ = try self.insert(self.root, &cursor, \"x\"); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .local_storage_escape);
}

test "returning the address of a runtime parameter expires its storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn direct(value: u32) *const u32 { return &value; }" ++
        "fn wrapped(value: u32) Holder { return .{ .ptr = &value }; }" ++
        "fn field(self: *Owner) *u32 { return &self.count; }" ++
        "fn element(items: []u32) *u32 { return &items[0]; }" ++
        "fn constant(comptime value: u32) *const u32 { return &value; }" ++
        "fn nested(value: u32) void { const inner = struct { fn get(other: u32) u32 { return other; } }; _ = inner.get(value); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| try std.testing.expectEqual(types.Rule.local_storage_escape, finding.rule);
}

test "deferred removal keeps an intrusive local node within its lifetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn wait(queue: *Queue) void { var pending: Pending = .{}; queue.append(&pending.node);" ++
        "defer if (pending.active) queue.remove(&pending.node); suspendUntilReady(&pending); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .local_storage_escape);
}

test "conditional deferred removal and custom create calls do not prove heap lifetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn retained(queue: *Queue, remove: bool) void { var pending: Pending = .{}; queue.append(&pending.node);" ++
        "if (remove) { defer queue.remove(&pending.node); } }" ++
        "fn custom(factory: *Factory) !*Value { var value = try factory.create(); return &value.payload; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    var escape_count: usize = 0;
    for (findings) |finding| if (finding.rule == .local_storage_escape) {
        escape_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), escape_count);
}

test "dereferencing the slice returns the array by value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn digest() [4]u8 { var buf = [_]u8{ 1, 2, 3, 4 }; return buf[0..4].*; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "comptime var arrays are interned and outlive the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn snake(comptime input: []const u8) []const u8 { comptime var output: [input.len * 2]u8 = undefined; return output[0..1]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "storage built in a labeled comptime block outlives the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn table(values: []const u8) []const u8 {\n" ++
        "    _ = values;\n" ++
        "    const result = comptime result: {\n" ++
        "        var result: [4]u8 = undefined;\n" ++
        "        @memset(&result, 0);\n" ++
        "        break :result result;\n" ++
        "    };\n" ++
        "    return &result;\n" ++
        "}\n";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "functions with only comptime parameters return promoted local slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn description(comptime input: []const u8) []const u8 { var output: [input.len]u8 = undefined; return output[0..1]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "comptime-only functions with braced return types return promoted local slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn named(comptime input: []const u8) struct { text: []const u8 } { var output: [input.len]u8 = undefined; return .{ .text = output[0..1] }; }\n" ++
        "fn checked(comptime input: []const u8) error{Empty}![]const u8 { var output: [input.len]u8 = undefined; return output[0..1]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a runtime parameter keeps local slice storage temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn bytes(comptime size: usize, fill: u8) []const u8 { var output: [size]u8 = undefined; output[0] = fill; return output[0..1]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "heap-backed slices and local array values do not warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn heap(allocator: std.mem.Allocator) ![]u8 { var bytes: []u8 = try allocator.alloc(u8, 2); return bytes; }\n" ++
        "fn value() [2]u8 { var local = [_]u8{ 1, 2 }; return local; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "returning a slice of a const stack array or from inside a conditional reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn constRuntime(val: u8) []const u8 { const local = [_]u8{ val, 1 }; return local[0..]; }\n" ++
        "fn sliceIf(cond: bool) []u8 { var local: [4]u8 = undefined; if (cond) { return local[0..]; } return local[1..]; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 3), findings.len);
}

test "formatting results and fixed writers over a local array are views of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn direct(v: u32) ![]const u8 { var buf: [8]u8 = undefined; return std.fmt.bufPrint(&buf, \"{d}\", .{v}); }\n" ++
        "fn bound(v: u32) ![]const u8 { var buf: [8]u8 = undefined; const text = try std.mem.print(buf[0..], \"{d}\", .{v}); return text; }\n" ++
        "fn either(v: u32, f: bool) ![]const u8 { var buf: [8]u8 = undefined;" ++
        " const text = if (f) try std.fmt.bufPrint(&buf, \"{d}\", .{v}) else \"-\"; return text; }\n" ++
        "fn writer(v: u32) ![]const u8 { var buf: [8]u8 = undefined; var w: std.Io.Writer = .fixed(&buf);" ++
        " try w.print(\"{d}\", .{v}); return w.buffered(); }\n" ++
        "fn outer(v: u32) ![]const u8 { var text: []const u8 = \"\";" ++
        " { var buf: [8]u8 = undefined; text = try std.fmt.bufPrint(&buf, \"{d}\", .{v}); } return text; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| try std.testing.expectEqual(types.Rule.returning_local_slice, finding.rule);
}

test "a returned file writer or reader over a local array escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn direct(io: std.Io) std.Io.File.Writer { var buf: [64]u8 = undefined; return std.Io.File.stdout().writer(io, &buf); }\n" ++
        "fn bound(io: std.Io, file: std.Io.File) std.Io.File.Reader { var buf: [64]u8 = undefined; const r = file.reader(io, &buf); return r; }\n" ++
        "fn borrowed(io: std.Io, buf: []u8) std.Io.File.Writer { return std.Io.File.stdout().writer(io, buf); }\n" ++
        "fn flushed(io: std.Io) !void { var buf: [64]u8 = undefined; var w = std.Io.File.stdout().writer(io, &buf);" ++
        " try w.interface.writeAll(\"x\"); try w.interface.flush(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| try std.testing.expectEqual(types.Rule.local_storage_escape, finding.rule);
}

test "views held by a returned aggregate, module state or an outliving container escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var last: []const u8 = \"\";\n" ++
        "const Names = struct { list: std.ArrayList([]const u8),\n" ++
        "    fn add(self: *Names, gpa: Allocator, v: u32) !void { var buf: [8]u8 = undefined;" ++
        " const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v}); try self.list.append(gpa, text); } };\n" ++
        "fn aggregate(v: u32) !Named { var buf: [8]u8 = undefined; const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v});" ++
        " return .{ .name = text }; }\n" ++
        "fn global(v: u32) !void { var buf: [8]u8 = undefined; last = try std.fmt.bufPrint(&buf, \"{d}\", .{v}); }\n" ++
        "fn key(map: *std.StringHashMapUnmanaged(u32), gpa: Allocator, v: u32) !void { var buf: [8]u8 = undefined;" ++
        " const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v}); try map.put(gpa, text, v); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    for (findings) |finding| try std.testing.expectEqual(types.Rule.local_storage_escape, finding.rule);
}

test "copies, lengths, element values and copying callees of local views stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(gpa: Allocator, v: u32) ![]u8 { var buf: [8]u8 = undefined;" ++
        " var text: []const u8 = try std.fmt.bufPrint(&buf, \"{d}\", .{v}); text = try gpa.dupe(u8, text); return text; }\n" ++
        "fn length(v: u32) !Count { var buf: [8]u8 = undefined; const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v});" ++
        " return .{ .count = text.len }; }\n" ++
        "fn chained() Atlas { var bits: [6]u8 = undefined; @memset(&bits, 0); const atlas: Atlas = .{ .first = bits[0..][0..3].* };" ++
        " return atlas; }\n" ++
        "fn opened(lib: Lib) !Face { var buf: [64]u8 = undefined; buf[0] = 0; var face = try Face.initFile(lib, buf[0..1 :0]);" ++
        " errdefer face.deinit(); return face; }\n" ++
        "fn encode(encoder: *Encoder, v: u32) void { var buf: [8]u8 = undefined;" ++
        " encoder.put(\"key\", .{ .string = std.fmt.bufPrint(&buf, \"{d}\", .{v}) catch unreachable }); }\n" ++
        "fn intern(map: *std.StringHashMapUnmanaged(u32), gpa: Allocator, v: u32) !void { var buf: [8]u8 = undefined;" ++
        " const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v});" ++
        " const gop = try map.getOrPut(gpa, text); if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, text); }\n" ++
        "fn entries(comptime n: usize) []const Count { comptime { var all: [n]Count = undefined;" ++
        " for (&all, 0..) |*e, i| e.* = .{ .count = i }; return &all; } }\n" ++
        "var program_name: []const u8 = \"\";\n" ++
        "pub fn main() !void { var buf: [8]u8 = undefined; program_name = try std.fmt.bufPrint(&buf, \"{d}\", .{1}); run(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a deferred pop or removal in the appending block keeps a local view within its lifetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const owner = "const S = struct { list: std.ArrayList([]const u8), map: std.StringHashMapUnmanaged(u32), gpa: Allocator };\n";
    const source: [:0]const u8 = owner ++
        "fn pop(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); defer _ = s.list.pop(); try g(); }\n" ++
        "fn shrink(s: *S, n: usize) !void { var buf: [8]u8 = undefined; const len = s.list.items.len;" ++
        " try s.list.append(s.gpa, buf[0..n]); defer s.list.shrinkRetainingCapacity(len); try g(); }\n" ++
        "fn length(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); defer s.list.items.len -= 1; try g(); }\n" ++
        "fn last(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]);" ++
        " defer _ = s.list.orderedRemove(s.list.items.len - 1); try g(); }\n" ++
        "fn key(s: *S, v: u32) !void { var buf: [8]u8 = undefined; const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v});" ++
        " try s.map.put(s.gpa, text, v); defer _ = s.map.remove(text); try g(); }\n" ++
        "fn labeled(s: *S, n: usize) !u8 { return blk: { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]);" ++
        " defer _ = s.list.pop(); break :blk try g(); }; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "an errdefer, a later or nested deferred removal, or another target still escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const owner = "const S = struct { list: std.ArrayList([]const u8), map: std.StringHashMapUnmanaged(u32), gpa: Allocator };\n";
    const source: [:0]const u8 = owner ++
        "fn errPop(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); errdefer _ = s.list.pop(); try g(); }\n" ++
        "fn late(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); try g(); defer _ = s.list.pop(); }\n" ++
        "fn other(s: *S, o: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); defer _ = o.list.pop(); }\n" ++
        "fn first(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); defer _ = s.list.orderedRemove(0); }\n" ++
        "fn nested(s: *S, n: usize) !void { var buf: [8]u8 = undefined; try s.list.append(s.gpa, buf[0..n]); { defer _ = s.list.pop(); } }\n" ++
        "fn guarded(s: *S, n: usize, c: bool) !void { var buf: [8]u8 = undefined; if (c) try s.list.append(s.gpa, buf[0..n]); defer _ = s.list.pop(); }\n" ++
        "fn key(s: *S, v: u32) !void { var buf: [8]u8 = undefined; const text = try std.fmt.bufPrint(&buf, \"{d}\", .{v});" ++
        " try s.map.put(s.gpa, text, v); defer _ = s.map.remove(\"other\"); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 7), findings.len);
    for (findings) |finding| try std.testing.expectEqual(types.Rule.local_storage_escape, finding.rule);
}

test "a deferred pop also pairs with a retained pointer to a local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn scoped(stack: *std.ArrayList(*Frame), gpa: Allocator) !void { var frame: Frame = .{}; try stack.append(gpa, &frame);" ++
        " defer _ = stack.pop(); try g(); }\n" ++
        "fn kept(stack: *std.ArrayList(*Frame), gpa: Allocator) !void { var frame: Frame = .{}; try stack.append(gpa, &frame); try g(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.local_storage_escape, findings[0].rule);
}

test "address tables of a function body agree with the scans per binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 =
        \\var registry: std.ArrayList(*u8) = .empty;
        \\fn run(list: *std.ArrayList(*u8), gpa: std.mem.Allocator, flag: bool) !Pair {
        \\    var x: u8 = 0;
        \\    var y: u8 = 1;
        \\    try list.append(gpa, &x);
        \\    try registry.append(gpa, wrap(&y), &x);
        \\    try self.list.append(gpa, &y);
        \\    try list.put(gpa, &x, &y);
        \\    const inner = struct { fn f() *u8 { var z: u8 = 0; return &z; } };
        \\    _ = inner;
        \\    if (flag) return &y;
        \\    if (x == 0) return .{ .first = &x, .second = &y, .third = call(&x), .fourth = &x };
        \\    return pair(&x, &y);
        \\}
        \\
    ;
    const tokens = try tokens_util.tokenize(allocator, source);
    var syntax = try @import("../context.zig").Syntax.init(allocator, source, tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    const context = syntax.ruleRun(allocator, types.Configuration.defaults(), &found);
    var bodies: usize = 0;
    for (tokens, 0..) |token, body| {
        if (token.tag != .l_brace or context.scopes.enclosingFunctionBody(body + 1) != body) continue;
        bodies += 1;
        const body_end = context.matchingToken(body, .l_brace, .r_brace).?;
        var returned: FunctionAddresses.Addresses = .{};
        try collectReturnedAddresses(context, body, body_end, &returned);
        var retained: FunctionAddresses.Addresses = .{};
        try collectRetainedAddresses(context, body, body_end, &retained);
        var returns: usize = 0;
        var calls: usize = 0;
        for (tokens[body + 1 .. body_end], body + 1..) |site_token, site| {
            if (site_token.tag != .identifier and site_token.tag != .keyword_return) continue;
            for ([_][]const u8{ "x", "y", "z", "gpa", "flag" }) |name| {
                if (site_token.tag == .keyword_return) {
                    if (context.scopes.enclosingFunctionBody(site) != body) continue;
                    const expected = returnedAddressOfBinding(context, name, site + 1, context.statementEnd(site).?);
                    try std.testing.expectEqual(expected, addressAt(returned.named(name), site));
                    if (expected != null) returns += 1;
                } else if (addressAt(retained.named(name), site)) |address| {
                    const call_end = context.matchingToken(site + 1, .l_paren, .r_paren).?;
                    try std.testing.expectEqual(argumentAddressOfBinding(context, name, site + 2, call_end), address);
                    calls += 1;
                }
            }
        }
        if (bodies == 1) {
            // `return &y`, `.first` and `.second`; `&x` and `&y` passed to the
            // parameter and module lists directly, not through `wrap` or `self`.
            try std.testing.expectEqual(@as(usize, 3), returns);
            try std.testing.expectEqual(@as(usize, 4), calls);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), bodies);
}

fn addressAt(addresses: []const FunctionAddresses.Address, site: usize) ?usize {
    for (addresses) |address| if (address.site == site) return address.address;
    return null;
}
