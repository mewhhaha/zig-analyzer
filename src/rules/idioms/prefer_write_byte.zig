const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const ArgumentRange = @import("../../syntax/tokens.zig").Range;
const parseSingleByteLiteral = @import("../../syntax/tokens.zig").parseSingleByteLiteral;

pub const rules = [_]types.Rule{
    .prefer_write_byte,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_write_byte);
    if (level == .off) return;

    for (context.tokens, 0..) |token, call_index| {
        if (token.tag != .identifier or call_index < 2 or
            context.tokens[call_index - 1].tag != .period or
            call_index + 1 >= context.tokens.len or
            context.tokens[call_index + 1].tag != .l_paren) continue;

        const method_name = context.tokenText(call_index);
        const is_write_all = std.mem.eql(u8, method_name, "writeAll");
        if (!is_write_all and !std.mem.eql(u8, method_name, "print")) continue;
        const call_end = context.matchingToken(call_index + 1, .l_paren, .r_paren) orelse continue;
        const fix_all = switch (receiverKind(context, call_index - 1)) {
            .other => continue,
            .unknown => false,
            .writer => true,
        };

        if (is_write_all) {
            try checkWriteAll(context, level, call_index, call_end, fix_all);
        } else {
            try checkPrint(context, level, call_index, call_end, fix_all);
        }
    }
}

const Receiver = enum {
    /// Declared as `std.Io.Writer` or a pointer to it, which has `writeByte`.
    writer,
    /// A writer of unknown type: `anytype`, an adapter named `*Writer`, a
    /// field or a call result. The rewrite is offered, not applied by `check --fix`.
    unknown,
    /// Not a writer: a namespace function such as `std.debug.print`, a binding
    /// declared with some other type, or a call under test.
    other,
};

/// What the receiver ending before the `.` at `period` is.
fn receiverKind(context: RuleRun, period: usize) Receiver {
    return switch (declaredReceiverKind(context, period)) {
        .writer => .writer,
        .writer_type => .unknown,
        // A receiver of unknown type counts only when its name says it is a writer.
        .unknown => if (writerNamed(context, period)) .unknown else .other,
        .other => .other,
    };
}

/// `Receiver` before the name is consulted: `writer_type` is a binding
/// declared with some other type named `...Writer`.
fn declaredReceiverKind(context: RuleRun, period: usize) enum { writer, writer_type, unknown, other } {
    const tokens = context.tokens;
    const start = context.pathStartBefore(period) orelse return .unknown;
    // `expectError(error.WriteFailed, w.writeAll("x"))` asserts on that very call.
    if (start > 0 and (tokens[start - 1].tag == .comma or
        (tokens[start - 1].tag == .l_paren and start > 1 and
            (tokens[start - 2].tag == .identifier or tokens[start - 2].tag == .builtin)))) return .other;
    // `std.debug.print`, `debug.print` and other namespace functions.
    if (context.tokenIs(period - 1, "debug") or context.tokenIs(start, "std")) return .other;
    if (start + 1 != period) return .unknown;
    const binding = context.scopes.findBinding(start) orelse return .unknown;
    const declaration = binding.token_index;
    if (declaration + 2 >= tokens.len) return .unknown;
    if (tokens[declaration + 1].tag != .colon) {
        // `const json = @import("json.zig");`
        if (tokens[declaration + 1].tag == .equal and context.tokenIs(declaration + 2, "@import")) return .other;
        return .unknown;
    }
    var type_start = declaration + 2;
    if (tokens[type_start].tag == .keyword_anytype) return .unknown;
    if (tokens[type_start].tag == .asterisk) type_start += 1;
    if (type_start < tokens.len and tokens[type_start].tag == .keyword_const) type_start += 1;
    var type_end = type_start;
    while (type_end + 2 < tokens.len and tokens[type_end].tag == .identifier and
        tokens[type_end + 1].tag == .period and tokens[type_end + 2].tag == .identifier) type_end += 2;
    if (type_end >= tokens.len or tokens[type_end].tag != .identifier) return .other;
    switch (tokens[type_end + 1].tag) {
        .comma, .r_paren, .equal, .semicolon => {},
        else => return .other,
    }
    const io_writer = context.tokenIs(type_end, "Writer") and type_end >= type_start + 2 and
        context.tokenIs(type_end - 2, "Io") and (type_end == type_start + 2 or
        (type_end == type_start + 4 and context.tokenIs(type_start, "std")));
    if (io_writer) return .writer;
    return if (std.mem.endsWith(u8, context.tokenText(type_end), "Writer")) .writer_type else .other;
}

/// Whether the receiver before the `.` at `period`, a name or a call such as
/// `file.writer()`, is named like a writer: `writer`, `stdout_writer`,
/// `interface` (the `std.Io.Writer` field of the file and buffer writers),
/// `w`, `out` or `stdout`. A `terminal` or `ctx` with a `print` method of its
/// own is not.
fn writerNamed(context: RuleRun, period: usize) bool {
    const tokens = context.tokens;
    if (period == 0) return false;
    var name = period - 1;
    if (tokens[name].tag == .r_paren) {
        const opening = context.scopes.matchingToken(name) orelse return false;
        if (opening == 0) return false;
        name = opening - 1;
    }
    if (tokens[name].tag != .identifier) return false;
    const text = context.tokenText(name);
    var lower: [64]u8 = undefined;
    if (text.len > lower.len) return false;
    const folded = std.ascii.lowerString(&lower, text);
    for ([_][]const u8{ "writer", "stdout", "stderr" }) |part| if (std.mem.find(u8, folded, part) != null) return true;
    for ([_][]const u8{ "w", "bw", "out", "output", "out_stream", "interface" }) |short| if (std.mem.eql(u8, text, short)) return true;
    return false;
}

fn checkWriteAll(context: RuleRun, level: types.Level, call_index: usize, call_end: usize, fix_all: bool) !void {
    // Expected arguments: 1 argument: a 1-character string literal
    // Check if there are no top-level commas in arguments
    if (hasTopLevelComma(context, call_index + 2, call_end)) return;
    if (call_index + 2 >= call_end) return;

    const arg_token = context.tokens[call_index + 2];
    if (arg_token.tag != .string_literal or call_index + 3 != call_end) return;

    const text = context.tokenText(call_index + 2);
    const char_lit = try parseSingleByteLiteral(context.allocator, text) orelse return;

    const edits = try context.allocator.alloc(types.Edit, 2);
    edits[0] = .{
        .span = context.tokens[call_index].loc,
        .replacement = "writeByte",
    };
    edits[1] = .{
        .span = arg_token.loc,
        .replacement = char_lit,
    };

    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{
        .title = try context.allocator.print("Use 'writeByte({s})'", .{char_lit}),
        .kind = .quickfix,
        .edits = edits,
        .preferred = true,
        .fix_all = fix_all,
    };

    try context.emit(.{
        .rule = .prefer_write_byte,
        .level = level,
        .span = context.tokens[call_index].loc,
        .message = try context.allocator.print(
            "writing a single character via 'writeAll' incurs slice overhead; use 'writeByte({s})'",
            .{char_lit},
        ),
        .fixes = fixes,
    });
}

fn checkPrint(context: RuleRun, level: types.Level, call_index: usize, call_end: usize, fix_all: bool) !void {
    // print has 2 arguments: format string, and tuple .{}
    const args = twoArguments(context, call_index + 1, call_end) orelse return;

    if (args[0].end != args[0].start + 1) return;
    const fmt_token = context.tokens[args[0].start];
    if (fmt_token.tag != .string_literal) return;

    const fmt_text = context.tokenText(args[0].start);

    // Case 1: fmt is a 1-character string literal and second arg is empty tuple .{}
    if (try parseSingleByteLiteral(context.allocator, fmt_text)) |char_lit| {
        if (isEmptyTuple(context, args[1].start, args[1].end)) {
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{
                .span = context.tokens[call_index].loc,
                .replacement = "writeByte",
            };
            edits[1] = .{
                .span = .{
                    .start = context.tokens[args[0].start].loc.start,
                    .end = context.tokens[args[1].end - 1].loc.end,
                },
                .replacement = char_lit,
            };

            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = try context.allocator.print("Use 'writeByte({s})'", .{char_lit}),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = fix_all,
            };

            try context.emit(.{
                .rule = .prefer_write_byte,
                .level = level,
                .span = context.tokens[call_index].loc,
                .message = try context.allocator.print(
                    "writing a single character via 'print' incurs format parsing overhead; use 'writeByte({s})'",
                    .{char_lit},
                ),
                .fixes = fixes,
            });
            return;
        }
    }

    // Case 2: fmt is "{c}" and second arg is a single element tuple .{val}
    if (std.mem.eql(u8, fmt_text, "\"{c}\"")) {
        if (extractSingleTupleElement(context, args[1].start, args[1].end)) |val_expr| {
            const edits = try context.allocator.alloc(types.Edit, 2);
            edits[0] = .{
                .span = context.tokens[call_index].loc,
                .replacement = "writeByte",
            };
            edits[1] = .{
                .span = .{
                    .start = context.tokens[args[0].start].loc.start,
                    .end = context.tokens[args[1].end - 1].loc.end,
                },
                .replacement = val_expr,
            };

            const fixes = try context.allocator.alloc(types.Fix, 1);
            fixes[0] = .{
                .title = try context.allocator.print("Use 'writeByte({s})'", .{val_expr}),
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
                .fix_all = fix_all,
            };

            try context.emit(.{
                .rule = .prefer_write_byte,
                .level = level,
                .span = context.tokens[call_index].loc,
                .message = try context.allocator.print(
                    "formatting a single character via 'print(\"{{c}}\", ...)' incurs format parsing overhead; use 'writeByte({s})'",
                    .{val_expr},
                ),
                .fixes = fixes,
            });
        }
    }
}

fn twoArguments(context: RuleRun, opening: usize, closing: usize) ?[2]ArgumentRange {
    var comma_idx: ?usize = null;
    var depth: usize = 0;

    for (context.tokens[opening + 1 .. closing], opening + 1..) |token, i| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (comma_idx != null) return null; // more than 2 args
                comma_idx = i;
            },
            else => {},
        }
    }

    const c = comma_idx orelse return null;
    if (c == opening + 1 or c + 1 == closing) return null;

    return .{
        .{ .start = opening + 1, .end = c },
        .{ .start = c + 1, .end = closing },
    };
}

fn hasTopLevelComma(context: RuleRun, start: usize, end: usize) bool {
    var depth: usize = 0;
    for (context.tokens[start..end]) |token| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn isEmptyTuple(context: RuleRun, start: usize, end: usize) bool {
    // Expected: . { }
    if (end < start + 3) return false;
    return context.tokens[start].tag == .period and
        context.tokens[start + 1].tag == .l_brace and
        context.tokens[start + 2].tag == .r_brace and
        start + 3 == end;
}

fn extractSingleTupleElement(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    // Expected: . { expr }
    if (end < start + 4) return null;
    if (context.tokens[start].tag != .period or context.tokens[start + 1].tag != .l_brace or
        context.tokens[end - 1].tag != .r_brace) return null;

    const inner_start = start + 2;
    const inner_end = end - 1;

    // Must not have top-level commas inside the tuple
    if (hasTopLevelComma(context, inner_start, inner_end)) return null;

    return std.mem.trim(u8, context.source[context.tokens[inner_start].loc.start..context.tokens[inner_end - 1].loc.end], " \t\r\n");
}

test "prefer write byte detects writeAll with single character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeClosing(writer: anytype) !void {
        \\    try writer.writeAll("}");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqual(2, findings[0].fixes[0].edits.len);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'}'", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte detects print with single character literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeNewline(writer: anytype) !void {
        \\    try writer.print("\n", .{});
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("'\\n'", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte detects print {c} format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeChar(writer: anytype, ch: u8) !void {
        \\    try writer.print("{c}", .{ch});
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.prefer_write_byte, findings[0].rule);
    try std.testing.expectEqualStrings("writeByte", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("ch", findings[0].fixes[0].edits[1].replacement);
}

test "prefer write byte ignores multi-byte string in writeAll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn writeWord(writer: anytype) !void {
        \\    try writer.writeAll("hello");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

test "prefer write byte applies its fix only to a declared std.Io.Writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn typed(writer: *std.Io.Writer, out: *Io.Writer) !void {
        \\    try writer.writeAll("\n");
        \\    try out.print(",", .{});
        \\    var fixed: std.Io.Writer = .fixed(&.{});
        \\    try fixed.writeAll(" ");
        \\}
        \\fn generic(writer: anytype, self: *Self, file: File) !void {
        \\    try writer.writeAll("\n");
        \\    try self.writer.writeAll("\n");
        \\    try file.writer().writeAll("\n");
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(6, findings.len);
    for (findings[0..3]) |finding| try std.testing.expect(finding.fixes[0].fix_all);
    for (findings[3..]) |finding| try std.testing.expect(!finding.fixes[0].fix_all);
}

test "prefer write byte ignores namespace functions, other receiver types and calls under test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const debug = std.debug;
        \\const Buffer = struct {
        \\    pub fn print(self: *Buffer, comptime format: []const u8, args: anytype) void {
        \\        _ = self;
        \\        _ = format;
        \\        _ = args;
        \\    }
        \\};
        \\fn emit(buffer: *Buffer, w: *std.Io.Writer, repl: *Repl) !void {
        \\    try repl.terminal.print("\n", .{});
        \\    std.debug.print("\n", .{});
        \\    debug.print(" ", .{});
        \\    buffer.print("\n", .{});
        \\    try std.testing.expectError(error.WriteFailed, w.writeAll("x"));
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

fn testConfiguration() types.Configuration {
    const configuration = support.only(&.{.prefer_write_byte}, .warning);
    return configuration;
}
