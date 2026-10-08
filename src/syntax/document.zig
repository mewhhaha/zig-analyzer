const std = @import("std");
const lsp = @import("lsp");
const tokenize = @import("tokens.zig").tokenize;
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
    version: i32,
    generation: u32,
    source: [:0]u8,
    tree: std.zig.Ast,
    tokens: []const std.zig.Token,
    declarations: []Declaration,
    /// Which binding each identifier refers to: the one scope resolver that
    /// rename, references, hover and the lint rules share.
    scopes: syntax_scope.Index,

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
        var parsed = try parseSource(allocator, owned_source);
        errdefer parsed.deinit(allocator);
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
        };
    }

    pub fn deinit(document: *Document) void {
        document.scopes.deinit();
        document.tree.deinit(document.allocator);
        document.allocator.free(document.tokens);
        document.allocator.free(document.declarations);
        document.allocator.free(document.source);
        document.allocator.free(document.uri);
        document.* = undefined;
    }

    pub fn applyChanges(
        document: *Document,
        next_version: i32,
        changes: []const lsp.types.TextDocument.ContentChangeEvent,
    ) !void {
        if (next_version <= document.version) return error.StaleVersion;

        var current_source: [:0]const u8 = document.source;
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

        const next_source = owned_source orelse try copySource(document.allocator, document.source);
        errdefer document.allocator.free(next_source);

        var parsed = try parseSource(document.allocator, next_source);
        errdefer parsed.deinit(document.allocator);

        document.scopes.deinit();
        document.tree.deinit(document.allocator);
        document.allocator.free(document.tokens);
        document.allocator.free(document.declarations);
        document.allocator.free(document.source);
        document.source = next_source;
        document.tree = parsed.tree;
        document.tokens = parsed.tokens;
        document.declarations = parsed.declarations;
        document.scopes = parsed.scopes;
        document.version = next_version;
        document.generation +%= 1;
        if (document.generation == 0) document.generation = 1;
    }

    pub fn byteOffset(document: *const Document, position: lsp.types.Position) usize {
        return lsp.offsets.positionToIndex(document.source, position, .@"utf-16");
    }

    pub fn range(document: *const Document, span: std.zig.Token.Loc) lsp.types.Range {
        // Spans can come from compiler replies computed against different
        // text; locToRange asserts in-bounds codepoint-aligned offsets, so
        // clamp here instead of trusting the producer.
        return lsp.offsets.locToRange(document.source, clampSpan(document.source, span), .@"utf-16");
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
        for (document.declarations) |declaration| {
            if (std.mem.eql(u8, declaration.name, name)) return declaration;
        }
        return null;
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

    fn deinit(parsed: *ParsedSource, allocator: std.mem.Allocator) void {
        parsed.scopes.deinit();
        parsed.tree.deinit(allocator);
        allocator.free(parsed.tokens);
        allocator.free(parsed.declarations);
    }
};

fn parseSource(allocator: std.mem.Allocator, source: [:0]const u8) !ParsedSource {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    errdefer tree.deinit(allocator);
    const owned_tokens = try tokenize(allocator, source);
    errdefer allocator.free(owned_tokens);
    const declarations = try collectDeclarations(allocator, source, owned_tokens);
    errdefer allocator.free(declarations);
    const scopes = try syntax_scope.Index.init(allocator, source, owned_tokens);
    return .{ .tree = tree, .tokens = owned_tokens, .declarations = declarations, .scopes = scopes };
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
