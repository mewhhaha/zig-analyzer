const std = @import("std");
const tokenize = @import("tokens.zig").tokenize;
const tokenText = @import("tokens.zig").tokenText;
const tokenIs = @import("tokens.zig").tokenIs;
const identifierName = @import("tokens.zig").identifierName;
const enclosingOpeningBrace = @import("tokens.zig").enclosingOpeningBrace;
const matchingToken = @import("tokens.zig").matchingToken;

pub const BindingKind = enum {
    callable,
    non_callable,
    unknown,
};

pub const Binding = struct {
    token_index: usize,
    scope: std.zig.Token.Loc,
    kind: BindingKind,
    alias_target: ?[]const u8 = null,
    scope_rank: usize = 0,
};

pub const none_token: u32 = std.math.maxInt(u32);
/// A `LexicalScope.parenthesis` left to the backward scan.
const unknown_token: u32 = none_token - 1;

const LexicalScope = struct {
    opening: ?usize,
    closing: usize,
    /// What `enclosingOpeningParenthesis` returns for the token (`none_token`
    /// for null), so finding parameters does not scan back over every field
    /// of a container; `unknown_token` when the scan has to tell.
    parenthesis: u32 = unknown_token,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    bindings: std.StringHashMapUnmanaged(std.ArrayList(Binding)) = .empty,
    usingnamespace_scopes: std.ArrayList(std.zig.Token.Loc) = .empty,
    matching_tokens: []u32 = &.{},
    enclosing_braces: []u32 = &.{},
    /// Every named `fn` declaration with a body, sorted by the body's `{`.
    function_bodies: []FunctionBody = &.{},
    /// Built by the first `identifiers` call; most indexes never need it.
    identifier_table: std.atomic.Value(?*IdentifierTable) = .init(null),

    pub const FunctionBody = struct { keyword: u32, body: u32 };

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: []const std.zig.Token,
    ) !Index {
        var index: Index = .{ .allocator = allocator, .source = source, .tokens = tokens };
        errdefer index.deinit();
        var scope_openings: std.ArrayList(u32) = .empty;
        defer scope_openings.deinit(allocator);
        try scope_openings.ensureTotalCapacity(allocator, 32);
        var parenthesis_openings: std.ArrayList(u32) = .empty;
        defer parenthesis_openings.deinit(allocator);
        try parenthesis_openings.ensureTotalCapacity(allocator, 32);
        var bracket_openings: std.ArrayList(u32) = .empty;
        defer bracket_openings.deinit(allocator);
        try bracket_openings.ensureTotalCapacity(allocator, 32);
        index.matching_tokens = try allocator.alloc(u32, tokens.len);
        @memset(index.matching_tokens, none_token);
        index.enclosing_braces = try allocator.alloc(u32, tokens.len);
        @memset(index.enclosing_braces, none_token);
        for (tokens, 0..) |token, token_index| switch (token.tag) {
            .l_brace => if (token_index <= std.math.maxInt(u32)) try scope_openings.append(allocator, @intCast(token_index)),
            .r_brace => if (scope_openings.pop()) |opening| {
                if (token_index <= std.math.maxInt(u32)) {
                    index.matching_tokens[opening] = @intCast(token_index);
                    index.matching_tokens[token_index] = opening;
                }
            },
            .l_paren => if (token_index <= std.math.maxInt(u32)) try parenthesis_openings.append(allocator, @intCast(token_index)),
            .r_paren => if (parenthesis_openings.pop()) |opening| {
                if (token_index <= std.math.maxInt(u32)) {
                    index.matching_tokens[opening] = @intCast(token_index);
                    index.matching_tokens[token_index] = opening;
                }
            },
            .l_bracket => if (token_index <= std.math.maxInt(u32)) try bracket_openings.append(allocator, @intCast(token_index)),
            .r_bracket => if (bracket_openings.pop()) |opening| {
                if (token_index <= std.math.maxInt(u32)) {
                    index.matching_tokens[opening] = @intCast(token_index);
                    index.matching_tokens[token_index] = opening;
                }
            },
            else => {},
        };
        scope_openings.clearRetainingCapacity();
        var parentheses: ParenthesisTracker = .{ .nested = tokens.len < unknown_token };
        defer parentheses.groups.deinit(allocator);
        try parentheses.groups.ensureTotalCapacity(allocator, 32);
        for (tokens, 0..) |token, token_index| {
            // Only `name:`, a parameter candidate, reads it.
            const parenthesis = if (token.tag == .identifier and token_index + 1 < tokens.len and
                tokens[token_index + 1].tag == .colon) parentheses.current() else unknown_token;
            try parentheses.step(allocator, token.tag, token_index);
            if (token.tag == .r_brace) _ = scope_openings.pop();
            index.enclosing_braces[token_index] = if (scope_openings.last()) |opening|
                opening
            else
                none_token;
            if (token.tag == .identifier) {
                const lexical_scope: LexicalScope = if (scope_openings.last()) |opening|
                    .{ .opening = opening, .closing = index.matchingToken(opening) orelse tokens.len - 1, .parenthesis = parenthesis }
                else
                    .{ .opening = null, .closing = tokens.len - 1, .parenthesis = parenthesis };
                if (bindingWithIndex(tokens, source, token_index, lexical_scope, &index)) |unindexed_candidate| {
                    var candidate = unindexed_candidate;
                    candidate.alias_target = aliasTarget(source, tokens, token_index);
                    candidate.scope_rank = if (scope_openings.last()) |opening| opening + 1 else 0;
                    const entry = try index.bindings.getOrPut(allocator, identifierName(tokenText(source, token)));
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(allocator, candidate);
                }
            }
            if (token.tag == .identifier and token.loc.end - token.loc.start == 14 and std.mem.eql(u8, tokenText(source, token), "usingnamespace")) {
                const lexical_scope: LexicalScope = if (scope_openings.last()) |opening|
                    .{ .opening = opening, .closing = index.matchingToken(opening) orelse tokens.len - 1 }
                else
                    .{ .opening = null, .closing = tokens.len - 1 };
                const scope = declarationScopeWithIndex(tokens, token_index, true, lexical_scope, &index) orelse continue;
                try index.usingnamespace_scopes.append(allocator, scope);
            }
            if (token.tag == .l_brace and token_index <= std.math.maxInt(u32)) try scope_openings.append(allocator, @intCast(token_index));
        }
        var function_bodies: std.ArrayList(FunctionBody) = .empty;
        errdefer function_bodies.deinit(allocator);
        for (tokens, 0..) |token, keyword| {
            if (token.tag != .keyword_fn or keyword + 2 >= tokens.len or tokens[keyword + 1].tag != .identifier or
                tokens[keyword + 2].tag != .l_paren or keyword > std.math.maxInt(u32)) continue;
            const parameters_end = index.matchingToken(keyword + 2) orelse continue;
            const body = functionBodyAfterParametersWithIndex(tokens, parameters_end, &index) orelse continue;
            try function_bodies.append(allocator, .{ .keyword = @intCast(keyword), .body = @intCast(body) });
        }
        // A function declared inside another's return type has its body first.
        std.mem.sort(FunctionBody, function_bodies.items, {}, struct {
            fn lessThan(_: void, left: FunctionBody, right: FunctionBody) bool {
                return left.body < right.body;
            }
        }.lessThan);
        index.function_bodies = try function_bodies.toOwnedSlice(allocator);
        var binding_lists = index.bindings.valueIterator();
        while (binding_lists.next()) |bindings| {
            std.mem.sort(Binding, bindings.items, {}, struct {
                fn lessThan(_: void, left: Binding, right: Binding) bool {
                    if (left.scope.start != right.scope.start) return left.scope.start < right.scope.start;
                    if (left.scope.end != right.scope.end) return left.scope.end > right.scope.end;
                    return left.token_index < right.token_index;
                }
            }.lessThan);
        }
        return index;
    }

    pub fn deinit(index: *Index) void {
        var iterator = index.bindings.valueIterator();
        while (iterator.next()) |bindings| bindings.deinit(index.allocator);
        index.bindings.deinit(index.allocator);
        index.usingnamespace_scopes.deinit(index.allocator);
        index.allocator.free(index.matching_tokens);
        index.allocator.free(index.enclosing_braces);
        index.allocator.free(index.function_bodies);
        if (index.identifier_table.load(.acquire)) |table| {
            table.deinit(index.allocator);
            index.allocator.destroy(table);
        }
    }

    /// The file's identifiers by spelling, built by the first caller. Threads
    /// sharing an index may race to build it; the first table published wins.
    pub fn identifiers(index: *const Index) !*const IdentifierTable {
        // The table is a cache: filling it does not change what the index answers.
        const slot = &@constCast(index).identifier_table;
        if (slot.load(.acquire)) |table| return table;
        const table = try index.allocator.create(IdentifierTable);
        errdefer index.allocator.destroy(table);
        table.* = try .init(index.allocator, index.source, index.tokens);
        if (slot.cmpxchgStrong(null, table, .acq_rel, .acquire)) |published| {
            table.deinit(index.allocator);
            index.allocator.destroy(table);
            return published.?;
        }
        return table;
    }

    /// The identifiers spelled exactly `name` in `[start, end)`, in token
    /// order: looked up in the identifier table once `identifiers` has built
    /// it, and scanned from the tokens until then, so a pass that asks for the
    /// table first gets the lookups and every caller gets the same answers.
    pub fn identifiersNamed(index: *const Index, name: []const u8, start: usize, end: usize) NameIterator {
        const bounded_end = @min(end, index.tokens.len);
        if (index.identifier_table.load(.acquire)) |table| {
            return .{ .index = index, .name = name, .positions = table.within(name, start, bounded_end), .cursor = 0, .end = bounded_end };
        }
        return .{ .index = index, .name = name, .positions = null, .cursor = start, .end = bounded_end };
    }

    pub const NameIterator = struct {
        index: *const Index,
        name: []const u8,
        /// The table's positions in range, or null when scanning tokens.
        positions: ?[]const u32,
        /// The next position in `positions`, or the next token to scan.
        cursor: usize,
        end: usize,

        pub fn next(iterator: *NameIterator) ?usize {
            if (iterator.positions) |positions| {
                if (iterator.cursor >= positions.len) return null;
                defer iterator.cursor += 1;
                return positions[iterator.cursor];
            }
            while (iterator.cursor < iterator.end) {
                const token_index = iterator.cursor;
                iterator.cursor += 1;
                const token = iterator.index.tokens[token_index];
                if (token.tag == .identifier and std.mem.eql(u8, tokenText(iterator.index.source, token), iterator.name)) return token_index;
            }
            return null;
        }
    };

    pub fn findBinding(index: *const Index, use_index: usize) ?Binding {
        if (use_index >= index.tokens.len or index.tokens[use_index].tag != .identifier) return null;
        return index.findBindingNamed(tokenText(index.source, index.tokens[use_index]), use_index);
    }

    /// The binding the identifier at `token_index` declares, or else the
    /// binding it refers to.
    pub fn resolve(index: *const Index, token_index: usize) ?Binding {
        if (token_index >= index.tokens.len or index.tokens[token_index].tag != .identifier) return null;
        if (index.bindings.get(identifierName(tokenText(index.source, index.tokens[token_index])))) |candidates| {
            for (candidates.items) |candidate| if (candidate.token_index == token_index) return candidate;
        }
        return index.findBinding(token_index);
    }

    /// Whether the binding visible at `receiver_index` is declared `name: type_name`
    /// with nothing member-accessed off the type.
    pub fn bindingHasType(
        index: *const Index,
        source: []const u8,
        tokens: []const std.zig.Token,
        receiver_index: usize,
        type_name: []const u8,
    ) bool {
        const visible_binding = index.findBinding(receiver_index) orelse return false;
        const declaration = visible_binding.token_index;
        if (declaration + 2 >= tokens.len or tokens[declaration + 1].tag != .colon or
            !tokenIs(source, tokens[declaration + 2], type_name)) return false;
        return declaration + 3 >= tokens.len or tokens[declaration + 3].tag != .period;
    }

    /// The binding `name` (spelled plainly or as `@"name"`) refers to at `use_index`.
    pub fn findBindingNamed(index: *const Index, name: []const u8, use_index: usize) ?Binding {
        if (use_index >= index.tokens.len) return null;
        const candidates = index.bindings.get(identifierName(name)) orelse return null;
        const occurrence = index.tokens[use_index].loc;
        var low: usize = 0;
        var high = candidates.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (candidates.items[middle].scope.start <= occurrence.start)
                low = middle + 1
            else
                high = middle;
        }
        var cursor = low;
        while (cursor > 0) {
            cursor -= 1;
            const candidate = candidates.items[cursor];
            if (!spanContains(candidate.scope, occurrence)) continue;
            // Only the quoted spelling reaches an `@"u8"` declaration; a plain
            // `u8` is always the primitive.
            if ((name.len == 0 or name[0] != '@') and index.source[index.tokens[candidate.token_index].loc.start] == '@' and
                std.zig.isPrimitive(name)) return null;
            return candidate;
        }
        return null;
    }

    /// `isContainerFieldDeclaration` with the enclosing block looked up in the index.
    pub fn isContainerFieldDeclaration(index: *const Index, identifier_index: usize) bool {
        return isContainerFieldDeclarationWithIndex(index.tokens, identifier_index, index);
    }

    pub fn usingnamespaceMayProvideName(index: *const Index, use_index: usize) bool {
        if (use_index >= index.tokens.len) return false;
        for (index.usingnamespace_scopes.items) |scope| {
            if (spanContains(scope, index.tokens[use_index].loc)) return true;
        }
        return false;
    }

    pub fn matchingToken(index: *const Index, opening_index: usize) ?usize {
        if (opening_index >= index.matching_tokens.len) return null;
        const target = index.matching_tokens[opening_index];
        return if (target == none_token) null else target;
    }

    /// Opening brace of the innermost block containing token `token_index`. A
    /// closing brace belongs to the block it closes.
    pub fn enclosingOpeningBrace(index: *const Index, token_index: usize) ?usize {
        if (token_index >= index.enclosing_braces.len) return null;
        const opening = if (index.tokens[token_index].tag == .r_brace)
            index.matching_tokens[token_index]
        else
            index.enclosing_braces[token_index];
        return if (opening == none_token) null else opening;
    }

    /// Closing brace of the innermost block containing token `token_index`.
    pub fn enclosingScopeEnd(index: *const Index, token_index: usize) ?usize {
        const opening = index.enclosingOpeningBrace(token_index) orelse return null;
        return index.matchingToken(opening);
    }

    /// Opening brace of the innermost function or test body containing
    /// `token_index`, looking through nested blocks.
    pub fn enclosingFunctionBody(index: *const Index, token_index: usize) ?usize {
        var brace = index.enclosingOpeningBrace(token_index);
        while (brace) |opening| : (brace = index.enclosingOpeningBrace(opening)) {
            if (index.braceKind(opening) == .function) return opening;
        }
        return null;
    }

    /// Opening brace of the innermost named `fn` declaration body that
    /// strictly contains `token_index`, looking through nested blocks and
    /// containers. Unlike `enclosingFunctionBody`, `test` blocks do not count,
    /// and the body is found by parsing the signature, so braces in a return
    /// type (`error{...}!T`, `struct {...}`) do not hide it.
    pub fn functionBodyContaining(index: *const Index, token_index: usize) ?usize {
        if (token_index >= index.enclosing_braces.len) return null;
        // The raw table leaves a body's own braces outside it.
        var brace = index.enclosing_braces[token_index];
        while (brace != none_token) : (brace = index.enclosing_braces[brace]) {
            if (index.functionKeyword(brace) != null) return brace;
        }
        return null;
    }

    /// The `fn` keyword of the declaration whose body opens at `body`.
    pub fn functionKeyword(index: *const Index, body: usize) ?usize {
        var low: usize = 0;
        var high = index.function_bodies.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = index.function_bodies[middle];
            if (candidate.body == body) return candidate.keyword;
            if (candidate.body < body) low = middle + 1 else high = middle;
        }
        return null;
    }

    /// Opening brace of the innermost function or test body holding
    /// `token_index`, or null when a container declaration holds it more
    /// closely.
    pub fn functionOrTestBodyHolding(index: *const Index, token_index: usize) ?usize {
        var brace = index.enclosingOpeningBrace(token_index);
        while (brace) |opening| : (brace = index.enclosingOpeningBrace(opening)) {
            switch (index.braceKind(opening)) {
                .function => return opening,
                .container => return null,
                .block => {},
            }
        }
        return null;
    }

    /// Whether `token_index` is inside a function or test body that no
    /// container declaration encloses more closely.
    pub fn insideFunctionOrTestBody(index: *const Index, token_index: usize) bool {
        return index.functionOrTestBodyHolding(token_index) != null;
    }

    /// Whether `token_index` is inside a `test` block, looking through nested
    /// blocks, functions and containers.
    pub fn insideTestBlock(index: *const Index, token_index: usize) bool {
        var brace = index.enclosingOpeningBrace(token_index);
        while (brace) |opening| : (brace = index.enclosingOpeningBrace(opening)) {
            if (opening == 0) break;
            const before = index.tokens[opening - 1].tag;
            if (before == .keyword_test) return true;
            if (opening >= 2 and index.tokens[opening - 2].tag == .keyword_test and
                (before == .string_literal or before == .identifier)) return true;
        }
        return false;
    }

    pub const BraceKind = enum { function, container, block };

    /// What the `{` at `opening` opens. A function body is the one its
    /// signature's parse found (`function_bodies`), so braces in a return
    /// type (`error{...}!T`, `struct {...}`) neither hide the body nor count
    /// as one.
    pub fn braceKind(index: *const Index, opening: usize) BraceKind {
        if (index.functionKeyword(opening) != null) return .function;
        const tokens = index.tokens;
        if (opening > 0) {
            const before = tokens[opening - 1].tag;
            if (before == .keyword_test) return .function;
            if (opening >= 2 and tokens[opening - 2].tag == .keyword_test and
                (before == .string_literal or before == .identifier)) return .function;
        }
        var cursor = opening;
        while (cursor > 0) {
            cursor -= 1;
            switch (tokens[cursor].tag) {
                .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return .container,
                .semicolon, .l_brace, .r_brace => break,
                else => {},
            }
        }
        return .block;
    }

    /// `tokens.fallibleOperationBetween` with the enclosing blocks looked up
    /// in the index.
    pub fn fallibleOperationBetween(index: *const Index, start: usize, end: usize, scope_opening: usize) bool {
        for (index.tokens[start..end], start..) |token, token_index| {
            const fallible = token.tag == .keyword_try or
                (token.tag == .keyword_return and token_index + 1 < end and index.tokens[token_index + 1].tag == .keyword_error);
            if (!fallible) continue;
            const enclosing = index.enclosingOpeningBrace(token_index) orelse continue;
            if (enclosing == scope_opening) return true;
            if (index.enclosingOpeningBrace(enclosing) == scope_opening) return true;
        }
        return false;
    }

    /// The first token of the statement holding `token_index` in its innermost
    /// block. The groups before it and around it and braced literals
    /// (`.{...}`, `T{...}`, `[_]T{...}`) belong to the statement; a block that
    /// closes before it ends the previous one.
    pub fn statementStart(index: *const Index, token_index: usize) usize {
        var cursor = token_index;
        while (cursor > 0) {
            const previous = cursor - 1;
            switch (index.tokens[previous].tag) {
                .semicolon, .l_brace => return cursor,
                .r_paren, .r_bracket => cursor = index.matchingToken(previous) orelse return cursor,
                .r_brace => {
                    const opening = index.matchingToken(previous) orelse return cursor;
                    if (opening == 0) return cursor;
                    switch (index.tokens[opening - 1].tag) {
                        .period, .identifier, .r_bracket => cursor = opening,
                        else => return cursor,
                    }
                },
                else => cursor = previous,
            }
        }
        return cursor;
    }

    /// `statementEnd` of every token inside the block opened at `opening`,
    /// found in one backward pass, for a pass that asks it of many tokens of
    /// one block: a scan from each `return` of a long `switch` reads the rest
    /// of the switch.
    pub fn statementEndsIn(index: *const Index, allocator: std.mem.Allocator, opening: usize) !StatementEnds {
        const closing = index.matchingToken(opening) orelse return .{ .opening = opening, .ends = &.{} };
        if (closing <= opening) return .{ .opening = opening, .ends = &.{} };
        const ends = try allocator.alloc(u32, closing - opening + 1);
        // A `;` ends at itself, a `}` that is reached ends the scan without
        // one, and a group goes on after its closer.
        ends[closing - opening] = none_token;
        var position = closing;
        while (position > opening + 1) {
            position -= 1;
            ends[position - opening] = switch (index.tokens[position].tag) {
                .semicolon => @intCast(position),
                .r_brace => none_token,
                .l_paren, .l_bracket, .l_brace => if (index.matchingToken(position)) |matching|
                    if (matching < closing) ends[matching + 1 - opening] else none_token
                else
                    none_token,
                else => ends[position + 1 - opening],
            };
        }
        return .{ .opening = opening, .ends = ends };
    }

    /// The `;` ending the statement that starts at `start`, or null when none
    /// ends inside the block holding `start` (on unbalanced input a group's
    /// closer can lie past the end of that block).
    pub fn statementEnd(index: *const Index, start: usize) ?usize {
        const limit = index.enclosingScopeEnd(start) orelse index.tokens.len;
        var cursor = start;
        while (cursor < limit) {
            switch (index.tokens[cursor].tag) {
                .l_paren, .l_bracket, .l_brace => cursor = index.matchingToken(cursor) orelse return null,
                .r_brace => return null,
                .semicolon => return cursor,
                else => {},
            }
            cursor += 1;
        }
        return null;
    }
};

/// `Index.statementEnd` for the tokens of one block (`Index.statementEndsIn`).
pub const StatementEnds = struct {
    opening: usize,
    /// By position after `opening`, through the block's `}`; `none_token`
    /// for none. Empty when the block has no closing brace.
    ends: []u32,

    pub fn deinit(statement_ends: *StatementEnds, allocator: std.mem.Allocator) void {
        allocator.free(statement_ends.ends);
    }

    /// `Index.statementEnd(start)` for `start` after the block's `{`, through its `}`.
    pub fn at(statement_ends: StatementEnds, index: *const Index, start: usize) ?usize {
        if (start <= statement_ends.opening or start - statement_ends.opening >= statement_ends.ends.len) return index.statementEnd(start);
        const end = statement_ends.ends[start - statement_ends.opening];
        return if (end == none_token) null else end;
    }
};

/// The identifier tokens of a file grouped by exact spelling (`@"name"` and
/// `name` are different spellings), each group in token order.
pub const IdentifierTable = struct {
    positions: []u32 = &.{},
    groups: std.StringHashMapUnmanaged(Group) = .empty,

    const Group = struct { start: u32, len: u32 };

    /// One hash lookup per identifier numbers its spelling; the numbers then
    /// place every identifier in its spelling's group.
    fn init(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token) !IdentifierTable {
        var table: IdentifierTable = .{};
        errdefer table.deinit(allocator);
        if (tokens.len > std.math.maxInt(u32)) return error.OutOfMemory;
        var spellings: std.ArrayList(u32) = .empty;
        defer spellings.deinit(allocator);
        var counts: std.ArrayList(u32) = .empty;
        defer counts.deinit(allocator);
        try table.groups.ensureTotalCapacity(allocator, @intCast(tokens.len / 16 + 16));
        for (tokens) |token| {
            if (token.tag != .identifier) continue;
            const entry = try table.groups.getOrPut(allocator, tokenText(source, token));
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .start = @intCast(counts.items.len), .len = 0 };
                try counts.append(allocator, 0);
            }
            counts.items[entry.value_ptr.start] += 1;
            try spellings.append(allocator, entry.value_ptr.start);
        }
        // Each spelling's first slot, then its next free slot as positions fill.
        var next_start: u32 = 0;
        for (counts.items) |*count| {
            const group_start = next_start;
            next_start += count.*;
            count.* = group_start;
        }
        var groups = table.groups.valueIterator();
        while (groups.next()) |group| {
            const spelling = group.start;
            group.start = counts.items[spelling];
            group.len = (if (spelling + 1 < counts.items.len) counts.items[spelling + 1] else next_start) - group.start;
        }
        table.positions = try allocator.alloc(u32, spellings.items.len);
        var identifier: usize = 0;
        for (tokens, 0..) |token, token_index| {
            if (token.tag != .identifier) continue;
            const slot = &counts.items[spellings.items[identifier]];
            table.positions[slot.*] = @intCast(token_index);
            slot.* += 1;
            identifier += 1;
        }
        return table;
    }

    fn deinit(table: *IdentifierTable, allocator: std.mem.Allocator) void {
        allocator.free(table.positions);
        table.groups.deinit(allocator);
    }

    /// The positions of the identifiers spelled exactly `name`.
    pub fn all(table: *const IdentifierTable, name: []const u8) []const u32 {
        const group = table.groups.get(name) orelse return &.{};
        return table.positions[group.start..][0..group.len];
    }

    /// The positions of the identifiers spelled exactly `name` in `[start, end)`.
    pub fn within(table: *const IdentifierTable, name: []const u8, start: usize, end: usize) []const u32 {
        const positions = table.all(name);
        const first = std.sort.partitionPoint(u32, positions, start, positionBefore);
        const last = first + std.sort.partitionPoint(u32, positions[first..], end, positionBefore);
        return positions[first..last];
    }

    /// The first identifier spelled exactly `name` in `[start, end)`.
    pub fn firstWithin(table: *const IdentifierTable, name: []const u8, start: usize, end: usize) ?usize {
        const positions = table.within(name, start, end);
        return if (positions.len == 0) null else positions[0];
    }

    fn positionBefore(bound: usize, position: u32) bool {
        return position < bound;
    }
};

/// Scope indexes of a fixed list of files, each built by the first pass that
/// needs it and then shared by every pass and thread that asks for it.
pub const LazyIndexes = struct {
    allocator: std.mem.Allocator,
    /// Guards each slot when several threads share the indexes; null when
    /// only one thread does.
    io: ?std.Io,
    slots: []Slot,

    const Slot = struct {
        mutex: std.Io.Mutex = .init,
        index: ?Index = null,
    };

    /// `allocator` must be thread-safe when `io` is given.
    pub fn init(allocator: std.mem.Allocator, io: ?std.Io, count: usize) !LazyIndexes {
        const slots = try allocator.alloc(Slot, count);
        @memset(slots, .{});
        return .{ .allocator = allocator, .io = io, .slots = slots };
    }

    pub fn deinit(indexes: *LazyIndexes) void {
        for (indexes.slots) |*slot| if (slot.index) |*built| built.deinit();
        indexes.allocator.free(indexes.slots);
    }

    /// The index of file `position`, built over `source` and `tokens` on
    /// first use; every caller passes the same file for a position.
    pub fn at(indexes: *LazyIndexes, position: usize, source: []const u8, tokens: []const std.zig.Token) !*const Index {
        const slot = &indexes.slots[position];
        if (indexes.io) |io| try slot.mutex.lock(io);
        defer if (indexes.io) |io| slot.mutex.unlock(io);
        if (slot.index == null) slot.index = try Index.init(indexes.allocator, source, tokens);
        return &slot.index.?;
    }
};

fn aliasTarget(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) ?[]const u8 {
    if (identifier_index + 3 >= tokens.len or tokens[identifier_index + 1].tag != .equal or
        tokens[identifier_index + 2].tag != .identifier or tokens[identifier_index + 3].tag != .semicolon) return null;
    return tokenText(source, tokens[identifier_index + 2]);
}

pub fn findBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    use_index: usize,
) ?Binding {
    if (use_index >= tokens.len or tokens[use_index].tag != .identifier) return null;
    const spelling = tokenText(source, tokens[use_index]);
    // A plain primitive spelling never refers to a quoted `@"u8"` declaration.
    if ((spelling.len == 0 or spelling[0] != '@') and std.zig.isPrimitive(spelling)) return null;
    const name = identifierName(spelling);
    var selected: ?Binding = null;
    for (tokens, 0..) |token, candidate_index| {
        if (token.tag != .identifier or !std.mem.eql(u8, identifierName(tokenText(source, token)), name)) continue;
        const candidate = binding(tokens, source, candidate_index, null) orelse continue;
        if (!spanContains(candidate.scope, tokens[use_index].loc)) continue;
        if (selected == null or scopeLength(candidate.scope) < scopeLength(selected.?.scope) or
            scopeLength(candidate.scope) == scopeLength(selected.?.scope) and
                candidate.token_index > selected.?.token_index)
        {
            selected = candidate;
        }
    }
    return selected;
}

pub fn isContainerFieldDeclaration(tokens: []const std.zig.Token, identifier_index: usize) bool {
    return isContainerFieldDeclarationWithIndex(tokens, identifier_index, null);
}

fn isContainerFieldDeclarationWithIndex(tokens: []const std.zig.Token, identifier_index: usize, opt_idx: ?*const Index) bool {
    if (identifier_index == 0 or identifier_index >= tokens.len or tokens[identifier_index].tag != .identifier or
        identifier_index + 1 >= tokens.len) return false;
    switch (tokens[identifier_index - 1].tag) {
        .l_brace, .r_brace, .comma, .semicolon, .doc_comment, .container_doc_comment => {},
        else => return false,
    }
    const opening = enclosingOpeningBraceWithIndex(tokens, identifier_index, opt_idx) orelse return false;
    if (!braceStartsContainer(tokens, opening)) return false;
    return switch (tokens[identifier_index + 1].tag) {
        .colon, .comma, .equal, .r_brace => true,
        else => false,
    };
}

pub fn usingnamespaceMayProvideName(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index >= tokens.len) return false;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or token.loc.end - token.loc.start != 14 or !std.mem.eql(u8, tokenText(source, token), "usingnamespace")) continue;
        const scope = declarationScope(tokens, index, true, null) orelse continue;
        if (spanContains(scope, tokens[use_index].loc)) return true;
    }
    return false;
}

fn binding(
    tokens: []const std.zig.Token,
    source: []const u8,
    identifier_index: usize,
    lexical_scope: ?LexicalScope,
) ?Binding {
    return bindingWithIndex(tokens, source, identifier_index, lexical_scope, null);
}

fn bindingWithIndex(
    tokens: []const std.zig.Token,
    source: []const u8,
    identifier_index: usize,
    lexical_scope: ?LexicalScope,
    opt_idx: ?*const Index,
) ?Binding {
    if (identifierIsNamedDeclaration(tokens, identifier_index)) {
        const declaration_tag = tokens[identifier_index - 1].tag;
        const container_member = if (lexical_scope) |scope|
            if (scope.opening) |opening| braceStartsContainer(tokens, opening) else true
        else
            declarationIsContainerMember(tokens, identifier_index - 1, opt_idx);
        return .{
            .token_index = identifier_index,
            .scope = declarationScopeWithIndex(tokens, identifier_index - 1, container_member, lexical_scope, opt_idx) orelse return null,
            .kind = if (declaration_tag == .keyword_fn)
                .callable
            else
                initializerKind(source, tokens, identifier_index),
        };
    }
    if (identifierIsFunctionParameter(tokens, identifier_index, lexical_scope, opt_idx)) {
        const body = functionBodyAfterParameter(tokens, identifier_index, lexical_scope, opt_idx) orelse return null;
        const closing = if (opt_idx) |idx| idx.matchingToken(body) orelse return null else matchingToken(tokens, body, .l_brace, .r_brace) orelse return null;
        return .{
            .token_index = identifier_index,
            .scope = .{ .start = tokens[identifier_index].loc.end, .end = tokens[closing].loc.end },
            .kind = .unknown,
        };
    }
    if (identifierIsCapture(tokens, identifier_index)) {
        const scope = captureScope(tokens, identifier_index, opt_idx) orelse return null;
        return .{ .token_index = identifier_index, .scope = scope, .kind = .unknown };
    }
    if (identifierIsDestructureBinding(tokens, identifier_index)) {
        const declaration_index = destructureDeclarationIndex(tokens, identifier_index) orelse return null;
        var scope = declarationScopeWithIndex(tokens, declaration_index, false, null, opt_idx) orelse return null;
        scope.start = tokens[identifier_index].loc.end;
        return .{
            .token_index = identifier_index,
            .scope = scope,
            .kind = .unknown,
        };
    }
    return null;
}

fn identifierIsNamedDeclaration(tokens: []const std.zig.Token, index: usize) bool {
    if (index == 0 or index + 1 >= tokens.len) return false;
    return switch (tokens[index - 1].tag) {
        .keyword_fn => tokens[index + 1].tag == .l_paren,
        .keyword_const, .keyword_var => switch (tokens[index + 1].tag) {
            .equal, .colon, .keyword_align, .keyword_addrspace, .keyword_linksection => true,
            else => false,
        } and
            declarationKeywordStartsStatement(tokens, index - 1),
        else => false,
    };
}

fn declarationKeywordStartsStatement(tokens: []const std.zig.Token, index: usize) bool {
    if (index == 0) return true;
    if (index >= 2 and tokens[index - 1].tag == .string_literal and tokens[index - 2].tag == .keyword_extern) return true;
    return switch (tokens[index - 1].tag) {
        .l_brace,
        .r_brace,
        .comma,
        .semicolon,
        .doc_comment,
        .container_doc_comment,
        .keyword_pub,
        .keyword_export,
        .keyword_extern,
        .keyword_inline,
        .keyword_noinline,
        .keyword_comptime,
        .keyword_threadlocal,
        => true,
        else => false,
    };
}

fn declarationIsContainerMember(tokens: []const std.zig.Token, keyword_index: usize, opt_idx: ?*const Index) bool {
    const opening = enclosingOpeningBraceWithIndex(tokens, keyword_index, opt_idx) orelse return true;
    return braceStartsContainer(tokens, opening);
}

fn braceStartsContainer(tokens: []const std.zig.Token, opening: usize) bool {
    var cursor = opening;
    var parenthesis_depth: usize = 0;
    while (cursor > 0 and opening - cursor < 32) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => parenthesis_depth -|= 1,
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => if (parenthesis_depth == 0) return true,
            .equal => if (parenthesis_depth == 0) return false,
            .semicolon, .l_brace, .r_brace => if (parenthesis_depth == 0) return false,
            else => {},
        }
    }
    return false;
}

fn declarationScope(
    tokens: []const std.zig.Token,
    declaration_index: usize,
    order_independent: bool,
    lexical_scope: ?LexicalScope,
) ?std.zig.Token.Loc {
    return declarationScopeWithIndex(tokens, declaration_index, order_independent, lexical_scope, null);
}

fn declarationScopeWithIndex(
    tokens: []const std.zig.Token,
    declaration_index: usize,
    order_independent: bool,
    lexical_scope: ?LexicalScope,
    opt_idx: ?*const Index,
) ?std.zig.Token.Loc {
    if (lexical_scope) |scope| return .{
        .start = if (order_independent)
            if (scope.opening) |opening| tokens[opening].loc.end else 0
        else
            tokens[declaration_index].loc.end,
        .end = tokens[scope.closing].loc.end,
    };
    const opening = enclosingOpeningBraceWithIndex(tokens, declaration_index, opt_idx);
    const closing = if (opening) |brace|
        if (opt_idx) |idx| idx.matchingToken(brace) orelse return null else matchingToken(tokens, brace, .l_brace, .r_brace) orelse return null
    else
        tokens.len - 1;
    return .{
        .start = if (order_independent)
            if (opening) |brace| tokens[brace].loc.end else 0
        else
            tokens[declaration_index].loc.end,
        .end = tokens[closing].loc.end,
    };
}

fn identifierIsFunctionParameter(tokens: []const std.zig.Token, index: usize, lexical_scope: ?LexicalScope, opt_idx: ?*const Index) bool {
    if (index + 1 >= tokens.len or tokens[index + 1].tag != .colon) return false;
    const opening = enclosingOpeningParenthesisIn(tokens, index, lexical_scope) orelse return false;
    if (opening < 2 or tokens[opening - 1].tag != .identifier or tokens[opening - 2].tag != .keyword_fn) return false;
    const closing = if (opt_idx) |idx| idx.matchingToken(opening) orelse return false else matchingToken(tokens, opening, .l_paren, .r_paren) orelse return false;
    return index < closing;
}

fn functionBodyAfterParameter(tokens: []const std.zig.Token, index: usize, lexical_scope: ?LexicalScope, opt_idx: ?*const Index) ?usize {
    const opening = enclosingOpeningParenthesisIn(tokens, index, lexical_scope) orelse return null;
    const closing = if (opt_idx) |idx| idx.matchingToken(opening) orelse return null else matchingToken(tokens, opening, .l_paren, .r_paren) orelse return null;
    return functionBodyAfterParametersWithIndex(tokens, closing, opt_idx);
}

pub fn functionBodyAfterParameters(tokens: []const std.zig.Token, parameters_end: usize) ?usize {
    return functionBodyAfterParametersWithIndex(tokens, parameters_end, null);
}

fn functionBodyAfterParametersWithIndex(tokens: []const std.zig.Token, parameters_end: usize, opt_idx: ?*const Index) ?usize {
    if (parameters_end >= tokens.len or tokens[parameters_end].tag != .r_paren) return null;
    var cursor = parameters_end + 1;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (cursor < tokens.len) : (cursor += 1) {
        switch (tokens[cursor].tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => if (parenthesis_depth == 0 and bracket_depth == 0) {
                if (!braceStartsReturnType(tokens, cursor, parameters_end + 1)) return cursor;
                cursor = if (opt_idx) |idx| idx.matchingToken(cursor) orelse return null else matchingToken(tokens, cursor, .l_brace, .r_brace) orelse return null;
            },
            .comma, .semicolon => if (parenthesis_depth == 0 and bracket_depth == 0) return null,
            else => {},
        }
    }
    return null;
}

fn braceStartsReturnType(tokens: []const std.zig.Token, opening: usize, return_type_start: usize) bool {
    var cursor = opening;
    while (cursor > return_type_start) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .colon,
            .keyword_error,
            .keyword_struct,
            .keyword_union,
            .keyword_enum,
            .keyword_opaque,
            .keyword_switch,
            .keyword_if,
            => return true,
            .bang, .question_mark, .asterisk, .identifier, .builtin, .l_paren, .r_paren, .comma => {},
            else => return false,
        }
    }
    return false;
}

/// The bodies of private functions that only test code reaches: each
/// reference to the function's name lies in a `test` block or in the body of
/// another such function. Another file cannot name a private declaration, so
/// the file alone decides. Rules that hold production code to a policy skip
/// these bodies as they skip `test` blocks.
pub const TestOnlyBodies = struct {
    /// `{` and `}` token indices, sorted and without nesting.
    ranges: []const Range = &.{},

    pub const Range = struct { opening: usize, closing: usize };

    pub fn deinit(bodies: *TestOnlyBodies, allocator: std.mem.Allocator) void {
        allocator.free(bodies.ranges);
        bodies.* = undefined;
    }

    /// Whether `token_index` lies inside one of the bodies, braces included.
    pub fn contains(bodies: TestOnlyBodies, token_index: usize) bool {
        var low: usize = 0;
        var high = bodies.ranges.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const range = bodies.ranges[middle];
            if (token_index < range.opening) {
                high = middle;
            } else if (token_index > range.closing) {
                low = middle + 1;
            } else return true;
        }
        return false;
    }
};

pub fn testOnlyBodies(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token) !TestOnlyBodies {
    const Function = struct {
        opening: usize,
        closing: ?usize = null,
        private: bool,
        text: []const u8,
        /// Index into `names` when a private function has this name.
        name: ?u32 = null,
    };
    // Where a reference to a private function's name appears.
    const Site = union(enum) { testing, production, function: usize };
    const Reference = struct { name: u32, site: Site };
    const Frame = struct { function: ?usize, testing: bool };
    // Same-named functions in different containers share their references,
    // so a verdict belongs to a name: either all of them are test-only or none.
    const Name = struct { eligible: bool = true, kept: bool = false, reached: bool = false };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var functions: std.ArrayList(Function) = .empty;
    // Function bodies by opening brace, filled in as signatures are passed.
    var body_owner: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    var name_ids: std.StringHashMapUnmanaged(u32) = .empty;
    var names: std.ArrayList(Name) = .empty;
    var references: std.ArrayList(Reference) = .empty;
    var frames: std.ArrayList(Frame) = .empty;
    var test_frames: usize = 0;

    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or index + 2 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, index + 2, .l_paren, .r_paren) orelse continue;
        const opening = functionBodyAfterParameters(tokens, parameters_end) orelse continue;
        try body_owner.put(arena, opening, functions.items.len);
        try functions.append(arena, .{
            .opening = opening,
            .private = functionIsPrivate(tokens, index),
            .text = tokenText(source, tokens[index + 1]),
        });
    }
    for (functions.items) |*function| {
        if (!function.private) continue;
        const entry = try name_ids.getOrPut(arena, function.text);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(names.items.len);
            try names.append(arena, .{});
        }
        function.name = entry.value_ptr.*;
    }
    // A public function sharing a private one's name makes every reference
    // to the name ambiguous.
    for (functions.items) |function| {
        if (function.private) continue;
        if (name_ids.get(function.text)) |id| names.items[id].eligible = false;
    }

    for (tokens, 0..) |token, index| switch (token.tag) {
        .l_brace => {
            const testing = index > 0 and (tokens[index - 1].tag == .keyword_test or
                (index > 1 and tokens[index - 2].tag == .keyword_test and
                    (tokens[index - 1].tag == .string_literal or tokens[index - 1].tag == .identifier)));
            if (testing) test_frames += 1;
            try frames.append(arena, .{ .function = body_owner.get(index), .testing = testing });
        },
        .r_brace => if (frames.pop()) |frame| {
            if (frame.testing) test_frames -= 1;
            if (frame.function) |function| functions.items[function].closing = index;
        },
        .identifier => {
            if (index > 0 and tokens[index - 1].tag == .keyword_fn) continue;
            const name = name_ids.get(tokenText(source, token)) orelse continue;
            const site: Site = site: {
                if (test_frames != 0) break :site .testing;
                var frame_index = frames.items.len;
                while (frame_index > 0) {
                    frame_index -= 1;
                    if (frames.items[frame_index].function) |function| break :site .{ .function = function };
                }
                break :site .production;
            };
            try references.append(arena, .{ .name = name, .site = site });
        },
        else => {},
    };
    for (functions.items) |function| {
        if (function.closing == null) if (function.name) |name| {
            names.items[name].eligible = false;
        };
    }

    // Start from every eligible referenced name and drop those that
    // production code or a function not kept reaches, until stable.
    for (references.items) |reference| names.items[reference.name].kept = names.items[reference.name].eligible;
    var changed = true;
    while (changed) {
        changed = false;
        for (references.items) |reference| {
            if (!names.items[reference.name].kept) continue;
            const from_production = switch (reference.site) {
                .testing => false,
                .production => true,
                .function => |function| if (functions.items[function].name) |caller|
                    caller != reference.name and !names.items[caller].kept
                else
                    true,
            };
            if (!from_production) continue;
            names.items[reference.name].kept = false;
            changed = true;
        }
    }
    // Of those, keep the ones a test reaches; the rest only reach each other.
    changed = true;
    while (changed) {
        changed = false;
        for (references.items) |reference| {
            const name = &names.items[reference.name];
            if (!name.kept or name.reached) continue;
            const from_test = switch (reference.site) {
                .testing => true,
                .production => false,
                .function => |function| if (functions.items[function].name) |caller| names.items[caller].reached else false,
            };
            if (!from_test) continue;
            name.reached = true;
            changed = true;
        }
    }

    var ranges: std.ArrayList(TestOnlyBodies.Range) = .empty;
    errdefer ranges.deinit(allocator);
    for (functions.items) |function| {
        const name = function.name orelse continue;
        if (names.items[name].reached) try ranges.append(allocator, .{ .opening = function.opening, .closing = function.closing.? });
    }
    std.mem.sort(TestOnlyBodies.Range, ranges.items, {}, struct {
        fn lessThan(_: void, left: TestOnlyBodies.Range, right: TestOnlyBodies.Range) bool {
            return left.opening < right.opening;
        }
    }.lessThan);
    // A nested body follows the body enclosing it and is covered by it.
    var kept_count: usize = 0;
    for (ranges.items) |range| {
        if (kept_count != 0 and range.opening <= ranges.items[kept_count - 1].closing) continue;
        ranges.items[kept_count] = range;
        kept_count += 1;
    }
    ranges.shrinkRetainingCapacity(kept_count);
    return .{ .ranges = try ranges.toOwnedSlice(allocator) };
}

/// Whether the `fn` at `fn_index` is neither `pub` nor exported, looking past
/// `inline`, `noinline` and calling-convention-free modifiers.
fn functionIsPrivate(tokens: []const std.zig.Token, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_inline, .keyword_noinline => {},
            .keyword_pub, .keyword_export, .keyword_extern => return false,
            else => return true,
        }
    }
    return true;
}

fn identifierIsCapture(tokens: []const std.zig.Token, index: usize) bool {
    var opening = index;
    while (opening > 0 and index - opening < 16) {
        opening -= 1;
        switch (tokens[opening].tag) {
            .pipe => break,
            .identifier, .asterisk, .comma => {},
            else => return false,
        }
    } else return false;
    var closing = index + 1;
    while (closing < tokens.len and closing - index < 16) : (closing += 1) switch (tokens[closing].tag) {
        .pipe => return true,
        .identifier, .asterisk, .comma => {},
        else => return false,
    };
    return false;
}

fn captureScope(tokens: []const std.zig.Token, index: usize, opt_idx: ?*const Index) ?std.zig.Token.Loc {
    var closing_pipe = index + 1;
    while (closing_pipe < tokens.len and tokens[closing_pipe].tag != .pipe) : (closing_pipe += 1) {}
    if (closing_pipe == tokens.len) return null;
    const body = closing_pipe + 1;
    if (body >= tokens.len) return null;
    const end = if (tokens[body].tag == .l_brace)
        if (opt_idx) |idx| idx.matchingToken(body) orelse return null else matchingToken(tokens, body, .l_brace, .r_brace) orelse return null
    else
        expressionEnd(tokens, body) orelse return null;
    return .{ .start = tokens[body].loc.start, .end = tokens[end].loc.end };
}

fn identifierIsDestructureBinding(tokens: []const std.zig.Token, index: usize) bool {
    return destructureDeclarationIndex(tokens, index) != null;
}

fn destructureDeclarationIndex(tokens: []const std.zig.Token, index: usize) ?usize {
    var cursor = index;
    var nested_braces: usize = 0;
    var declaration_index: ?usize = null;
    while (cursor > 0 and index - cursor < 64) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_const, .keyword_var => {
                if (!declarationKeywordStartsStatement(tokens, cursor)) return null;
                declaration_index = cursor;
                break;
            },
            .l_brace => nested_braces += 1,
            .equal, .semicolon, .r_brace => return null,
            else => {},
        }
    }
    if (declaration_index == null) return null;
    cursor = index + 1;
    while (cursor < tokens.len and cursor - index < 64) : (cursor += 1) switch (tokens[cursor].tag) {
        .equal => return if (nested_braces != 0 or index > 0 and
            (tokens[index - 1].tag == .keyword_const or tokens[index - 1].tag == .keyword_var)) declaration_index else null,
        .semicolon => return null,
        else => {},
    };
    return null;
}

fn initializerKind(source: []const u8, tokens: []const std.zig.Token, identifier_index: usize) BindingKind {
    if (identifier_index + 2 >= tokens.len or tokens[identifier_index + 1].tag != .equal) return .unknown;
    const initializer = tokens[identifier_index + 2];
    return switch (initializer.tag) {
        .number_literal, .string_literal, .char_literal, .multiline_string_literal_line => .non_callable,
        .identifier => if (std.mem.eql(u8, tokenText(source, initializer), "true") or
            std.mem.eql(u8, tokenText(source, initializer), "false") or
            std.mem.eql(u8, tokenText(source, initializer), "null") or
            std.mem.eql(u8, tokenText(source, initializer), "undefined")) .non_callable else .unknown,
        .period => .non_callable,
        else => .unknown,
    };
}

fn enclosingOpeningBraceWithIndex(tokens: []const std.zig.Token, index: usize, opt_idx: ?*const Index) ?usize {
    if (opt_idx) |idx| {
        if (index >= idx.enclosing_braces.len) return null;
        const b = idx.enclosing_braces[index];
        return if (b == none_token) null else b;
    }
    return enclosingOpeningBrace(tokens, index);
}

/// `enclosingOpeningParenthesis`, from `lexical_scope` when that knows it.
fn enclosingOpeningParenthesisIn(tokens: []const std.zig.Token, index: usize, lexical_scope: ?LexicalScope) ?usize {
    const known = if (lexical_scope) |scope| scope.parenthesis else unknown_token;
    if (known == unknown_token) return enclosingOpeningParenthesis(tokens, index);
    return if (known == none_token) null else known;
}

/// `enclosingOpeningParenthesis` of each token of a forward pass. While each
/// closer closes the innermost open group, that scan skips the closed groups
/// before a token and stops at the innermost open one: a `(` is the answer, a
/// `{` or a `;` directly inside it ends the scan, and a `[` is looked through.
/// Past a closer that does not, the scan's separate depth counts no longer
/// follow the nesting, and the answers are `unknown_token`.
const ParenthesisTracker = struct {
    groups: std.ArrayList(Group) = .empty,
    /// Token indexes must fit below the sentinels.
    nested: bool,

    const Group = struct {
        closer: std.zig.Token.Tag,
        /// What tokens directly inside the group resolve to.
        parenthesis: u32,
    };

    /// The answer for the token `step` is given next.
    fn current(tracker: *const ParenthesisTracker) u32 {
        if (!tracker.nested) return unknown_token;
        return if (tracker.groups.last()) |group| group.parenthesis else none_token;
    }

    fn step(tracker: *ParenthesisTracker, allocator: std.mem.Allocator, tag: std.zig.Token.Tag, token_index: usize) !void {
        if (!tracker.nested) return;
        switch (tag) {
            .l_paren => try tracker.groups.append(allocator, .{ .closer = .r_paren, .parenthesis = @intCast(token_index) }),
            .l_brace => try tracker.groups.append(allocator, .{ .closer = .r_brace, .parenthesis = none_token }),
            .l_bracket => try tracker.groups.append(allocator, .{ .closer = .r_bracket, .parenthesis = tracker.current() }),
            .r_paren, .r_brace, .r_bracket => {
                const closes_innermost = if (tracker.groups.pop()) |group| group.closer == tag else false;
                if (!closes_innermost) tracker.nested = false;
            },
            .semicolon => if (tracker.groups.lastPtr()) |group| {
                group.parenthesis = none_token;
            },
            else => {},
        }
    }
};

fn enclosingOpeningParenthesis(tokens: []const std.zig.Token, index: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => parenthesis_depth += 1,
            .l_paren => {
                if (parenthesis_depth == 0 and brace_depth == 0 and bracket_depth == 0) return cursor;
                parenthesis_depth -|= 1;
            },
            .r_brace => brace_depth += 1,
            .l_brace => {
                if (brace_depth == 0) return null;
                brace_depth -= 1;
            },
            .r_bracket => bracket_depth += 1,
            .l_bracket => bracket_depth -|= 1,
            .semicolon => if (parenthesis_depth == 0 and brace_depth == 0 and bracket_depth == 0) return null,
            else => {},
        }
    }
    return null;
}

fn expressionEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var inside_capture = false;
    for (tokens[start..], start..) |token, index| switch (token.tag) {
        .l_paren => parenthesis_depth += 1,
        .r_paren => {
            if (parenthesis_depth == 0) return index -| 1;
            parenthesis_depth -= 1;
        },
        .l_bracket => bracket_depth += 1,
        .r_bracket => bracket_depth -|= 1,
        .l_brace => brace_depth += 1,
        .r_brace => {
            if (brace_depth == 0) return index -| 1;
            brace_depth -= 1;
        },
        .pipe => inside_capture = !inside_capture,
        .semicolon => if (!inside_capture and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0) return index -| 1,
        .comma => if (!inside_capture and parenthesis_depth == 0 and bracket_depth == 0 and brace_depth == 0 and
            !commaContinuesDestructuringAssignment(tokens, index)) return index -| 1,
        else => {},
    };
    return null;
}

fn commaContinuesDestructuringAssignment(tokens: []const std.zig.Token, comma_index: usize) bool {
    for (tokens[comma_index + 1 ..]) |token| switch (token.tag) {
        .equal => return true,
        .semicolon, .l_brace, .r_brace => return false,
        else => {},
    };
    return false;
}

fn spanContains(scope: std.zig.Token.Loc, occurrence: std.zig.Token.Loc) bool {
    return occurrence.start >= scope.start and occurrence.end <= scope.end;
}

fn scopeLength(scope: std.zig.Token.Loc) usize {
    return scope.end -| scope.start;
}

test "bindings respect lexical scopes and local declaration order" {
    const source: [:0]const u8 =
        "const global = 1;\n" ++
        "fn first(arg: u8) void { _ = global; _ = arg; _ = later; _ = foreign; const later = 1; }\n" ++
        "fn second() void { const foreign = 1; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var later_use: ?usize = null;
    var foreign_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (later_use == null and token.loc.start >= std.mem.find(u8, source, "_ = later").? and std.mem.eql(u8, tokenText(source, token), "later")) later_use = index;
        if (token.loc.start >= std.mem.find(u8, source, "_ = foreign").? and token.loc.start < std.mem.find(u8, source, "fn second").? and std.mem.eql(u8, tokenText(source, token), "foreign")) foreign_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, later_use.?) == null);
    try std.testing.expect(findBinding(source, tokens, foreign_use.?) == null);
}

test "indexed bindings select the innermost alias" {
    const source: [:0]const u8 =
        "const Alias = Global;\n" ++
        "fn run() void { const Alias = Local; _ = Alias; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();

    const use_start = std.mem.find(u8, source, "_ = Alias").?;
    var use_index: ?usize = null;
    for (tokens, 0..) |token, token_index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "Alias")) {
            use_index = token_index;
            break;
        }
    }
    try std.testing.expect(use_index != null);
    const selected = index.findBinding(use_index.?);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("Local", selected.?.alias_target.?);
    try std.testing.expect(selected.?.scope_rank != 0);
}

test "structural index resolves delimiters statements and enclosing scopes" {
    const source: [:0]const u8 = "fn run(values: []u8) void { const value = call(values[0]); _ = value; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();

    var declaration_index: ?usize = null;
    var call_opening: ?usize = null;
    for (tokens, 0..) |token, token_index| {
        if (token.tag == .keyword_const) declaration_index = token_index;
        if (token.tag == .l_paren and token_index > 0 and std.mem.eql(u8, tokenText(source, tokens[token_index - 1]), "call")) {
            call_opening = token_index;
        }
    }
    try std.testing.expect(declaration_index != null);
    try std.testing.expect(call_opening != null);
    const call_closing = index.matchingToken(call_opening.?);
    try std.testing.expect(call_closing != null);
    try std.testing.expectEqual(std.zig.Token.Tag.r_paren, tokens[call_closing.?].tag);
    const statement_end = index.statementEnd(declaration_index.?);
    try std.testing.expect(statement_end != null);
    try std.testing.expectEqual(std.zig.Token.Tag.semicolon, tokens[statement_end.?].tag);
    const scope_end = index.enclosingScopeEnd(declaration_index.?);
    try std.testing.expect(scope_end != null);
    try std.testing.expectEqual(std.zig.Token.Tag.r_brace, tokens[scope_end.?].tag);
}

const nested_blocks_source: [:0]const u8 =
    \\const top = 1;
    \\const Outer = struct {
    \\    field: u8,
    \\    const member = 2;
    \\    fn method(self: Outer) u8 {
    \\        const local = blk: {
    \\            const inner = self.field;
    \\            break :blk inner;
    \\        };
    \\        const Nested = struct {
    \\            const declared = 3;
    \\            fn deep() u8 {
    \\                if (local) { return declared; }
    \\                return 0;
    \\            }
    \\        };
    \\        return Nested.deep() + local;
    \\    }
    \\};
    \\test "case" {
    \\    var x: u8 = 0;
    \\    for (0..2) |i| { x += i; }
    \\}
    \\
;

fn indexOfText(source: []const u8, tokens: []const std.zig.Token, text: []const u8, occurrence: usize) usize {
    var seen: usize = 0;
    for (tokens, 0..) |token, token_index| {
        if (!std.mem.eql(u8, tokenText(source, token), text)) continue;
        if (seen == occurrence) return token_index;
        seen += 1;
    }
    unreachable;
}

test "index scans agree with the token scans at every token" {
    const tokens = try tokenize(std.testing.allocator, nested_blocks_source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, nested_blocks_source, tokens);
    defer index.deinit();
    for (tokens, 0..) |token, token_index| {
        try std.testing.expectEqual(enclosingOpeningBrace(tokens, token_index), index.enclosingOpeningBrace(token_index));
        try std.testing.expectEqual(@import("tokens.zig").enclosingScopeEnd(tokens, token_index), index.enclosingScopeEnd(token_index));
        try std.testing.expectEqual(isContainerFieldDeclaration(tokens, token_index), index.isContainerFieldDeclaration(token_index));
        switch (token.tag) {
            .keyword_const, .keyword_var, .keyword_return => try std.testing.expectEqual(
                @import("tokens.zig").statementEnd(tokens, token_index),
                index.statementEnd(token_index),
            ),
            .l_paren, .l_bracket, .l_brace => try std.testing.expectEqual(
                @import("tokens.zig").matchingDelimiter(tokens, token_index),
                index.matchingToken(token_index),
            ),
            .r_paren, .r_bracket, .r_brace => {
                const opening_tag: std.zig.Token.Tag = switch (token.tag) {
                    .r_paren => .l_paren,
                    .r_bracket => .l_bracket,
                    else => .l_brace,
                };
                try std.testing.expectEqual(
                    @import("tokens.zig").matchingOpeningToken(tokens, token_index, opening_tag, token.tag),
                    index.matchingToken(token_index),
                );
            },
            else => {},
        }
    }
}

test "block statement ends agree with statementEnd at every token" {
    const sources = [_][:0]const u8{
        nested_blocks_source,
        \\fn f(k: u8, xs: []u8) !u8 {
        \\    switch (k) {
        \\        0 => return 1,
        \\        1 => return error.Bad,
        \\        else => {},
        \\    }
        \\    var i: usize = 0;
        \\    while (i < xs.len) : (i = i + 1) { xs[i] = .{ .a = 1, .b = (2) }[0]; }
        \\    if (k > 2) |c| g(c) else return 0;
        \\    return @intCast(i);
        \\}
        ,
    };
    for (sources) |source| {
        const tokens = try tokenize(std.testing.allocator, source);
        defer std.testing.allocator.free(tokens);
        var index = try Index.init(std.testing.allocator, source, tokens);
        defer index.deinit();
        for (tokens, 0..) |token, opening| {
            if (token.tag != .l_brace) continue;
            var ends = try index.statementEndsIn(std.testing.allocator, opening);
            defer ends.deinit(std.testing.allocator);
            const closing = index.matchingToken(opening) orelse continue;
            for (opening + 1..closing + 1) |start| {
                try std.testing.expectEqual(index.statementEnd(start), ends.at(&index, start));
            }
        }
    }
}

test "identifier positions agree with a token scan over every range" {
    const tokens = try tokenize(std.testing.allocator, nested_blocks_source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, nested_blocks_source, tokens);
    defer index.deinit();
    for ([_]bool{ false, true }) |built| {
        const identifiers = if (built) try index.identifiers() else null;
        for (tokens) |named| {
            if (named.tag != .identifier) continue;
            const name = tokenText(nested_blocks_source, named);
            for (0..tokens.len + 1) |start| {
                const end = @min(tokens.len, start + 7);
                var expected: std.ArrayList(u32) = .empty;
                defer expected.deinit(std.testing.allocator);
                for (tokens[start..end], start..) |token, token_index| {
                    if (token.tag == .identifier and std.mem.eql(u8, tokenText(nested_blocks_source, token), name)) {
                        try expected.append(std.testing.allocator, @intCast(token_index));
                    }
                }
                var named_positions = index.identifiersNamed(name, start, end);
                for (expected.items) |position| try std.testing.expectEqual(@as(usize, position), named_positions.next().?);
                try std.testing.expectEqual(null, named_positions.next());
                const table = identifiers orelse continue;
                try std.testing.expectEqualSlices(u32, expected.items, table.within(name, start, end));
                try std.testing.expectEqual(
                    if (expected.items.len == 0) null else @as(usize, expected.items[0]),
                    table.firstWithin(name, start, end),
                );
            }
        }
    }
    try std.testing.expectEqual(0, (try index.identifiers()).all("absent").len);
}

test "the index stays iterative over brackets nested far past the parser's limit" {
    // Dependencies read from disk are indexed without being parsed, so a file
    // the parse guard skips still reaches the index.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "fn f() void {");
    for (0..50_000) |_| try text.appendSlice(std.testing.allocator, "{ const a = (");
    try text.append(std.testing.allocator, 0);
    const source = text.items[0 .. text.items.len - 1 :0];
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    try std.testing.expectEqual(@as(?usize, tokens.len - 6), index.enclosingOpeningBrace(tokens.len - 4));
    _ = index.resolve(tokens.len - 4);
}

test "fallible operations between two tokens agree with the token scan" {
    const source: [:0]const u8 =
        \\fn run(allocator: Allocator) !void {
        \\    const first = try allocator.alloc(u8, 1);
        \\    if (first.len == 0) {
        \\        try check(first);
        \\        if (ready) { return error.Busy; }
        \\    }
        \\    defer allocator.free(first);
        \\}
        \\
    ;
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    var openings: usize = 0;
    for (tokens, 0..) |token, scope_opening| {
        if (token.tag != .l_brace) continue;
        openings += 1;
        for (0..tokens.len) |start| for (start..tokens.len) |end| try std.testing.expectEqual(
            @import("tokens.zig").fallibleOperationBetween(tokens, start, end, scope_opening),
            index.fallibleOperationBetween(start, end, scope_opening),
        );
    }
    try std.testing.expectEqual(@as(usize, 3), openings);
}

test "a closing brace belongs to the block it closes" {
    const tokens = try tokenize(std.testing.allocator, nested_blocks_source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, nested_blocks_source, tokens);
    defer index.deinit();
    const opening = indexOfText(nested_blocks_source, tokens, "{", 4);
    const closing = index.matchingToken(opening).?;
    try std.testing.expectEqual(std.zig.Token.Tag.r_brace, tokens[closing].tag);
    try std.testing.expectEqual(@as(?usize, opening), index.enclosingOpeningBrace(closing));
    try std.testing.expectEqual(@as(?usize, closing), index.enclosingScopeEnd(closing));
    // The opening brace belongs to the block around it instead.
    try std.testing.expect(index.enclosingOpeningBrace(opening).? < opening);
    // Top-level tokens and out-of-range queries have no enclosing block.
    try std.testing.expectEqual(@as(?usize, null), index.enclosingOpeningBrace(0));
    try std.testing.expectEqual(@as(?usize, null), index.enclosingScopeEnd(tokens.len));
}

test "function bodies are found through nested blocks and stop at containers" {
    const tokens = try tokenize(std.testing.allocator, nested_blocks_source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, nested_blocks_source, tokens);
    defer index.deinit();
    const source = nested_blocks_source;
    const method_body = indexOfText(source, tokens, "{", 1);
    const deep_body = indexOfText(source, tokens, "{", 4);
    const test_body = indexOfText(source, tokens, "{", 6);
    // Top-level and container-level declarations are not inside a body.
    try std.testing.expect(!index.insideFunctionOrTestBody(indexOfText(source, tokens, "top", 0)));
    try std.testing.expect(!index.insideFunctionOrTestBody(indexOfText(source, tokens, "member", 0)));
    try std.testing.expectEqual(@as(?usize, null), index.enclosingFunctionBody(indexOfText(source, tokens, "member", 0)));
    // A labeled block and the declarations of a container inside a method sit in different bodies.
    const inner = indexOfText(source, tokens, "inner", 0);
    try std.testing.expect(index.insideFunctionOrTestBody(inner));
    try std.testing.expectEqual(@as(?usize, method_body), index.enclosingFunctionBody(inner));
    const declared = indexOfText(source, tokens, "declared", 0);
    try std.testing.expect(!index.insideFunctionOrTestBody(declared));
    try std.testing.expectEqual(@as(?usize, method_body), index.enclosingFunctionBody(declared));
    // A plain block inside a function still belongs to the function.
    const deep_return = indexOfText(source, tokens, "return", 0);
    try std.testing.expectEqual(@as(?usize, deep_body), index.enclosingFunctionBody(deep_return));
    try std.testing.expect(index.insideFunctionOrTestBody(deep_return));
    // Test blocks count as bodies too.
    const test_variable = indexOfText(source, tokens, "x", 0);
    try std.testing.expectEqual(@as(?usize, test_body), index.enclosingFunctionBody(test_variable));
    try std.testing.expect(index.insideFunctionOrTestBody(test_variable));
}

test "declaration bodies are found past braces in return types and skip test blocks" {
    const source: [:0]const u8 =
        \\fn failing() error{Oops}!void {
        \\    const a = 1;
        \\}
        \\fn shaped() struct { ok: bool } {
        \\    const Inner = struct {
        \\        fn method() void { const b = 2; }
        \\        field: u8 = 3,
        \\    };
        \\    return .{ .ok = Inner.c };
        \\}
        \\test "case" { const d = 4; }
        \\
    ;
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    const failing_body = indexOfText(source, tokens, "{", 1);
    const shaped_body = indexOfText(source, tokens, "{", 3);
    const method_body = indexOfText(source, tokens, "{", 5);
    try std.testing.expectEqual(@as(?usize, failing_body), index.functionBodyContaining(indexOfText(source, tokens, "a", 0)));
    try std.testing.expectEqual(@as(?usize, indexOfText(source, tokens, "fn", 0)), index.functionKeyword(failing_body));
    try std.testing.expectEqual(@as(?usize, method_body), index.functionBodyContaining(indexOfText(source, tokens, "b", 0)));
    // Container fields inside a body, and the body's own braces, belong to the enclosing function.
    try std.testing.expectEqual(@as(?usize, shaped_body), index.functionBodyContaining(indexOfText(source, tokens, "field", 0)));
    try std.testing.expectEqual(@as(?usize, shaped_body), index.functionBodyContaining(method_body));
    try std.testing.expectEqual(@as(?usize, null), index.functionBodyContaining(shaped_body));
    try std.testing.expectEqual(@as(?usize, null), index.functionBodyContaining(index.matchingToken(shaped_body).?));
    try std.testing.expectEqual(@as(?usize, null), index.functionKeyword(indexOfText(source, tokens, "{", 2)));
    try std.testing.expectEqual(@as(?usize, null), index.functionBodyContaining(indexOfText(source, tokens, "d", 0)));
    // The scope walks agree: a braced return type neither hides the body nor
    // counts as one.
    const a = indexOfText(source, tokens, "a", 0);
    try std.testing.expectEqual(@as(?usize, failing_body), index.enclosingFunctionBody(a));
    try std.testing.expectEqual(@as(?usize, failing_body), index.functionOrTestBodyHolding(a));
    try std.testing.expect(index.insideFunctionOrTestBody(a));
    try std.testing.expect(!index.insideFunctionOrTestBody(indexOfText(source, tokens, "Oops", 0)));
    try std.testing.expectEqual(@as(?usize, null), index.enclosingFunctionBody(indexOfText(source, tokens, "Oops", 0)));
    try std.testing.expectEqual(Index.BraceKind.block, index.braceKind(indexOfText(source, tokens, "{", 0)));
    try std.testing.expectEqual(Index.BraceKind.container, index.braceKind(indexOfText(source, tokens, "{", 2)));
    try std.testing.expectEqual(@as(?usize, shaped_body), index.functionOrTestBodyHolding(indexOfText(source, tokens, "return", 0)));
    try std.testing.expectEqual(@as(?usize, null), index.functionOrTestBodyHolding(indexOfText(source, tokens, "field", 0)));
    try std.testing.expectEqual(@as(?usize, null), index.functionOrTestBodyHolding(indexOfText(source, tokens, "ok", 0)));
    try std.testing.expect(index.insideFunctionOrTestBody(indexOfText(source, tokens, "d", 0)));
}

test "test blocks are found through the blocks and containers declared in them" {
    const source: [:0]const u8 =
        "fn run() void { const plain = 1; }\n" ++
        "test \"named\" { const T = struct { fn helper() void { const nested = 2; } }; }\n" ++
        "test decl { { const block = 3; } }\n" ++
        "test { const anonymous = 4; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    try std.testing.expect(!index.insideTestBlock(indexOfText(source, tokens, "plain", 0)));
    try std.testing.expect(!index.insideTestBlock(indexOfText(source, tokens, "run", 0)));
    try std.testing.expect(index.insideTestBlock(indexOfText(source, tokens, "nested", 0)));
    try std.testing.expect(index.insideTestBlock(indexOfText(source, tokens, "block", 0)));
    try std.testing.expect(index.insideTestBlock(indexOfText(source, tokens, "anonymous", 0)));
}

test "statement starts look past groups and literals but not earlier blocks" {
    const source: [:0]const u8 =
        "fn run() void {\n" ++
        "    if (ready) { prepare(); }\n" ++
        "    defer report(.{ .code = 1 }, [_]u8{ 2 }, Point{ .x = 3 }) catch first;\n" ++
        "    call(nested(inner) catch second);\n" ++
        "}\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    const deferred = indexOfText(source, tokens, "defer", 0);
    try std.testing.expectEqual(deferred, index.statementStart(indexOfText(source, tokens, "first", 0)));
    try std.testing.expectEqual(indexOfText(source, tokens, "call", 0), index.statementStart(indexOfText(source, tokens, "second", 0)));
    try std.testing.expectEqual(indexOfText(source, tokens, "prepare", 0), index.statementStart(indexOfText(source, tokens, "prepare", 0) + 1));
    try std.testing.expectEqual(@as(usize, 0), index.statementStart(0));
}

test "usingnamespace uncertainty is limited to its container" {
    const source: [:0]const u8 =
        "const WithMixin = struct { usingnamespace Mixin; fn run() void { borrowed(); } };\n" ++
        "fn plain() void { missing(); }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var borrowed: ?usize = null;
    var missing: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (std.mem.eql(u8, tokenText(source, token), "borrowed")) borrowed = index;
        if (std.mem.eql(u8, tokenText(source, token), "missing")) missing = index;
    }
    try std.testing.expect(usingnamespaceMayProvideName(source, tokens, borrowed.?));
    try std.testing.expect(!usingnamespaceMayProvideName(source, tokens, missing.?));
}

test "enum and struct fields are recognized as container declarations" {
    const source: [:0]const u8 =
        "const State = enum { const Code = u8; ready, waiting = 2 };\n" ++
        "const Entry = struct { value: u8 };\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var declaration_count: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and isContainerFieldDeclaration(tokens, index)) declaration_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), declaration_count);
}

test "parameters remain visible after an error set return type" {
    const source: [:0]const u8 = "fn run(io: Io, delay: u64) error{Canceled}!void { try io.sleep(delay); }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var io_use: ?usize = null;
    var delay_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < std.mem.find(u8, source, "try io").?) continue;
        if (std.mem.eql(u8, tokenText(source, token), "io")) io_use = index;
        if (std.mem.eql(u8, tokenText(source, token), "delay")) delay_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, io_use.?) != null);
    try std.testing.expect(findBinding(source, tokens, delay_use.?) != null);
}

test "comptime parameters are visible in later parameter and return types" {
    const source: [:0]const u8 = "fn identity(comptime T: type, value: T) T { return value; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var resolved_type_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (!std.mem.eql(u8, tokenText(source, token), "T") or
            token.loc.start <= std.mem.find(u8, source, "T: type").?) continue;
        if (findBinding(source, tokens, index) != null) resolved_type_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_type_uses);
}

test "parameters remain visible after a labeled return type" {
    const source: [:0]const u8 =
        "fn call(self: u8, function: u8) result: { break :result u8; } { return self + function; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const body_start = std.mem.findLast(u8, source, "{ return").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < body_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "parameters remain visible after earlier anonymous struct parameters" {
    const source: [:0]const u8 =
        "fn run(first: struct { value: u8 }, options: struct { ready: bool }) void { _ = first; _ = options; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const body_start = std.mem.find(u8, source, "_ = first").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < body_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "pointer const qualifiers do not introduce destructuring bindings" {
    const source: [:0]const u8 = "const Target = struct {}; fn f(target: *const Target) void { const value = 1; _ = Target; _ = target; _ = value; }";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var index = try Index.init(std.testing.allocator, source, tokens);
    defer index.deinit();
    for (tokens, 0..) |token, use| {
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], "Target") or use == 1) continue;
        try std.testing.expectEqual(@as(usize, 1), index.findBinding(use).?.token_index);
    }
}

test "typed destructuring declarations introduce each binding" {
    const source: [:0]const u8 =
        "fn run(pair: struct { u8, u8 }) void { const first: u8, const second: u8 = pair; _ = first; _ = second; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const uses_start = std.mem.find(u8, source, "_ = first").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < uses_start or token.tag != .identifier) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "container declarations remain visible after fields" {
    const source: [:0]const u8 =
        "const Container = struct { value: State, const State = enum { ready }; };\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var state_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start < std.mem.find(u8, source, "value: State").? or
            token.loc.start >= std.mem.find(u8, source, "const State").?) continue;
        if (std.mem.eql(u8, tokenText(source, token), "State")) state_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, state_use.?) != null);
}

test "aligned and ABI-named container declarations resolve before their declaration" {
    const source: [:0]const u8 =
        "const first = aligned_table[0]; const second = &external_value;\n" ++
        "const aligned_table align(64) = [_]u8{1}; extern \"c\" var external_value: u8;\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const declarations_start = std.mem.find(u8, source, "const aligned_table").?;
    var resolved_uses: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= declarations_start or token.tag != .identifier) continue;
        const name = tokenText(source, token);
        if (!std.mem.eql(u8, name, "aligned_table") and !std.mem.eql(u8, name, "external_value")) continue;
        if (findBinding(source, tokens, index) != null) resolved_uses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), resolved_uses);
}

test "captures span an unbraced loop expression with another capture" {
    const source: [:0]const u8 =
        "fn run(optional: ?u8, values: []u8) void { if (optional) |name| for (values, 0..) |value, index| { _ = name + value + index; }; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const use_start = std.mem.find(u8, source, "_ = name").?;
    var name_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "name")) name_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, name_use.?) != null);
}

test "captures span an unbraced destructuring assignment" {
    const source: [:0]const u8 =
        "fn run(optional: ?Pair) void { var x: u8 = 0; var y: u8 = 0; if (optional) |pair| x, y = pair.values(); _ = x + y; }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const use_start = std.mem.find(u8, source, "pair.values").?;
    var pair_use: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.loc.start >= use_start and std.mem.eql(u8, tokenText(source, token), "pair")) pair_use = index;
    }
    try std.testing.expect(findBinding(source, tokens, pair_use.?) != null);
}

test "test-only bodies are private functions only tests and other test-only functions reach" {
    const source: [:0]const u8 =
        "fn scenario() void { fixture(); }\n" ++
        "fn fixture() void {}\n" ++
        "fn shared() void {}\n" ++
        "pub fn exported() void { shared(); }\n" ++
        "fn unused() void {}\n" ++
        "fn spin() void { spin(); }\n" ++
        "fn left() void { right(); }\n" ++
        "fn right() void { left(); }\n" ++
        "const Wrapper = struct { fn method() void {} };\n" ++
        "test \"a\" { scenario(); shared(); left(); Wrapper.method(); }\n";
    const tokens = try tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    var bodies = try testOnlyBodies(std.testing.allocator, source, tokens);
    defer bodies.deinit(std.testing.allocator);
    var inside: std.ArrayList([]const u8) = .empty;
    defer inside.deinit(std.testing.allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_fn or !bodies.contains(functionBodyAfterParameters(tokens, matchingToken(tokens, index + 2, .l_paren, .r_paren).?).?)) continue;
        try inside.append(std.testing.allocator, tokenText(source, tokens[index + 1]));
    }
    const expected = [_][]const u8{ "scenario", "fixture", "left", "right", "method" };
    try std.testing.expectEqual(expected.len, inside.items.len);
    for (expected, inside.items) |name, found| try std.testing.expectEqualStrings(name, found);
}

fn expectTrackedParenthesesMatchScan(tokens: []const std.zig.Token) !void {
    var tracker: ParenthesisTracker = .{ .nested = true };
    defer tracker.groups.deinit(std.testing.allocator);
    for (tokens, 0..) |token, token_index| {
        const tracked = tracker.current();
        try tracker.step(std.testing.allocator, token.tag, token_index);
        if (tracked == unknown_token) continue;
        const expected = enclosingOpeningParenthesis(tokens, token_index);
        try std.testing.expectEqual(expected, if (tracked == none_token) null else @as(?usize, tracked));
    }
}

test "tracked enclosing parentheses agree with the backward scan" {
    const sources = [_][:0]const u8{
        "const Big = struct { a: u8, b: u16 = 0, c: [n: 0]u8, };\n",
        "fn run(a: u8, b: struct { c: u8 }, d: [k: 0]u8) void { call(e: u8); const f = (g: { h; }); }\n",
        "fn broken(a: u8 }, b: u8) void { x(]; y: u8, }\n",
    };
    for (sources) |source| {
        const tokens = try tokenize(std.testing.allocator, source);
        defer std.testing.allocator.free(tokens);
        try expectTrackedParenthesesMatchScan(tokens);
    }
    // Generated delimiter sequences, mostly well nested, some not.
    const tags = [_]std.zig.Token.Tag{ .l_paren, .r_paren, .l_brace, .r_brace, .l_bracket, .r_bracket, .semicolon, .identifier };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var tokens: [96]std.zig.Token = undefined;
    for (0..400) |_| {
        var open: std.ArrayList(std.zig.Token.Tag) = .empty;
        defer open.deinit(std.testing.allocator);
        for (&tokens, 0..) |*token, position| {
            var tag = tags[random.uintLessThan(usize, tags.len)];
            if (open.last()) |closer| if (random.uintLessThan(u8, 10) < 7) switch (tag) {
                .r_paren, .r_brace, .r_bracket => tag = closer,
                else => {},
            };
            switch (tag) {
                .l_paren => try open.append(std.testing.allocator, .r_paren),
                .l_brace => try open.append(std.testing.allocator, .r_brace),
                .l_bracket => try open.append(std.testing.allocator, .r_bracket),
                .r_paren, .r_brace, .r_bracket => if (open.last() == tag) {
                    _ = open.pop();
                },
                else => {},
            }
            token.* = .{ .tag = tag, .loc = .{ .start = position, .end = position + 1 } };
        }
        try expectTrackedParenthesesMatchScan(&tokens);
    }
}
