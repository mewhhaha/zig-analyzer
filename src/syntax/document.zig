const std = @import("std");
const lsp = @import("lsp");
const tokens_util = @import("tokens.zig");
const tokenize = tokens_util.tokenize;
const syntax_scope = @import("scope.zig");

pub const Declaration = struct {
    name: []const u8,
    span: std.zig.Token.Loc,
    kind: Kind,
    brace_depth: u32,

    pub const Kind = enum {
        constant,
        variable,
        function,
    };
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    uri: []const u8,
    /// The newest version applied. While `edited` holds text not parsed yet,
    /// `source` and everything derived from it describe an older version.
    version: i32,
    generation: u32,
    source: [:0]u8,
    tree: std.zig.Ast,
    tokens: []const std.zig.Token,
    declarations: []Declaration,
    /// Which binding each identifier refers to: the one scope resolver that
    /// rename, references, hover and the lint rules share.
    scopes: syntax_scope.Index,
    /// The token nesting past the limits of `tokens.excessiveNesting` when the
    /// source is too deep to parse safely. The tree, tokens, declarations and
    /// scopes are then those of an empty file, and nothing is analyzed.
    excessive_nesting: ?std.zig.Token.Loc,
    /// Where each line of `source` starts, so positions convert in O(log n).
    line_starts: []const usize,
    /// The index in `declarations` of the first declaration of each name.
    declaration_names: std.StringHashMapUnmanaged(u32),
    /// Text `applyText` produced after `source`; `refresh` parses it.
    edited: ?[:0]u8 = null,

    pub fn open(
        allocator: std.mem.Allocator,
        uri: []const u8,
        version: i32,
        source: []const u8,
    ) !Document {
        const owned_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(owned_uri);
        const owned_source = try copySource(allocator, source);
        errdefer allocator.free(owned_source);
        const parsed = try parseSource(allocator, owned_source);
        return .{
            .allocator = allocator,
            .uri = owned_uri,
            .version = version,
            .generation = 1,
            .source = owned_source,
            .tree = parsed.tree,
            .tokens = parsed.tokens,
            .declarations = parsed.declarations,
            .scopes = parsed.scopes,
            .excessive_nesting = parsed.excessive_nesting,
            .line_starts = parsed.line_starts,
            .declaration_names = parsed.declaration_names,
        };
    }

    pub fn deinit(document: *Document) void {
        document.releaseSyntax();
        document.allocator.free(document.source);
        if (document.edited) |edited| document.allocator.free(edited);
        document.allocator.free(document.uri);
        document.* = undefined;
    }

    /// Frees what `parseSource` derived from `source`.
    fn releaseSyntax(document: *const Document) void {
        var parsed: ParsedSource = .{
            .tree = document.tree,
            .tokens = document.tokens,
            .declarations = document.declarations,
            .scopes = document.scopes,
            .line_starts = document.line_starts,
            .declaration_names = document.declaration_names,
        };
        parsed.deinit(document.allocator);
    }

    /// Applies `changes` and parses the result.
    pub fn applyChanges(
        document: *Document,
        next_version: i32,
        changes: []const lsp.types.TextDocument.ContentChangeEvent,
    ) !void {
        try document.applyText(next_version, changes);
        try document.refresh();
    }

    /// Applies `changes` to the text only. Until `refresh`, `source` and
    /// everything derived from it keep describing the text before them, so a
    /// burst of edits is parsed once.
    pub fn applyText(
        document: *Document,
        next_version: i32,
        changes: []const lsp.types.TextDocument.ContentChangeEvent,
    ) !void {
        if (next_version <= document.version) return error.StaleVersion;

        const previous_source = document.text();
        var current_source: [:0]const u8 = previous_source;
        var owned_source: ?[:0]u8 = null;
        errdefer if (owned_source) |owned| document.allocator.free(owned);

        for (changes) |source_change| {
            const replacement = switch (source_change) {
                .text_document_content_change_whole_document => |whole| {
                    const replaced = try copySource(document.allocator, whole.text);
                    if (owned_source) |owned| document.allocator.free(owned);
                    owned_source = replaced;
                    current_source = replaced;
                    continue;
                },
                .text_document_content_change_partial => |partial| partial,
            };

            if (lsp.offsets.orderPosition(replacement.range.start, replacement.range.end) == .gt) {
                return error.InvalidRange;
            }
            const changed_span = lsp.offsets.rangeToLoc(current_source, replacement.range, .@"utf-16");
            const prefix_length = std.math.add(
                usize,
                changed_span.start,
                replacement.text.len,
            ) catch |err| switch (err) {
                error.Overflow => return error.InvalidRange,
            };
            const replaced_length = std.math.add(
                usize,
                prefix_length,
                current_source.len - changed_span.end,
            ) catch |err| switch (err) {
                error.Overflow => return error.InvalidRange,
            };
            const replaced_source = try document.allocator.allocSentinel(u8, replaced_length, 0);
            @memcpy(replaced_source[0..changed_span.start], current_source[0..changed_span.start]);
            @memcpy(
                replaced_source[changed_span.start..][0..replacement.text.len],
                replacement.text,
            );
            @memcpy(
                replaced_source[changed_span.start + replacement.text.len ..],
                current_source[changed_span.end..],
            );
            if (owned_source) |owned| document.allocator.free(owned);
            owned_source = replaced_source;
            current_source = replaced_source;
        }

        const next_source = owned_source orelse try copySource(document.allocator, previous_source);
        if (document.edited) |edited| document.allocator.free(edited);
        document.edited = next_source;
        document.version = next_version;
    }

    /// Parses the text `applyText` left, if any, and makes it the source.
    pub fn refresh(document: *Document) !void {
        const next_source = document.edited orelse return;
        const parsed = try parseSource(document.allocator, next_source);
        document.releaseSyntax();
        document.allocator.free(document.source);
        document.edited = null;
        document.source = next_source;
        document.tree = parsed.tree;
        document.tokens = parsed.tokens;
        document.declarations = parsed.declarations;
        document.scopes = parsed.scopes;
        document.excessive_nesting = parsed.excessive_nesting;
        document.line_starts = parsed.line_starts;
        document.declaration_names = parsed.declaration_names;
        document.generation +%= 1;
        if (document.generation == 0) document.generation = 1;
    }

    /// The newest text, which `source` lags behind until `refresh`.
    pub fn text(document: *const Document) [:0]const u8 {
        return document.edited orelse document.source;
    }

    pub fn byteOffset(document: *const Document, position: lsp.types.Position) usize {
        if (position.line >= document.line_starts.len) return document.source.len;
        const line_start = document.line_starts[position.line];
        const line = std.mem.sliceTo(document.source[line_start..], '\n');
        return line_start + lsp.offsets.getNCodeUnitByteCount(line, position.character, .@"utf-16");
    }

    pub fn range(document: *const Document, span: std.zig.Token.Loc) lsp.types.Range {
        // Spans can come from compiler replies computed against different
        // text; positions need in-bounds codepoint-aligned offsets, so clamp
        // here instead of trusting the producer.
        const clamped = clampSpan(document.source, span);
        return .{ .start = document.positionAt(clamped.start), .end = document.positionAt(clamped.end) };
    }

    /// The bytes of lines `first` through `last`, each line's newline left out
    /// but the end inclusive: exactly the offsets whose positions lie on them.
    pub fn lineSpan(document: *const Document, first: u32, last: u32) std.zig.Token.Loc {
        const starts = document.line_starts;
        if (first >= starts.len) return .{ .start = document.source.len, .end = document.source.len };
        const end = if (@as(usize, last) + 1 < starts.len) starts[last + 1] - 1 else document.source.len;
        return .{ .start = starts[first], .end = @max(starts[first], end) };
    }

    /// Index of the first token starting at or after `offset`.
    pub fn firstTokenFrom(document: *const Document, offset: usize) usize {
        return std.sort.lowerBound(std.zig.Token, document.tokens, offset, struct {
            fn order(target: usize, token: std.zig.Token) std.math.Order {
                return std.math.order(target, token.loc.start);
            }
        }.order);
    }

    /// The position of `offset`, an in-bounds codepoint boundary of `source`:
    /// a binary search for its line, then UTF-16 units counted within it.
    fn positionAt(document: *const Document, offset: usize) lsp.types.Position {
        const line = tokens_util.lineOf(document.line_starts, offset);
        const line_text = document.source[document.line_starts[line]..offset];
        return .{ .line = @intCast(line), .character = @intCast(lsp.offsets.countCodeUnits(line_text, .@"utf-16")) };
    }

    pub fn identifierAt(document: *const Document, byte_offset: usize) ?std.zig.Token.Loc {
        const token = document.tokenAt(byte_offset) orelse return null;
        return if (token.tag == .identifier) token.loc else null;
    }

    pub fn tokenAt(document: *const Document, byte_offset: usize) ?std.zig.Token {
        var token_ending_at_offset: ?std.zig.Token = null;
        for (document.tokens) |token| {
            if (token.tag == .eof or token.loc.start > byte_offset) return token_ending_at_offset;
            if (token.loc.start <= byte_offset and byte_offset < token.loc.end) return token;
            if (token.loc.end == byte_offset) token_ending_at_offset = token;
        }
        return token_ending_at_offset;
    }

    pub fn declarationNamed(document: *const Document, name: []const u8) ?Declaration {
        const index = document.declaration_names.get(name) orelse return null;
        return document.declarations[index];
    }

    /// Whether some declaration's name spans exactly `span`.
    pub fn declaresSpan(document: *const Document, span: std.zig.Token.Loc) bool {
        // Declarations are collected in source order.
        const index = std.sort.lowerBound(Declaration, document.declarations, span.start, struct {
            fn order(start: usize, declaration: Declaration) std.math.Order {
                return std.math.order(start, declaration.span.start);
            }
        }.order);
        return index < document.declarations.len and std.meta.eql(document.declarations[index].span, span);
    }

    pub fn identifierSpans(
        document: *const Document,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]std.zig.Token.Loc {
        var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
        errdefer spans.deinit(allocator);
        for (document.tokens) |token| {
            if (token.tag == .eof) break;
            if (token.tag != .identifier) continue;
            if (std.mem.eql(u8, document.source[token.loc.start..token.loc.end], name)) {
                try spans.append(allocator, token.loc);
            }
        }
        return try spans.toOwnedSlice(allocator);
    }

    /// Every occurrence of the binding that the identifier at `byte_offset`
    /// refers to, the declaration first, or null when it refers to no local
    /// binding. Member names after a `.` are never occurrences.
    pub fn scopedIdentifierSpans(
        document: *const Document,
        allocator: std.mem.Allocator,
        byte_offset: usize,
    ) !?[]std.zig.Token.Loc {
        const target_index = for (document.tokens, 0..) |token, index| {
            if (token.tag == .eof) return null;
            if (token.tag == .identifier and token.loc.start <= byte_offset and byte_offset <= token.loc.end) break index;
        } else return null;
        const binding = document.scopes.resolve(target_index) orelse return null;
        const name = document.source[document.tokens[target_index].loc.start..document.tokens[target_index].loc.end];

        var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
        errdefer spans.deinit(allocator);
        try spans.append(allocator, document.tokens[binding.token_index].loc);
        for (document.tokens, 0..) |token, index| {
            if (token.tag == .eof) break;
            if (token.tag != .identifier or index == binding.token_index) continue;
            if (!std.mem.eql(u8, document.source[token.loc.start..token.loc.end], name)) continue;
            if (index > 0 and document.tokens[index - 1].tag == .period) continue;
            const resolved = document.scopes.resolve(index) orelse continue;
            if (resolved.token_index != binding.token_index) continue;
            try spans.append(allocator, token.loc);
        }
        return try spans.toOwnedSlice(allocator);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    documents: std.StringHashMapUnmanaged(Document) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(store: *Store) void {
        var iterator = store.documents.valueIterator();
        while (iterator.next()) |document| document.deinit();
        store.documents.deinit(store.allocator);
        store.* = undefined;
    }

    pub fn open(
        store: *Store,
        uri: []const u8,
        version: i32,
        source: []const u8,
    ) !void {
        var document = try Document.open(store.allocator, uri, version, source);
        errdefer document.deinit();
        const entry = try store.documents.getOrPut(store.allocator, document.uri);
        if (entry.found_existing) {
            var previous_document = entry.value_ptr.*;
            entry.key_ptr.* = document.uri;
            entry.value_ptr.* = document;
            previous_document.deinit();
        } else {
            entry.value_ptr.* = document;
        }
    }

    pub fn change(
        store: *Store,
        uri: []const u8,
        version: i32,
        changes: []const lsp.types.TextDocument.ContentChangeEvent,
    ) !void {
        const document = store.documents.getPtr(uri) orelse return error.DocumentNotOpen;
        try document.applyChanges(version, changes);
    }

    /// `change` without parsing: see `Document.applyText`.
    pub fn changeText(
        store: *Store,
        uri: []const u8,
        version: i32,
        changes: []const lsp.types.TextDocument.ContentChangeEvent,
    ) !void {
        const document = store.documents.getPtr(uri) orelse return error.DocumentNotOpen;
        try document.applyText(version, changes);
    }

    /// Parses every document whose text changed since it was parsed.
    pub fn refresh(store: *Store) !void {
        var documents = store.documents.valueIterator();
        while (documents.next()) |document| try document.refresh();
    }

    pub fn close(store: *Store, uri: []const u8) bool {
        const removed = store.documents.fetchRemove(uri) orelse return false;
        var document = removed.value;
        document.deinit();
        return true;
    }

    pub fn get(store: *Store, uri: []const u8) ?*Document {
        return store.documents.getPtr(uri);
    }

    pub fn getConst(store: *const Store, uri: []const u8) ?*const Document {
        return store.documents.getPtr(uri);
    }
};

const ParsedSource = struct {
    tree: std.zig.Ast,
    tokens: []const std.zig.Token,
    declarations: []Declaration,
    scopes: syntax_scope.Index,
    excessive_nesting: ?std.zig.Token.Loc = null,
    line_starts: []const usize = &.{},
    declaration_names: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(parsed: *ParsedSource, allocator: std.mem.Allocator) void {
        parsed.declaration_names.deinit(allocator);
        allocator.free(parsed.line_starts);
        parsed.scopes.deinit();
        parsed.tree.deinit(allocator);
        allocator.free(parsed.tokens);
        allocator.free(parsed.declarations);
    }
};

fn parseSource(allocator: std.mem.Allocator, source: [:0]const u8) !ParsedSource {
    const line_starts = try tokens_util.lineStarts(allocator, source);
    errdefer allocator.free(line_starts);
    const owned_tokens = try tokenize(allocator, source);
    var parsed = if (tokens_util.excessiveNesting(owned_tokens)) |excess| deep: {
        // Parsing would overflow the stack: stand in an empty file.
        const span = owned_tokens[excess].loc;
        allocator.free(owned_tokens);
        var empty = try parseTokens(allocator, "", try tokenize(allocator, ""));
        empty.excessive_nesting = span;
        break :deep empty;
    } else try parseTokens(allocator, source, owned_tokens);
    parsed.line_starts = line_starts;
    return parsed;
}

/// Takes ownership of `owned_tokens`, the tokens of `source`.
fn parseTokens(allocator: std.mem.Allocator, source: [:0]const u8, owned_tokens: []const std.zig.Token) !ParsedSource {
    errdefer allocator.free(owned_tokens);
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    errdefer tree.deinit(allocator);
    const declarations = try collectDeclarations(allocator, source, owned_tokens);
    errdefer allocator.free(declarations);
    var declaration_names: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer declaration_names.deinit(allocator);
    for (declarations, 0..) |declaration, index| {
        const entry = try declaration_names.getOrPut(allocator, declaration.name);
        if (!entry.found_existing) entry.value_ptr.* = @intCast(index);
    }
    const scopes = try syntax_scope.Index.init(allocator, source, owned_tokens);
    return .{
        .tree = tree,
        .tokens = owned_tokens,
        .declarations = declarations,
        .scopes = scopes,
        .declaration_names = declaration_names,
    };
}

fn collectDeclarations(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
) ![]Declaration {
    var declarations: std.ArrayList(Declaration) = .empty;
    errdefer declarations.deinit(allocator);

    var expected_kind: ?Declaration.Kind = null;
    var brace_depth: u32 = 0;
    for (tokens) |token| {
        switch (token.tag) {
            .keyword_const => expected_kind = .constant,
            .keyword_var => expected_kind = .variable,
            .keyword_fn => expected_kind = .function,
            .identifier => if (expected_kind) |kind| {
                try declarations.append(allocator, .{
                    .name = source[token.loc.start..token.loc.end],
                    .span = token.loc,
                    .kind = kind,
                    .brace_depth = brace_depth,
                });
                expected_kind = null;
            },
            .l_brace => {
                brace_depth += 1;
                expected_kind = null;
            },
            .r_brace => {
                brace_depth -|= 1;
                expected_kind = null;
            },
            .doc_comment,
            .container_doc_comment,
            .keyword_pub,
            .keyword_export,
            .keyword_extern,
            .keyword_inline,
            .keyword_noinline,
            .keyword_threadlocal,
            .keyword_comptime,
            => {},
            .eof => break,
            else => {
                if (expected_kind != null) expected_kind = null;
            },
        }
    }
    return try declarations.toOwnedSlice(allocator);
}

fn clampSpan(source: []const u8, span: std.zig.Token.Loc) std.zig.Token.Loc {
    var start = @min(span.start, source.len);
    var end = @min(@max(span.end, start), source.len);
    while (start > 0 and start < source.len and isUtf8Continuation(source[start])) start -= 1;
    while (end > start and end < source.len and isUtf8Continuation(source[end])) end -= 1;
    return .{ .start = start, .end = end };
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn copySource(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const owned = try allocator.allocSentinel(u8, source.len, 0);
    @memcpy(owned, source);
    return owned;
}

test "document indexes declarations despite a trailing parse error" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const generated = struct {\n    fn answer() u8 { return 42; }\n};\nconst broken =",
    );
    defer document.deinit();

    try std.testing.expect(document.tree.errors.len != 0);
    try std.testing.expectEqual(@as(usize, 3), document.declarations.len);
    try std.testing.expectEqualStrings("generated", document.declarations[0].name);
    try std.testing.expectEqualStrings("answer", document.declarations[1].name);
    try std.testing.expectEqualStrings("broken", document.declarations[2].name);
}

test "a document nested too deep to parse stands in an empty file until it is fixed" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "const x = ");
    for (0..50_000) |_| try text.appendSlice(allocator, "[(");
    const blob = text.items;
    var document = try Document.open(allocator, "file:///blob.zig", 1, blob);
    defer document.deinit();
    try std.testing.expectEqualStrings("[", blob[document.excessive_nesting.?.start..document.excessive_nesting.?.end]);
    try std.testing.expectEqual(@as(usize, 1), document.tokens.len);
    try std.testing.expectEqual(@as(usize, 0), document.tree.errors.len);
    try std.testing.expectEqual(@as(usize, 0), document.declarations.len);
    try std.testing.expect(document.tokenAt(20) == null);

    try document.applyChanges(2, &.{.{ .text_document_content_change_whole_document = .{ .text = "const x = 1;\n" } }});
    try std.testing.expectEqual(@as(?std.zig.Token.Loc, null), document.excessive_nesting);
    try std.testing.expectEqualStrings("x", document.declarations[0].name);
}

test "indexed positions agree with a scan of the whole text" {
    const source = "const 🦎 = \"¶↉\";\n\n  x\r\n🇺🇸 y\n";
    var document = try Document.open(std.testing.allocator, "file:///positions.zig", 1, source);
    defer document.deinit();
    for (0..source.len + 1) |offset| {
        if (offset < source.len and source[offset] & 0b1100_0000 == 0b1000_0000) continue;
        const expected = lsp.offsets.indexToPosition(source, offset, .@"utf-16");
        try std.testing.expectEqual(expected, document.range(.{ .start = offset, .end = offset }).start);
        try std.testing.expectEqual(lsp.offsets.locToRange(source, .{ .start = 0, .end = offset }, .@"utf-16"), document.range(.{ .start = 0, .end = offset }));
    }
    for (0..7) |line| for (0..20) |character| {
        const position: lsp.types.Position = .{ .line = @intCast(line), .character = @intCast(character) };
        try std.testing.expectEqual(lsp.offsets.positionToIndex(source, position, .@"utf-16"), document.byteOffset(position));
    };
}

test "text edits wait for a refresh while the parsed source stays whole" {
    var document = try Document.open(std.testing.allocator, "file:///deferred.zig", 1, "const first = 1;\n");
    defer document.deinit();
    try document.applyText(2, &.{.{ .text_document_content_change_whole_document = .{ .text = "const second = 2;\n" } }});
    try document.applyText(3, &.{.{ .text_document_content_change_partial = .{
        .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 0 } },
        .text = "const third = 3;\n",
    } }});
    try std.testing.expectError(error.StaleVersion, document.applyText(3, &.{}));
    try std.testing.expectEqual(@as(i32, 3), document.version);
    try std.testing.expectEqualStrings("const first = 1;\n", document.source);
    try std.testing.expectEqualStrings("first", document.declarations[0].name);
    try std.testing.expectEqualStrings("const second = 2;\nconst third = 3;\n", document.text());

    try document.refresh();
    try std.testing.expectEqual(@as(?[:0]u8, null), document.edited);
    try std.testing.expectEqualStrings("const second = 2;\nconst third = 3;\n", document.source);
    try std.testing.expectEqualStrings("third", document.declarationNamed("third").?.name);
    try std.testing.expect(document.declarationNamed("first") == null);
    try std.testing.expectEqual(@as(u32, 1), document.range(document.declarationNamed("third").?.span).start.line);
}

test "incremental changes use UTF-16 positions" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const 🦎name = 1;\n");
    defer document.deinit();

    const changes = [_]lsp.types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 8 },
                .end = .{ .line = 0, .character = 12 },
            },
            .text = "value",
        },
    }};
    try document.applyChanges(2, &changes);
    try std.testing.expectEqualStrings("const 🦎value = 1;\n", document.source);
}

test "document rejects a reversed change range without changing source" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "const stable = 1;\n");
    defer document.deinit();

    const changes = [_]lsp.types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 10 },
                .end = .{ .line = 0, .character = 4 },
            },
            .text = "renamed",
        },
    }};
    try std.testing.expectError(error.InvalidRange, document.applyChanges(2, &changes));
    try std.testing.expectEqualStrings("const stable = 1;\n", document.source);
}

test "range clamps spans that outlive the source and snaps mid-codepoint offsets" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "\"😀\" ok");
    defer document.deinit();

    const past_end = document.range(.{ .start = 3, .end = 100 });
    try std.testing.expectEqual(@as(u32, 1), past_end.start.character);
    try std.testing.expectEqual(@as(u32, 7), past_end.end.character);

    const inside_codepoint = document.range(.{ .start = 2, .end = 3 });
    try std.testing.expectEqual(@as(u32, 1), inside_codepoint.start.character);
    try std.testing.expectEqual(@as(u32, 1), inside_codepoint.end.character);

    const reversed = document.range(.{ .start = 6, .end = 1 });
    try std.testing.expectEqual(reversed.start, reversed.end);
}

test "document rejects stale versions without changing source" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 4, "const stable = 1;\n");
    defer document.deinit();

    const changes = [_]lsp.types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_whole_document = .{ .text = "const stale = 2;\n" },
    }};
    try std.testing.expectError(error.StaleVersion, document.applyChanges(4, &changes));
    try std.testing.expectEqualStrings("const stable = 1;\n", document.source);
}

test "store owns URI keys and closes documents" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.open("file:///fixture.zig", 1, "const value = 1;\n");
    try std.testing.expect(store.get("file:///fixture.zig") != null);
    for (2..5) |version| {
        try store.open("file:///fixture.zig", @intCast(version), "const replacement = 2;\n");
        const reopened = store.get("file:///fixture.zig").?;
        try std.testing.expectEqual(@as(i32, @intCast(version)), reopened.version);
        try std.testing.expectEqualStrings("const replacement = 2;\n", reopened.source);
    }
    try std.testing.expect(store.close("file:///fixture.zig"));
    try std.testing.expect(store.get("file:///fixture.zig") == null);
}

test "identifier lookup finds declarations and every reference" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const answer = 42;\nconst copy = answer;\n",
    );
    defer document.deinit();

    const identifier_span = document.identifierAt(36).?;
    const name = document.source[identifier_span.start..identifier_span.end];
    try std.testing.expectEqualStrings("answer", name);
    try std.testing.expectEqualStrings("answer", document.declarationNamed(name).?.name);

    const reference_spans = try document.identifierSpans(std.testing.allocator, name);
    defer std.testing.allocator.free(reference_spans);
    try std.testing.expectEqual(@as(usize, 2), reference_spans.len);
}

test "token lookup prefers punctuation beginning at an identifier boundary" {
    var document = try Document.open(std.testing.allocator, "file:///fixture.zig", 1, "value+1;\n");
    defer document.deinit();

    try std.testing.expectEqual(std.zig.Token.Tag.plus, document.tokenAt(5).?.tag);
    try std.testing.expectEqual(std.zig.Token.Tag.semicolon, document.tokenAt(7).?.tag);
    try std.testing.expect(document.identifierAt(5) == null);
}

test "scoped identifier lookup excludes an unrelated parameter" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "fn increment(value: u32) u32 { return value + 1; }\nfn describe(value: []const u8) []const u8 { return value; }\n",
    );
    defer document.deinit();

    const spans = (try document.scopedIdentifierSpans(std.testing.allocator, 13)).?;
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    for (spans) |span| {
        try std.testing.expect(span.start < 52);
    }
}

test "scoped identifier lookup follows a loop capture" {
    const source = "fn run(values: []const u32) void { for (values) |value| { _ = value; } }";
    var document = try Document.open(std.testing.allocator, "file:///capture.zig", 1, source);
    defer document.deinit();
    const use_offset = std.mem.findLast(u8, source, "value").?;
    const spans = (try document.scopedIdentifierSpans(std.testing.allocator, use_offset)).?;
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("value", source[spans[0].start..spans[0].end]);
}
