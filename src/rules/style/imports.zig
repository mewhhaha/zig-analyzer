//! `@import` declarations: duplicates, unused, redundant paths and sort order.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const lineEnd = @import("../../syntax/tokens.zig").lineEnd;
const attachedCommentStart = @import("../../syntax/tokens.zig").attachedCommentStart;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Fix = types.Fix;
const RelatedSpan = types.RelatedSpan;

pub const rules = [_]types.Rule{
    .unsorted_imports,
    .duplicate_import,
    .unused_import,
    .redundant_import_path,
};

pub fn run(context: RuleRun) !void {
    try findImportIssues(context);
    try findUnsortedImports(context);
}

fn findImportIssues(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const duplicate_level = context.level(.duplicate_import);
    const unused_level = context.level(.unused_import);
    const path_level = context.level(.redundant_import_path);
    if (duplicate_level == .off and unused_level == .off and path_level == .off) return;
    var seen_paths: std.StringHashMapUnmanaged(std.zig.Token.Loc) = .empty;
    defer seen_paths.deinit(context.allocator);
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .l_brace) brace_depth += 1;
        if (token.tag == .r_brace) brace_depth -|= 1;
        if (brace_depth != 0 or token.tag != .keyword_const or index + 7 >= tokens.len or
            tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            !tokenIs(source, tokens[index + 3], "@import") or tokens[index + 4].tag != .l_paren or
            tokens[index + 5].tag != .string_literal or tokens[index + 6].tag != .r_paren or
            tokens[index + 7].tag != .semicolon) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_pub) continue;
        const alias = tokenText(source, tokens[index + 1]);
        const raw_path = tokenText(source, tokens[index + 5]);
        const path = raw_path[1 .. raw_path.len - 1];
        const declaration_span = std.zig.Token.Loc{ .start = lineStart(source, token.loc.start), .end = lineEnd(source, tokens[index + 7].loc.end) };
        if (duplicate_level != .off) {
            if (seen_paths.get(path)) |first_span| {
                const fixes: []const Fix = if (attachedCommentStart(source, declaration_span.start) == declaration_span.start) fixes: {
                    const allocated = try Fix.single(context.allocator, .{
                        .title = "Remove duplicate import",
                        .span = declaration_span,
                        .replacement = "",
                        .preferred = true,
                        .fix_all = true,
                    });
                    break :fixes allocated;
                } else &.{};
                const related = try context.allocator.alloc(RelatedSpan, 1);
                related[0] = .{ .span = first_span, .message = "the same module is imported here first" };
                try context.emit(.{
                    .rule = .duplicate_import,
                    .level = duplicate_level,
                    .span = tokens[index + 5].loc,
                    .message = try context.allocator.print("module '{s}' is imported more than once", .{path}),
                    .related = related,
                    .fixes = fixes,
                });
            } else try seen_paths.put(context.allocator, path, tokens[index + 5].loc);
        }
        if (unused_level != .off and identifierUseCount(source, tokens, alias) == 1) {
            const fixes: []const Fix = if (attachedCommentStart(source, declaration_span.start) == declaration_span.start) fixes: {
                const allocated = try Fix.single(context.allocator, .{
                    .title = "Remove unused import",
                    .span = declaration_span,
                    .replacement = "",
                    .preferred = true,
                    .fix_all = true,
                });
                break :fixes allocated;
            } else &.{};
            try context.emit(.{
                .rule = .unused_import,
                .level = unused_level,
                .span = tokens[index + 1].loc,
                .message = try context.allocator.print("import alias '{s}' is never referenced", .{alias}),
                .fixes = fixes,
            });
        }
        if (path_level != .off and std.mem.startsWith(u8, path, "./") and path.len > 2) {
            const fixes = try Fix.single(context.allocator, .{
                .title = "Normalize import path",
                .span = tokens[index + 5].loc,
                .replacement = try context.allocator.print("\"{s}\"", .{path[2..]}),
                .preferred = true,
                .fix_all = true,
            });
            try context.emit(.{
                .rule = .redundant_import_path,
                .level = path_level,
                .span = tokens[index + 5].loc,
                .message = try context.allocator.print("relative import path '{s}' has a redundant './' segment", .{path}),
                .fixes = fixes,
            });
        }
    }
}

fn identifierUseCount(source: []const u8, tokens: []const std.zig.Token, name: []const u8) usize {
    var count: usize = 0;
    for (tokens) |token| {
        if (token.tag == .identifier and tokenIs(source, token, name)) count += 1;
    }
    return count;
}

const Import = struct {
    start: usize,
    end: usize,
    alias: []const u8,
    path: []const u8,
};

fn findUnsortedImports(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.unsorted_imports);
    if (level == .off) return;
    var imports: std.ArrayList(Import) = .empty;
    defer imports.deinit(context.allocator);
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .l_brace) {
            brace_depth += 1;
            continue;
        }
        if (token.tag == .r_brace) {
            brace_depth -|= 1;
            continue;
        }
        if (brace_depth != 0) continue;
        if (token.tag != .keyword_const or index + 7 >= tokens.len or tokens[index + 1].tag != .identifier or
            tokens[index + 2].tag != .equal or !tokenIs(source, tokens[index + 3], "@import") or
            tokens[index + 4].tag != .l_paren or tokens[index + 5].tag != .string_literal or
            tokens[index + 6].tag != .r_paren or tokens[index + 7].tag != .semicolon)
        {
            continue;
        }
        const raw_path = tokenText(source, tokens[index + 5]);
        const declaration_start = lineStart(source, token.loc.start);
        try imports.append(context.allocator, .{
            .start = attachedCommentStart(source, declaration_start),
            .end = lineEnd(source, tokens[index + 7].loc.end),
            .alias = tokenText(source, tokens[index + 1]),
            .path = raw_path[1 .. raw_path.len - 1],
        });
    }
    if (imports.items.len < 2 or !importsAreContiguous(source, imports.items) or importsAreSorted(imports.items)) return;
    const replacement = try sortedImportText(context.allocator, source, imports.items);
    const fixes = try Fix.single(context.allocator, .{
        .title = "Organize imports",
        .kind = .organize_imports,
        .span = .{ .start = imports.items[0].start, .end = imports.last().?.end },
        .replacement = replacement,
    });
    try context.emit(.{
        .rule = .unsorted_imports,
        .level = level,
        .span = .{ .start = imports.items[0].start, .end = imports.last().?.end },
        .message = try context.allocator.dupe(u8, "top-level imports are not grouped and sorted by path"),
        .fixes = fixes,
    });
}

fn importsAreContiguous(source: []const u8, imports: []const Import) bool {
    for (imports[1..], 1..) |current, index| {
        if (imports[index - 1].end > current.start) return false;
        const between = std.mem.trim(u8, source[imports[index - 1].end..current.start], " \t\r\n");
        if (between.len != 0) return false;
    }
    return true;
}

fn importsAreSorted(imports: []const Import) bool {
    for (imports[1..], 1..) |current, index| {
        if (importLessThan(current, imports[index - 1])) return false;
    }
    return true;
}

fn importLessThan(left: Import, right: Import) bool {
    const left_group = importGroup(left.path);
    const right_group = importGroup(right.path);
    if (left_group != right_group) return left_group < right_group;
    const path_order = std.mem.order(u8, left.path, right.path);
    if (path_order != .eq) return path_order == .lt;
    return std.mem.lessThan(u8, left.alias, right.alias);
}

fn importGroup(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin") or std.mem.eql(u8, path, "root")) return 0;
    if (std.mem.findScalar(u8, path, '/') == null and !std.mem.endsWith(u8, path, ".zig")) return 1;
    return 2;
}

fn sortedImportText(allocator: std.mem.Allocator, source: []const u8, imports: []const Import) ![]const u8 {
    const sorted = try allocator.dupe(Import, imports);
    std.mem.sort(Import, sorted, {}, struct {
        fn lessThan(_: void, left: Import, right: Import) bool {
            return importLessThan(left, right);
        }
    }.lessThan);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var previous_group: ?u2 = null;
    for (sorted) |import| {
        const group = importGroup(import.path);
        if (previous_group) |previous| if (previous != group) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(source[import.start..import.end]);
        // The file's last line may lack its newline; moving it must not join two imports.
        if (import.start == import.end or source[import.end - 1] != '\n') try writer.writer.writeByte('\n');
        previous_group = group;
    }
    return try writer.toOwnedSlice();
}

test "organize imports preserves directly attached comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// package docs\n" ++
        "const package = @import(\"package\");\n" ++
        "// standard library\n" ++
        "const std = @import(\"std\");\n";
    const configuration = support.only(&.{.unsorted_imports}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const replacement = found[0].fixes[0].edits[0].replacement;
    try std.testing.expect(std.mem.find(u8, replacement, "// standard library\nconst std") != null);
    try std.testing.expect(std.mem.find(u8, replacement, "// package docs\nconst package") != null);
}

test "organize imports leaves container doc comments in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "//! Module documentation.\n" ++
        "const zebra = @import(\"zebra.zig\");\n" ++
        "const apple = @import(\"apple.zig\");\n" ++
        "fn use() void { _ = zebra; _ = apple; }\n";
    const configuration = support.only(&.{.unsorted_imports}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var import_count: usize = 0;
    for (found) |finding| if (finding.rule == .unsorted_imports) {
        import_count += 1;
        try std.testing.expectEqual(std.mem.find(u8, source, "const zebra").?, finding.fixes[0].edits[0].span.start);
        try std.testing.expect(std.mem.find(u8, finding.fixes[0].edits[0].replacement, "//!") == null);
    };
    try std.testing.expectEqual(@as(usize, 1), import_count);
}
