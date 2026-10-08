//! Rewrites that repair one finding or one selection and that no rule can
//! express as a plain `Fix` because they depend on more than the finding's own
//! span: moving a cleanup, inserting a deferred release, generating a missing
//! function, extracting a selected expression. Each returns byte edits; the
//! transport converts them.
const std = @import("std");

const analysis = @import("../analysis.zig");
const tokens_util = @import("../syntax/tokens.zig");
const syntax_types = @import("../syntax/types.zig");
const action_context = @import("context.zig");

pub const Candidate = action_context.Candidate;

/// The rewrites offered for `finding` (not yet filtered by requested kinds).
pub fn forFinding(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    finding: analysis.Finding,
) ![]const Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    switch (finding.rule) {
        .unresolved_call => if (try generateFunctionEdit(allocator, source, finding.span)) |generated| {
            const edits = try allocator.alloc(analysis.Edit, 1);
            edits[0] = generated;
            try candidates.append(allocator, .{
                .title = try allocator.print("Generate function '{s}'", .{source[finding.span.start..finding.span.end]}),
                .kind = .refactor_rewrite,
                .edits = edits,
            });
        },
        .unreleased_allocation => if (try allocationCleanupEdit(allocator, source, finding.span)) |cleanup| {
            const edits = try allocator.alloc(analysis.Edit, 1);
            edits[0] = cleanup.edit;
            try candidates.append(allocator, .{ .title = cleanup.title, .kind = .quickfix, .edits = edits });
        },
        .cleanup_after_fallible_operation => if (try moveCleanupAfterAcquisition(allocator, source, finding.span)) |edits| {
            try candidates.append(allocator, .{
                .title = "Move cleanup directly after acquisition",
                .kind = .quickfix,
                .edits = edits,
                .preferred = true,
            });
        },
        else => {},
    }
    return try candidates.toOwnedSlice(allocator);
}

/// The refactoring that extracts the selected expression into a constant, when
/// the selection is exactly one expression of `tree`.
pub fn extractExpression(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    selection: std.zig.Token.Loc,
) !?Candidate {
    const extraction = try extractExpressionEdits(allocator, source, tree, selection) orelse return null;
    const edits = try allocator.alloc(analysis.Edit, 2);
    edits[0] = extraction.declaration;
    edits[1] = extraction.replacement;
    return .{
        .title = try allocator.print("Extract into const '{s}'", .{extraction.name}),
        .kind = .refactor_extract,
        .edits = edits,
        .preferred = true,
    };
}

const CleanupAction = struct {
    title: []const u8,
    edit: analysis.Edit,
};

fn allocationCleanupEdit(
    allocator: std.mem.Allocator,
    source: []const u8,
    binding_span: std.zig.Token.Loc,
) !?CleanupAction {
    const statement_start = if (std.mem.findScalarLast(u8, source[0..binding_span.start], '\n')) |nl| nl + 1 else 0;
    const relative_end = std.mem.findScalar(u8, source[binding_span.end..], ';') orelse return null;
    const statement_end = binding_span.end + relative_end + 1;
    const statement = source[statement_start..statement_end];
    const equal = std.mem.findScalar(u8, statement, '=') orelse return null;
    const method_offset, const release = allocationCall(statement[equal + 1 ..]) orelse return null;
    var receiver = std.mem.trim(u8, statement[equal + 1 ..][0..method_offset], " \t\r\n");
    if (std.mem.startsWith(u8, receiver, "try ")) receiver = std.mem.trimStart(u8, receiver[4..], " \t");
    if (receiver.len == 0) return null;
    for (receiver) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '.') return null;
    }
    const binding_name = source[binding_span.start..binding_span.end];
    const indentation_end = for (source[statement_start..], statement_start..) |character, offset| {
        if (character != ' ' and character != '\t') break offset;
    } else statement_start;
    const indentation = source[statement_start..indentation_end];
    const title = try allocator.print("Insert defer {s}.{s}({s})", .{ receiver, release, binding_name });
    errdefer allocator.free(title);
    const replacement = try allocator.print("\n{s}defer {s}.{s}({s});", .{ indentation, receiver, release, binding_name });
    return .{
        .title = title,
        .edit = .{
            .span = .{ .start = statement_end, .end = statement_end },
            .replacement = replacement,
        },
    };
}

fn moveCleanupAfterAcquisition(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    binding_span: std.zig.Token.Loc,
) !?[]const analysis.Edit {
    const tokens = try tokens_util.tokenize(allocator, source);
    defer allocator.free(tokens);
    var binding_index: ?usize = null;
    for (tokens, 0..) |token, index| if (std.meta.eql(token.loc, binding_span)) {
        binding_index = index;
        break;
    };
    const declaration_name_index = binding_index orelse return null;
    const binding_name = source[binding_span.start..binding_span.end];
    var allocation_end = declaration_name_index;
    while (allocation_end < tokens.len and tokens[allocation_end].tag != .semicolon) : (allocation_end += 1) {}
    if (allocation_end >= tokens.len) return null;
    var defer_index = allocation_end + 1;
    const defer_end = while (defer_index < tokens.len) {
        while (defer_index < tokens.len and tokens[defer_index].tag != .keyword_defer) : (defer_index += 1) {}
        if (defer_index >= tokens.len) return null;
        var candidate_end = defer_index;
        var contains_binding = false;
        var contains_release = false;
        while (candidate_end < tokens.len and tokens[candidate_end].tag != .semicolon) : (candidate_end += 1) {
            if (tokens[candidate_end].tag == .identifier and
                std.mem.eql(u8, source[tokens[candidate_end].loc.start..tokens[candidate_end].loc.end], binding_name))
            {
                contains_binding = true;
            }
            if (tokens[candidate_end].tag != .identifier) continue;
            if (analysis.resources.isReleaseMethod(source[tokens[candidate_end].loc.start..tokens[candidate_end].loc.end])) contains_release = true;
        }
        if (candidate_end >= tokens.len) return null;
        if (contains_binding and contains_release) break candidate_end;
        defer_index = candidate_end + 1;
    } else return null;

    const cleanup_line_start = if (std.mem.findScalarLast(u8, source[0..tokens[defer_index].loc.start], '\n')) |nl| nl + 1 else 0;
    const cleanup_prefix = source[cleanup_line_start..tokens[defer_index].loc.start];
    if (std.mem.trim(u8, cleanup_prefix, " \t\r").len != 0) return null;
    const cleanup_statement_end = tokens[defer_end].loc.end;
    const cleanup_line_end = if (std.mem.findScalar(u8, source[cleanup_statement_end..], '\n')) |relative|
        cleanup_statement_end + relative + 1
    else
        source.len;
    if (std.mem.trim(u8, source[cleanup_statement_end..cleanup_line_end], " \t\r\n").len != 0) return null;

    const cleanup_line = std.mem.trimEnd(u8, source[cleanup_line_start..cleanup_line_end], "\r\n");
    const edits = try allocator.alloc(analysis.Edit, 2);
    edits[0] = .{
        .span = .{ .start = tokens[allocation_end].loc.end, .end = tokens[allocation_end].loc.end },
        .replacement = try allocator.print("\n{s}", .{cleanup_line}),
    };
    edits[1] = .{
        .span = .{ .start = cleanup_line_start, .end = cleanup_line_end },
        .replacement = "",
    };
    return edits;
}

fn generateFunctionEdit(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name_span: std.zig.Token.Loc,
) !?analysis.Edit {
    if (try insideContainerAt(allocator, source, name_span.start)) return null;
    const tokens = try tokens_util.tokenize(allocator, source);
    defer allocator.free(tokens);
    const declaredTypeName = syntax_types.declaredTypeName;
    var opening = name_span.end;
    while (opening < source.len and std.ascii.isWhitespace(source[opening])) : (opening += 1) {}
    if (opening >= source.len or source[opening] != '(') return null;
    const closing = matchingByte(source, opening, '(', ')') orelse return null;
    const statement_start = (std.mem.findScalarLast(u8, source[0..name_span.start], ';') orelse
        std.mem.findScalarLast(u8, source[0..name_span.start], '{') orelse 0) + 1;
    const prefix = source[statement_start..name_span.start];
    const equal = std.mem.findScalarLast(u8, prefix, '=') orelse return null;
    const colon = std.mem.findScalarLast(u8, prefix[0..equal], ':') orelse return null;
    const return_type = std.mem.trim(u8, prefix[colon + 1 .. equal], " \t\r\n");
    if (return_type.len == 0) return null;
    const function_name = source[name_span.start..name_span.end];
    const arguments_source = source[opening + 1 .. closing];
    if (std.mem.findAny(u8, arguments_source, "([{") != null) return null;
    var parameter_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (parameter_names.items) |name| {
            if (@intFromPtr(name.ptr) < @intFromPtr(source.ptr) or @intFromPtr(name.ptr) >= @intFromPtr(source.ptr) + source.len) allocator.free(name);
        }
        parameter_names.deinit(allocator);
    }
    var parameter_types: std.ArrayList([]const u8) = .empty;
    defer parameter_types.deinit(allocator);
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_names.deinit(allocator);
    var arguments = std.mem.splitScalar(u8, arguments_source, ',');
    while (arguments.next()) |raw_argument| {
        const argument = std.mem.trim(u8, raw_argument, " \t\r\n");
        if (argument.len == 0) continue;
        const parameter_index = parameter_names.items.len + 1;
        const parameter_name = if (syntax_types.isIdentifier(argument) and !seen_names.contains(argument))
            argument
        else
            try allocator.print("arg{d}", .{parameter_index});
        try seen_names.put(allocator, parameter_name, {});
        try parameter_names.append(allocator, parameter_name);
        try parameter_types.append(
            allocator,
            if (syntax_types.isIdentifier(argument)) declaredTypeName(source, tokens, argument) orelse "anytype" else "anytype",
        );
    }
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("\nfn {s}(", .{function_name});
    for (parameter_names.items, parameter_types.items, 0..) |parameter_name, parameter_type, parameter_index| {
        if (parameter_index != 0) try writer.writer.writeAll(", ");
        try writer.writer.print("{s}: {s}", .{ parameter_name, parameter_type });
    }
    try writer.writer.print(") {s} {{\n", .{return_type});
    for (parameter_names.items) |parameter_name| {
        try writer.writer.print("    _ = {s};\n", .{parameter_name});
    }
    try writer.writer.writeAll("    @panic(\"TODO\");\n}\n");
    return .{
        .span = .{ .start = source.len, .end = source.len },
        .replacement = try writer.toOwnedSlice(),
    };
}

fn insideContainerAt(allocator: std.mem.Allocator, source: [:0]const u8, offset: usize) !bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(allocator);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof or token.loc.start >= offset) break;
        try tokens.append(allocator, token);
    }
    var brace_kinds: std.ArrayList(bool) = .empty;
    defer brace_kinds.deinit(allocator);
    var container_depth: usize = 0;
    for (tokens.items, 0..) |token, index| switch (token.tag) {
        .l_brace => {
            var cursor = index;
            var is_container = false;
            while (cursor > 0 and index - cursor < 8) {
                cursor -= 1;
                switch (tokens.items[cursor].tag) {
                    .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {
                        is_container = true;
                        break;
                    },
                    .semicolon, .l_brace, .r_brace => break,
                    else => {},
                }
            }
            try brace_kinds.append(allocator, is_container);
            container_depth += @intFromBool(is_container);
        },
        .r_brace => if (brace_kinds.pop()) |was_container| {
            container_depth -= @intFromBool(was_container);
        },
        else => {},
    };
    return container_depth != 0;
}

fn matchingByte(source: []const u8, opening: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    for (source[opening..], opening..) |character, offset| {
        if (character == open) depth += 1;
        if (character != close) continue;
        depth -= 1;
        if (depth == 0) return offset;
    }
    return null;
}

const Extraction = struct {
    name: []const u8,
    declaration: analysis.Edit,
    replacement: analysis.Edit,
};

fn extractExpressionEdits(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    selection: std.zig.Token.Loc,
) !?Extraction {
    if (selection.start == selection.end) return null;
    var exact_node = false;
    for (1..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        if (selection.start == start and selection.end == end) {
            exact_node = true;
            break;
        }
    }
    if (!exact_node) return null;
    const line_start = if (std.mem.findScalarLast(u8, source[0..selection.start], '\n')) |nl| nl + 1 else 0;
    var indentation_end = line_start;
    while (indentation_end < source.len and
        (source[indentation_end] == ' ' or source[indentation_end] == '\t')) : (indentation_end += 1)
    {}
    const indentation = source[line_start..indentation_end];
    var suffix: usize = 1;
    var name: []const u8 = "value";
    while (identifierOccurs(source, name)) : (suffix += 1) {
        name = try allocator.print("value{d}", .{suffix + 1});
    }
    return .{
        .name = name,
        .declaration = .{
            .span = .{ .start = line_start, .end = line_start },
            .replacement = try allocator.print(
                "{s}const {s} = {s};\n",
                .{ indentation, name, source[selection.start..selection.end] },
            ),
        },
        .replacement = .{ .span = selection, .replacement = name },
    };
}

fn identifierOccurs(source: [:0]const u8, name: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return false;
        if (token.tag == .identifier and std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) return true;
    }
}

/// The first call `.method(` in `text` that allocates, with the offset of its
/// `.` and the name of the release that frees its result.
fn allocationCall(text: []const u8) ?struct { usize, []const u8 } {
    var search_from: usize = 0;
    while (std.mem.findScalarPos(u8, text, search_from, '.')) |period| {
        search_from = period + 1;
        var end = period + 1;
        while (end < text.len and syntax_types.isIdentifierByte(text[end])) end += 1;
        if (end == period + 1 or end >= text.len or text[end] != '(') continue;
        if (analysis.resources.uniqueAllocationRelease(text[period + 1 .. end])) |release| return .{ period, release };
    }
    return null;
}

test "late allocation cleanup action moves the existing defer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: anytype) !void {\n" ++
        "    const buffer = try allocator.alloc(u8, 16);\n" ++
        "    try initialize(buffer);\n" ++
        "    defer finishOtherWork(buffer);\n" ++
        "    defer allocator.free(buffer);\n" ++
        "}\n";
    const binding_start = std.mem.find(u8, source, "buffer =") orelse unreachable;
    const edits = (try moveCleanupAfterAcquisition(arena_state.allocator(), source, .{
        .start = binding_start,
        .end = binding_start + "buffer".len,
    })).?;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expect(std.mem.find(u8, edits[0].replacement, "defer allocator.free(buffer);") != null);
    try std.testing.expectEqualStrings("", edits[1].replacement);
    try std.testing.expect(std.mem.find(u8, source[edits[1].span.start..edits[1].span.end], "finishOtherWork") == null);
}

test "late resource cleanup action moves close after acquisition" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: [:0]const u8 =
        "fn run(dir: std.fs.Dir) !void {\n" ++
        "    var file = try dir.openFile(\"input\", .{});\n" ++
        "    try validate();\n" ++
        "    defer file.close();\n" ++
        "}\n";
    const binding_start = std.mem.find(u8, source, "file =") orelse unreachable;
    const edits = (try moveCleanupAfterAcquisition(arena_state.allocator(), source, .{
        .start = binding_start,
        .end = binding_start + "file".len,
    })).?;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expect(std.mem.find(u8, edits[0].replacement, "defer file.close();") != null);
    try std.testing.expectEqualStrings("", edits[1].replacement);
}
