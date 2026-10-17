const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const Suppressions = @import("../configuration.zig").Suppressions;
const types = @import("../types.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const tokenize = @import("../../syntax/tokens.zig").tokenize;
const stdlib_replacements = @import("modernize.zig").stdlib_replacements;

/// Whether an index run reports anything under `configuration`.
pub fn enabled(configuration: types.Configuration) bool {
    return configuration.level(.deprecated_declaration) != .off or configuration.level(.removed_std_api) != .off;
}

pub const Source = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
    /// Scope index of `source` and `tokens` when the caller already has one.
    scopes: ?*const syntax_scope.Index = null,
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
    scopes: *const syntax_scope.Index,
    /// Set when this file built its own scope index.
    owned_scopes: ?syntax_scope.Index,
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
/// What an index run reads and reports into. Project and editor callers have
/// tokens but no shared syntax tree, so this is narrower than a `RuleRun`.
pub const Target = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    scopes: ?*const syntax_scope.Index = null,
    configuration: types.Configuration,
    findings: *std.ArrayList(types.Finding),

    fn level(target: Target, rule: types.Rule) types.Level {
        return target.configuration.level(rule);
    }

    fn emit(target: Target, finding: types.Finding) !void {
        if (finding.level == .off) return;
        try target.findings.append(target.allocator, finding);
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    loader: ?Loader = null,
    files: std.StringHashMapUnmanaged(*File) = .empty,
    import_paths: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    root: ?*File = null,
    used_files: std.StringHashMapUnmanaged(void) = .empty,
    /// Directory of the file `@import("std")` resolved to; files under it are
    /// the standard library. Borrowed from `import_paths`.
    std_directory: ?[]const u8 = null,
    /// The members of each container body looked up so far; see `declarationIn`.
    members: std.AutoHashMapUnmanaged(MembersKey, Members) = .empty,

    pub fn init(allocator: std.mem.Allocator, loader: ?Loader) Index {
        return .{ .allocator = allocator, .loader = loader };
    }

    pub fn deinit(index: *Index) void {
        var files = index.files.iterator();
        while (files.next()) |entry| {
            const file = entry.value_ptr.*;
            if (file.owned_scopes) |*owned| owned.deinit();
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
        var members = index.members.valueIterator();
        while (members.next()) |container| if (container.names) |*names| names.deinit(index.allocator);
        index.members.deinit(index.allocator);
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

    pub fn run(index: *Index, context: Target, path: []const u8, imported_only: bool) !void {
        if (!enabled(context.configuration)) return;
        const deprecations = context.level(.deprecated_declaration) != .off;
        const file = try index.addFile(.{ .path = path, .source = context.source, .tokens = context.tokens, .scopes = context.scopes });
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
            if (deprecations and token.tag == .identifier) try index.emitReference(context, file, site, token.loc, imported_only);
            while (cursor + 2 < file.tokens.len and file.tokens[cursor + 1].tag == .period and
                file.tokens[cursor + 2].tag == .identifier)
            {
                const member_index = cursor + 2;
                const container = try index.namespace(site, 23) orelse break;
                site = try index.declarationIn(container, tokenText(file, member_index)) orelse {
                    try index.emitRemoved(context, file, start, site, container, member_index);
                    break;
                };
                if (deprecations) try index.emitReference(context, file, site, file.tokens[member_index].loc, imported_only);
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
        var owned_scopes: ?syntax_scope.Index = if (source.scopes == null)
            try syntax_scope.Index.init(index.allocator, source.source, tokens)
        else
            null;
        errdefer if (owned_scopes) |*owned| owned.deinit();
        const file = try index.allocator.create(File);
        errdefer index.allocator.destroy(file);
        file.* = .{
            .source = source,
            .tokens = tokens,
            .scopes = undefined,
            .owned_scopes = owned_scopes,
            .owned_tokens = source.tokens == null,
        };
        file.scopes = source.scopes orelse &file.owned_scopes.?;
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
        if (index.std_directory == null and std.mem.eql(u8, spelling, "std")) index.std_directory = std.Io.Dir.path.dirname(path);
        try index.used_files.put(index.allocator, path, {});
        if (index.files.get(path)) |file| return file;
        const source = try loader.load(loader.context, index.allocator, path) orelse return null;
        errdefer if (source.owned_source) index.allocator.free(source.source);
        return try index.addFile(source);
    }

    fn emitReference(index: *Index, context: Target, root: *File, raw_site: Site, span: std.zig.Token.Loc, imported_only: bool) !void {
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
        return try index.declarationIn(container_site, name);
    }

    /// The declaration `name` selects in the container body `container_site`:
    /// its only top-level declaration of that name, public unless the body is
    /// in the file being checked. Each body is scanned once and its names kept.
    fn declarationIn(index: *Index, container_site: Site, name: []const u8) !?Site {
        const file = container_site.file;
        const body = container_site.body.?;
        const key: MembersKey = .{
            .file = @intFromPtr(file),
            .start = body.start,
            .end = body.end,
            .public_only = file != index.root,
        };
        const entry = try index.members.getOrPut(index.allocator, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
            errdefer _ = index.members.remove(key);
            entry.value_ptr.names = try containerMembers(index.allocator, file, body, key.public_only);
        }
        const names = entry.value_ptr.names orelse return null;
        const declaration = names.get(name) orelse return null;
        return .{ .file = file, .declaration = declaration orelse return null };
    }

    fn namespace(index: *Index, site: Site, budget: usize) anyerror!?Site {
        return index.namespaceOf(site, budget, .values);
    }

    /// What a declaration may be for `namespaceOf` to read a container from it.
    const Reach = enum {
        /// Also a typed constant, variable or parameter, through its type.
        values,
        /// Only a namespace or type: a value's members are the fields and
        /// methods of an instance, not a namespace path.
        namespaces,
    };

    /// The container `site` names.
    fn namespaceOf(index: *Index, site: Site, budget: usize, reach: Reach) anyerror!?Site {
        if (budget == 0) return null;
        if (site.body != null) return site;
        const declaration = site.declaration orelse return null;
        const file = site.file;
        if (declaration + 2 >= file.tokens.len) return null;
        const typed_namespace = tokenIs(file, declaration + 2, "type") and file.tokens[declaration + 1].tag == .colon;
        if (typed_namespace and (declaration == 0 or file.tokens[declaration - 1].tag != .keyword_const)) return null;
        const typed_value = file.tokens[declaration + 1].tag == .colon and !typed_namespace;
        if (typed_value and reach == .namespaces) return null;
        const expression = if (typed_value)
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
        return try index.namespaceOf(target, budget - 1, reach);
    }

    /// Reports member `member_index` of the chain starting at `chain_start`
    /// when `container`, the standard-library namespace `receiver` names,
    /// provably declares no such member, with the replacement when one is
    /// known. Values, namespaces the index cannot list (generated by a call,
    /// `@Type`, or a conditional), and containers outside the installed
    /// standard library are declined.
    fn emitRemoved(index: *Index, context: Target, root: *File, chain_start: usize, receiver: Site, container: Site, member_index: usize) !void {
        const level = context.level(.removed_std_api);
        if (level == .off or !index.isStandard(container.file)) return;
        const name = tokenText(root, member_index);
        if (name[0] == '@') return;
        // The receiver must name the container as a namespace, not as the type
        // of a value. Checked before the member scan: a field read through a
        // value is the common way to get here, and a typed declaration fails
        // this at once.
        const namespace_site = try index.namespaceOf(receiver, 23, .namespaces) orelse return;
        if (namespace_site.file != container.file or !std.meta.eql(namespace_site.body, container.body) or
            !declaresNoMember(container, name)) return;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(context.allocator);
        if (!try index.ownerPath(context.allocator, container, &path)) return;
        if (path.items.len != 0) try path.append(context.allocator, '.');
        try path.appendSlice(context.allocator, name);

        // The longest known path wins, so std.io.fixedBufferStream gets its
        // own advice rather than std.io's.
        var ends: [3]usize = .{ path.items.len, 0, 0 };
        var last = member_index;
        var extra: usize = 0;
        while (extra + 1 < ends.len and last + 2 < root.tokens.len and root.tokens[last + 1].tag == .period and
            root.tokens[last + 2].tag == .identifier) : (extra += 1)
        {
            last += 2;
            try path.append(context.allocator, '.');
            try path.appendSlice(context.allocator, tokenText(root, last));
            ends[extra + 1] = path.items.len;
        }
        var advice: ?[]const u8 = null;
        var known = path.items[0..ends[0]];
        var known_end = member_index;
        var candidate = extra + 1;
        while (candidate > 0) {
            candidate -= 1;
            const prefix = path.items[0..ends[candidate]];
            for (&stdlib_replacements) |entry| {
                if (!std.mem.eql(u8, entry.path, prefix)) continue;
                advice = entry.advice;
                known = prefix;
                known_end = member_index + 2 * candidate;
                break;
            }
            if (advice != null) break;
        }
        if (advice != null) {
            // That rule reports the same table entry, with its fixes, when it
            // is spelled from the std import.
            if (context.level(.modernize_deprecated_stdlib) != .off and spelledFromStd(root, chain_start, known_end, known)) return;
        } else for (removed_namespaces) |entry| {
            if (std.mem.eql(u8, entry.path, known)) advice = entry.advice;
        }
        const message = if (advice) |replacement|
            try context.allocator.print("std.{s} was removed from the standard library; use {s}", .{ known, replacement })
        else
            try context.allocator.print("std.{s} does not exist in the standard library", .{known});
        errdefer context.allocator.free(message);
        try context.emit(.{ .rule = .removed_std_api, .level = level, .span = root.tokens[member_index].loc, .message = message });
    }

    fn isStandard(index: *const Index, file: *const File) bool {
        const directory = index.std_directory orelse return false;
        const path = file.source.path;
        return path.len > directory.len + 1 and std.mem.startsWith(u8, path, directory) and
            std.Io.Dir.path.isSep(path[directory.len]);
    }

    /// Appends the standard-library path of `container`, empty for the root
    /// (`fs`, `Io.Dir`, `Build.LazyPath`), or returns false when a container
    /// on the way is not a named declaration.
    fn ownerPath(index: *const Index, allocator: std.mem.Allocator, container: Site, path: *std.ArrayList(u8)) !bool {
        const file = container.file;
        const directory = index.std_directory.?;
        const file_path = file.source.path;
        if (!std.mem.endsWith(u8, file_path, ".zig")) return false;
        const relative = file_path[directory.len + 1 .. file_path.len - ".zig".len];
        if (!std.mem.eql(u8, relative, "std")) {
            for (relative) |byte| try path.append(allocator, if (std.Io.Dir.path.isSep(byte)) '.' else byte);
        }
        var names: [8]usize = undefined;
        var count: usize = 0;
        var brace: u32 = if (container.body.?.start == 0) syntax_scope.none_token else @intCast(container.body.?.start - 1);
        while (brace != syntax_scope.none_token) : (count += 1) {
            if (count == names.len) return false;
            names[count] = containerName(file, brace) orelse return false;
            brace = file.scopes.enclosing_braces[names[count]];
        }
        while (count > 0) {
            count -= 1;
            if (path.items.len != 0) try path.append(allocator, '.');
            try path.appendSlice(allocator, tokenText(file, names[count]));
        }
        return true;
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
    try index.run(.{
        .allocator = context.allocator,
        .source = context.source,
        .tokens = context.tokens,
        .scopes = context.scopes,
        .configuration = context.configuration,
        .findings = context.findings,
    }, "", false);
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

/// Whole namespaces the standard library dropped, for members of them that the
/// replacement table does not name.
const removed_namespaces = [_]struct { path: []const u8, advice: []const u8 }{
    .{ .path = "io", .advice = "std.Io" },
};

/// A container body: the address of its file, its token range, and whether
/// only public declarations count.
const MembersKey = struct { file: usize, start: usize, end: usize, public_only: bool };

const Members = struct {
    /// Each top-level declaration name, mapped to its name token, or to null
    /// when it is declared twice; null when a group in the body is unbalanced.
    names: ?std.StringHashMapUnmanaged(?usize) = null,
};

fn containerMembers(
    allocator: std.mem.Allocator,
    file: *const File,
    body: Range,
    public_only: bool,
) !?std.StringHashMapUnmanaged(?usize) {
    var names: std.StringHashMapUnmanaged(?usize) = .empty;
    errdefer names.deinit(allocator);
    var cursor = body.start;
    while (cursor < body.end) : (cursor += 1) {
        const tag = file.tokens[cursor].tag;
        if (tag == .l_brace or tag == .l_paren or tag == .l_bracket) {
            cursor = file.scopes.matchingToken(cursor) orelse {
                names.deinit(allocator);
                return null;
            };
            continue;
        }
        if (tag != .keyword_const and tag != .keyword_var and tag != .keyword_fn) continue;
        if (cursor + 1 >= body.end or file.tokens[cursor + 1].tag != .identifier) continue;
        if (public_only and !isPublic(file, cursor)) continue;
        const entry = try names.getOrPut(allocator, tokenText(file, cursor + 1));
        entry.value_ptr.* = if (entry.found_existing) null else cursor + 1;
    }
    return names;
}

/// Whether no top-level token of `container` names `name`: no declaration,
/// private or public, no field or enum value, and no `usingnamespace` that
/// could provide it. Any other top-level mention also counts as a doubt, except
/// a member access such as `std.Io.Dir`, which names another container's member.
fn declaresNoMember(container: Site, name: []const u8) bool {
    const file = container.file;
    const body = container.body.?;
    var cursor = body.start;
    while (cursor < body.end) : (cursor += 1) {
        switch (file.tokens[cursor].tag) {
            .l_brace, .l_paren, .l_bracket => cursor = file.scopes.matchingToken(cursor) orelse return false,
            .identifier => {
                if (cursor > 0 and file.tokens[cursor - 1].tag == .period) continue;
                var text = tokenText(file, cursor);
                if (std.mem.eql(u8, text, "usingnamespace")) return false;
                if (text.len >= 3 and text[0] == '@') text = text[2 .. text.len - 1];
                if (std.mem.eql(u8, text, name)) return false;
            },
            else => {},
        }
    }
    return true;
}

/// The name token of the `const Name = struct {` (or enum, union, opaque)
/// declaration whose body opens at `brace`.
fn containerName(file: *const File, brace: usize) ?usize {
    if (brace == 0) return null;
    var cursor = brace - 1;
    if (file.tokens[cursor].tag == .r_paren) cursor = (file.scopes.matchingToken(cursor) orelse return null) -| 1;
    switch (file.tokens[cursor].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {},
        else => return null,
    }
    while (cursor > 0 and (file.tokens[cursor - 1].tag == .keyword_extern or file.tokens[cursor - 1].tag == .keyword_packed)) cursor -= 1;
    if (cursor < 3 or file.tokens[cursor - 1].tag != .equal) return null;
    cursor -= 2;
    if (cursor >= 2 and tokenIs(file, cursor, "type") and file.tokens[cursor - 1].tag == .colon) cursor -= 2;
    if (cursor == 0 or file.tokens[cursor].tag != .identifier or file.tokens[cursor - 1].tag != .keyword_const) return null;
    return cursor;
}

/// Whether tokens `start` through `end` spell `std.<path>` from a plain
/// `const std = @import("std");`, the form `modernize-deprecated-stdlib` reads.
fn spelledFromStd(file: *const File, start: usize, end: usize, path: []const u8) bool {
    if (!tokenIs(file, start, "std")) return false;
    const binding = file.scopes.findBinding(start) orelse return false;
    const declaration = binding.token_index;
    if (declaration == 0 or declaration + 6 >= file.tokens.len or file.tokens[declaration - 1].tag != .keyword_const or
        file.tokens[declaration + 1].tag != .equal or !tokenIs(file, declaration + 2, "@import") or
        !tokenIs(file, declaration + 4, "\"std\"") or file.tokens[declaration + 6].tag != .semicolon) return false;
    var cursor = start;
    var segments = std.mem.splitScalar(u8, path, '.');
    while (segments.next()) |segment| {
        if (cursor + 2 > end or !tokenIs(file, cursor + 2, segment)) return false;
        cursor += 2;
    }
    return cursor == end;
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
    return testFindingsWith(allocator, source, loader, imported_only, .defaults());
}

fn testFindingsWith(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    loader: ?Loader,
    imported_only: bool,
    configuration: types.Configuration,
) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    errdefer found.deinit(allocator);
    var index: Index = .init(allocator, loader);
    defer index.deinit();
    try index.run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = configuration, .findings = &found }, "/root/main.zig", imported_only);
    const suppressions = try Suppressions.init(allocator, source);
    defer suppressions.deinit(allocator);
    suppressions.filter(&found);
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
    configuration.levels[@backingInt(types.Rule.removed_std_api)] = .off;
    found.clearRetainingCapacity();
    try index.run(.{ .allocator = allocator, .source = source, .tokens = tokens, .configuration = configuration, .findings = &found }, "/root/main.zig", true);
    try std.testing.expectEqual(@as(usize, 0), found.items.len);
}

const test_std_sources = [_]Source{
    .{ .path = "/lib/std/std.zig", .source = "pub const fs = @import(\"fs.zig\");\npub const Thread = @import(\"Thread.zig\");\n" ++
        "pub const Build = @import(\"Build.zig\");\npub const lang = @import(\"lang.zig\");\n" ++
        "pub const Generated = Make(u8);\npub const options: Options = .{};\npub const Options = struct { level: u8 = 0 };\n" ++
        "pub const Mixed = struct { usingnamespace @import(\"fs.zig\"); };\nfn Make(comptime T: type) type { return struct { value: T }; }\n" },
    .{ .path = "/lib/std/fs.zig", .source = "const std = @import(\"std.zig\");\npub const path = @import(\"fs/path.zig\");\n" ++
        "pub const max_path_bytes = std.Io.Dir.max_path_bytes;\nfn hidden() void {}\n" },
    .{ .path = "/lib/std/fs/path.zig", .source = "pub fn current() void {}\n" },
    .{ .path = "/lib/std/Thread.zig", .source = "impl: u8,\npub fn spawn() void {}\n" },
    .{ .path = "/lib/std/lang.zig", .source = "pub const Mode = enum { debug, fast };\n" },
    .{ .path = "/lib/std/Build.zig", .source = "pub const LazyPath = union(enum) {\n    src: u8,\n    pub fn dirname() void {}\n};\n" },
    .{ .path = "/root/api.zig", .source = "pub fn present() void {}\n" },
};

test "removed std paths resolve through aliases and name their replacements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &test_std_sources };
    const source = "const std = @import(\"std\");\nconst fs = std.fs;\nconst Thread = std.Thread;\n" ++
        "fn f(file: fs.File) void {\n" ++
        "    _ = std.fs.cwd();\n" ++
        "    _ = fs.cwd();\n" ++
        "    _ = @import(\"std\").fs.cwd();\n" ++
        "    _ = std.io.fixedBufferStream;\n" ++
        "    _ = std.io.Writer;\n" ++
        "    _ = std.fs.unknown;\n" ++
        "    _ = std.Build.LazyPath.basename;\n" ++
        "    var mutex: Thread.Mutex = .{};\n" ++
        "    const dir: fs.Dir = undefined;\n" ++
        "    _ = .{ file, &mutex, dir };\n" ++
        "}\n";
    const found = try testFindings(arena.allocator(), source, loader.callbacks(), true);
    const expected = [_]struct { span: []const u8, message: []const u8 }{
        .{ .span = "File", .message = "std.fs.File was removed from the standard library; use std.Io.File, whose operations take an Io instance" },
        .{ .span = "cwd", .message = "std.fs.cwd was removed from the standard library; use std.Io.Dir.cwd()" },
        .{ .span = "cwd", .message = "std.fs.cwd was removed from the standard library; use std.Io.Dir.cwd()" },
        .{ .span = "cwd", .message = "std.fs.cwd was removed from the standard library; use std.Io.Dir.cwd()" },
        .{ .span = "io", .message = "std.io.fixedBufferStream was removed from the standard library; use std.Io.Reader.fixed or std.Io.Writer.fixed" },
        .{ .span = "io", .message = "std.io was removed from the standard library; use std.Io" },
        .{ .span = "unknown", .message = "std.fs.unknown does not exist in the standard library" },
        .{ .span = "basename", .message = "std.Build.LazyPath.basename was removed from the standard library; use path resolution during a make step" },
        .{ .span = "Mutex", .message = "std.Thread.Mutex was removed from the standard library; use std.Io.Mutex" },
        .{ .span = "Dir", .message = "std.fs.Dir was removed from the standard library; use std.Io.Dir, whose operations take an Io instance" },
    };
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, finding| {
        try std.testing.expectEqual(types.Rule.removed_std_api, finding.rule);
        try std.testing.expectEqualStrings(want.span, source[finding.span.start..finding.span.end]);
        try std.testing.expectEqualStrings(want.message, finding.message);
    }
}

test "removed std paths decline values fields generated namespaces and other modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &test_std_sources };
    const found = try testFindings(arena.allocator(), "const std = @import(\"std\");\nconst api = @import(\"api.zig\");\n" ++
        "fn f(thread: std.Thread, mode: std.lang.Mode) void {\n" ++
        "    _ = std.fs.hidden;\n" ++
        "    _ = thread.impl;\n" ++
        "    _ = thread.missing;\n" ++
        "    _ = std.lang.Mode.debug;\n" ++
        "    _ = mode.missing;\n" ++
        "    _ = std.Generated.missing;\n" ++
        "    _ = std.options.level;\n" ++
        "    _ = std.options.missing;\n" ++
        "    _ = std.Mixed.missing;\n" ++
        "    _ = std.fs.path.current;\n" ++
        "    _ = std.Build.LazyPath.src;\n" ++
        "    _ = std.fs.@\"cwd\";\n" ++
        "    _ = api.missing;\n" ++
        "}\n", loader.callbacks(), true);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "removed std paths spelled from the std import defer to the modernize table rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loader: TestLoader = .{ .sources = &test_std_sources };
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.modernize_deprecated_stdlib)] = .warning;
    const source = "const std = @import(\"std\");\nconst fs = std.fs;\n" ++
        "fn f() void { _ = std.fs.cwd(); _ = fs.cwd(); _ = std.fs.unknown; _ = std.io.Writer; }\n";
    const found = try testFindingsWith(arena.allocator(), source, loader.callbacks(), true, configuration);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqual(std.mem.find(u8, source, " fs.cwd").? + " fs.".len, found[0].span.start);
    try std.testing.expectEqualStrings("unknown", source[found[1].span.start..found[1].span.end]);
    try std.testing.expectEqualStrings("io", source[found[2].span.start..found[2].span.end]);
}
