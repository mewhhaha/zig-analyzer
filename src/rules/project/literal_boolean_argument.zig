//! Literal `true` or `false` arguments to project functions whose boolean parameter the name does not describe.
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const File = run_module.File;
const types = @import("../types.zig");
const project = @import("../project.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const matchingToken = tokens_util.matchingToken;
const topLevelComma = tokens_util.topLevelComma;
const findTag = tokens_util.findTag;
const foreignDeclaration = tokens_util.foreignDeclaration;
const PathRange = tokens_util.Range;

pub const rules = [_]types.Rule{.literal_boolean_argument};

const BooleanParameter = struct {
    name: []const u8,
    index: usize,
};

const BooleanFunction = struct {
    parameter_count: usize,
    boolean_parameters: []const BooleanParameter,
};

pub fn find(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.literal_boolean_argument) == .off) return;
    var declaration_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer declaration_counts.deinit(run.allocator);
    var boolean_functions: std.StringHashMapUnmanaged(BooleanFunction) = .empty;
    defer {
        var it = boolean_functions.valueIterator();
        while (it.next()) |fn_val| run.allocator.free(fn_val.boolean_parameters);
        boolean_functions.deinit(run.allocator);
    }
    for (run.files) |file| {
        if (file.generated) continue;
        for (file.tokens, 0..) |token, fn_index| {
            if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or
                file.tokens[fn_index + 1].tag != .identifier or file.tokens[fn_index + 2].tag != .l_paren) continue;
            const function_name = tokenText(file.source, file.tokens[fn_index + 1]);
            const declaration_count = try declaration_counts.getOrPut(run.allocator, function_name);
            if (!declaration_count.found_existing) declaration_count.value_ptr.* = 0;
            declaration_count.value_ptr.* += 1;
            if (foreignDeclaration(file.tokens, fn_index)) continue;
            const parameters_end = matchingToken(file.tokens, fn_index + 2, .l_paren, .r_paren) orelse continue;
            const parameter_count = functionParameterCount(file.tokens, fn_index + 2, parameters_end);
            if (parameter_count < 2) continue;
            var boolean_parameters: std.ArrayList(BooleanParameter) = .empty;
            errdefer boolean_parameters.deinit(run.allocator);
            var parameter_start = fn_index + 3;
            var parameter_index: usize = 0;
            while (parameter_start < parameters_end) : (parameter_index += 1) {
                const comma = topLevelComma(file.tokens, parameter_start, parameters_end) orelse parameters_end;
                if (booleanParameterName(file, parameter_start, comma)) |parameter_name| {
                    if (!functionDescribesBoolean(function_name, parameter_name)) {
                        try boolean_parameters.append(run.allocator, .{ .name = parameter_name, .index = parameter_index });
                    }
                }
                if (comma == parameters_end) break;
                parameter_start = comma + 1;
            }
            if (boolean_parameters.items.len == 0) {
                boolean_parameters.deinit(run.allocator);
            } else {
                const entry = try boolean_functions.getOrPut(run.allocator, function_name);
                if (!entry.found_existing) {
                    const owned_parameters = try boolean_parameters.toOwnedSlice(run.allocator);
                    entry.value_ptr.* = .{
                        .parameter_count = parameter_count,
                        .boolean_parameters = owned_parameters,
                    };
                } else {
                    boolean_parameters.deinit(run.allocator);
                }
            }
        }
    }

    for (run.files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, call_index| {
            if (token.tag != .identifier or call_index + 1 >= file.tokens.len or
                file.tokens[call_index + 1].tag != .l_paren or
                (call_index > 0 and file.tokens[call_index - 1].tag == .keyword_fn)) continue;
            const function_name = tokenText(file.source, token);
            const function = boolean_functions.get(function_name) orelse continue;
            if (declaration_counts.get(function_name).? != 1) continue;
            const call_end = matchingToken(file.tokens, call_index + 1, .l_paren, .r_paren) orelse continue;
            const argument_count = callArgumentCount(file.tokens, call_index + 1, call_end);
            const member_call = call_index > 0 and file.tokens[call_index - 1].tag == .period;
            const parameter_offset: usize = if (member_call and argument_count + 1 == function.parameter_count)
                1
            else if (argument_count == function.parameter_count)
                0
            else
                continue;
            for (function.boolean_parameters) |parameter| {
                if (parameter.index < parameter_offset) continue;
                const argument_index = parameter.index - parameter_offset;
                const argument = callArgument(file.tokens, call_index + 1, call_end, argument_index) orelse continue;
                if (argument.end != argument.start + 1 or
                    (!tokenIs(file.source, file.tokens[argument.start], "true") and
                        !tokenIs(file.source, file.tokens[argument.start], "false"))) continue;
                try run.report(.{
                    .file_index = file_index,
                    .rule = .literal_boolean_argument,
                    .span = file.tokens[argument.start].loc,
                    .message = try run.allocator.print(
                        "literal boolean argument hides parameter '{s}' in call to '{s}'; use an enum or options struct",
                        .{ parameter.name, function_name },
                    ),
                });
            }
        }
    }
}

fn functionDescribesBoolean(function_name: []const u8, parameter_name: []const u8) bool {
    if (std.ascii.findIgnoreCase(function_name, parameter_name) != null or
        std.ascii.startsWithIgnoreCase(function_name, "test")) return true;
    if ((parameter_name.len <= 2 or std.ascii.eqlIgnoreCase(parameter_name, "value")) and
        (std.ascii.startsWithIgnoreCase(function_name, "set") or
            std.ascii.startsWithIgnoreCase(function_name, "enable") or
            std.ascii.startsWithIgnoreCase(function_name, "disable"))) return true;
    if (parameter_name.len > 2 and std.ascii.endsWithIgnoreCase(parameter_name, "ed") and
        std.ascii.findIgnoreCase(function_name, parameter_name[0 .. parameter_name.len - 2]) != null) return true;
    return false;
}

fn booleanParameterName(file: File, start: usize, end: usize) ?[]const u8 {
    const colon = findTag(file.tokens, start, end, .colon) orelse return null;
    if (colon == start or colon + 2 != end or file.tokens[colon - 1].tag != .identifier or
        !tokenIs(file.source, file.tokens[colon + 1], "bool")) return null;
    for (file.tokens[start..colon]) |token| if (token.tag == .keyword_comptime) return null;
    return tokenText(file.source, file.tokens[colon - 1]);
}

fn functionParameterCount(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    if (opening + 1 == closing) return 0;
    var count: usize = 1;
    var start = opening + 1;
    while (topLevelComma(tokens, start, closing)) |comma| {
        count += 1;
        start = comma + 1;
    }
    return count;
}

fn callArgumentCount(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    if (opening + 1 == closing) return 0;
    var count: usize = 1;
    var start = opening + 1;
    while (topLevelComma(tokens, start, closing)) |comma| {
        count += 1;
        start = comma + 1;
    }
    return count;
}

fn callArgument(tokens: []const std.zig.Token, opening: usize, closing: usize, wanted: usize) ?PathRange {
    var start = opening + 1;
    var index: usize = 0;
    while (start < closing) : (index += 1) {
        const comma = topLevelComma(tokens, start, closing) orelse closing;
        if (index == wanted) return .{ .start = start, .end = comma };
        if (comma == closing) return null;
        start = comma + 1;
    }
    return null;
}

test "literal boolean arguments require a unique resolved project function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.literal_boolean_argument}, .information);
    const files = [_]project.SourceFile{
        .{
            .path = "src/action.zig",
            .source = "pub fn oneEdit(context: ActionRun, title: []const u8, preferred: bool) void { _ = context; _ = title; _ = preferred; }",
        },
        .{
            .path = "src/main.zig",
            .source = "fn run(context: ActionRun) void { context.oneEdit(\"Rename\", false); } fn render(value: u8, compact: bool) void { _ = value; _ = compact; } fn use() void { render(1, true); }",
        },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(types.Rule.literal_boolean_argument, finding.finding.rule);
}

test "literal boolean arguments skip self-describing and ambiguous functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.literal_boolean_argument}, .information);
    const files = [_]project.SourceFile{
        .{
            .path = "src/a.zig",
            .source = "fn setEnabled(enabled: bool) void { _ = enabled; } fn setShouldAntialias(context: Context, v: bool) void { _ = context; _ = v; } fn updateFocus(context: Context, focused: bool) void { _ = context; _ = focused; } fn testDragSelection(context: Context, rect: bool) void { _ = context; _ = rect; } fn choose(comptime fast: bool, value: u8) void { _ = fast; _ = value; } fn render(value: u8, compact: bool) void { _ = value; _ = compact; }",
        },
        .{
            .path = "src/b.zig",
            .source = "fn render(value: u8, compact: bool) void { _ = value; _ = compact; } fn use(context: Context) void { setEnabled(true); setShouldAntialias(context, true); updateFocus(context, false); testDragSelection(context, true); choose(false, 1); render(1, true); }",
        },
    };
    const found = try project.findings(arena.allocator(), &files, configuration);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}
