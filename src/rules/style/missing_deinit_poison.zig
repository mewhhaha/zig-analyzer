//! `deinit` methods that release what their receiver owns but leave the
//! receiver intact. Ending with `self.* = undefined;` lets safe builds catch a
//! use after `deinit`, a double `deinit` among them, at the first access. The
//! "Poison after deinit" action builds its edit from `poisonEdit` too.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");

pub const rules = [_]types.Rule{.missing_deinit_poison};

pub fn run(context: RuleRun) !void {
    const level = context.level(.missing_deinit_poison);
    if (level == .off) return;
    const tokens = context.tokens;
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn) continue;
        const name = mutableReceiver(context.source, tokens, fn_index) orelse continue;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse continue;
        const body_start = bodyAfterParameters(tokens, parameters_end) orelse continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (body_end == body_start + 1 or !poisonable(context.source, tokens, name, body_start, body_end)) continue;
        if (!releasesResources(context, name, body_start, body_end) or endsByMarkingField(context, name, body_end)) continue;
        const fixes = try context.allocator.alloc(types.Fix, 1);
        const edits = try context.allocator.alloc(types.Edit, 1);
        edits[0] = try poisonEdit(context.allocator, context.source, tokens, name, body_end);
        fixes[0] = .{ .title = "Poison after deinit", .kind = .quickfix, .edits = edits, .preferred = true };
        try context.emit(.{
            .rule = .missing_deinit_poison,
            .level = level,
            .span = tokens[fn_index + 1].loc,
            .message = try context.allocator.print(
                "deinit releases resources but does not end with '{s}.* = undefined;', so a later use of the released value goes unnoticed",
                .{context.tokenText(name)},
            ),
            .fixes = fixes,
        });
    }
}

/// The receiver name of `fn deinit(name: *T, ..)` at `fn_index` when it is a
/// mutable pointer.
pub fn mutableReceiver(source: []const u8, tokens: []const std.zig.Token, fn_index: usize) ?usize {
    if (fn_index + 5 >= tokens.len or tokens[fn_index + 1].tag != .identifier or
        !tokens_util.tokenIs(source, tokens[fn_index + 1], "deinit") or tokens[fn_index + 2].tag != .l_paren or
        tokens[fn_index + 3].tag != .identifier or tokens_util.tokenIs(source, tokens[fn_index + 3], "_") or
        tokens[fn_index + 4].tag != .colon or tokens[fn_index + 5].tag != .asterisk) return null;
    var cursor = fn_index + 6;
    while (cursor < tokens.len) : (cursor += 1) switch (tokens[cursor].tag) {
        .keyword_const => return null,
        .keyword_align, .keyword_volatile, .keyword_allowzero => {},
        .l_paren => cursor = tokens_util.matchingToken(tokens, cursor, .l_paren, .r_paren) orelse return null,
        else => break,
    };
    return fn_index + 3;
}

/// The `{` of the body after the parameter list closing at `parameters_end`.
pub fn bodyAfterParameters(tokens: []const std.zig.Token, parameters_end: usize) ?usize {
    var cursor = parameters_end + 1;
    while (cursor < tokens.len) : (cursor += 1) switch (tokens[cursor].tag) {
        .l_brace => return cursor,
        .semicolon, .eof => return null,
        else => {},
    };
    return null;
}

/// Whether poisoning the receiver named at `name` may be appended to the body
/// in `(body_start, body_end)`: the body does not already poison it last, and
/// does not discard it with `_ = self;`, which a use would make a compile error.
pub fn poisonable(source: []const u8, tokens: []const std.zig.Token, name: usize, body_start: usize, body_end: usize) bool {
    const receiver = tokens_util.tokenText(source, tokens[name]);
    if (body_end >= body_start + 6 and tokens_util.tokenIs(source, tokens[body_end - 5], receiver) and
        tokens[body_end - 4].tag == .period_asterisk and tokens[body_end - 3].tag == .equal and
        tokens_util.tokenIs(source, tokens[body_end - 2], "undefined") and tokens[body_end - 1].tag == .semicolon) return false;
    for (tokens[body_start + 1 .. body_end], body_start + 1..) |token, index| {
        if (token.tag == .identifier and tokens_util.tokenIs(source, token, "_") and index + 3 < body_end and
            tokens[index + 1].tag == .equal and tokens_util.tokenIs(source, tokens[index + 2], receiver) and
            tokens[index + 3].tag == .semicolon) return false;
    }
    return true;
}

/// The edit appending `name.* = undefined;` as the body's last statement.
pub fn poisonEdit(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token, name: usize, body_end: usize) !types.Edit {
    const receiver = tokens_util.tokenText(source, tokens[name]);
    const closing = tokens[body_end].loc.start;
    const line_start = tokens_util.lineStart(source, closing);
    if (std.mem.trim(u8, source[line_start..closing], " \t").len == 0) {
        const indentation = tokens_util.lineIndentation(source, closing);
        return .{
            .span = .{ .start = line_start, .end = line_start },
            .replacement = try allocator.print("{s}    {s}.* = undefined;\n", .{ indentation, receiver }),
        };
    }
    // A body on one line: `{ a.free(self.bytes); }`.
    const previous_end = tokens[body_end - 1].loc.end;
    return .{
        .span = .{ .start = previous_end, .end = previous_end },
        .replacement = try allocator.print(" {s}.* = undefined;", .{receiver}),
    };
}

/// Whether the body calls a release method (`free`, `destroy`, `deinit`,
/// `close`, ...), and none releases the receiver's own memory or resets it.
fn releasesResources(context: RuleRun, name: usize, body_start: usize, body_end: usize) bool {
    const tokens = context.tokens;
    const receiver = context.tokenText(name);
    var releases = false;
    for (body_start + 1..body_end) |index| switch (tokens[index].tag) {
        // An early exit skips a poison appended at the end.
        .keyword_return => return false,
        .identifier => {
            if (context.tokenIs(index, receiver) and tokens[index - 1].tag != .period) {
                // `self.* = .empty;` resets the value for reuse.
                if (tokens[index + 1].tag == .period_asterisk and tokens[index + 2].tag == .equal) return false;
                // `allocator.destroy(self)` frees the receiver itself.
                if ((tokens[index - 1].tag == .l_paren or tokens[index - 1].tag == .comma) and
                    (tokens[index + 1].tag == .r_paren or tokens[index + 1].tag == .comma)) return false;
                continue;
            }
            if (tokens[index - 1].tag == .period and tokens[index + 1].tag == .l_paren and
                resources.isReleaseMethod(context.tokenText(index))) releases = true;
        },
        else => {},
    };
    return releases;
}

/// Whether the body's last statement assigns a field of the receiver, as in
/// `self.fd = -1;`: a released state the value keeps on purpose.
fn endsByMarkingField(context: RuleRun, name: usize, body_end: usize) bool {
    const tokens = context.tokens;
    const start = tokens_util.statementStart(tokens, body_end - 1);
    if (!context.tokenIs(start, context.tokenText(name)) or tokens[start + 1].tag != .period) return false;
    const path = tokens_util.pathAfter(tokens, start) orelse return false;
    return tokens[path.end].tag == .equal;
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.missing_deinit_poison}, .information));
}

test "a releasing deinit that keeps its receiver reports and poisons it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Buffer = struct {
        \\    bytes: []u8,
        \\    file: std.Io.File,
        \\    pub fn deinit(buffer: *Buffer, gpa: std.mem.Allocator, io: std.Io) void {
        \\        gpa.free(buffer.bytes);
        \\        buffer.file.close(io);
        \\    }
        \\};
        \\const Inline = struct {
        \\    list: std.ArrayList(u8),
        \\    fn deinit(self: *Inline, gpa: std.mem.Allocator) void { self.list.deinit(gpa); }
        \\};
    ;
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "deinit", "deinit" });
    try std.testing.expectEqualStrings("        buffer.* = undefined;\n", found[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings(" self.* = undefined;", found[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("Poison after deinit", found[0].fixes[0].title);
}

test "poisoned, by-value, empty, resetting and self-freeing deinits stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const A = struct {
        \\    bytes: []u8,
        \\    fn deinit(self: *A, gpa: std.mem.Allocator) void {
        \\        gpa.free(self.bytes);
        \\        self.* = undefined;
        \\    }
        \\};
        \\const B = struct {
        \\    bytes: []u8,
        \\    fn deinit(self: B, gpa: std.mem.Allocator) void {
        \\        gpa.free(self.bytes);
        \\    }
        \\};
        \\const C = struct {
        \\    fn deinit(self: *C) void {
        \\        _ = self;
        \\    }
        \\    fn other(self: *C) void {
        \\        _ = self;
        \\    }
        \\};
        \\const D = struct {
        \\    list: std.ArrayList(u8),
        \\    fn deinit(self: *D, gpa: std.mem.Allocator) void {
        \\        self.list.deinit(gpa);
        \\        self.* = .{ .list = .empty };
        \\    }
        \\};
        \\const E = struct {
        \\    bytes: []u8,
        \\    gpa: std.mem.Allocator,
        \\    fn deinit(self: *E) void {
        \\        self.gpa.free(self.bytes);
        \\        self.gpa.destroy(self);
        \\    }
        \\};
        \\const F = struct {
        \\    count: usize,
        \\    fn deinit(self: *F) void {
        \\        self.count = 0;
        \\    }
        \\};
        \\const G = struct {
        \\    bytes: ?[]u8,
        \\    fn deinit(self: *G, gpa: std.mem.Allocator) void {
        \\        const bytes = self.bytes orelse return;
        \\        gpa.free(bytes);
        \\    }
        \\};
        \\const H = struct {
        \\    bytes: []u8,
        \\    fn deinit(self: *const H, gpa: std.mem.Allocator) void {
        \\        gpa.free(self.bytes);
        \\    }
        \\};
        \\const I = struct {
        \\    fn deinit(self: *I) void {}
        \\};
        \\const J = struct {
        \\    fd: i32,
        \\    fn deinit(self: *J) void {
        \\        std.posix.close(self.fd);
        \\        self.fd = -1;
        \\    }
        \\};
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
}
