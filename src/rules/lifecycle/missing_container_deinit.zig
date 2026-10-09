const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const container_types = @import("../container_types.zig");
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;

pub const rules = [_]types.Rule{
    .missing_container_deinit,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.missing_container_deinit);
    if (level == .off) return;

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;

        if (!insideFunctionOrTestBody(context.tokens, declaration_index)) continue;

        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!isContainerDeclaration(context.source, context.tokens, declaration_index, declaration_end)) continue;

        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);

        // Check if container is mutated with an allocating method
        var allocator_name: ?[]const u8 = null;
        var has_mutating_call = false;

        for (context.tokens[declaration_end + 1 .. scope_end], declaration_end + 1..) |call_candidate, index| {
            if (call_candidate.tag != .identifier or !context.tokenIs(index, container_name) or
                index + 2 >= scope_end or context.tokens[index + 1].tag != .period or
                context.tokens[index + 2].tag != .identifier) continue;

            const method_name = context.tokenText(index + 2);
            if (isMutatingMethod(method_name)) {
                has_mutating_call = true;
                if (allocator_name == null and isAllocatingMethod(method_name) and
                    index + 3 < scope_end and context.tokens[index + 3].tag == .l_paren)
                {
                    allocator_name = firstArgumentText(context.source, context.tokens, index + 3);
                }
            }
        }

        if (!has_mutating_call) continue;
        if (isArenaAllocator(allocator_name) or allocatorAliasesArena(context, allocator_name, declaration_index)) continue;

        // Check if container is deinitialized or transferred
        if (hasDeinitOrTransfer(context, container_name, declaration_end + 1, scope_end)) continue;

        // Construct message and optional quickfix
        var fixes: []const types.Fix = &.{};
        if (allocator_name) |alloc_expr| {
            const line_start = findLineStart(context.source, context.tokens[declaration_index].loc.start);
            var indent_end = line_start;
            while (indent_end < context.source.len and (context.source[indent_end] == ' ' or context.source[indent_end] == '\t')) indent_end += 1;
            const indent = context.source[line_start..indent_end];

            const allocated_fixes = try context.singleFix(.{
                .title = try context.allocator.print(
                    "Insert 'defer {s}.deinit({s});'",
                    .{ container_name, alloc_expr },
                ),
                .span = .{
                    .start = context.tokens[declaration_end].loc.end,
                    .end = context.tokens[declaration_end].loc.end,
                },
                .replacement = try context.allocator.print(
                    "\n{s}defer {s}.deinit({s});",
                    .{ indent, container_name, alloc_expr },
                ),
                .preferred = true,
                .fix_all = true,
            });
            fixes = allocated_fixes;
        }

        try context.emit(.{
            .rule = .missing_container_deinit,
            .level = level,
            .span = context.tokens[declaration_index + 1].loc,
            .fixes = fixes,
            .message = if (allocator_name) |alloc_expr|
                try context.allocator.print(
                    "unmanaged container '{s}' is mutated without visible 'deinit({s})' or ownership transfer",
                    .{ container_name, alloc_expr },
                )
            else
                try context.allocator.print(
                    "unmanaged container '{s}' is mutated without visible 'deinit' or ownership transfer",
                    .{container_name},
                ),
        });
    }
}

fn isMutatingMethod(name: []const u8) bool {
    const mutating_methods = [_][]const u8{
        "append",
        "appendSlice",
        "appendNTimes",
        "appendAssumeCapacity",
        "addOne",
        "addOneAssumeCapacity",
        "insert",
        "insertSlice",
        "put",
        "putNoClobber",
        "putAssumeCapacity",
        "putAssumeCapacityNoClobber",
        "getOrPut",
        "getOrPutValue",
        "getOrPutAssumeCapacity",
        "ensureTotalCapacity",
        "ensureTotalCapacityPrecise",
        "ensureUnusedCapacity",
        "clone",
    };
    for (mutating_methods) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isAllocatingMethod(name: []const u8) bool {
    const allocating_methods = [_][]const u8{
        "append",
        "appendSlice",
        "appendNTimes",
        "insert",
        "insertSlice",
        "addOne",
        "put",
        "putNoClobber",
        "getOrPut",
        "getOrPutValue",
        "ensureTotalCapacity",
        "ensureTotalCapacityPrecise",
        "ensureUnusedCapacity",
        "clone",
    };
    for (allocating_methods) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isArenaAllocator(allocator_name: ?[]const u8) bool {
    const name = allocator_name orelse return false;
    // The build graph's allocator is an arena owned by `std.Build`.
    return std.ascii.findIgnoreCase(name, "arena") != null or std.mem.eql(u8, name, "b.allocator");
}

/// `const temporary = arena_state.allocator();` before the container.
fn allocatorAliasesArena(context: RuleRun, allocator_name: ?[]const u8, before: usize) bool {
    const name = allocator_name orelse return false;
    var index = before;
    while (index > 1) {
        index -= 1;
        if (!context.tokenIs(index, name) or context.tokens[index - 1].tag != .keyword_const or
            index + 5 >= before or context.tokens[index + 1].tag != .equal) continue;
        const end = context.statementEnd(index) orelse continue;
        for (context.tokens[index + 2 .. end]) |token| {
            if (token.tag == .identifier and std.ascii.findIgnoreCase(tokenText(context.source, token), "arena") != null) return true;
        }
        return false;
    }
    return false;
}

fn isContainerDeclaration(
    source: []const u8,
    tokens: []const std.zig.Token,
    declaration_index: usize,
    declaration_end: usize,
) bool {
    if (declaration_index + 2 >= declaration_end) return false;

    // Check if the declaration contains '.init(' (managed container handled by missing_resource_cleanup)
    for (tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |token, index| {
        if (token.tag == .period and index + 2 < declaration_end and
            tokenIs(source, tokens[index + 1], "init") and tokens[index + 2].tag == .l_paren)
        {
            return false;
        }
    }

    // `.empty`, `.{}` and methods such as `insert` also belong to fixed-storage
    // sets and user types. Require a known allocating container before proposing
    // a deinit that might not exist.
    // A fixed buffer never allocates, so there is nothing to deinit.
    for (tokens[declaration_index + 2 .. declaration_end]) |token| {
        if (token.tag == .identifier and tokenIs(source, token, "initBuffer")) return false;
    }
    // A managed container carries its allocator from `init` and releases with `deinit()`.
    for (tokens[declaration_index + 2 .. declaration_end], declaration_index + 2..) |token, index| {
        if (token.tag == .identifier and (tokenIs(source, token, "Managed") or tokenIs(source, token, "AlignedManaged")) and
            index > 0 and tokens[index - 1].tag == .period) return false;
    }
    return container_types.firstKindIn(source, tokens, declaration_index + 2, declaration_end) != null;
}

fn hasDeinitOrTransfer(
    context: RuleRun,
    container_name: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index < end) : (index += 1) {
        const token = context.tokens[index];

        // Case 1: container.deinit(...) or container.clearAndFree(...)
        if (token.tag == .identifier and context.tokenIs(index, container_name) and
            index + 2 < end and context.tokens[index + 1].tag == .period and
            context.tokens[index + 2].tag == .identifier)
        {
            const method = context.tokenText(index + 2);
            if (std.mem.eql(u8, method, "deinit") or std.mem.eql(u8, method, "clearAndFree")) {
                return true;
            }
            if (std.mem.eql(u8, method, "toOwnedSlice") or std.mem.eql(u8, method, "toOwnedSliceSentinel") or
                std.mem.eql(u8, method, "moveTo"))
            {
                return true;
            }
        }

        // Case 2: return ... container_name ...
        if (token.tag == .keyword_return) {
            const return_end = context.statementEnd(index) orelse end;
            var cursor = index + 1;
            while (cursor < return_end and cursor < end) : (cursor += 1) {
                if (context.tokens[cursor].tag == .identifier and context.tokenIs(cursor, container_name)) {
                    // Check if it's returning a sub-property like .items or .capacity without transfer
                    if (cursor + 2 < return_end and context.tokens[cursor + 1].tag == .period and
                        (context.tokenIs(cursor + 2, "items") or context.tokenIs(cursor + 2, "capacity") or
                            context.tokenIs(cursor + 2, "len")))
                    {
                        // Sub-property access does not transfer the container backing storage
                    } else {
                        return true;
                    }
                }
            }
        }

        // Case 3: assigned to a struct field or dereferenced pointer (ownership transferred to aggregate/destination)
        // e.g. .list = container_name, dest.* = container_name
        if (token.tag == .equal and index + 1 < end and context.tokens[index + 1].tag == .identifier and
            context.tokenIs(index + 1, container_name))
        {
            if (index >= 2 and (context.tokens[index - 1].tag == .period or context.tokens[index - 1].tag == .asterisk)) {
                return true;
            }
        }
    }
    return false;
}

fn firstArgumentText(source: []const u8, tokens: []const std.zig.Token, l_paren_index: usize) ?[]const u8 {
    if (l_paren_index + 1 >= tokens.len) return null;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var end_token_index = l_paren_index + 1;
    while (end_token_index < tokens.len) : (end_token_index += 1) {
        const tag = tokens[end_token_index].tag;
        switch (tag) {
            .l_paren => paren_depth += 1,
            .r_paren => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break;
                paren_depth -|= 1;
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .comma => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) break,
            else => {},
        }
    }
    if (end_token_index <= l_paren_index + 1) return null;
    const arg_start = tokens[l_paren_index + 1].loc.start;
    const arg_end = tokens[end_token_index - 1].loc.end;
    if (arg_start >= arg_end or arg_end > source.len) return null;
    const trimmed = std.mem.trim(u8, source[arg_start..arg_end], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn insideFunctionOrTestBody(tokens: []const std.zig.Token, declaration_index: usize) bool {
    var nested_closing_braces: usize = 0;
    var cursor = declaration_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => nested_closing_braces += 1,
            .l_brace => {
                if (nested_closing_braces != 0) {
                    nested_closing_braces -= 1;
                    continue;
                }
                var signature_cursor = cursor;
                while (signature_cursor > 0) {
                    signature_cursor -= 1;
                    switch (tokens[signature_cursor].tag) {
                        .keyword_fn, .keyword_test => return true,
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return false,
                        .semicolon, .l_brace, .r_brace => break,
                        else => {},
                    }
                }
                return false;
            },
            else => {},
        }
    }
    return false;
}

fn findLineStart(source: []const u8, offset: usize) usize {
    var cursor = offset;
    while (cursor > 0 and source[cursor - 1] != '\n') : (cursor -= 1) {}
    return cursor;
}

fn testConfiguration() types.Configuration {
    const configuration = support.only(&.{.missing_container_deinit}, .warning);
    return configuration;
}

test "missing container deinit detects mutated unmanaged list without deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn process(allocator: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    try list.append(allocator, 42);
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.missing_container_deinit, findings[0].rule);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "list") != null);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "deinit(allocator)") != null);
    try std.testing.expectEqual(1, findings[0].fixes.len);
    try std.testing.expect(std.mem.find(u8, findings[0].fixes[0].edits[0].replacement, "defer list.deinit(allocator);") != null);
}

test "missing container deinit detects mutated unmanaged map without deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn cache(allocator: std.mem.Allocator, key: []const u8) !void {
        \\    var map: std.StringHashMapUnmanaged(void) = .empty;
        \\    try map.put(allocator, key, {});
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqual(types.Rule.missing_container_deinit, findings[0].rule);
    try std.testing.expect(std.mem.find(u8, findings[0].message, "map") != null);
}

test "missing container deinit ignores container with defer deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn process(allocator: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    defer list.deinit(allocator);
        \\    try list.append(allocator, 42);
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

test "missing container deinit ignores container with toOwnedSlice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn process(allocator: std.mem.Allocator) ![]u32 {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    errdefer list.deinit(allocator);
        \\    try list.append(allocator, 42);
        \\    return try list.toOwnedSlice(allocator);
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

test "missing container deinit ignores unmutated container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn process() void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    _ = list;
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

test "missing container deinit ignores arena-backed container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn process(arena: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    try list.append(arena, 42);
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(0, findings.len);
}

test "missing container deinit does not invent ownership for fixed-storage sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Flag = enum { ready, busy };
        \\const LocalSet = struct {
        \\    flag: Flag = .ready,
        \\    fn insert(self: *LocalSet, flag: Flag) void {
        \\        self.flag = flag;
        \\    }
        \\};
        \\fn collect(flag: Flag) void {
        \\    var typed: std.EnumSet(Flag) = .empty;
        \\    typed.insert(flag);
        \\    var inferred = std.EnumSet(Flag).empty;
        \\    inferred.insert(flag);
        \\    var local: LocalSet = .{};
        \\    local.insert(flag);
        \\}
    ;
    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());
    try std.testing.expectEqual(0, findings.len);
}

test "annotated unmanaged containers are tracked and managed ones are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = types.Configuration.defaults();
    const unmanaged = try support.findings(
        arena.allocator(),
        run,
        "fn f(gpa: A) !void { var l: std.ArrayList(u8) = .empty; try l.append(gpa, 1); }",
        config,
    );
    try std.testing.expectEqual(@as(usize, 1), unmanaged.len);
    const managed = try support.findings(
        arena.allocator(),
        run,
        "fn f(gpa: A) !void { var l = try std.array_list.Managed(u8).initCapacity(gpa, 2); l.appendAssumeCapacity(1); try l.appendSlice(&.{ 1, 2 }); }",
        config,
    );
    try std.testing.expectEqual(@as(usize, 0), managed.len);
    const build = try support.findings(
        arena.allocator(),
        run,
        "fn f(b: *std.Build) !void { var m: std.array_hash_map.String(u8) = .empty; try m.put(b.allocator, \"k\", 1); }",
        config,
    );
    try std.testing.expectEqual(@as(usize, 0), build.len);
}

test "fixed buffers and arena aliases need no deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = types.Configuration.defaults();
    const buffer = try support.findings(
        arena.allocator(),
        run,
        "fn f() void { var values = [_]u8{1}; var l: std.array_list.Aligned(u8, null) = .initBuffer(&values); l.appendAssumeCapacity(1); }",
        config,
    );
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    const alias = try support.findings(
        arena.allocator(),
        run,
        "fn f(arena_state: *std.heap.ArenaAllocator) !void { const temporary = arena_state.allocator(); var l: std.ArrayList(u8) = .empty; try l.append(temporary, 1); }",
        config,
    );
    try std.testing.expectEqual(@as(usize, 0), alias.len);
}
