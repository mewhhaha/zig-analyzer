const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const syntax_scope = @import("../syntax_scope.zig");

pub const Source = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
    owned_source: bool = false,
};

/// Callbacks return paths and owned sources allocated with the supplied allocator.
/// An editor may also return a borrowed open-document overlay.
pub const Loader = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?[]const u8,
    load: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?Source,
};

const File = struct {
    source: Source,
    tokens: []const std.zig.Token,
    scopes: syntax_scope.Index,
    owned_tokens: bool,
};

const Range = struct { start: usize, end: usize };
const Site = struct {
    file: *File,
    declaration: ?usize = null,
    body: ?Range = null,
};

/// Files are indexed only when a reference traverses their import. The index
/// can be shared by all project files, without scanning the whole standard library.
pub const Index = struct {
    allocator: std.mem.Allocator,
    loader: ?Loader = null,
    files: std.StringHashMapUnmanaged(*File) = .empty,
    import_paths: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    root: ?*File = null,
    used_files: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator, loader: ?Loader) Index {
        return .{ .allocator = allocator, .loader = loader };
    }

    pub fn deinit(index: *Index) void {
        var files = index.files.iterator();
        while (files.next()) |entry| {
            const file = entry.value_ptr.*;
            file.scopes.deinit();
            if (file.owned_tokens) index.allocator.free(file.tokens);
            if (file.source.owned_source) index.allocator.free(file.source.source);
            index.allocator.destroy(file);
            index.allocator.free(entry.key_ptr.*);
        }
        index.files.deinit(index.allocator);
        var paths = index.import_paths.iterator();
        while (paths.next()) |entry| {
            index.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |path| index.allocator.free(path);
        }
        index.import_paths.deinit(index.allocator);
        index.used_files.deinit(index.allocator);
    }

    pub fn addSource(index: *Index, source: Source) !void {
        _ = try index.addFile(source);
    }

    pub fn dependencyPaths(index: *const Index, allocator: std.mem.Allocator) ![]const []const u8 {
        const paths = try allocator.alloc([]const u8, index.used_files.count());
        var keys = index.used_files.keyIterator();
        var position: usize = 0;
        while (keys.next()) |key| : (position += 1) paths[position] = key.*;
        return paths;
    }

    pub fn run(index: *Index, context: RuleRun, path: []const u8, imported_only: bool) !void {
        if (context.level(.deprecated_declaration) == .off) return;
        const file = try index.addFile(.{ .path = path, .source = context.source, .tokens = context.tokens });
        index.root = file;
        index.used_files.clearRetainingCapacity();
        for (file.tokens, 0..) |token, start| {
            if (start > 0 and file.tokens[start - 1].tag == .period) continue;
            var cursor = start;
            var site: Site = if (token.tag == .identifier) blk: {
                const binding = file.scopes.findBinding(start) orelse continue;
                if (binding.token_index == start) continue;
                break :blk .{ .file = file, .declaration = binding.token_index };
            } else if (token.tag == .builtin and tokenIs(file, start, "@import")) blk: {
                if (start + 1 >= file.tokens.len or file.tokens[start + 1].tag != .l_paren) continue;
                const end = file.scopes.matchingToken(start + 1) orelse continue;
                cursor = end;
                break :blk try index.resolveExpression(file, .{ .start = start, .end = end + 1 }, 24) orelse continue;
            } else continue;
            if (token.tag == .identifier) try index.emitReference(context, file, site, token.loc, imported_only);
            while (cursor + 2 < file.tokens.len and file.tokens[cursor + 1].tag == .period and
                file.tokens[cursor + 2].tag == .identifier)
            {
                const member_index = cursor + 2;
                site = try index.member(site, tokenText(file, member_index), 24) orelse break;
                try index.emitReference(context, file, site, file.tokens[member_index].loc, imported_only);
                cursor = member_index;
            }
        }
    }

    fn addFile(index: *Index, source: Source) !*File {
        if (index.files.get(source.path)) |file| return file;
        const key = try index.allocator.dupe(u8, source.path);
        errdefer index.allocator.free(key);
        const tokens = source.tokens orelse try tokenize(index.allocator, source.source);
        errdefer if (source.tokens == null) index.allocator.free(tokens);
        var scopes = try syntax_scope.Index.init(index.allocator, source.source, tokens);
        errdefer scopes.deinit();
        const file = try index.allocator.create(File);
        errdefer index.allocator.destroy(file);
        file.* = .{ .source = source, .tokens = tokens, .scopes = scopes, .owned_tokens = source.tokens == null };
        file.source.path = key;
        try index.files.put(index.allocator, key, file);
        return file;
    }

    fn importedFile(index: *Index, current: *const File, spelling: []const u8) !?*File {
        const loader = index.loader orelse return null;
        const key = try index.allocator.print("{s}\x00{s}", .{ current.source.path, spelling });
        const entry = index.import_paths.getOrPut(index.allocator, key) catch |err| {
            index.allocator.free(key);
            return err;
        };
        if (entry.found_existing) {
            index.allocator.free(key);
        } else {
            entry.value_ptr.* = null;
            entry.value_ptr.* = try loader.resolve(loader.context, index.allocator, current.source.path, spelling);
        }
        const path = entry.value_ptr.* orelse return null;
        try index.used_files.put(index.allocator, path, {});
        if (index.files.get(path)) |file| return file;
        const source = try loader.load(loader.context, index.allocator, path) orelse return null;
        errdefer if (source.owned_source) index.allocator.free(source.source);
        return try index.addFile(source);
    }

    fn emitReference(index: *Index, context: RuleRun, root: *File, raw_site: Site, span: std.zig.Token.Loc, imported_only: bool) !void {
        var site = raw_site;
        var budget: usize = 24;
        while (budget > 0) : (budget -= 1) {
            const declaration = site.declaration orelse return;
            if (deprecationAdvice(site.file.source.source, site.file.tokens, declaration)) |advice| {
                if (imported_only and site.file == root) return;
                // The finding's advice must outlive the temporary imported source index.
                const message = try context.allocator.print("declaration '{s}' is deprecated{s}{s}", .{
                    tokenText(site.file, declaration), if (advice.len == 0) "" else ": ", advice,
                });
                errdefer context.allocator.free(message);
                try context.emit(.{ .rule = .deprecated_declaration, .level = context.level(.deprecated_declaration), .span = span, .message = message });
                return;
            }
            // A current public namespace/type alias has its own deprecation
            // policy, even when its implementation uses an older spelling.
            // For example, std.Io.Dir.path aliases deprecated std.fs.path.
            if (site.file != root and declaration > 0 and isPublic(site.file, declaration - 1) and
                try index.isNamespaceAlias(site, budget)) return;
            // Follow a constant declaration alias, not a variable's current value.
            const expression = constantInitializer(site.file, declaration) orelse return;
            site = try index.resolveExpression(site.file, expression, budget) orelse return;
        }
    }

    fn isNamespaceAlias(index: *Index, raw_site: Site, raw_budget: usize) !bool {
        var site = raw_site;
        var budget = raw_budget;
        while (budget > 0) : (budget -= 1) {
            if (site.body != null) return true;
            const declaration = site.declaration orelse return false;
            const file = site.file;
            if (declaration == 0 or file.tokens[declaration - 1].tag != .keyword_const or
                declaration + 2 >= file.tokens.len) return false;
            // A typed value also has a receiver namespace, but must retain
            // inherited deprecation advice from value reexports.
            if (file.tokens[declaration + 1].tag == .colon and
                !tokenIs(file, declaration + 2, "type")) return false;
            const expression = constantInitializer(file, declaration) orelse return false;
            var start = expression.start;
            while (start < expression.end and (file.tokens[start].tag == .keyword_extern or
                file.tokens[start].tag == .keyword_packed)) start += 1;
            if (start < expression.end and (file.tokens[start].tag == .keyword_struct or
                file.tokens[start].tag == .keyword_union or file.tokens[start].tag == .keyword_enum or
                file.tokens[start].tag == .keyword_opaque))
            {
                const container = try index.namespace(site, budget) orelse return false;
                // `struct { ... }{ ... }` is a value rather than a type alias.
                return container.body.?.end + 1 == expression.end;
            }
            site = try index.resolveExpression(file, expression, budget) orelse return false;
        }
        return false;
    }

    fn member(index: *Index, site: Site, name: []const u8, budget: usize) anyerror!?Site {
        if (budget == 0) return null;
        const container_site = try index.namespace(site, budget - 1) orelse return null;
        const body = container_site.body.?;
        var cursor = body.start;
        var selected: ?usize = null;
        while (cursor < body.end) : (cursor += 1) {
            const tag = container_site.file.tokens[cursor].tag;
            if (tag == .l_brace or tag == .l_paren or tag == .l_bracket) {
                cursor = container_site.file.scopes.matchingToken(cursor) orelse return null;
                continue;
            }
            if (tag != .keyword_const and tag != .keyword_var and tag != .keyword_fn) continue;
            if (cursor + 1 >= body.end or container_site.file.tokens[cursor + 1].tag != .identifier or
                !std.mem.eql(u8, tokenText(container_site.file, cursor + 1), name)) continue;
            if (container_site.file != index.root and !isPublic(container_site.file, cursor)) continue;
            if (selected != null) return null;
            selected = cursor + 1;
        }
        return if (selected) |declaration| .{ .file = container_site.file, .declaration = declaration } else null;
    }

    fn namespace(index: *Index, site: Site, budget: usize) anyerror!?Site {
        if (budget == 0) return null;
        if (site.body != null) return site;
        const declaration = site.declaration orelse return null;
        const file = site.file;
        if (declaration + 2 >= file.tokens.len) return null;
        const typed_namespace = tokenIs(file, declaration + 2, "type") and file.tokens[declaration + 1].tag == .colon;
        if (typed_namespace and (declaration == 0 or file.tokens[declaration - 1].tag != .keyword_const)) return null;
        const expression = if (file.tokens[declaration + 1].tag == .colon and !typed_namespace)
            declaredType(file, declaration) orelse return null
        else
            constantInitializer(file, declaration) orelse return null;
        var start = expression.start;
        while (start < expression.end and (file.tokens[start].tag == .keyword_extern or file.tokens[start].tag == .keyword_packed)) start += 1;
        if (start < expression.end and (file.tokens[start].tag == .keyword_struct or
            file.tokens[start].tag == .keyword_union or file.tokens[start].tag == .keyword_enum or
            file.tokens[start].tag == .keyword_opaque))
        {
            start += 1;
            if (start < expression.end and file.tokens[start].tag == .l_paren) start = (file.scopes.matchingToken(start) orelse return null) + 1;
            if (start >= expression.end or file.tokens[start].tag != .l_brace) return null;
            const end = file.scopes.matchingToken(start) orelse return null;
            return .{ .file = file, .body = .{ .start = start + 1, .end = end } };
        }
        const target = try index.resolveExpression(file, expression, budget - 1) orelse return null;
        return try index.namespace(target, budget - 1);
    }

    fn resolveExpression(index: *Index, file: *File, raw_range: Range, budget: usize) anyerror!?Site {
        if (budget == 0 or raw_range.start >= raw_range.end or raw_range.end > file.tokens.len) return null;
        var range = raw_range;
        while (range.start < range.end and (file.tokens[range.start].tag == .asterisk or
            file.tokens[range.start].tag == .keyword_const or file.tokens[range.start].tag == .keyword_try or
            file.tokens[range.start].tag == .ampersand)) range.start += 1;
        if (range.start >= range.end) return null;
        if (file.tokens[range.start].tag == .l_paren and file.scopes.matchingToken(range.start) == range.end - 1) {
            return try index.resolveExpression(file, .{ .start = range.start + 1, .end = range.end - 1 }, budget - 1);
        }
        var cursor = range.start;
        var site: Site = if (file.tokens[cursor].tag == .identifier) blk: {
            const binding = file.scopes.findBinding(cursor) orelse return null;
            // Mutable imports/type aliases do not establish namespace identity.
            if (binding.token_index > 0 and file.tokens[binding.token_index - 1].tag == .keyword_var and
                file.tokens[binding.token_index + 1].tag != .colon) return null;
            break :blk .{ .file = file, .declaration = binding.token_index };
        } else if (tokenIs(file, cursor, "@import")) blk: {
            if (cursor + 3 >= range.end or file.tokens[cursor + 1].tag != .l_paren or
                file.tokens[cursor + 2].tag != .string_literal or file.tokens[cursor + 3].tag != .r_paren) return null;
            const literal = tokenText(file, cursor + 2);
            if (literal.len < 2 or std.mem.findScalar(u8, literal, '\\') != null) return null;
            const imported = try index.importedFile(file, literal[1 .. literal.len - 1]) orelse return null;
            cursor += 3;
            break :blk .{ .file = imported, .body = .{ .start = 0, .end = imported.tokens.len } };
        } else if (tokenIs(file, cursor, "@This")) blk: {
            if (cursor + 2 >= range.end or file.tokens[cursor + 1].tag != .l_paren or file.tokens[cursor + 2].tag != .r_paren) return null;
            const enclosing = file.scopes.enclosing_braces[cursor];
            cursor += 2;
            break :blk .{ .file = file, .body = if (enclosing == syntax_scope.none_token)
                .{ .start = 0, .end = file.tokens.len }
            else
                .{ .start = enclosing + 1, .end = file.scopes.matchingToken(enclosing) orelse return null } };
        } else return null;
        cursor += 1;
        while (cursor + 1 < range.end and file.tokens[cursor].tag == .period and file.tokens[cursor + 1].tag == .identifier) {
            site = try index.member(site, tokenText(file, cursor + 1), budget - 1) orelse return null;
            cursor += 2;
        }
        return if (cursor == range.end) site else null;
    }
};

pub fn runLocal(context: RuleRun) !void {
    if (context.level(.deprecated_declaration) == .off) return;
    var index: Index = .init(context.allocator, null);
    defer index.deinit();
    try index.run(context, "", false);
}

/// A deprecation marker applies to the declaration, not prose that deprecates
/// only default initialization or describes an unrelated protocol feature.
pub fn deprecationAdvice(source: []const u8, tokens: []const std.zig.Token, declaration: usize) ?[]const u8 {
    if (declaration == 0) return null;
    var cursor = declaration - 1;
    while (cursor > 0 and (tokens[cursor - 1].tag == .keyword_pub or tokens[cursor - 1].tag == .keyword_export or
        tokens[cursor - 1].tag == .keyword_extern or tokens[cursor - 1].tag == .keyword_inline)) cursor -= 1;
    while (cursor > 0 and tokens[cursor - 1].tag == .doc_comment) {
        cursor -= 1;
        const text = std.mem.trim(u8, source[tokens[cursor].loc.start..tokens[cursor].loc.end], "/ \t\r\n");
        const marker = "Deprecated";
        if (text.len < marker.len or !std.ascii.eqlIgnoreCase(text[0..marker.len], marker)) continue;
        if (text.len > marker.len and std.mem.findScalar(u8, ":;, .\t", text[marker.len]) == null) continue;
        return std.mem.trimStart(u8, text[marker.len..], ":;, .\t");
    }
    return null;
}

fn isPublic(file: *const File, keyword: usize) bool {
    var cursor = keyword;
    while (cursor > 0) {
        cursor -= 1;
        switch (file.tokens[cursor].tag) {
            .keyword_pub => return true,
            .keyword_export, .keyword_extern, .keyword_inline => {},
            else => return false,
        }
    }
    return false;
}

fn constantInitializer(file: *const File, declaration: usize) ?Range {
    if (declaration == 0 or declaration + 2 >= file.tokens.len or file.tokens[declaration - 1].tag != .keyword_const) return null;
    const end = file.scopes.statementEnd(declaration) orelse return null;
    var cursor = declaration + 1;
    while (cursor < end) : (cursor += 1) {
        if (file.tokens[cursor].tag == .equal) return .{ .start = cursor + 1, .end = end };
        if (file.tokens[cursor].tag == .l_paren or file.tokens[cursor].tag == .l_bracket or file.tokens[cursor].tag == .l_brace) {
            cursor = file.scopes.matchingToken(cursor) orelse return null;
        }
    }
    return null;
}

fn declaredType(file: *const File, declaration: usize) ?Range {
    if (declaration + 2 >= file.tokens.len or file.tokens[declaration + 1].tag != .colon) return null;
    var end = declaration + 2;
    while (end < file.tokens.len) : (end += 1) {
        switch (file.tokens[end].tag) {
            .equal, .comma, .r_paren, .semicolon => return .{ .start = declaration + 2, .end = end },
            .l_paren, .l_bracket => end = file.scopes.matchingToken(end) orelse return null,
            .l_brace, .r_brace => return null,
            else => {},
        }
    }
    return null;
}

fn tokenText(file: *const File, token: usize) []const u8 {
    return file.source.source[file.tokens[token].loc.start..file.tokens[token].loc.end];
}

fn tokenIs(file: *const File, token: usize, text: []const u8) bool {
    return token < file.tokens.len and std.mem.eql(u8, tokenText(file, token), text);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token);
    }
    return try tokens.toOwnedSlice(allocator);
}

const TestLoader = struct {
    sources: []const Source,
    reads: usize = 0,

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, current: []const u8, spelling: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, spelling, "std")) return try allocator.dupe(u8, "/lib/std/std.zig");
        if (!std.mem.endsWith(u8, spelling, ".zig")) return null;
        return try std.Io.Dir.path.resolveAlloc(allocator, &.{ std.Io.Dir.path.dirname(current).?, spelling });
    }

    fn load(raw: *anyopaque, _: std.mem.Allocator, path: []const u8) !?Source {
        const loader: *TestLoader = @ptrCast(@alignCast(raw));
        loader.reads += 1;
        for (loader.sources) |source| if (std.mem.eql(u8, source.path, path)) return source;
        return null;
    }

    fn callbacks(loader: *TestLoader) Loader {
        return .{ .context = loader, .resolve = resolve, .load = load };
    }
};

fn testFindings(allocator: std.mem.Allocator, source: [:0]const u8, loader: ?Loader, imported_only: bool) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    errdefer found.deinit(allocator);
    var index: Index = .init(allocator, loader);
    defer index.deinit();
    try index.run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = .defaults(), .findings = &found }, "/root/main.zig", imported_only);
    return try found.toOwnedSlice(allocator);
}

test "local deprecations normalize markers and respect lexical bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try testFindings(arena.allocator(), "/// Deprecated: use new_a\nconst a = 1;\n" ++
        "/// Deprecated; use new_b\nconst b = 2;\n" ++
        "/// Deprecated, use new_c\nconst c = 3;\n" ++
        "/// Deprecated.\nconst d = 4;\n" ++
        "/// Deprecated in favor of next\nconst e = 5;\n" ++
        "/// Default initialization is deprecated; use .empty.\nconst Good = struct {};\n" ++
        "fn use() void { _ = a; _ = b; _ = c; _ = d; _ = e; _ = Good; { const a = 0; _ = a; } }", null, false);
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "use new_a") != null);
}

test "imported deprecations follow namespaces constant aliases and explicit receiver types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &.{
        .{ .path = "/lib/std/std.zig", .source = "pub const Reader = @import(\"reader.zig\");" },
        .{ .path = "/lib/std/reader.zig", .source = "const Reader = @This();\n/// Deprecated; use current\npub fn old(_: *Reader) void {}\n/// Default initialization is deprecated.\npub const State = struct {};\n" },
    } };
    const found = try testFindings(arena.allocator(), "const library = @import(\"std\"); const Reader: type = library.Reader; const Alias = Reader;\n" ++
        "const old = Reader.old; fn use(reader: *const Alias) void { reader.old(); old(); _ = library.Reader.State; _ = @import(\"std\").Reader.old; }", loader.callbacks(), true);
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqual(@as(usize, 2), loader.reads);
    for (found) |finding| {
        try std.testing.expectEqual(types.Rule.deprecated_declaration, finding.rule);
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    }
}

test "imported deprecations skip custom shadowed mutable private and opaque receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &.{.{ .path = "/root/api.zig", .source = "/// Deprecated: use next\npub fn old() void {}\n/// Deprecated: private\nfn hidden() void {}\n" }} };
    const found = try testFindings(arena.allocator(), "const api = @import(\"api.zig\"); fn f(api: Custom, unknown: Custom) void { api.old(); unknown.old(); }\n" ++
        "fn g() void { api.hidden(); const unknown = arbitrary(); unknown.old(); }\n" ++
        "comptime { var lib: type = @import(\"api.zig\"); lib = Custom; lib.old(); }\n" ++
        "const cyclic = cyclic; fn h() void { cyclic.old(); }", loader.callbacks(), true);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "imported deprecations follow reexports and honor caller suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &.{
        .{ .path = "/root/api.zig", .source = "pub const legacy = @import(\"detail.zig\").old; pub const value = @import(\"detail.zig\").old_value; pub const anonymous = @import(\"detail.zig\").old_anonymous;" },
        .{ .path = "/root/detail.zig", .source = "pub const Record = struct {};\n/// Deprecated in favor of next\npub fn old() void {}\n/// Deprecated: use next value\npub const old_value: Record = .{};\n/// Deprecated: use next inferred value\npub const old_anonymous = struct { x: u8 }{ .x = 1 };" },
    } };
    const found = try testFindings(arena.allocator(), "const api = @import(\"api.zig\");\nfn f() void {\napi.legacy();\n_ = api.value;\n_ = api.anonymous;\n// zig-analyzer: disable-next-line deprecated-declaration\napi.legacy();\n}", loader.callbacks(), true);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "in favor of next") != null);
    try std.testing.expect(std.mem.find(u8, found[1].message, "use next value") != null);
    try std.testing.expect(std.mem.find(u8, found[2].message, "use next inferred value") != null);
}

test "current public namespace aliases do not inherit deprecated implementation spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &.{
        .{ .path = "/lib/std/std.zig", .source = "pub const fs = @import(\"fs.zig\"); pub const Io = struct { pub const Dir = @import(\"dir.zig\"); };" },
        .{ .path = "/lib/std/fs.zig", .source = "/// Deprecated: use std.Io.Dir.path\npub const path = @import(\"path.zig\");" },
        .{ .path = "/lib/std/dir.zig", .source = "const std = @import(\"std.zig\"); pub const path = std.fs.path;" },
        .{ .path = "/lib/std/path.zig", .source = "pub fn current() void {}\n/// Deprecated: use current\npub fn old() void {}" },
    } };
    const source = "const std = @import(\"std\"); const Path = std.Io.Dir.path; " ++
        "fn f() void { Path.current(); Path.old(); std.fs.path.current(); }";
    const found = try testFindings(arena.allocator(), source, loader.callbacks(), true);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("old", source[found[0].span.start..found[0].span.end]);
    try std.testing.expectEqualStrings("path", source[found[1].span.start..found[1].span.end]);
}

test "deprecation index borrowed overlays override loader sources and disabled checks do no work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var loader: TestLoader = .{ .sources = &.{.{ .path = "/root/api.zig", .source = "pub fn old() void {}" }} };
    var index: Index = .init(allocator, loader.callbacks());
    defer index.deinit();
    try index.addSource(.{ .path = "/root/api.zig", .source = "/// Deprecated: unsaved advice\npub fn old() void {}" });
    const source: [:0]const u8 = "const api = @import(\"api.zig\"); fn f() void { api.old(); }";
    const tokens = try tokenize(allocator, source);
    var found: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    try index.run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = configuration, .findings = &found }, "/root/main.zig", true);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.find(u8, found.items[0].message, "unsaved advice") != null);
    try std.testing.expectEqual(@as(usize, 0), loader.reads);
    configuration.levels[@backingInt(types.Rule.deprecated_declaration)] = .off;
    found.clearRetainingCapacity();
    try index.run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = configuration, .findings = &found }, "/root/main.zig", true);
    try std.testing.expectEqual(@as(usize, 0), found.items.len);
}
