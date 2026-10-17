//! `anytype` writer and reader parameters that are only ever the receiver of
//! `std.Io.Writer` or `std.Io.Reader` method calls, and so can name the
//! interface type.
const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .prefer_typed_io_parameter,
};

/// A method of the interface and how many arguments a call passes it.
const Method = struct { name: []const u8, arguments: usize };

const Interface = struct {
    type_name: []const u8,
    methods: []const Method,
};

/// The public `*Writer` methods of the 0.17 `std/Io/Writer.zig` callers use;
/// the vtable defaults and drain helpers are left out.
const writer: Interface = .{ .type_name = "std.Io.Writer", .methods = &.{
    .{ .name = "advance", .arguments = 1 },
    .{ .name = "alignBuffer", .arguments = 4 },
    .{ .name = "alignBufferOptions", .arguments = 2 },
    .{ .name = "ensureUnusedCapacity", .arguments = 1 },
    .{ .name = "flush", .arguments = 0 },
    .{ .name = "print", .arguments = 2 },
    .{ .name = "printAscii", .arguments = 2 },
    .{ .name = "printAsciiChar", .arguments = 2 },
    .{ .name = "printBase64", .arguments = 1 },
    .{ .name = "printByteSize", .arguments = 3 },
    .{ .name = "printFloat", .arguments = 2 },
    .{ .name = "printHex", .arguments = 2 },
    .{ .name = "printInt", .arguments = 4 },
    .{ .name = "printStringEscaped", .arguments = 1 },
    .{ .name = "printUnicodeCodepoint", .arguments = 1 },
    .{ .name = "printValue", .arguments = 4 },
    .{ .name = "sendFileAll", .arguments = 2 },
    .{ .name = "splatByte", .arguments = 2 },
    .{ .name = "splatByteAll", .arguments = 2 },
    .{ .name = "splatBytes", .arguments = 2 },
    .{ .name = "splatBytesAll", .arguments = 2 },
    .{ .name = "undo", .arguments = 1 },
    .{ .name = "writableArray", .arguments = 1 },
    .{ .name = "writableSlice", .arguments = 1 },
    .{ .name = "write", .arguments = 1 },
    .{ .name = "writeAll", .arguments = 1 },
    .{ .name = "writeByte", .arguments = 1 },
    .{ .name = "writeInt", .arguments = 3 },
    .{ .name = "writeLeb128", .arguments = 1 },
    .{ .name = "writeSleb128", .arguments = 1 },
    .{ .name = "writeSliceEndian", .arguments = 3 },
    .{ .name = "writeSliceSwap", .arguments = 2 },
    .{ .name = "writeSplat", .arguments = 2 },
    .{ .name = "writeSplatAll", .arguments = 2 },
    .{ .name = "writeStruct", .arguments = 2 },
    .{ .name = "writeUleb128", .arguments = 1 },
    .{ .name = "writeVec", .arguments = 1 },
    .{ .name = "writeVecAll", .arguments = 1 },
} };

/// The public `*Reader` methods of the 0.17 `std/Io/Reader.zig` callers use.
const reader: Interface = .{ .type_name = "std.Io.Reader", .methods = &.{
    .{ .name = "allocRemaining", .arguments = 2 },
    .{ .name = "appendExact", .arguments = 3 },
    .{ .name = "appendRemaining", .arguments = 3 },
    .{ .name = "appendRemainingUnlimited", .arguments = 2 },
    .{ .name = "buffered", .arguments = 0 },
    .{ .name = "bufferedLen", .arguments = 0 },
    .{ .name = "discard", .arguments = 1 },
    .{ .name = "discardAll", .arguments = 1 },
    .{ .name = "discardAll64", .arguments = 1 },
    .{ .name = "discardDelimiterExclusive", .arguments = 1 },
    .{ .name = "discardDelimiterInclusive", .arguments = 1 },
    .{ .name = "discardDelimiterLimit", .arguments = 2 },
    .{ .name = "discardRemaining", .arguments = 0 },
    .{ .name = "discardShort", .arguments = 1 },
    .{ .name = "fill", .arguments = 1 },
    .{ .name = "fillMore", .arguments = 0 },
    .{ .name = "peek", .arguments = 1 },
    .{ .name = "peekArray", .arguments = 1 },
    .{ .name = "peekByte", .arguments = 0 },
    .{ .name = "peekDelimiterExclusive", .arguments = 1 },
    .{ .name = "peekDelimiterInclusive", .arguments = 1 },
    .{ .name = "peekGreedy", .arguments = 1 },
    .{ .name = "peekInt", .arguments = 2 },
    .{ .name = "peekSentinel", .arguments = 1 },
    .{ .name = "peekStruct", .arguments = 2 },
    .{ .name = "peekStructPointer", .arguments = 1 },
    .{ .name = "readAllocAll", .arguments = 2 },
    .{ .name = "readAllocShort", .arguments = 2 },
    .{ .name = "readSliceAll", .arguments = 1 },
    .{ .name = "readSliceEndian", .arguments = 3 },
    .{ .name = "readSliceEndianAlloc", .arguments = 4 },
    .{ .name = "readSliceShort", .arguments = 1 },
    .{ .name = "readVec", .arguments = 1 },
    .{ .name = "readVecAll", .arguments = 1 },
    .{ .name = "stream", .arguments = 2 },
    .{ .name = "streamDelimiter", .arguments = 2 },
    .{ .name = "streamDelimiterEnding", .arguments = 2 },
    .{ .name = "streamDelimiterLimit", .arguments = 3 },
    .{ .name = "streamExact", .arguments = 2 },
    .{ .name = "streamExact64", .arguments = 2 },
    .{ .name = "streamRemaining", .arguments = 1 },
    .{ .name = "take", .arguments = 1 },
    .{ .name = "takeArray", .arguments = 1 },
    .{ .name = "takeByte", .arguments = 0 },
    .{ .name = "takeByteSigned", .arguments = 0 },
    .{ .name = "takeDelimiter", .arguments = 1 },
    .{ .name = "takeDelimiterExclusive", .arguments = 1 },
    .{ .name = "takeDelimiterInclusive", .arguments = 1 },
    .{ .name = "takeEnum", .arguments = 2 },
    .{ .name = "takeEnumNonexhaustive", .arguments = 2 },
    .{ .name = "takeInt", .arguments = 2 },
    .{ .name = "takeLeb128", .arguments = 1 },
    .{ .name = "takeSentinel", .arguments = 1 },
    .{ .name = "takeStruct", .arguments = 2 },
    .{ .name = "takeStructPointer", .arguments = 1 },
    .{ .name = "takeVarInt", .arguments = 3 },
    .{ .name = "toss", .arguments = 1 },
    .{ .name = "tossBuffered", .arguments = 0 },
} };

pub fn run(context: RuleRun) !void {
    const level = context.level(.prefer_typed_io_parameter);
    if (level == .off) return;
    const tree = context.tree;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const prototype_node, const body = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, prototype_node) orelse continue;
        // std.json calls `jsonStringify` with its `*std.json.Stringify`, whose
        // `write` and `print` share the writer's names but not its interface.
        if (prototype.name_token) |name| if (std.mem.eql(u8, tree.tokenSlice(name), "jsonStringify")) continue;
        var parameters = prototype.iterate(tree);
        while (parameters.next()) |parameter| {
            const anytype_token = parameter.anytype_ellipsis3 orelse continue;
            if (tree.tokenTag(anytype_token) != .keyword_anytype or parameter.comptime_noalias != null) continue;
            const name_token = parameter.name_token orelse continue;
            const name = tree.tokenSlice(name_token);
            const interface = interfaceNamed(name) orelse continue;
            if (!onlyInterfaceCalls(context, interface, name, name_token + 1, tree.nodeMainToken(body), tree.lastToken(body))) continue;
            try context.emit(.{
                .rule = .prefer_typed_io_parameter,
                .level = level,
                .span = context.tokens[anytype_token].loc,
                .message = try context.allocator.print(
                    "'{s}' is only the receiver of {s} methods; declare it '*{s}' instead of 'anytype'",
                    .{ name, interface.type_name, interface.type_name },
                ),
            });
        }
    }
}

/// The interface a parameter's name says it is; other names are left alone,
/// since a type of their own may share a method name such as `print`.
fn interfaceNamed(name: []const u8) ?Interface {
    var lower: [64]u8 = undefined;
    if (name.len > lower.len) return null;
    const folded = std.ascii.lowerString(&lower, name);
    if (std.mem.find(u8, folded, "writer") != null) return writer;
    if (std.mem.find(u8, folded, "reader") != null) return reader;
    for ([_][]const u8{ "w", "bw", "out", "output", "out_stream" }) |short| if (std.mem.eql(u8, name, short)) return writer;
    for ([_][]const u8{ "r", "br", "input", "in_stream" }) |short| if (std.mem.eql(u8, name, short)) return reader;
    return null;
}

/// Whether every reference to `name` after its declaration is in the body
/// `[body_start, body_end]` as the receiver of a call of an `interface` method
/// with that method's argument count, and there is at least one.
fn onlyInterfaceCalls(
    context: RuleRun,
    interface: Interface,
    name: []const u8,
    start: usize,
    body_start: usize,
    body_end: usize,
) bool {
    var calls: usize = 0;
    for (context.tokens[start..body_end], start..) |token, index| {
        if (token.tag != .identifier or !context.refersToBinding(index, name)) continue;
        if (index < body_start or index + 3 >= body_end or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) return false;
        const closing = context.matchingToken(index + 3, .l_paren, .r_paren) orelse return false;
        const method = context.tokenText(index + 2);
        const known = for (interface.methods) |candidate| {
            if (std.mem.eql(u8, candidate.name, method)) break candidate;
        } else return false;
        if (argumentCount(context, index + 3, closing) != known.arguments) return false;
        calls += 1;
    }
    return calls != 0;
}

fn argumentCount(context: RuleRun, opening: usize, closing: usize) usize {
    if (closing == opening + 1) return 0;
    var depth: usize = 0;
    var commas: usize = 0;
    for (context.tokens[opening + 1 .. closing]) |token| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            commas += 1;
        },
        else => {},
    };
    const trailing = context.tokens[closing - 1].tag == .comma;
    return commas + 1 - @intFromBool(trailing);
}

test "anytype writers and readers used only through the interface report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn format(self: Point, writer: anytype) !void {\n" ++
        "    try writer.print(\"({d}, {d})\", .{ self.x, self.y });\n" ++
        "    try writer.writeByte('\\n');\n" ++
        "}\n" ++
        "fn header(r: anytype) !u32 {\n" ++
        "    const magic = try r.takeInt(u32, .little);\n" ++
        "    r.toss(4);\n" ++
        "    return magic;\n" ++
        "}\n";
    const found = try findingsFor(arena.allocator(), source);
    try support.expectSpans(source, found, &.{ "anytype", "anytype" });
    try std.testing.expect(std.mem.find(u8, found[0].message, "'*std.Io.Writer'") != null);
    try std.testing.expect(std.mem.find(u8, found[1].message, "'*std.Io.Reader'") != null);
}

test "parameters passed on, reflected on, or used through other methods stay anytype" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn forwarded(writer: anytype) !void { try writer.writeAll(\"a\"); try emit(writer); }\n" ++
        "fn reflected(writer: anytype) @TypeOf(writer).Error!void { try writer.writeAll(\"a\"); }\n" ++
        "fn legacy(writer: anytype) !void { try writer.writeByteNTimes(' ', 4); }\n" ++
        "fn oldStruct(writer: anytype, value: Header) !void { try writer.writeStruct(value); }\n" ++
        "fn field(writer: anytype) usize { return writer.end; }\n" ++
        "fn unused(writer: anytype) void { _ = writer; }\n" ++
        "fn other(logger: anytype) void { logger.print(\"{d}\", .{1}); }\n" ++
        "fn compileTime(comptime writer: anytype) void { writer.flush(); }\n" ++
        "fn legacyReader(reader: anytype) !u8 { return reader.readByte(); }\n" ++
        "fn mixed(writer: anytype) !void { _ = try writer.takeByte(); }\n" ++
        "const Details = struct { bytes: []const u8, pub fn jsonStringify(self: Details, writer: anytype) !void { try writer.print(\"{s}\", .{self.bytes}); } };\n";
    const found = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.prefer_typed_io_parameter}, .warning));
}
