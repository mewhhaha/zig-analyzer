const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.undefined_readvec_destination);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 5 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const descriptor_count = undefinedSliceDescriptorCount(context, declaration_index, declaration_end) orelse continue;
        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const binding = context.tokenText(declaration_index + 1);
        const call_index = readVecCallWithDestination(context, binding, declaration_end + 1, scope_end) orelse continue;
        if (destinationInitializedBefore(context, binding, descriptor_count, declaration_end + 1, call_index)) continue;
        try context.emit(.{
            .rule = .undefined_readvec_destination,
            .level = level,
            .span = context.tokens[call_index].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "readVec reads destination slice descriptors from '{s}', but those descriptors are still undefined",
                .{binding},
            ),
        });
    }
}

fn undefinedSliceDescriptorCount(context: RuleRun, start: usize, end: usize) ?usize {
    var equal_index: ?usize = null;
    var descriptor_count: ?usize = null;
    var descriptor_type: ?[]const u8 = null;
    var bracket_pairs: usize = 0;
    var index = start + 2;
    while (index < end) : (index += 1) {
        if (context.tokens[index].tag == .equal) {
            equal_index = index;
            break;
        }
        if (context.tokens[index].tag != .l_bracket) continue;
        bracket_pairs += 1;
        if (bracket_pairs == 1 and index + 2 < end and
            context.tokens[index + 1].tag == .number_literal and context.tokens[index + 2].tag == .r_bracket)
        {
            descriptor_count = std.fmt.parseInt(usize, context.tokenText(index + 1), 10) catch null;
            if (index + 3 < end and context.tokens[index + 3].tag == .identifier) {
                descriptor_type = context.tokenText(index + 3);
            }
        }
    }
    const equal = equal_index orelse return null;
    const contains_slice = bracket_pairs >= 2 or if (descriptor_type) |type_name|
        descriptorTypeContainsSlice(context, type_name)
    else
        false;
    if (!contains_slice or equal + 1 >= end or
        context.tokens[equal + 1].tag != .identifier or !context.tokenIs(equal + 1, "undefined")) return null;
    return descriptor_count;
}

fn descriptorTypeContainsSlice(context: RuleRun, type_name: []const u8) bool {
    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .identifier or !context.tokenIs(declaration_index, type_name) or declaration_index == 0 or
            context.tokens[declaration_index - 1].tag != .keyword_const) continue;
        var struct_index = declaration_index + 1;
        while (struct_index < context.tokens.len and struct_index < declaration_index + 4 and
            context.tokens[struct_index].tag != .keyword_struct) : (struct_index += 1)
        {}
        if (struct_index >= context.tokens.len or context.tokens[struct_index].tag != .keyword_struct or
            struct_index + 1 >= context.tokens.len or context.tokens[struct_index + 1].tag != .l_brace) continue;
        const container_end = context.matchingToken(struct_index + 1, .l_brace, .r_brace) orelse continue;
        for (context.tokens[struct_index + 2 .. container_end], struct_index + 2..) |field, field_index| {
            if (field.tag == .l_bracket and field_index + 1 < container_end and
                context.tokens[field_index + 1].tag == .r_bracket) return true;
        }
    }
    return false;
}

fn readVecCallWithDestination(context: RuleRun, binding: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index + 4 < end) : (index += 1) {
        if (!context.tokenIs(index, "readVec") or index == 0 or context.tokens[index - 1].tag != .period or
            context.tokens[index + 1].tag != .l_paren) continue;
        const call_end = context.matchingToken(index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end >= end) continue;
        var argument_index = index + 2;
        if (context.tokens[argument_index].tag == .ampersand) argument_index += 1;
        if (argument_index < call_end and context.tokenIs(argument_index, binding)) return index;
    }
    return null;
}

fn destinationInitializedBefore(context: RuleRun, binding: []const u8, descriptor_count: usize, start: usize, end: usize) bool {
    var initialized: u64 = 0;
    var index = start;
    while (index + 1 < end) : (index += 1) {
        if (!context.tokenIs(index, binding)) continue;
        if (context.tokens[index + 1].tag == .equal) return true;
        if (descriptor_count > 64 or context.tokens[index + 1].tag != .l_bracket or
            index + 2 >= end or context.tokens[index + 2].tag != .number_literal) continue;
        const closing = context.matchingToken(index + 1, .l_bracket, .r_bracket) orelse continue;
        if (closing != index + 3 or closing + 1 >= end or context.tokens[closing + 1].tag != .equal) continue;
        const descriptor_index = std.fmt.parseInt(usize, context.tokenText(index + 2), 10) catch continue;
        if (descriptor_index < descriptor_count) initialized |= @as(u64, 1) << @intCast(descriptor_index);
    }
    if (descriptor_count == 0) return true;
    const expected = if (descriptor_count == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(descriptor_count)) - 1;
    return initialized == expected;
}

test "undefined readVec destination descriptors report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype) !void {\n" ++
        "    var buffers: [1][]u8 = undefined;\n" ++
        "    _ = try reader.readVec(&buffers);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "initialized descriptors and ordinary byte buffers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype) !void {\n" ++
        "    var storage: [16]u8 = undefined;\n" ++
        "    var buffers: [1][]u8 = undefined;\n" ++
        "    buffers[0] = &storage;\n" ++
        "    _ = try reader.readVec(&buffers);\n" ++
        "    _ = try reader.readSliceShort(&storage);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "partially initialized descriptor arrays report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive(reader: anytype) !void {\n" ++
        "    var storage: [16]u8 = undefined;\n" ++
        "    var buffers: [2][]u8 = undefined;\n" ++
        "    buffers[0] = &storage;\n" ++
        "    _ = try reader.readVec(&buffers);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "undefined custom slice descriptor structs report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Buffer = struct { ptr: []u8 };\n" ++
        "fn receive(reader: anytype) !void {\n" ++
        "    var buffers: [2]Buffer = undefined;\n" ++
        "    _ = try reader.readVec(&buffers);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "unrelated readVec function stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn receive() !void {\n" ++
        "    var buffers: [1][]u8 = undefined;\n" ++
        "    readVec(&buffers);\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
