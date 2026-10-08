//! Acquired resources (files, directories, locks, pipes) with no visible release or ownership transfer in their scope.
const std = @import("std");

const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const enclosingOpeningBrace = @import("../../syntax/tokens.zig").enclosingOpeningBrace;
const matchingToken = @import("../../syntax/tokens.zig").matchingToken;
const statementEnd = @import("../../syntax/tokens.zig").statementEnd;
const enclosingScopeEnd = @import("../../syntax/tokens.zig").enclosingScopeEnd;
const lineStart = @import("../../syntax/tokens.zig").lineStart;
const matchingOpeningToken = @import("../../syntax/tokens.zig").matchingOpeningToken;
const insideFunctionOrTestBody = @import("../../syntax/tokens.zig").insideFunctionOrTestBody;
const rule_context = @import("../context.zig");
const RuleRun = rule_context.RuleRun;
const resources = @import("../resources.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

const Configuration = types.Configuration;
const Fix = types.Fix;

pub const rules = [_]types.Rule{
    .missing_resource_cleanup,
};

pub fn run(context: RuleRun) !void {
    try findMissingResourceCleanup(context);
}

fn findMissingResourceCleanup(context: RuleRun) !void {
    const source = context.source;
    const tokens = context.tokens;
    const level = context.level(.missing_resource_cleanup);
    if (level == .off) return;
    for (tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= tokens.len or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .equal) continue;
        if (!insideFunctionOrTestBody(tokens, declaration_index)) continue;
        const statement_end = statementEnd(tokens, declaration_index) orelse continue;
        var pair: ?resources.Pair = null;
        var resource_acquisition_index: ?usize = null;
        var acquisition_index: usize = declaration_index + 3;
        while (acquisition_index < statement_end) : (acquisition_index += 1) {
            switch (tokens[acquisition_index].tag) {
                // A type definition initializer: any init/openFile inside it is a
                // method declaration or nested body, not an acquisition by this binding.
                .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque, .keyword_fn => break,
                else => {},
            }
            if (tokens[acquisition_index].tag != .identifier or acquisition_index + 1 >= statement_end or
                tokens[acquisition_index + 1].tag != .l_paren) continue;
            if (!initializerCallIsTopLevel(tokens, declaration_index + 3, acquisition_index)) continue;
            const name = tokenText(source, tokens[acquisition_index]);
            const candidate = resources.lookup(context.configuration, name, resources.callReceiver(source, tokens, acquisition_index)) orelse continue;
            if (!resources.acquires(candidate, source, tokens, declaration_index + 3, acquisition_index)) continue;
            pair = candidate;
            resource_acquisition_index = acquisition_index;
            if (pair != null) break;
        }
        const resource = pair orelse continue;
        const release_uses_first_argument = absoluteIoDirectoryCall(source, tokens, resource_acquisition_index.?);
        const release_argument = if (release_uses_first_argument)
            firstSimpleCallArgument(source, tokens, resource_acquisition_index.?)
        else
            null;
        const scope_end = enclosingScopeEnd(tokens, declaration_index) orelse continue;
        const binding_name = tokenText(source, tokens[declaration_index + 1]);
        if (bindingHasRelease(source, tokens, binding_name, statement_end + 1, scope_end, resource.release, resource.alternative_release) or
            bindingObviouslyEscapes(source, tokens, binding_name, statement_end + 1, scope_end)) continue;
        const line_start = lineStart(source, tokens[declaration_index].loc.start);
        var indentation_end = line_start;
        while (indentation_end < source.len and (source[indentation_end] == ' ' or source[indentation_end] == '\t')) indentation_end += 1;
        var fixes: []const Fix = &.{};
        if (!release_uses_first_argument or release_argument != null) {
            const title = try context.allocator.print(
                "Insert 'defer {s}.{s}({s})'",
                .{ binding_name, resource.release, release_argument orelse "" },
            );
            errdefer context.allocator.free(title);
            const allocated_fixes = try Fix.single(context.allocator, .{
                .title = title,
                .span = .{ .start = tokens[statement_end].loc.end, .end = tokens[statement_end].loc.end },
                .replacement = try context.allocator.print(
                    "\n{s}defer {s}.{s}({s});",
                    .{ source[line_start..indentation_end], binding_name, resource.release, release_argument orelse "" },
                ),
                .preferred = true,
            });
            fixes = allocated_fixes;
        }
        try context.emit(.{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = tokens[declaration_index + 1].loc,
            .fixes = fixes,
            .message = try context.allocator.print(
                "resource '{s}' from {s} has no visible {s}{s} or ownership transfer",
                .{
                    binding_name,
                    resource.acquisition,
                    resource.release,
                    if (resource.alternative_release) |alternative| try context.allocator.print("/{s}", .{alternative}) else "",
                },
            ),
        });
    }

    for (tokens, 0..) |token, lock_index| {
        if (!tokenIs(source, token, "lock") or lock_index < 2 or lock_index + 2 >= tokens.len or
            tokens[lock_index - 1].tag != .period or tokens[lock_index - 2].tag != .identifier or
            tokens[lock_index + 1].tag != .l_paren or tokens[lock_index + 2].tag != .r_paren) continue;
        // A bound result means this is a guard-style lock, not std's void-returning Mutex.lock.
        var receiver_start = lock_index - 2;
        while (receiver_start >= 2 and tokens[receiver_start - 1].tag == .period and
            tokens[receiver_start - 2].tag == .identifier) receiver_start -= 2;
        if (receiver_start > 0 and tokens[receiver_start - 1].tag == .equal) continue;
        const scope_end = enclosingScopeEnd(tokens, lock_index) orelse continue;
        const scope_opening = matchingOpeningToken(tokens, scope_end, .l_brace, .r_brace) orelse continue;
        const receiver = tokenText(source, tokens[lock_index - 2]);
        if (bindingReleaseIndex(source, tokens, receiver, lock_index + 3, scope_end, "unlock", null)) |unlock_index| {
            if (explicitErrorReturnBetween(tokens, lock_index + 3, unlock_index, scope_opening)) |return_index| {
                try context.emit(.{
                    .rule = .missing_resource_cleanup,
                    .level = level,
                    .span = tokens[return_index].loc,
                    .message = try context.allocator.print(
                        "mutex '{s}' remains locked when this error path leaves the scope before unlock",
                        .{receiver},
                    ),
                });
            }
            continue;
        }
        if (bindingHasRelease(source, tokens, receiver, scope_opening + 1, lock_index, "unlock", null)) continue;
        if (lockCleanupIsPublicContract(source, tokens, lock_index, scope_end)) continue;
        try context.emit(.{
            .rule = .missing_resource_cleanup,
            .level = level,
            .span = token.loc,
            .message = try context.allocator.print("mutex '{s}' is locked without a visible unlock before leaving this scope", .{receiver}),
        });
    }
}

fn firstSimpleCallArgument(
    source: []const u8,
    tokens: []const std.zig.Token,
    call_index: usize,
) ?[]const u8 {
    if (call_index + 3 >= tokens.len or tokens[call_index + 1].tag != .l_paren or
        tokens[call_index + 2].tag != .identifier or
        (tokens[call_index + 3].tag != .comma and tokens[call_index + 3].tag != .r_paren)) return null;
    return tokenText(source, tokens[call_index + 2]);
}

fn absoluteIoDirectoryCall(source: []const u8, tokens: []const std.zig.Token, call_index: usize) bool {
    return call_index >= 6 and tokens[call_index - 1].tag == .period and
        tokenIs(source, tokens[call_index - 2], "Dir") and tokens[call_index - 3].tag == .period and
        tokenIs(source, tokens[call_index - 4], "Io") and tokens[call_index - 5].tag == .period and
        tokenIs(source, tokens[call_index - 6], "std");
}

fn explicitErrorReturnBetween(
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
    scope_opening: usize,
) ?usize {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .keyword_return or index + 1 >= end or tokens[index + 1].tag != .keyword_error) continue;
        const enclosing = enclosingOpeningBrace(tokens, index) orelse continue;
        if (enclosing == scope_opening or enclosingOpeningBrace(tokens, enclosing) == scope_opening) return index;
    }
    return null;
}

fn initializerCallIsTopLevel(tokens: []const std.zig.Token, start: usize, call_index: usize) bool {
    var brace_depth: usize = 0;
    for (tokens[start..call_index]) |token| switch (token.tag) {
        .l_brace => brace_depth += 1,
        .r_brace => brace_depth -|= 1,
        else => {},
    };
    return brace_depth == 0;
}

fn lockCleanupIsPublicContract(source: []const u8, tokens: []const std.zig.Token, index: usize, scope_end: usize) bool {
    const closing = enclosingScopeEnd(tokens, index) orelse return false;
    const opening = matchingOpeningToken(tokens, closing, .l_brace, .r_brace) orelse return false;
    var cursor = opening;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_fn => {
                if (cursor + 1 >= tokens.len or tokens[cursor + 1].tag != .identifier) return false;
                const function_name = tokenText(source, tokens[cursor + 1]);
                var receiver_start = index - 2;
                while (receiver_start >= 2 and tokens[receiver_start - 1].tag == .period and
                    tokens[receiver_start - 2].tag == .identifier) receiver_start -= 2;
                const private_wrapper = std.mem.eql(u8, function_name, "lock") and
                    tokenIs(source, tokens[receiver_start], "self");
                if (private_wrapper) return true;
                if (cursor == 0 or tokens[cursor - 1].tag != .keyword_pub) return false;
                if (std.mem.startsWith(u8, function_name, "lock")) return true;
                for (tokens[index + 1 .. scope_end]) |token| if (token.tag == .keyword_return) return true;
                return false;
            },
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn bindingHasRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
    release: []const u8,
    alternative_release: ?[]const u8,
) bool {
    return bindingReleaseIndex(source, tokens, binding_name, start, end, release, alternative_release) != null;
}

fn bindingReleaseIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
    release: []const u8,
    alternative_release: ?[]const u8,
) ?usize {
    var index = start;
    while (index + 3 < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name) or tokens[index + 1].tag != .period or
            tokens[index + 2].tag != .identifier or tokens[index + 3].tag != .l_paren) continue;
        const method = tokenText(source, tokens[index + 2]);
        if (std.mem.eql(u8, method, release)) return index + 2;
        if (alternative_release) |alternative| if (std.mem.eql(u8, method, alternative)) return index + 2;
    }
    return null;
}

fn bindingObviouslyEscapes(
    source: []const u8,
    tokens: []const std.zig.Token,
    binding_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return or token.tag == .keyword_break) {
            const return_end = statementEnd(tokens, index) orelse continue;
            for (tokens[index + 1 .. @min(return_end, end)]) |return_token| {
                if (tokenIs(source, return_token, binding_name)) return true;
            }
        }
        if (token.tag != .l_paren or index == 0) continue;
        const closing = matchingToken(tokens, index, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        for (tokens[index + 1 .. closing]) |argument_token| {
            if (tokenIs(source, argument_token, binding_name)) return true;
        }
    }
    var index = start;
    while (index < @min(end, tokens.len)) : (index += 1) {
        if (!tokenIs(source, tokens[index], binding_name)) continue;
        if (index > 0 and tokens[index - 1].tag == .keyword_return) return true;
        if (index > 0 and tokens[index - 1].tag == .equal and bindingIsWholeAssignedValue(tokens, index, end)) return true;
    }
    return false;
}

fn bindingIsWholeAssignedValue(tokens: []const std.zig.Token, index: usize, end: usize) bool {
    if (index + 1 >= end) return true;
    return switch (tokens[index + 1].tag) {
        .semicolon, .comma, .r_brace, .r_paren => true,
        else => false,
    };
}

test "resource diagnostics require visible close unlock or ownership transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn leak(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    mutex.lock();\n" ++
        "}\n" ++
        "fn clean(directory: anytype, mutex: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    defer file.close();\n" ++
        "    const list = try std.ArrayList(u8).initCapacity(allocator, 4);\n" ++
        "    defer list.deinit(allocator);\n" ++
        "    mutex.lock();\n" ++
        "    defer mutex.unlock();\n" ++
        "}\n" ++
        "fn transfer(directory: anytype) !anytype {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "    return file;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), warning_count);
}

test "resource ownership can leave a nested block through break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn build(allocator: anytype) !Step {\n" ++
        "    return .{ .remove = value: {\n" ++
        "        var list = try std.ArrayList(u8).initCapacity(allocator, 0);\n" ++
        "        break :value list;\n" ++
        "    } };\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "field cleanup satisfies aggregate resource ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn run(allocator: anytype) void { var owner = Owner{ .values = .empty, .positions = Map.init(allocator) };" ++
        "defer owner.values.deinit(allocator); defer owner.positions.deinit(); }";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "error return before unlock leaves the mutex locked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn consume(mutex: anytype, fail: bool) !void { mutex.lock();" ++
        "if (fail) return error.NotReady; mutex.unlock(); }" ++
        "fn safe(mutex: anytype, fail: bool) !void { mutex.lock(); defer mutex.unlock();" ++
        "if (fail) return error.NotReady; }";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), warning_count);
}

test "public lock APIs and temporary unlock restoration do not require local cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "pub fn lockDemand(self: *State) void { self.mutex.lock(); }\n" ++
        "pub fn drain(self: *State) Iterator { self.mutex.lock(); return .{ .state = self }; }\n" ++
        "pub fn run(mutex: anytype) void { mutex.lock(); }\n" ++
        "fn lock(self: *State) void { self.writer.lock(); }\n" ++
        "fn lockAndWork(self: *State) void { self.writer.lock(); work(); }\n" ++
        "fn restore(self: *State) void { self.mutex.unlock(); defer self.mutex.lock(); work(); }\n" ++
        "fn leak(mutex: anytype) void { mutex.lock(); }\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var warning_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        warning_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), warning_count);
}

test "bound lock results are guards not mutex locks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn guarded(db: anytype) void {\n" ++
        "    const guard = db.lock();\n" ++
        "    defer guard.deinit();\n" ++
        "}\n" ++
        "fn leaky(mutex: anytype) void {\n" ++
        "    mutex.lock();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var lock_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        lock_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "'mutex'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), lock_count);
}

test "type definitions inside test bodies are not resource acquisitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "test \"merge\" {\n" ++
        "    const T = struct {\n" ++
        "        output_buf: std.ArrayList(u8),\n" ++
        "        fn init(gpa: std.mem.Allocator) !@This() {\n" ++
        "            return .{ .output_buf = std.ArrayList(u8).init(gpa) };\n" ++
        "        }\n" ++
        "    };\n" ++
        "    _ = T;\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .missing_resource_cleanup);
}

test "missing resource cleanup offers inserting a defer after the acquisition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(directory: anytype) !void {\n" ++
        "    const file = try directory.openFile(\"state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expect(!finding.fixes[0].fix_all);
        const edit = finding.fixes[0].edits[0];
        try std.testing.expectEqual(edit.span.start, edit.span.end);
        try std.testing.expectEqual(std.mem.findScalar(u8, source, ';').? + 1, edit.span.start);
        try std.testing.expectEqualStrings("\n    defer file.close();", edit.replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute file cleanup preserves the IO argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(io: std.Io) !void {\n" ++
        "    const file = try std.Io.Dir.openFileAbsolute(io, \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
        try std.testing.expectEqualStrings("\n    defer file.close(io);", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute directory cleanup preserves the IO argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(io: std.Io) !void {\n" ++
        "    const directory = try std.Io.Dir.openDirAbsolute(io, \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqualStrings("\n    defer directory.close(io);", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "legacy absolute directory cleanup does not pass the path to close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(path: []const u8) !void {\n" ++
        "    const directory = try std.fs.openDirAbsolute(path, .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqualStrings("\n    defer directory.close();", finding.fixes[0].edits[0].replacement);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "absolute file cleanup still reports when the IO argument is not a simple binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn load(threaded: *Threaded) !void {\n" ++
        "    const file = try std.Io.Dir.openFileAbsolute(threaded.io(), \"/tmp/state\", .{});\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.rule == .missing_resource_cleanup) {
        cleanup_count += 1;
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "a declared resource pair needs a visible release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const leaking: [:0]const u8 = "fn load() !void { const connection = try Db.open(); _ = connection.id; }";
    const declared = try support.findings(arena.allocator(), run, leaking, configuration);
    try support.expectRules(declared, &.{.missing_resource_cleanup});
    try std.testing.expect(std.mem.find(u8, declared[0].message, "Db.open") == null);
    try std.testing.expectEqualStrings("Insert 'defer connection.close()'", declared[0].fixes[0].title);
    const builtin = try support.findings(arena.allocator(), run, leaking, types.Configuration.defaults());
    try support.expectRules(builtin, &.{});
    const released: [:0]const u8 = "fn load() !void { const connection = try Db.open(); defer connection.close(); }";
    try support.expectRules(try support.findings(arena.allocator(), run, released, configuration), &.{});
    const other: [:0]const u8 = "fn load() !void { const connection = try Cache.open(); _ = connection.id; }";
    try support.expectRules(try support.findings(arena.allocator(), run, other, configuration), &.{});
}
