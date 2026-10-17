//! `format` methods with the pre-0.15 `(self, comptime fmt, options, writer)`
//! signature, which `std.fmt` no longer calls.
const std = @import("std");
const Ast = std.zig.Ast;
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .legacy_format_method,
};

/// The parameters a legacy `format` method has beyond `self` and the writer.
pub const LegacyFormat = struct {
    /// The `format` name token.
    name: Ast.TokenIndex,
    /// First token of the `comptime fmt: []const u8` parameter.
    first: Ast.TokenIndex,
    /// Last token of the options parameter's type.
    last: Ast.TokenIndex,
};

/// Whether `prototype` is `format(self, comptime fmt: []const u8, options:
/// std.fmt.FormatOptions, writer: anytype)`, the method Zig 0.15 replaced with
/// `format(self, writer: *std.Io.Writer) std.Io.Writer.Error!void`. The options
/// type may also be spelled `fmt.FormatOptions` or `std.fmt.Options`.
pub fn legacyFormat(tree: *const Ast, prototype: Ast.full.FnProto) ?LegacyFormat {
    const name = prototype.name_token orelse return null;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "format")) return null;
    var parameters: [4]Ast.full.FnProto.Param = undefined;
    var count: usize = 0;
    var iterator = prototype.iterate(tree);
    while (iterator.next()) |parameter| : (count += 1) {
        if (count == parameters.len) return null;
        parameters[count] = parameter;
    }
    if (count != parameters.len) return null;
    const specifier = parameters[1];
    const comptime_token = specifier.comptime_noalias orelse return null;
    if (tree.tokenTag(comptime_token) != .keyword_comptime) return null;
    const specifier_type = specifier.type_expr orelse return null;
    if (!spells(tree, specifier_type, &.{ .l_bracket, .r_bracket, .keyword_const, .identifier }) or
        !std.mem.eql(u8, tree.tokenSlice(tree.lastToken(specifier_type)), "u8")) return null;
    const options_type = parameters[2].type_expr orelse return null;
    const last = tree.lastToken(options_type);
    const first = tree.firstToken(options_type);
    if (tree.tokenTag(last) != .identifier) return null;
    const type_name = tree.tokenSlice(last);
    const options = std.mem.eql(u8, type_name, "FormatOptions") or
        (std.mem.eql(u8, type_name, "Options") and last >= first + 2 and std.mem.eql(u8, tree.tokenSlice(last - 2), "fmt"));
    if (!options) return null;
    var cursor = first;
    while (cursor < last) : (cursor += 2) {
        if (tree.tokenTag(cursor) != .identifier or tree.tokenTag(cursor + 1) != .period) return null;
    }
    return .{ .name = name, .first = comptime_token, .last = last };
}

/// Whether the tokens of `node` have exactly the tags `expected`.
fn spells(tree: *const Ast, node: Ast.Node.Index, expected: []const std.zig.Token.Tag) bool {
    const first = tree.firstToken(node);
    if (tree.lastToken(node) - first + 1 != expected.len) return false;
    for (expected, first..) |tag, token| if (tree.tokenTag(@intCast(token)) != tag) return false;
    return true;
}

pub fn run(context: RuleRun) !void {
    const level = context.level(.legacy_format_method);
    if (level == .off) return;
    const tree = context.tree;
    var called_directly: ?bool = null;
    for (0..tree.nodes.len) |raw_node| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const prototype = tree.fullFnProto(&buffer, node) orelse continue;
        const legacy = legacyFormat(tree, prototype) orelse continue;
        // A file that calls `value.format(fmt, options, writer)` itself uses
        // the method as an ordinary function rather than through std.fmt.
        if (called_directly == null) called_directly = callsFormatDirectly(context);
        if (called_directly.?) return;
        const related = try context.allocator.alloc(types.RelatedSpan, 1);
        related[0] = .{
            .span = .{ .start = context.tokens[legacy.first].loc.start, .end = context.tokens[legacy.last].loc.end },
            .message = "remove the format string and options parameters; callers then format the value with {f} instead of {} or {any}",
        };
        try context.emit(.{
            .rule = .legacy_format_method,
            .level = level,
            .span = context.tokens[legacy.name].loc,
            .message = "this format method has the pre-0.15 signature, which std.fmt no longer calls; declare format(self, writer: *std.Io.Writer) std.Io.Writer.Error!void and format the value with {f}",
            .related = related,
        });
    }
}

/// Whether the file has a `value.format(a, b, c)` call: three arguments, the
/// legacy method's own parameters after `self`.
fn callsFormatDirectly(context: RuleRun) bool {
    const tokens = context.tokens;
    for (tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or tokens[index - 1].tag != .period or
            index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren or !context.tokenIs(index, "format")) continue;
        // `std.fmt.format(writer, format, args)` is the old print function.
        if (context.tokenIs(index - 2, "fmt")) continue;
        const closing = context.scopes.matchingToken(index + 1) orelse continue;
        var commas: usize = 0;
        var cursor = index + 2;
        while (cursor < closing) : (cursor += 1) switch (tokens[cursor].tag) {
            .l_paren, .l_bracket, .l_brace => cursor = context.scopes.matchingToken(cursor) orelse closing,
            .comma => if (cursor + 1 < closing) {
                commas += 1;
            },
            else => {},
        };
        if (commas == 2) return true;
    }
    return false;
}

test "legacy format methods report their old signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn format(self: Point, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        \\        _ = fmt;
        \\        _ = options;
        \\        try writer.print("{d}", .{self.x});
        \\    }
        \\};
        \\const Feature = struct {
        \\    pub fn format(
        \\        self: Feature,
        \\        comptime _: []const u8,
        \\        _: std.fmt.Options,
        \\        writer: *std.Io.Writer,
        \\    ) !void {
        \\        _ = self;
        \\        _ = writer;
        \\    }
        \\};
    ;
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| {
        try std.testing.expectEqualStrings("format", source[finding.span.start..finding.span.end]);
        try std.testing.expectEqual(@as(usize, 1), finding.related.len);
    }
    const related = findings[0].related[0].span;
    try std.testing.expectEqualStrings("comptime fmt: []const u8, options: std.fmt.FormatOptions", source[related.start..related.end]);
}

test "current format methods and other four-parameter functions are not reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Point = struct {
        \\    x: i32,
        \\    pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        \\        try writer.print("{d}", .{self.x});
        \\    }
        \\};
        \\const Template = struct {
        \\    pub fn format(self: Template, comptime fmt: []const u8, args: anytype, writer: anytype) !void {
        \\        _ = .{ self, fmt, args, writer };
        \\    }
        \\    pub fn render(self: Template, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        \\        _ = .{ self, fmt, options, writer };
        \\    }
        \\};
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), source)).len);
    const called: [:0]const u8 =
        \\const std = @import("std");
        \\const Feature = struct {
        \\    pub fn format(self: Feature, comptime layout: []const u8, opts: std.fmt.FormatOptions, writer: *std.Io.Writer) !void {
        \\        _ = .{ self, layout, opts, writer };
        \\    }
        \\    fn render(self: Feature, writer: *std.Io.Writer) !void {
        \\        try self.format("", .{}, writer);
        \\    }
        \\};
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), called)).len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return support.findings(allocator, run, source, support.only(&.{.legacy_format_method}, .warning));
}
