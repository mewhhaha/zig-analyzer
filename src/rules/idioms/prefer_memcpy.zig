//! Element-by-element copies between distinct arrays or slices that `@memcpy` expresses directly.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_module = @import("../../syntax/tokens.zig");

const findTag = tokens_module.findTag;

pub const rules = [_]types.Rule{.prefer_memcpy};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_memcpy);
    if (level == .off) return;
    for (context.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 9 >= context.tokens.len or context.tokens[for_index + 1].tag != .l_paren) continue;
        const iter_end = context.matchingToken(for_index + 1, .l_paren, .r_paren) orelse continue;
        if (iter_end + 3 >= context.tokens.len or context.tokens[iter_end + 1].tag != .pipe) continue;
        const capture_end = findTag(context.tokens, iter_end + 2, context.tokens.len, .pipe) orelse continue;

        const header_end = tokens_module.argumentsEnd(context.tokens, for_index + 1, iter_end) orelse continue;

        // Check for multi-sequence copy: for (dest, src) |*d, s| d.* = s;
        if (tokens_module.topLevelComma(context.tokens, for_index + 2, header_end)) |comma_idx| {
            if (comma_idx == for_index + 2 or comma_idx + 1 >= header_end) continue;
            const arg1_text = std.mem.trim(u8, context.source[context.tokens[for_index + 2].loc.start..context.tokens[comma_idx - 1].loc.end], " \t\r\n");
            const arg2_text = std.mem.trim(u8, context.source[context.tokens[comma_idx + 1].loc.start..context.tokens[header_end - 1].loc.end], " \t\r\n");
            if (std.mem.find(u8, arg1_text, "..") == null and std.mem.find(u8, arg2_text, "..") == null) {
                // Multi-sequence loop over two sequences
                const captures = context.tokens[iter_end + 2 .. capture_end];
                var comma_in_caps: ?usize = null;
                for (captures, 0..) |cap_tok, c_idx| {
                    if (cap_tok.tag == .comma and comma_in_caps == null) comma_in_caps = c_idx;
                }

                if (comma_in_caps) |cap_comma| {
                    const left_caps = captures[0..cap_comma];
                    const right_caps = captures[cap_comma + 1 ..];
                    var dest_arg: ?[]const u8 = null;
                    var src_arg: ?[]const u8 = null;
                    var dest_ident: ?[]const u8 = null;
                    var src_ident: ?[]const u8 = null;

                    if (left_caps.len == 2 and left_caps[0].tag == .asterisk and left_caps[1].tag == .identifier and
                        right_caps.len == 1 and right_caps[0].tag == .identifier)
                    {
                        dest_arg = arg1_text;
                        src_arg = arg2_text;
                        dest_ident = context.tokenText(iter_end + 3);
                        src_ident = context.tokenText(iter_end + 2 + cap_comma + 1);
                    } else if (left_caps.len == 1 and left_caps[0].tag == .identifier and
                        right_caps.len == 2 and right_caps[0].tag == .asterisk and right_caps[1].tag == .identifier)
                    {
                        dest_arg = arg2_text;
                        src_arg = arg1_text;
                        dest_ident = context.tokenText(iter_end + 2 + cap_comma + 2);
                        src_ident = context.tokenText(iter_end + 2);
                    }

                    if (dest_arg != null and src_arg != null and dest_ident != null and src_ident != null) {
                        const is_braced = context.tokens[capture_end + 1].tag == .l_brace;
                        const body_end = if (is_braced)
                            context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue
                        else blk: {
                            var s = capture_end + 1;
                            while (s < context.tokens.len and context.tokens[s].tag != .semicolon) : (s += 1) {}
                            if (s >= context.tokens.len) continue;
                            break :blk s;
                        };

                        const stmt_start = if (is_braced) capture_end + 2 else capture_end + 1;
                        const semi_index = if (is_braced) body_end - 1 else body_end;
                        if (stmt_start + 4 == semi_index and
                            context.tokenIs(stmt_start, dest_ident.?) and
                            context.tokens[stmt_start + 1].tag == .period_asterisk and
                            context.tokens[stmt_start + 2].tag == .equal and
                            context.tokenIs(stmt_start + 3, src_ident.?) and
                            context.tokens[semi_index].tag == .semicolon)
                        {
                            // Only distinct local arrays are provably disjoint; two slices may
                            // overlap, where @memcpy is illegal, so that rewrite is a quick fix.
                            const distinct = !std.mem.eql(u8, dest_arg.?, src_arg.?) and
                                bindingsAreDistinctLocalArrays(context, for_index, dest_arg.?, src_arg.?);
                            const fixes = try context.singleFix(.{
                                .title = "Replace the element loop with @memcpy",
                                .kind = .refactor_rewrite,
                                .span = .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end },
                                .replacement = try context.allocator.print("@memcpy({s}{s}, {s}{s});", .{ addressOf(distinct), dest_arg.?, addressOf(distinct), src_arg.? }),
                                .preferred = distinct,
                                .fix_all = distinct,
                            });
                            try context.emit(.{
                                .rule = .prefer_memcpy,
                                .level = level,
                                .span = token.loc,
                                .message = if (distinct)
                                    "this loop only copies corresponding elements from distinct bindings; use @memcpy"
                                else
                                    "this loop only copies corresponding elements; use @memcpy if the slices cannot overlap",
                                .fixes = fixes,
                            });
                            continue;
                        }
                    }
                }
            }
        }

        // Index-based copy: for (0..dst.len) |j| { dst[j] = src[j]; }
        const range = context.source[context.tokens[for_index + 2].loc.start..context.tokens[header_end - 1].loc.end];
        if (std.mem.find(u8, range, "0..") == null or std.mem.find(u8, range, ".len") == null) continue;
        if (capture_end != iter_end + 3 or capture_end + 1 >= context.tokens.len) continue;

        const is_braced = context.tokens[capture_end + 1].tag == .l_brace;
        const body_end = if (is_braced)
            context.matchingToken(capture_end + 1, .l_brace, .r_brace) orelse continue
        else blk: {
            var s = capture_end + 1;
            while (s < context.tokens.len and context.tokens[s].tag != .semicolon) : (s += 1) {}
            if (s >= context.tokens.len) continue;
            break :blk s;
        };

        const index_name = context.tokenText(iter_end + 2);
        const stmt_start = if (is_braced) capture_end + 2 else capture_end + 1;
        const semi_index = if (is_braced) body_end - 1 else body_end;
        if (stmt_start + 9 != semi_index) continue;

        const body = context.tokens[stmt_start..semi_index];
        if (body[0].tag != .identifier or body[1].tag != .l_bracket or !context.tokenIs(stmt_start + 2, index_name) or
            body[3].tag != .r_bracket or body[4].tag != .equal or body[5].tag != .identifier or
            body[6].tag != .l_bracket or !context.tokenIs(stmt_start + 7, index_name) or body[8].tag != .r_bracket) continue;
        const destination = context.tokenText(stmt_start);
        const source = context.tokenText(stmt_start + 5);
        if (std.mem.eql(u8, destination, source) or !bindingsAreDistinctLocalArrays(context, for_index, destination, source)) continue;
        const fixes = try context.singleFix(.{
            .title = "Replace the element loop with @memcpy",
            .kind = .refactor_rewrite,
            .span = .{ .start = token.loc.start, .end = context.tokens[body_end].loc.end },
            .replacement = try context.allocator.print("@memcpy(&{s}, &{s});", .{ destination, source }),
            .preferred = true,
            .fix_all = true,
        });
        try context.emit(.{ .rule = .prefer_memcpy, .level = level, .span = token.loc, .message = "this loop only copies corresponding elements from distinct bindings; use @memcpy", .fixes = fixes });
    }
}

/// `@memcpy` takes slices and pointers, not arrays: the distinct-array case
/// rewrites loops over local arrays, which need their address.
fn addressOf(arrays: bool) []const u8 {
    return if (arrays) "&" else "";
}

fn bindingsAreDistinctLocalArrays(context: RuleRun, before: usize, left: []const u8, right: []const u8) bool {
    var saw_left = false;
    var saw_right = false;
    var index: usize = 0;
    while (index + 4 < before) : (index += 1) {
        if ((context.tokens[index].tag != .keyword_const and context.tokens[index].tag != .keyword_var) or
            context.tokens[index + 1].tag != .identifier) continue;
        const name = context.tokenText(index + 1);
        if (!std.mem.eql(u8, name, left) and !std.mem.eql(u8, name, right)) continue;
        const end = context.statementEnd(index) orelse continue;
        const declaration = context.source[context.tokens[index].loc.start..context.tokens[end].loc.end];
        const owns_array = std.mem.find(u8, declaration, "[_]") != null or
            (findTag(context.tokens, index + 2, end, .colon) != null and findTag(context.tokens, index + 2, end, .l_bracket) != null);
        if (!owns_array) continue;
        if (std.mem.eql(u8, name, left)) saw_left = true else saw_right = true;
    }
    return saw_left and saw_right;
}

test "prefer_memcpy handles multi-sequence loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(dest: []u8, src: []const u8) void {\n" ++
        "    for (dest, src) |*d, s| d.* = s;\n" ++
        "    for (src, dest) |s, *d| { d.* = s; }\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_memcpy}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("@memcpy(dest, src);", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("@memcpy(dest, src);", found[1].fixes[0].edits[0].replacement);
    // Two slices may overlap, so the rewrite is never applied automatically.
    try std.testing.expect(!found[0].fixes[0].fix_all);
    try std.testing.expect(!found[1].fixes[0].fix_all);
}

test "prefer_memcpy tolerates trailing commas in the loop header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy(dest: []u8, src: []const u8) void {\n" ++
        "    for (\n        dest,\n        src,\n    ) |*d, s| d.* = s;\n" ++
        "    for (dest,) |*d| d.* = 0;\n" ++
        "    for () |_| {}\n" ++
        "}\n";
    const configuration = support.only(&.{.prefer_memcpy}, .information);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("@memcpy(dest, src);", found[0].fixes[0].edits[0].replacement);
}

test "distinct local arrays copy with a fix-all rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn copy() void {\n" ++
        "    var dst: [4]u8 = undefined;\n" ++
        "    const src = [_]u8{ 1, 2, 3, 4 };\n" ++
        "    for (dst, src) |*d, s| d.* = s;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_memcpy}, .information));
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings("@memcpy(&dst, &src);", found[0].fixes[0].edits[0].replacement);
}

test "element copy loops report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void { var dst: [4]u8 = undefined; const src = [_]u8{ 1, 2, 3, 4 }; for (0..dst.len) |j| { dst[j] = src[j]; } }";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.prefer_memcpy}, .information));
    try support.expectRules(found, &.{.prefer_memcpy});
}
