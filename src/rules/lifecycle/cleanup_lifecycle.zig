//! Deferred cleanup that targets the wrong value: a binding reassigned after its `defer`, and resources released only on error paths.
const std = @import("std");
const types = @import("../types.zig");
const RuleRun = @import("../context.zig").RuleRun;
const resources = @import("../resources.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{ .defer_uses_reassigned_binding, .resource_cleanup_on_error_only };

pub fn run(context: RuleRun) !void {
    try findReassignedCleanupBindings(context);
    try findErrorOnlyResourceCleanup(context);
}

fn findReassignedCleanupBindings(context: RuleRun) !void {
    const level = context.level(.defer_uses_reassigned_binding);
    if (level == .off) return;
    for (context.tokens, 0..) |token, defer_index| {
        if (token.tag != .keyword_defer) continue;
        const scope_opening = context.enclosingOpeningBrace(defer_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const defer_end = context.statementEnd(defer_index) orelse continue;
        const cleanup_binding = cleanupBinding(context, defer_index + 1, defer_end) orelse continue;
        for (context.tokens[defer_end + 1 .. scope_end], defer_end + 1..) |candidate, index| {
            if (candidate.tag != .identifier or !context.tokenIs(index, cleanup_binding) or index + 1 >= scope_end or
                !context.refersToBinding(index, cleanup_binding) or context.tokens[index + 1].tag != .equal or
                context.enclosingOpeningBrace(index) != scope_opening) continue;
            if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or
                context.tokens[index - 1].tag == .keyword_var)) continue;
            const assignment_end = context.statementEnd(index) orelse continue;
            if (replacementConsumesOriginal(context, cleanup_binding, index + 2, assignment_end) or
                replacementRestoresWriterList(context, cleanup_binding, defer_end + 1, index, index + 2, assignment_end) or
                replacementRelinquishesOwnership(context, cleanup_binding, defer_end + 1, index, index + 2, assignment_end) or
                releasedBeforeReplacement(context, cleanup_binding, defer_end + 1, index)) continue;
            try context.emit(.{
                .rule = .defer_uses_reassigned_binding,
                .level = level,
                .span = candidate.loc,
                .message = try context.allocator.print(
                    "binding '{s}' is reassigned after deferred cleanup captures it; cleanup will target the replacement and may leak the original value",
                    .{cleanup_binding},
                ),
            });
            break;
        }
    }
}

fn findErrorOnlyResourceCleanup(context: RuleRun) !void {
    const level = context.level(.resource_cleanup_on_error_only);
    if (level == .off) return;
    for (context.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier or context.tokens[declaration_index + 2].tag != .equal) continue;
        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        const resource = resources.acquiredIn(context, declaration_index + 3, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration_index) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        const binding_name = context.tokenText(declaration_index + 1);
        var error_cleanup = false;
        var normal_cleanup = false;
        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |_, index| {
            if (!context.tokenIs(index, resource.release)) continue;
            const statement_start = precedingStatementKeyword(context.tokens, index);
            if (!releaseReferencesBinding(context, binding_name, index, scope_end)) continue;
            if (statement_start == .keyword_errdefer) error_cleanup = true else normal_cleanup = true;
        }
        if (!error_cleanup or normal_cleanup or
            bindingTransferred(context, binding_name, resource.release, declaration_end + 1, scope_end)) continue;
        try context.emit(.{
            .rule = .resource_cleanup_on_error_only,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .message = try context.allocator.print(
                "resource '{s}' is cleaned up by errdefer only; a successful return leaves {s} unhandled unless ownership is transferred",
                .{ binding_name, resource.release },
            ),
        });
    }
}

fn cleanupBinding(context: RuleRun, start: usize, end: usize) ?[]const u8 {
    for (context.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !resources.isReleaseMethod(context.tokenText(method_index))) continue;
        if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and
            context.tokens[method_index - 2].tag == .identifier and
            (context.tokenIs(method_index, "close") or context.tokenIs(method_index, "deinit") or
                context.tokenIs(method_index, "join") or context.tokenIs(method_index, "detach") or
                context.tokenIs(method_index, "unlock")))
        {
            const receiver_index = method_index - 2;
            const capture_receiver = receiver_index > start and context.tokens[receiver_index - 1].tag == .pipe or
                receiver_index > start + 1 and context.tokens[receiver_index - 1].tag == .asterisk and
                    context.tokens[receiver_index - 2].tag == .pipe;
            if (!capture_receiver) return context.tokenText(receiver_index);
        }
        if (method_index + 2 >= end or context.tokens[method_index + 1].tag != .l_paren) continue;
        const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier) return context.tokenText(argument_index);
        }
    }
    return null;
}

fn releasedBeforeReplacement(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !resources.isReleaseMethod(context.tokenText(index))) continue;
        if (index >= 2 and context.tokens[index - 1].tag == .period and context.tokenIs(index - 2, name)) return true;
        if (releaseReferencesBinding(context, name, index, end)) return true;
    }
    return false;
}

fn replacementConsumesOriginal(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    var names_original = false;
    var transfers_allocation = false;
    const transfer_methods = [_][]const u8{ "realloc", "reallocAdvanced", "remap" };
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier) continue;
        if (context.tokenIs(index, name)) names_original = true;
        for (transfer_methods) |method| {
            if (context.tokenIs(index, method)) transfers_allocation = true;
        }
    }
    return names_original and transfers_allocation;
}

fn replacementRelinquishesOwnership(
    context: RuleRun,
    name: []const u8,
    search_start: usize,
    assignment_index: usize,
    replacement_start: usize,
    replacement_end: usize,
) bool {
    if (replacement_start + 1 >= replacement_end or context.tokens[replacement_start].tag != .period) return false;
    const resets_to_empty = context.tokens[replacement_start + 1].tag == .identifier and
        context.tokenIs(replacement_start + 1, "empty") or
        replacement_start + 2 < replacement_end and context.tokens[replacement_start + 1].tag == .l_brace and
            context.tokens[replacement_start + 2].tag == .r_brace;
    if (!resets_to_empty) return false;
    for (context.tokens[search_start..assignment_index], search_start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > search_start and context.tokens[index - 1].tag == .equal) return true;
        var opening = index;
        while (opening > search_start and index - opening < 16) {
            opening -= 1;
            if (context.tokens[opening].tag == .l_paren) break;
            if (context.tokens[opening].tag == .semicolon or context.tokens[opening].tag == .l_brace) break;
        }
        if (context.tokens[opening].tag != .l_paren or opening == 0 or
            context.tokens[opening - 1].tag != .identifier) continue;
        if (std.mem.find(u8, context.tokenText(opening - 1), "Owned") != null) return true;
    }
    return false;
}

fn replacementRestoresWriterList(
    context: RuleRun,
    name: []const u8,
    search_start: usize,
    assignment_index: usize,
    replacement_start: usize,
    replacement_end: usize,
) bool {
    var writer_name: ?[]const u8 = null;
    for (context.tokens[replacement_start..replacement_end], replacement_start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, "toArrayList") or index < 2 or
            context.tokens[index - 1].tag != .period or context.tokens[index - 2].tag != .identifier) continue;
        writer_name = context.tokenText(index - 2);
        break;
    }
    const expected_writer = writer_name orelse return false;
    for (context.tokens[search_start..assignment_index], search_start..) |token, method_index| {
        if (token.tag != .identifier or !context.tokenIs(method_index, "fromArrayList") or
            method_index == 0 or context.tokens[method_index - 1].tag != .period or method_index + 1 >= assignment_index or
            context.tokens[method_index + 1].tag != .l_paren) continue;
        var equal_index = method_index;
        while (equal_index > search_start and context.tokens[equal_index].tag != .equal and
            context.tokens[equal_index].tag != .semicolon) : (equal_index -= 1)
        {}
        if (context.tokens[equal_index].tag != .equal or equal_index < 2 or
            context.tokens[equal_index - 1].tag != .identifier or !context.tokenIs(equal_index - 1, expected_writer) or
            (context.tokens[equal_index - 2].tag != .keyword_var and context.tokens[equal_index - 2].tag != .keyword_const)) continue;
        const call_end = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse continue;
        if (call_end >= assignment_index) continue;
        for (context.tokens[method_index + 2 .. call_end], method_index + 2..) |argument, argument_index| {
            if (argument.tag == .ampersand and argument_index + 1 < call_end and
                context.tokens[argument_index + 1].tag == .identifier and context.tokenIs(argument_index + 1, name)) return true;
        }
    }
    return false;
}

fn bindingTransferred(context: RuleRun, name: []const u8, release: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index > start and
            context.tokens[index - 1].tag == .equal) return true;
        if (token.tag == .keyword_return) {
            const return_end = context.statementEnd(index) orelse continue;
            for (context.tokens[index + 1 .. @min(return_end, end)], index + 1..) |return_token, return_index| {
                if (return_token.tag == .identifier and context.tokenIs(return_index, name)) return true;
            }
        }
        if (token.tag == .l_paren and index > start and context.tokens[index - 1].tag == .identifier and
            !context.tokenIs(index - 1, release))
        {
            const closing = context.matchingToken(index, .l_paren, .r_paren) orelse continue;
            if (closing >= end) continue;
            for (index + 1..closing) |argument_index| {
                if (context.refersToBinding(argument_index, name)) return true;
            }
        }
    }
    return false;
}

fn precedingStatementKeyword(tokens: []const std.zig.Token, index: usize) std.zig.Token.Tag {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_defer, .keyword_errdefer => return tokens[cursor].tag,
            .semicolon, .l_brace, .r_brace => return .invalid,
            else => {},
        }
    }
    return .invalid;
}

fn releaseReferencesBinding(context: RuleRun, name: []const u8, method_index: usize, end: usize) bool {
    if (method_index >= 2 and context.tokens[method_index - 1].tag == .period and context.tokenIs(method_index - 2, name)) return true;
    if (method_index + 1 >= end or context.tokens[method_index + 1].tag != .l_paren) return false;
    const closing = context.matchingToken(method_index + 1, .l_paren, .r_paren) orelse return false;
    for (context.tokens[method_index + 2 .. @min(closing, end)], method_index + 2..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
    }
    return false;
}

test "cleanup lifetime mistakes warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype, count: usize) !void { var file = try a.openFile(\"x\", .{}); errdefer file.close(); var bytes = try a.alloc(u8, count); defer a.free(bytes); bytes = try a.alloc(u8, 2); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "realloc transfers the original allocation into the replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(a: anytype) !void { var bytes = try a.alloc(u8, 1); defer a.free(bytes); bytes = try a.realloc(bytes, 2); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "advanced realloc and moved empty resources preserve deferred cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn grow(a: anytype) !void { var bytes = try a.alloc(u8, 1); defer a.free(bytes); bytes = try a.reallocAdvanced(bytes, 2, 0); }" ++
        "fn move(owner: anytype, a: anytype) void { var stack = acquire(); defer stack.deinit(a); owner.stack = stack; stack = .{}; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "cleanup reassignment ignores ownership moves and shadow declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn transfer(a: anytype, supplied: ?[]u8) void {" ++
        "var ranges = acquire(); defer ranges.deinit(a);" ++
        "const result = takeOwned(ranges); ranges = .empty; _ = result;" ++
        "const owned_path = supplied; defer if (owned_path) |path| a.free(path);" ++
        "const path = supplied orelse return; _ = path;" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "clearing a deferred binding without transferring it still warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(a: anytype) void { var ranges = acquire(); defer ranges.deinit(a); ranges = .empty; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(types.Rule.defer_uses_reassigned_binding, findings[0].rule);
}

test "assigning a same-named field does not reassign the deferred binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(owner: anytype, allocator: anytype) !void { var syntax = try parse(); defer syntax.deinit(allocator); owner.syntax = syntax; }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "allocating writers restore their array list before deferred cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn render(allocator: std.mem.Allocator) !void {" ++
        "var output: std.ArrayList(u8) = .empty;" ++
        "defer output.deinit(allocator);" ++
        "var output_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &output);" ++
        "defer output = output_writer.toArrayList();" ++
        "try output_writer.writer.writeAll(\"done\");" ++
        "}";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (findings) |finding| try std.testing.expect(finding.rule != .defer_uses_reassigned_binding);
}

test "appending a resource to a container transfers ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn add(self: anytype, dir: anytype, gpa: anytype) !void { var file = try dir.openFile(\"x\", .{}); errdefer file.close(); try self.files.append(gpa, file); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "defer loop captures do not bind later declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(values: anytype) !void { defer for (values) |*it| it.close(); var it = try Iterator.init(); defer it.close(); }";
    const findings = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "a declared resource pair reports cleanup registered only for errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 =
        "fn load() !void { const connection = try Db.open(); errdefer connection.close(); try validate(); }";
    const declared = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expectEqual(types.Rule.resource_cleanup_on_error_only, declared[0].rule);
    const builtin = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), builtin.len);
}
