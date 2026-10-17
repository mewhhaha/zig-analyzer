//! Parameter ordering conventions: allocators first, comptime parameters before runtime ones.
const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const topLevelComma = @import("../../syntax/tokens.zig").topLevelComma;
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const Range = @import("../../syntax/tokens.zig").Range;

pub const rules = [_]types.Rule{ .allocator_first_parameter, .comptime_parameter_order };

pub fn run(context: RuleRun) !void {
    const allocator_level = context.level(.allocator_first_parameter);
    const comptime_level = context.level(.comptime_parameter_order);
    if (allocator_level == .off and comptime_level == .off) return;
    for (context.tokens, 0..) |_, fn_index| {
        if (!context.isNamedFunction(fn_index) or externallyConstrained(context, fn_index)) continue;
        const opening = nextTagBefore(context.tokens, fn_index + 1, .l_paren, .semicolon) orelse continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (nextTagBefore(context.tokens, closing + 1, .l_brace, .semicolon) == null) continue;
        var parameter_start = opening + 1;
        var position: usize = 0;
        // A runtime parameter other than the receiver came before.
        var saw_runtime = false;
        // Earlier runtime parameter names, which a later parameter's type may
        // name, and the token ranges of their types.
        var runtime_names: [16][]const u8 = undefined;
        var runtime_count: usize = 0;
        var runtime_types: [16]Range = undefined;
        var runtime_type_count: usize = 0;
        while (parameter_start < closing) {
            const comma = topLevelComma(context.tokens, parameter_start, closing) orelse closing;
            if (parameter_start < comma) {
                const is_receiver = position == 0 and isReceiver(context, fn_index, parameter_start, comma);
                const explicit_comptime = context.tokens[parameter_start].tag == .keyword_comptime;
                // `T: type` is comptime without the keyword.
                const is_comptime = explicit_comptime or
                    (parameter_start + 3 == comma and context.tokens[parameter_start + 1].tag == .colon and
                        context.tokenIs(parameter_start + 2, "type"));
                // The allocator leads the runtime parameters; the receiver and
                // comptime configuration may precede it.
                const allocator_type = findAllocatorType(context, parameter_start, comma);
                if (allocator_type != null and saw_runtime and allocator_level != .off) try context.emit(.{
                    .rule = .allocator_first_parameter,
                    .level = allocator_level,
                    .span = context.tokens[allocator_type.?].loc,
                    .message = "std.mem.Allocator should be the first parameter after an optional self parameter",
                });
                // `comptime f: fn (@TypeOf(context)) T` cannot move before
                // `context`; a format string or function stays with the
                // arguments that follow it, and a callback with the context
                // whose type it takes.
                if (explicit_comptime and saw_runtime and comptime_level != .off and
                    !namesAny(context, parameter_start + 1, comma, runtime_names[0..runtime_count]) and
                    !pairedWithArguments(context, parameter_start, comma, closing) and
                    !callbackOfEarlierType(context, parameter_start, comma, runtime_types[0..runtime_type_count])) try context.emit(.{
                    .rule = .comptime_parameter_order,
                    .level = comptime_level,
                    .span = context.tokens[parameter_start].loc,
                    .message = "comptime parameters configure the function and should precede runtime parameters",
                });
                if (!is_comptime and !is_receiver) {
                    saw_runtime = true;
                    if (runtime_count < runtime_names.len and context.tokens[parameter_start].tag == .identifier) {
                        runtime_names[runtime_count] = context.tokenText(parameter_start);
                        runtime_count += 1;
                    }
                }
                if (!is_comptime and runtime_type_count < runtime_types.len and parameter_start + 2 < comma and
                    context.tokens[parameter_start + 1].tag == .colon)
                {
                    runtime_types[runtime_type_count] = .{ .start = parameter_start + 2, .end = comma };
                    runtime_type_count += 1;
                }
                position += 1;
            }
            if (comma == closing) break;
            parameter_start = comma + 1;
        }
    }
}

/// Whether the first parameter, spanning `[start, end)`, is the receiver that
/// method-call syntax or a type-erased callback fixes in first place: `self`,
/// or typed (through `*`/`*const`) as `Self`, `@This()`, the enclosing
/// container, or `anyopaque`.
fn isReceiver(context: RuleRun, fn_index: usize, start: usize, end: usize) bool {
    if (context.tokens[start].tag != .identifier) return false;
    if (context.tokenIs(start, "self")) return true;
    if (start + 2 >= end or context.tokens[start + 1].tag != .colon) return false;
    var type_start = start + 2;
    if (context.tokens[type_start].tag == .asterisk) type_start += 1;
    if (type_start < end and context.tokens[type_start].tag == .keyword_const) type_start += 1;
    if (type_start + 3 == end and context.tokens[type_start].tag == .builtin and context.tokenIs(type_start, "@This")) return true;
    if (type_start + 1 != end or context.tokens[type_start].tag != .identifier) return false;
    if (context.tokenIs(type_start, "Self") or context.tokenIs(type_start, "anyopaque")) return true;
    if (enclosingContainerName(context, fn_index)) |container| if (context.tokenIs(type_start, container)) return true;
    // `const Reader = @This();` names the container, often a whole file.
    const alias = context.scopes.findBinding(type_start) orelse return false;
    const declaration = alias.token_index;
    return declaration + 2 < context.tokens.len and context.tokens[declaration + 1].tag == .equal and
        context.tokenIs(declaration + 2, "@This") and
        context.scopes.enclosingOpeningBrace(declaration) == context.scopes.enclosingOpeningBrace(fn_index);
}

/// The name `N` of `const N = struct { ... }` (or union, enum, opaque)
/// directly enclosing the declaration at `index`.
fn enclosingContainerName(context: RuleRun, index: usize) ?[]const u8 {
    const brace = context.scopes.enclosingOpeningBrace(index) orelse return null;
    if (brace == 0) return null;
    var keyword = brace - 1;
    if (context.tokens[keyword].tag == .r_paren) keyword = (context.scopes.matchingToken(keyword) orelse return null) -| 1;
    switch (context.tokens[keyword].tag) {
        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => {},
        else => return null,
    }
    if (keyword > 0 and (context.tokens[keyword - 1].tag == .keyword_packed or context.tokens[keyword - 1].tag == .keyword_extern)) keyword -= 1;
    if (keyword < 2 or context.tokens[keyword - 1].tag != .equal or context.tokens[keyword - 2].tag != .identifier) return null;
    return context.tokenText(keyword - 2);
}

/// Whether a type in `[start, end)` refers to one of `names`; a parameter name
/// inside a function type, `fn (context: Context) void`, does not.
fn namesAny(context: RuleRun, start: usize, end: usize, names: []const []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or context.tokens[index + 1].tag == .colon) continue;
        for (names) |name| if (context.tokenIs(index, name)) return true;
    }
    return false;
}

/// Whether the comptime parameter spanning `[start, end)` is a format string
/// or a function directly followed by the runtime `anytype` arguments it
/// takes, as in `print(w, comptime fmt, args)` and `spawn(config, comptime f, args)`.
fn pairedWithArguments(context: RuleRun, start: usize, end: usize, closing: usize) bool {
    if (end >= closing or start + 3 >= end or context.tokens[start + 2].tag != .colon) return false;
    const type_text = context.source[context.tokens[start + 3].loc.start..context.tokens[end - 1].loc.end];
    if (!std.mem.eql(u8, type_text, "[]const u8") and !std.mem.eql(u8, type_text, "[:0]const u8") and
        !std.mem.eql(u8, type_text, "anytype") and !functionType(context, start + 3, end)) return false;
    var next = end + 1;
    while (next < closing and context.tokens[next].tag == .doc_comment) next += 1;
    const next_end = topLevelComma(context.tokens, next, closing) orelse closing;
    return next + 3 == next_end and context.tokens[next].tag == .identifier and
        context.tokens[next + 1].tag == .colon and context.tokens[next + 2].tag == .keyword_anytype;
}

/// Whether the comptime parameter spanning `[start, end)` is a callback whose
/// type takes the type of an earlier runtime parameter, the context it is
/// called with: `context: Context, comptime callback: fn (Context) void`.
fn callbackOfEarlierType(context: RuleRun, start: usize, end: usize, earlier_types: []const Range) bool {
    if (start + 3 >= end or context.tokens[start + 2].tag != .colon or !functionType(context, start + 3, end)) return false;
    for (start + 3..end) |index| {
        if (!namesType(context, index)) continue;
        for (earlier_types) |earlier| for (earlier.start..earlier.end) |earlier_index| {
            if (namesType(context, earlier_index) and context.tokenIs(earlier_index, context.tokenText(index))) return true;
        };
    }
    return false;
}

/// Whether the identifier at `index` names a type rather than a parameter,
/// a namespace qualifying one (`c` in `c.Options`) or a primitive.
fn namesType(context: RuleRun, index: usize) bool {
    if (context.tokens[index].tag != .identifier) return false;
    return switch (context.tokens[index + 1].tag) {
        .colon, .period => false,
        else => !std.zig.isPrimitive(context.tokenText(index)),
    };
}

/// `fn (...) T`, `*const fn (...) T` or an optional of either.
fn functionType(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end]) |token| switch (token.tag) {
        .question_mark, .asterisk, .keyword_const => {},
        .keyword_fn => return true,
        else => return false,
    };
    return false;
}

fn externallyConstrained(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 5) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_extern or context.tokens[cursor].tag == .keyword_export) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) break;
    }
    return false;
}

fn findAllocatorType(context: RuleRun, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "Allocator") and index >= start + 4 and
            context.tokenIs(index - 4, "std") and context.tokenIs(index - 2, "mem")) return index;
    }
    return null;
}

test "misplaced allocator and comptime parameters report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 = "fn configure(value: u8, comptime T: type, other: u8, allocator: std.mem.Allocator) void { _ = T; _ = value; _ = other; _ = allocator; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .allocator_first_parameter, .comptime_parameter_order }, .information));
    try support.expectRules(found, &.{ .comptime_parameter_order, .allocator_first_parameter });
}

test "receivers and parameters a later type depends on keep their place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn converted(len: usize, context: anytype, comptime convert: fn (@TypeOf(context), usize) u32) u32 { return convert(context, len); }\n" ++
        "const Visitor = struct {\n" ++
        "    fn append(visitor: *@This(), _: std.mem.Allocator, child: u32) void { _ = visitor; _ = child; }\n" ++
        "    fn appendTwo(visitor: *const Visitor, gpa: std.mem.Allocator, child: u32) void { _ = visitor; _ = gpa; _ = child; }\n" ++
        "};\n" ++
        "fn origin(_: *anyopaque, allocator: std.mem.Allocator, id: u32) u32 { _ = allocator; return id; }\n" ++
        "fn late(value: u32, comptime mode: bool) u32 { return if (mode) value else 0; }\n" ++
        "fn send(comptime Context: type, context: Context, comptime callback: fn (context: Context) void) void { callback(context); }\n" ++
        "const Reader = @This();\n" ++
        "fn take(r: *Reader, comptime T: type, gpa: std.mem.Allocator) T { _ = r; _ = gpa; return undefined; }\n" ++
        "fn specConst(T: type, comptime default_value: T, gpa: std.mem.Allocator) T { _ = gpa; return default_value; }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{ .allocator_first_parameter, .comptime_parameter_order }, .information));
    try support.expectRules(found, &.{.comptime_parameter_order});
    try std.testing.expectEqual(std.mem.find(u8, source, "comptime mode").?, found[0].span.start);
}

test "format strings and callbacks stay with the arguments and context they take" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn print(w: *Writer, comptime fmt: []const u8, args: anytype) void { w.print(fmt, args); }\n" ++
        "fn spawn(config: Config, comptime f: anytype, args: anytype) void { _ = config; @call(.auto, f, args); }\n" ++
        "fn tick(io: *IO, context: Context, comptime callback: fn (context: Context, io: *IO) void) void { callback(context, io); }\n" ++
        "fn write(w: *Writer, comptime text: []const u8) void { w.writeAll(text); }\n" ++
        "fn apply(value: u32, comptime f: fn (u32) u32) u32 { return f(value); }\n" ++
        "fn cross(backend: c.Backend, comptime options: fn (c.Options) void) void { options(backend); }\n" ++
        "fn tagged(w: *Writer, comptime fmt: []const u8, value: u32) void { w.print(fmt, .{value}); }\n";
    const found = try support.findings(arena.allocator(), run, source, support.only(&.{.comptime_parameter_order}, .information));
    try support.expectRules(found, &.{ .comptime_parameter_order, .comptime_parameter_order, .comptime_parameter_order, .comptime_parameter_order });
    try std.testing.expectEqual(std.mem.find(u8, source, "comptime text").?, found[0].span.start);
    try std.testing.expectEqual(std.mem.find(u8, source, "comptime f: fn").?, found[1].span.start);
    try std.testing.expectEqual(std.mem.find(u8, source, "comptime options").?, found[2].span.start);
    try std.testing.expectEqual(std.mem.findLast(u8, source, "comptime fmt").?, found[3].span.start);
}
