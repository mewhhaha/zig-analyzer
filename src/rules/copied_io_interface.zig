const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");

pub fn run(context: RuleRun) !void {
    const level = context.level(.copied_io_interface);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or
            (context.tokens[declaration_index + 2].tag != .colon and
                context.tokens[declaration_index + 2].tag != .equal)) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const equal_index = findTag(context.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
        const copied_field = copiedInterfaceField(context, equal_index + 1, declaration_end) orelse continue;
        if (!fieldHasIoOwner(context, copied_field, declaration_index)) continue;

        try context.emit(.{
            .rule = .copied_io_interface,
            .level = level,
            .span = context.tokens[copied_field].loc,
            .message = try std.fmt.allocPrint(
                context.allocator,
                "copying the '{s}' interface detaches it from implementation state used by its callbacks; keep the implementation value and pass a pointer to its interface",
                .{context.tokenText(copied_field)},
            ),
        });
    }
}

fn copiedInterfaceField(context: RuleRun, start: usize, end: usize) ?usize {
    var index = end;
    while (index > start) {
        index -= 1;
        if (context.tokens[index].tag != .identifier or
            (!context.tokenIs(index, "interface") and !context.tokenIs(index, "writer")) or
            index == 0 or context.tokens[index - 1].tag != .period) continue;
        if (index + 1 != end) return null;
        if (expressionTakesAddress(context, start, index)) return null;
        return index;
    }
    return null;
}

fn expressionTakesAddress(context: RuleRun, start: usize, field_index: usize) bool {
    _ = start;
    return field_index >= 3 and context.tokens[field_index - 2].tag == .identifier and
        context.tokens[field_index - 3].tag == .ampersand;
}

fn fieldHasIoOwner(context: RuleRun, field_index: usize, before: usize) bool {
    if (context.tokenIs(field_index, "writer")) {
        if (field_index < 2 or context.tokens[field_index - 2].tag != .identifier) return false;
        return bindingIsWriterImplementation(context, context.tokenText(field_index - 2), before);
    }

    if (field_index < 2) return false;
    if (context.tokens[field_index - 2].tag == .r_paren) {
        const call = callBeforeClosingParenthesis(context, field_index - 2) orelse return false;
        if (!context.tokenIs(call.method_index, "reader") and !context.tokenIs(call.method_index, "writer")) return false;
        return callHasStdProvenance(context, call.method_index, before);
    }
    if (context.tokens[field_index - 2].tag != .identifier) return false;
    return bindingIsIoImplementation(context, context.tokenText(field_index - 2), before);
}

const Call = struct {
    method_index: usize,
};

fn callBeforeClosingParenthesis(context: RuleRun, closing_index: usize) ?Call {
    var depth: usize = 0;
    var cursor = closing_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth > 0) {
                    depth -= 1;
                    continue;
                }
                if (cursor < 2 or context.tokens[cursor - 1].tag != .identifier or
                    context.tokens[cursor - 2].tag != .period) return null;
                return .{ .method_index = cursor - 1 };
            },
            else => {},
        }
    }
    return null;
}

fn callHasStdProvenance(context: RuleRun, method_index: usize, before: usize) bool {
    if (statementContains(context, before, method_index, "std")) return true;
    if (method_index >= 2 and context.tokens[method_index - 2].tag == .identifier) {
        const receiver = context.tokenText(method_index - 2);
        if (bindingIsFile(context, receiver, before)) return true;
    }
    return false;
}

fn bindingIsIoImplementation(context: RuleRun, binding: []const u8, before: usize) bool {
    const declaration = bindingDeclaration(context, binding, before) orelse return false;
    const source = statementSource(context, declaration.start, declaration.end);
    if (containsAny(source, &.{
        "std.Io.File.Reader",
        "std.Io.File.Writer",
        "std.fs.File.Reader",
        "std.fs.File.Writer",
        "std.Io.Writer.Allocating",
    })) return true;
    if (std.mem.indexOf(u8, source, ".reader(") == null and
        std.mem.indexOf(u8, source, ".writer(") == null) return false;
    if (std.mem.indexOf(u8, source, "std.") != null) return true;

    const method_index = findMethod(context, declaration.start, declaration.end, &.{ "reader", "writer" }) orelse return false;
    if (method_index < 2 or context.tokens[method_index - 2].tag != .identifier) return false;
    return bindingIsFile(context, context.tokenText(method_index - 2), declaration.start);
}

fn bindingIsWriterImplementation(context: RuleRun, binding: []const u8, before: usize) bool {
    const declaration = bindingDeclaration(context, binding, before) orelse return false;
    const source = statementSource(context, declaration.start, declaration.end);
    return std.mem.indexOf(u8, source, "std.Io.Writer.") != null and
        std.mem.indexOf(u8, source, "std.Io.Writer =") == null;
}

fn bindingIsFile(context: RuleRun, binding: []const u8, before: usize) bool {
    const declaration = bindingDeclaration(context, binding, before) orelse return false;
    const source = statementSource(context, declaration.start, declaration.end);
    return containsAny(source, &.{ "std.Io.File", "std.fs.File", "std.Io.Dir", "std.fs.cwd()" }) and
        (std.mem.indexOf(u8, source, "openFile(") != null or
            std.mem.indexOf(u8, source, "createFile(") != null or
            std.mem.indexOf(u8, source, ": std.Io.File") != null or
            std.mem.indexOf(u8, source, ": std.fs.File") != null);
}

const Declaration = struct {
    start: usize,
    end: usize,
};

fn bindingDeclaration(context: RuleRun, binding: []const u8, before: usize) ?Declaration {
    if (parameterShadowsBinding(context, binding, before)) return null;
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, binding) or
            (context.tokens[index - 1].tag != .keyword_const and context.tokens[index - 1].tag != .keyword_var)) continue;
        const end = context.statementEnd(index - 1) orelse continue;
        if (end >= before) continue;
        if (context.enclosingOpeningBrace(index)) |opening| {
            const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
            if (before >= closing) continue;
        }
        return .{ .start = index - 1, .end = end };
    }
    return null;
}

fn parameterShadowsBinding(context: RuleRun, binding: []const u8, use_index: usize) bool {
    for (context.tokens[0..use_index], 0..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= use_index or
            context.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = context.matchingToken(function_index + 2, .l_paren, .r_paren) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < use_index and context.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= use_index) continue;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse continue;
        if (use_index >= body_end) continue;
        for (context.tokens[function_index + 3 .. parameters_end], function_index + 3..) |parameter, index| {
            if (parameter.tag == .identifier and context.tokenIs(index, binding) and index + 1 < parameters_end and
                context.tokens[index + 1].tag == .colon) return true;
        }
    }
    return false;
}

fn findMethod(context: RuleRun, start: usize, end: usize, methods: []const []const u8) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index == 0 or context.tokens[index - 1].tag != .period) continue;
        for (methods) |method| if (context.tokenIs(index, method)) return index;
    }
    return null;
}

fn findTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn statementContains(context: RuleRun, start: usize, end: usize, expected: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, expected)) return true;
    }
    return false;
}

fn statementSource(context: RuleRun, start: usize, end: usize) []const u8 {
    return context.source[context.tokens[start].loc.start..context.tokens[end].loc.end];
}

fn containsAny(source: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, source, needle) != null) return true;
    return false;
}

test "copied file interfaces report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn useFile(io: std.Io, path: []const u8) !void {\n" ++
        "    const file = try std.Io.Dir.cwd().openFile(io, path, .{});\n" ++
        "    var buffer: [1024]u8 = undefined;\n" ++
        "    var file_reader = file.reader(io, &buffer);\n" ++
        "    const reader = file_reader.interface;\n" ++
        "    const direct = file.reader(io, &buffer).interface;\n" ++
        "    const stderr = std.Io.File.stderr().writer(io, &buffer).interface;\n" ++
        "    _ = reader;\n" ++
        "    _ = direct;\n" ++
        "    _ = stderr;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
}

test "copied allocating writer interface reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: std.mem.Allocator) void {\n" ++
        "    var allocating = std.Io.Writer.Allocating.init(allocator);\n" ++
        "    var writer = allocating.writer;\n" ++
        "    _ = &writer;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
}

test "interface pointers and explicit state transfers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn useFile(file: std.Io.File, io: std.Io) void {\n" ++
        "    var buffer: [1024]u8 = undefined;\n" ++
        "    var file_reader: std.Io.File.Reader = .initStreaming(file, io, &buffer);\n" ++
        "    const reader = &file_reader.interface;\n" ++
        "    file_reader.interface = io.reader;\n" ++
        "    defer io.reader = file_reader.interface;\n" ++
        "    try file_reader.interface.readSliceAll(&buffer);\n" ++
        "    const buffered: []const u8 = file_reader.interface.buffered();\n" ++
        "    _ = reader;\n" ++
        "    _ = buffered;\n" ++
        "}\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "I/O implementations do not lend provenance across functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn standard(file: std.Io.File, io: std.Io, buffer: []u8) void { " ++
        "var implementation: std.Io.File.Reader = file.reader(io, buffer); _ = implementation; } " ++
        "fn custom(implementation: *Custom) void { const reader = implementation.interface; _ = reader; }";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "parameters shadow global I/O implementations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "var implementation: std.Io.File.Reader = undefined; " ++
        "fn custom(implementation: *Custom) void { const reader = implementation.interface; _ = reader; }";
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
