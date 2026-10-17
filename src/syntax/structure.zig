//! Where things are in one document, for editor views that only need its
//! shape: the regions an editor folds, the nested spans a selection grows
//! through, how each occurrence of a binding uses it, the files `@import` and
//! `@embedFile` strings name, and the named `test` declarations. Offsets are
//! bytes and lines are zero-based; the transport converts them to positions.
const std = @import("std");
const document_module = @import("document.zig");
const tokens_util = @import("tokens.zig");

const Document = document_module.Document;
const Loc = std.zig.Token.Loc;
const Token = std.zig.Token;

pub const Fold = struct {
    start_line: u32,
    /// The last line hidden with the fold. A closing delimiter that starts its
    /// line stays visible, so a block folds to its first line and its `}`.
    end_line: u32,
    kind: Kind,

    pub const Kind = enum { code, comment, imports };
};

/// Every foldable region of `document`, by start line, at most one per line:
/// multi-line blocks, containers, argument and parameter lists, runs of
/// comment or doc-comment lines, multi-line string literals, and groups of
/// top-level imports. One pass over the text and one over the tokens.
pub fn folds(allocator: std.mem.Allocator, document: *const Document) ![]Fold {
    const source = document.source;
    const tokens = document.tokens;
    const lines = try allocator.alloc(u32, tokens.len);
    defer allocator.free(lines);
    var found: std.ArrayList(Fold) = .empty;
    errdefer found.deinit(allocator);

    // The text pass: each token's line, and the runs of whole-line `//`
    // comments in the gaps between tokens (the tokenizer skips them).
    var comments: Run = .{ .kind = .comment };
    var line: u32 = 0;
    var offset: usize = 0;
    var line_has_token = false;
    for (tokens, lines) |token, *token_line| {
        while (offset < token.loc.start) {
            switch (source[offset]) {
                '\n' => {
                    line += 1;
                    line_has_token = false;
                    offset += 1;
                },
                '/' => {
                    if (!line_has_token) try comments.add(allocator, &found, line);
                    const line_end = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len;
                    offset = @min(line_end, token.loc.start);
                },
                else => offset += 1,
            }
        }
        token_line.* = line;
        line_has_token = true;
        offset = @max(offset, token.loc.end);
        line += @intCast(std.mem.countScalar(u8, source[token.loc.start..offset], '\n'));
    }
    try comments.finish(allocator, &found);

    var documentation: Run = .{ .kind = .comment };
    var documentation_tag: Token.Tag = .doc_comment;
    var string_lines: Run = .{ .kind = .code };
    var imports: Run = .{ .kind = .imports };
    var import_end: ?usize = null;
    for (tokens, 0..) |token, index| {
        switch (token.tag) {
            .doc_comment, .container_doc_comment => {
                if (token.tag != documentation_tag) try documentation.finish(allocator, &found);
                documentation_tag = token.tag;
                try documentation.add(allocator, &found, lines[index]);
            },
            .multiline_string_literal_line => try string_lines.add(allocator, &found, lines[index]),
            .l_brace, .l_paren, .l_bracket => if (document.scopes.matchingToken(index)) |closing| {
                const closing_line = lines[closing];
                const end_line = if (lines[closing - 1] < closing_line) closing_line - 1 else closing_line;
                if (end_line > lines[index]) try found.append(allocator, .{ .start_line = lines[index], .end_line = end_line, .kind = .code });
            },
            else => {},
        }
        if (token.tag != .doc_comment and token.tag != .container_doc_comment) try documentation.finish(allocator, &found);
        if (token.tag != .multiline_string_literal_line) try string_lines.finish(allocator, &found);

        // Imports group by adjacency in the token stream, so blank lines
        // between the standard library and local imports keep one group.
        if (import_end) |end| if (index <= end) continue;
        const declaration = topLevelAlias(document, index) orelse continue;
        if (import_end == null or import_end.? + 1 != index) {
            try imports.finish(allocator, &found);
            imports = .{ .kind = .imports, .start = lines[index], .active = true };
        }
        if (declaration.imports) imports.has_import = true;
        imports.end = lines[declaration.end];
        import_end = declaration.end;
    }
    try imports.finish(allocator, &found);

    std.mem.sort(Fold, found.items, {}, struct {
        fn lessThan(_: void, left: Fold, right: Fold) bool {
            if (left.start_line != right.start_line) return left.start_line < right.start_line;
            return left.end_line < right.end_line;
        }
    }.lessThan);
    // Editors show one fold per start line; keep the smallest, which ends at
    // the delimiter that closes the line's own block.
    var kept: usize = 0;
    for (found.items) |fold| {
        if (kept != 0 and found.items[kept - 1].start_line == fold.start_line) continue;
        found.items[kept] = fold;
        kept += 1;
    }
    found.shrinkRetainingCapacity(kept);
    return try found.toOwnedSlice(allocator);
}

/// Consecutive lines of one kind, folded once they span two lines or more.
const Run = struct {
    kind: Fold.Kind,
    start: u32 = 0,
    end: u32 = 0,
    active: bool = false,
    /// Import runs fold only when at least one member is an `@import`.
    has_import: bool = false,

    fn add(run: *Run, allocator: std.mem.Allocator, found: *std.ArrayList(Fold), line: u32) !void {
        if (run.active and line == run.end + 1) {
            run.end = line;
            return;
        }
        try run.finish(allocator, found);
        run.* = .{ .kind = run.kind, .start = line, .end = line, .active = true };
    }

    fn finish(run: *Run, allocator: std.mem.Allocator, found: *std.ArrayList(Fold)) !void {
        defer run.* = .{ .kind = run.kind };
        if (!run.active or run.end <= run.start) return;
        if (run.kind == .imports and !run.has_import) return;
        try found.append(allocator, .{ .start_line = run.start, .end_line = run.end, .kind = run.kind });
    }
};

const Alias = struct {
    /// The `;` ending the declaration.
    end: usize,
    imports: bool,
};

/// The top-level `const name = @import("...")...;` or `const name = a.b;`
/// starting at token `index` (its `pub` or `const`).
fn topLevelAlias(document: *const Document, index: usize) ?Alias {
    const tokens = document.tokens;
    var cursor = index;
    if (tokens[cursor].tag == .keyword_pub) cursor += 1;
    if (cursor + 3 >= tokens.len or tokens[cursor].tag != .keyword_const or
        tokens[cursor + 1].tag != .identifier or tokens[cursor + 2].tag != .equal) return null;
    if (index > 0 and tokens[index - 1].tag == .keyword_pub) return null;
    if (document.scopes.enclosingOpeningBrace(index) != null) return null;
    cursor += 3;
    var imports = false;
    if (tokens[cursor].tag == .builtin and tokens_util.tokenIs(document.source, tokens[cursor], "@import")) {
        if (cursor + 3 >= tokens.len or tokens[cursor + 1].tag != .l_paren or
            tokens[cursor + 2].tag != .string_literal or tokens[cursor + 3].tag != .r_paren) return null;
        imports = true;
        cursor += 4;
    } else {
        if (tokens[cursor].tag != .identifier) return null;
        cursor += 1;
    }
    while (cursor + 1 < tokens.len and tokens[cursor].tag == .period and tokens[cursor + 1].tag == .identifier) cursor += 2;
    if (cursor >= tokens.len or tokens[cursor].tag != .semicolon) return null;
    return .{ .end = cursor, .imports = imports };
}

/// For each offset, the spans a selection grows through, innermost first:
/// the token at the offset, each syntax node containing it, and the whole
/// source. Every span strictly contains the one before. One pass over the
/// syntax tree serves all offsets.
pub fn selectionChains(
    allocator: std.mem.Allocator,
    document: *const Document,
    offsets: []const usize,
) ![]const []const Loc {
    const tree = &document.tree;
    const candidates = try allocator.alloc(std.ArrayList(Loc), offsets.len);
    defer allocator.free(candidates);
    @memset(candidates, .empty);
    defer for (candidates) |*candidate| candidate.deinit(allocator);
    for (offsets, candidates) |offset, *candidate| {
        if (document.tokenAt(offset)) |token| if (token.tag != .eof) try candidate.append(allocator, token.loc);
    }
    for (1..tree.nodes.len) |node_index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(node_index));
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (last < first or last >= document.tokens.len) continue;
        const span: Loc = .{ .start = document.tokens[first].loc.start, .end = document.tokens[last].loc.end };
        for (offsets, candidates) |offset, *candidate| {
            if (span.start <= offset and offset <= span.end) try candidate.append(allocator, span);
        }
    }

    const chains = try allocator.alloc([]const Loc, offsets.len);
    var built: usize = 0;
    errdefer {
        for (chains[0..built]) |chain| allocator.free(chain);
        allocator.free(chains);
    }
    for (candidates, chains) |*candidate, *chain| {
        try candidate.append(allocator, .{ .start = 0, .end = document.source.len });
        std.mem.sort(Loc, candidate.items, {}, struct {
            fn lessThan(_: void, left: Loc, right: Loc) bool {
                const left_length = left.end - left.start;
                const right_length = right.end - right.start;
                if (left_length != right_length) return left_length < right_length;
                return left.start > right.start;
            }
        }.lessThan);
        var nested: std.ArrayList(Loc) = .empty;
        errdefer nested.deinit(allocator);
        for (candidate.items) |span| {
            if (nested.last()) |inner| {
                if (std.meta.eql(inner, span) or span.start > inner.start or span.end < inner.end) continue;
            }
            try nested.append(allocator, span);
        }
        chain.* = try nested.toOwnedSlice(allocator);
        built += 1;
    }
    return chains;
}

pub const Access = enum { read, write };

pub const Occurrence = struct {
    span: Loc,
    access: Access,
};

/// Every occurrence of the binding the identifier at `byte_offset` refers to,
/// the declaration first, with whether it writes the binding (its declaration
/// or an assignment to it) or reads it; null when the identifier refers to no
/// binding the scope index knows.
pub fn bindingOccurrences(
    allocator: std.mem.Allocator,
    document: *const Document,
    byte_offset: usize,
) !?[]Occurrence {
    const spans = try document.scopedIdentifierSpans(allocator, byte_offset) orelse return null;
    defer allocator.free(spans);
    const occurrences = try allocator.alloc(Occurrence, spans.len);
    for (spans, occurrences, 0..) |span, *occurrence, position| {
        occurrence.* = .{ .span = span, .access = if (position == 0 or assignedAt(document.tokens, span)) .write else .read };
    }
    return occurrences;
}

/// Whether the identifier token at `span` is the target of an assignment.
fn assignedAt(tokens: []const Token, span: Loc) bool {
    const index = tokenIndexAt(tokens, span.start) orelse return false;
    return index + 1 < tokens.len and tokens_util.isAssignment(tokens[index + 1].tag);
}

/// Index of the token starting at `start`, by binary search.
fn tokenIndexAt(tokens: []const Token, start: usize) ?usize {
    var low: usize = 0;
    var high = tokens.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (tokens[middle].loc.start < start) low = middle + 1 else high = middle;
    }
    return if (low < tokens.len and tokens[low].loc.start == start) low else null;
}

pub const FileReference = struct {
    /// The text between the quotes.
    span: Loc,
    path: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// `@import("x.zig")` or `@import("x.zon")`.
        import,
        /// `@embedFile("x")`.
        embed,
        /// A `.path = "x"` of a `build.zig.zon`, naming a package directory.
        package,
    };
};

/// The relative file paths `document` names: `@import` of a `.zig` or `.zon`
/// file, `@embedFile`, and, in a `build.zig.zon`, each `.path = "..."`.
/// Module names (`@import("std")`) and absolute paths are not included.
pub fn fileReferences(allocator: std.mem.Allocator, document: *const Document) ![]FileReference {
    const tokens = document.tokens;
    const source = document.source;
    const manifest = std.mem.endsWith(u8, document.uri, "build.zig.zon");
    var found: std.ArrayList(FileReference) = .empty;
    errdefer found.deinit(allocator);
    for (tokens, 0..) |token, index| {
        const kind: FileReference.Kind, const literal_index = switch (token.tag) {
            .builtin => kind: {
                if (index + 3 >= tokens.len or tokens[index + 1].tag != .l_paren or
                    tokens[index + 2].tag != .string_literal or tokens[index + 3].tag != .r_paren) continue;
                const name = tokens_util.tokenText(source, token);
                if (std.mem.eql(u8, name, "@import")) break :kind .{ .import, index + 2 };
                if (std.mem.eql(u8, name, "@embedFile")) break :kind .{ .embed, index + 2 };
                continue;
            },
            .period => kind: {
                if (!manifest or index + 3 >= tokens.len or tokens[index + 1].tag != .identifier or
                    !tokens_util.tokenIs(source, tokens[index + 1], "path") or
                    tokens[index + 2].tag != .equal or tokens[index + 3].tag != .string_literal) continue;
                break :kind .{ .package, index + 3 };
            },
            else => continue,
        };
        const literal = tokens[literal_index].loc;
        if (literal.end - literal.start < 3) continue;
        const span: Loc = .{ .start = literal.start + 1, .end = literal.end - 1 };
        const path = source[span.start..span.end];
        // Escapes would need decoding; real paths do not use them.
        if (std.mem.findScalar(u8, path, '\\') != null or std.Io.Dir.path.isAbsolute(path)) continue;
        if (kind == .import and !std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, ".zon")) continue;
        try found.append(allocator, .{ .span = span, .path = path, .kind = kind });
    }
    return try found.toOwnedSlice(allocator);
}

pub const TestDeclaration = struct {
    /// From the `test` keyword to the end of the name.
    span: Loc,
    /// The string's contents, or the identifier of a decltest.
    name: []const u8,
};

/// Every `test "name"` and `test name` declaration; unnamed tests cannot be
/// selected by a filter and are left out.
pub fn testDeclarations(allocator: std.mem.Allocator, document: *const Document) ![]TestDeclaration {
    const tokens = document.tokens;
    var found: std.ArrayList(TestDeclaration) = .empty;
    errdefer found.deinit(allocator);
    for (tokens, 0..) |token, index| {
        if (token.tag != .keyword_test or index + 2 >= tokens.len or tokens[index + 2].tag != .l_brace) continue;
        const name_token = tokens[index + 1];
        const name = switch (name_token.tag) {
            .identifier => tokens_util.tokenText(document.source, name_token),
            .string_literal => name: {
                const literal = tokens_util.tokenText(document.source, name_token);
                if (literal.len < 3 or std.mem.findScalar(u8, literal, '\\') != null) continue;
                break :name literal[1 .. literal.len - 1];
            },
            else => continue,
        };
        try found.append(allocator, .{ .span = .{ .start = token.loc.start, .end = name_token.loc.end }, .name = name });
    }
    return try found.toOwnedSlice(allocator);
}

fn testDocument(source: []const u8) !Document {
    return Document.open(std.testing.allocator, "file:///structure.zig", 1, source);
}

fn expectFold(found: []const Fold, start_line: u32, end_line: u32, kind: Fold.Kind) !void {
    for (found) |fold| {
        if (fold.start_line == start_line) {
            try std.testing.expectEqual(end_line, fold.end_line);
            try std.testing.expectEqual(kind, fold.kind);
            return;
        }
    }
    std.debug.print("no fold starts on line {d}\n", .{start_line});
    return error.TestExpectedFold;
}

test "blocks fold to the line before their closing brace" {
    var document = try testDocument(
        \\fn run(value: u32) u32 {
        \\    if (value > 1) {
        \\        return value;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
    );
    defer document.deinit();
    const found = try folds(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try expectFold(found, 0, 5, .code);
    try expectFold(found, 1, 2, .code);
    try expectFold(found, 3, 4, .code);
}

test "comment, doc-comment, string and import runs fold" {
    var document = try testDocument(
        \\//! Module documentation
        \\//! continues here.
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const other = @import("other.zig");
        \\
        \\// A plain comment
        \\// over two lines.
        \\const text =
        \\    \\first
        \\    \\second
        \\;
        \\/// Documented
        \\/// constant.
        \\const answer = 42; // trailing
        \\// not a run with the trailing comment
        \\
    );
    defer document.deinit();
    const found = try folds(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try expectFold(found, 0, 1, .comment);
    try expectFold(found, 2, 4, .imports);
    try expectFold(found, 6, 7, .comment);
    try expectFold(found, 9, 10, .code);
    try expectFold(found, 12, 13, .comment);
    try std.testing.expectEqual(@as(usize, 5), found.len);
}

test "aliases without an import do not fold as imports" {
    var document = try testDocument("const a = b.c;\nconst d = e.f;\n");
    defer document.deinit();
    const found = try folds(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "selection grows from the token through enclosing nodes" {
    const source = "fn run(value: u32) u32 {\n    return value + 1;\n}\n";
    var document = try testDocument(source);
    defer document.deinit();
    const offset = std.mem.findLast(u8, source, "value").? + 2;
    const chains = try selectionChains(std.testing.allocator, &document, &.{offset});
    defer {
        for (chains) |chain| std.testing.allocator.free(chain);
        std.testing.allocator.free(chains);
    }
    const chain = chains[0];
    try std.testing.expectEqualStrings("value", source[chain[0].start..chain[0].end]);
    try std.testing.expectEqualStrings("value + 1", source[chain[1].start..chain[1].end]);
    try std.testing.expectEqualStrings("return value + 1", source[chain[2].start..chain[2].end]);
    try std.testing.expectEqual(source.len, chain[chain.len - 1].end);
    for (chain[1..], chain[0 .. chain.len - 1]) |outer, inner| {
        try std.testing.expect(outer.start <= inner.start and inner.end <= outer.end);
        try std.testing.expect(!std.meta.eql(outer, inner));
    }
}

test "binding occurrences mark declarations and assignments as writes" {
    const source = "fn run() u32 {\n    var total: u32 = 0;\n    total += 2;\n    return total;\n}\n";
    var document = try testDocument(source);
    defer document.deinit();
    const occurrences = (try bindingOccurrences(std.testing.allocator, &document, std.mem.findLast(u8, source, "total").?)).?;
    defer std.testing.allocator.free(occurrences);
    try std.testing.expectEqual(@as(usize, 3), occurrences.len);
    try std.testing.expectEqual(Access.write, occurrences[0].access);
    try std.testing.expectEqual(Access.write, occurrences[1].access);
    try std.testing.expectEqual(Access.read, occurrences[2].access);
}

test "file references name relative imports and embedded files only" {
    var document = try testDocument(
        \\const std = @import("std");
        \\const other = @import("other.zig");
        \\const data = @embedFile("data/table.txt");
        \\const absolute = @import("/abs/path.zig");
        \\
    );
    defer document.deinit();
    const found = try fileReferences(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("other.zig", found[0].path);
    try std.testing.expectEqual(FileReference.Kind.import, found[0].kind);
    try std.testing.expectEqualStrings("data/table.txt", found[1].path);
    try std.testing.expectEqual(FileReference.Kind.embed, found[1].kind);
}

test "manifest dependency paths are file references" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///project/build.zig.zon",
        1,
        ".{ .dependencies = .{ .local = .{ .path = \"../local\" } } }\n",
    );
    defer document.deinit();
    const found = try fileReferences(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("../local", found[0].path);
    try std.testing.expectEqual(FileReference.Kind.package, found[0].kind);
}

test "named tests and decltests are listed; unnamed tests are not" {
    var document = try testDocument("test \"adds numbers\" {}\ntest {}\ntest run {}\nfn run() void {}\n");
    defer document.deinit();
    const found = try testDeclarations(std.testing.allocator, &document);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("adds numbers", found[0].name);
    try std.testing.expectEqualStrings("test \"adds numbers\"", document.source[found[0].span.start..found[0].span.end]);
    try std.testing.expectEqualStrings("run", found[1].name);
}
