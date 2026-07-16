const std = @import("std");
const lsp = @import("lsp");

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
    declarations: []Declaration,

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
            .declarations = parsed.declarations,
        };
    }

    pub fn deinit(document: *Document) void {
        document.tree.deinit(document.allocator);
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

        var next_source = try copySource(document.allocator, document.source);
        errdefer document.allocator.free(next_source);

        for (changes) |source_change| {
            const replacement = switch (source_change) {
                .text_document_content_change_whole_document => |whole| {
                    const replaced = try copySource(document.allocator, whole.text);
                    document.allocator.free(next_source);
                    next_source = replaced;
                    continue;
                },
                .text_document_content_change_partial => |partial| partial,
            };

            const changed_span = lsp.offsets.rangeToLoc(next_source, replacement.range, .@"utf-16");
            const replaced_length = changed_span.start + replacement.text.len + next_source.len - changed_span.end;
            const replaced_source = try document.allocator.allocSentinel(u8, replaced_length, 0);
            @memcpy(replaced_source[0..changed_span.start], next_source[0..changed_span.start]);
            @memcpy(
                replaced_source[changed_span.start..][0..replacement.text.len],
                replacement.text,
            );
            @memcpy(
                replaced_source[changed_span.start + replacement.text.len ..],
                next_source[changed_span.end..],
            );
            document.allocator.free(next_source);
            next_source = replaced_source;
        }

        var parsed = try parseSource(document.allocator, next_source);
        errdefer parsed.deinit(document.allocator);

        document.tree.deinit(document.allocator);
        document.allocator.free(document.declarations);
        document.allocator.free(document.source);
        document.source = next_source;
        document.tree = parsed.tree;
        document.declarations = parsed.declarations;
        document.version = next_version;
        document.generation +%= 1;
        if (document.generation == 0) document.generation = 1;
    }

    pub fn byteOffset(document: *const Document, position: lsp.types.Position) usize {
        return lsp.offsets.positionToIndex(document.source, position, .@"utf-16");
    }

    pub fn range(document: *const Document, span: std.zig.Token.Loc) lsp.types.Range {
        return lsp.offsets.locToRange(document.source, span, .@"utf-16");
    }

    pub fn declarationAt(document: *const Document, byte_offset: usize) ?Declaration {
        for (document.declarations) |declaration| {
            if (declaration.span.start <= byte_offset and byte_offset <= declaration.span.end) {
                return declaration;
            }
        }
        return null;
    }

    pub fn identifierAt(document: *const Document, byte_offset: usize) ?std.zig.Token.Loc {
        var tokenizer = std.zig.Tokenizer.init(document.source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) return null;
            if (token.tag != .identifier) continue;
            if (token.loc.start <= byte_offset and byte_offset <= token.loc.end) return token.loc;
        }
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
        var tokenizer = std.zig.Tokenizer.init(document.source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .identifier) continue;
            if (std.mem.eql(u8, document.source[token.loc.start..token.loc.end], name)) {
                try spans.append(allocator, token.loc);
            }
        }
        return try spans.toOwnedSlice(allocator);
    }

    pub fn scopedIdentifierSpans(
        document: *const Document,
        allocator: std.mem.Allocator,
        byte_offset: usize,
    ) !?[]std.zig.Token.Loc {
        var tokens: std.ArrayList(std.zig.Token) = .empty;
        defer tokens.deinit(allocator);
        var tokenizer = std.zig.Tokenizer.init(document.source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            try tokens.append(allocator, token);
        }

        const target_index = for (tokens.items, 0..) |token, index| {
            if (token.tag == .identifier and token.loc.start <= byte_offset and byte_offset <= token.loc.end) {
                break index;
            }
        } else return null;
        const target = tokens.items[target_index];
        const name = document.source[target.loc.start..target.loc.end];
        const binding = findBinding(tokens.items, document.source, target_index, name) orelse return null;

        var spans: std.ArrayList(std.zig.Token.Loc) = .empty;
        errdefer spans.deinit(allocator);
        for (tokens.items, 0..) |token, index| {
            if (token.tag != .identifier) continue;
            if (!std.mem.eql(u8, document.source[token.loc.start..token.loc.end], name)) continue;
            if (index == binding.token_index) {
                try spans.append(allocator, token.loc);
                continue;
            }
            if (token.loc.start < binding.scope.start or token.loc.end > binding.scope.end) continue;
            if (isInsideShadow(tokens.items, document.source, index, name, binding)) continue;
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
        if (try store.documents.fetchPut(store.allocator, document.uri, document)) |previous| {
            var previous_document = previous.value;
            previous_document.deinit();
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
    declarations: []Declaration,

    fn deinit(parsed: *ParsedSource, allocator: std.mem.Allocator) void {
        parsed.tree.deinit(allocator);
        allocator.free(parsed.declarations);
    }
};

fn parseSource(allocator: std.mem.Allocator, source: [:0]const u8) !ParsedSource {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    errdefer tree.deinit(allocator);
    const declarations = try collectDeclarations(allocator, source);
    return .{ .tree = tree, .declarations = declarations };
}

fn collectDeclarations(allocator: std.mem.Allocator, source: [:0]const u8) ![]Declaration {
    var declarations: std.ArrayList(Declaration) = .empty;
    errdefer declarations.deinit(allocator);

    var tokenizer = std.zig.Tokenizer.init(source);
    var expected_kind: ?Declaration.Kind = null;
    var brace_depth: u32 = 0;
    while (true) {
        const token = tokenizer.next();
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

fn copySource(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const owned = try allocator.allocSentinel(u8, source.len, 0);
    @memcpy(owned, source);
    return owned;
}

const Binding = struct {
    token_index: usize,
    scope: std.zig.Token.Loc,
};

fn findBinding(
    tokens: []const std.zig.Token,
    source: []const u8,
    target_index: usize,
    name: []const u8,
) ?Binding {
    var selected: ?Binding = null;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
        const scope = bindingScope(tokens, index, source.len) orelse continue;
        if (index != target_index and
            (tokens[target_index].loc.start < scope.start or tokens[target_index].loc.end > scope.end))
        {
            continue;
        }
        if (selected == null or scope.end - scope.start < selected.?.scope.end - selected.?.scope.start) {
            selected = .{ .token_index = index, .scope = scope };
        }
    }
    return selected;
}

fn bindingScope(tokens: []const std.zig.Token, identifier_index: usize, source_length: usize) ?std.zig.Token.Loc {
    if (identifier_index > 0 and identifier_index + 1 < tokens.len and
        tokens[identifier_index - 1].tag == .pipe and tokens[identifier_index + 1].tag == .pipe)
    {
        var body_index = identifier_index + 2;
        while (body_index < tokens.len and tokens[body_index].tag != .l_brace) : (body_index += 1) {}
        if (body_index == tokens.len) return null;
        const closing_brace = matchingToken(tokens, body_index, .l_brace, .r_brace) orelse return null;
        return .{
            .start = tokens[identifier_index].loc.end,
            .end = tokens[closing_brace].loc.end,
        };
    }
    if (identifier_index > 0) {
        switch (tokens[identifier_index - 1].tag) {
            .keyword_fn => return .{ .start = 0, .end = source_length },
            .keyword_const, .keyword_var => {
                const opening_brace = enclosingOpeningBrace(tokens, identifier_index) orelse {
                    return .{ .start = 0, .end = source_length };
                };
                const closing_brace = matchingToken(tokens, opening_brace, .l_brace, .r_brace) orelse return null;
                return .{
                    .start = tokens[identifier_index].loc.end,
                    .end = tokens[closing_brace].loc.end,
                };
            },
            else => {},
        }
    }
    if (identifier_index + 1 >= tokens.len or tokens[identifier_index + 1].tag != .colon) return null;

    const opening_parenthesis = enclosingOpeningParenthesis(tokens, identifier_index) orelse return null;
    const closing_parenthesis = matchingToken(tokens, opening_parenthesis, .l_paren, .r_paren) orelse return null;
    var body_index = closing_parenthesis + 1;
    while (body_index < tokens.len and tokens[body_index].tag != .l_brace) : (body_index += 1) {}
    if (body_index == tokens.len) return null;
    const closing_brace = matchingToken(tokens, body_index, .l_brace, .r_brace) orelse return null;
    return .{
        .start = tokens[body_index].loc.start,
        .end = tokens[closing_brace].loc.end,
    };
}

fn enclosingOpeningBrace(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn enclosingOpeningParenthesis(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            .l_brace, .semicolon => return null,
            else => {},
        }
    }
    return null;
}

fn matchingToken(
    tokens: []const std.zig.Token,
    opening_index: usize,
    opening_tag: std.zig.Token.Tag,
    closing_tag: std.zig.Token.Tag,
) ?usize {
    var depth: usize = 0;
    for (tokens[opening_index..], opening_index..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn isInsideShadow(
    tokens: []const std.zig.Token,
    source: []const u8,
    occurrence_index: usize,
    name: []const u8,
    selected: Binding,
) bool {
    for (tokens, 0..) |token, index| {
        if (index == selected.token_index or token.tag != .identifier) continue;
        if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) continue;
        const shadow_scope = bindingScope(tokens, index, source.len) orelse continue;
        if (shadow_scope.start < selected.scope.start or shadow_scope.end > selected.scope.end) continue;
        if (occurrence_index == index) return true;
        const occurrence = tokens[occurrence_index].loc;
        if (occurrence.start >= shadow_scope.start and occurrence.end <= shadow_scope.end) return true;
    }
    return false;
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
    const use_offset = std.mem.lastIndexOf(u8, source, "value").?;
    const spans = (try document.scopedIdentifierSpans(std.testing.allocator, use_offset)).?;
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("value", source[spans[0].start..spans[0].end]);
}
