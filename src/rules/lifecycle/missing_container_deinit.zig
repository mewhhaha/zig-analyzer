const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const container_types = @import("../container_types.zig");
const resources = @import("../resources.zig");
const summaries = @import("../summaries.zig");
const syntax_scope = @import("../../syntax/scope.zig");
const tokenText = @import("../../syntax/tokens.zig").tokenText;
const tokenIs = @import("../../syntax/tokens.zig").tokenIs;
const lineStart = @import("../../syntax/tokens.zig").lineStart;

pub const rules = [_]types.Rule{
    .missing_container_deinit,
};

pub fn run(context: RuleRun) !void {
    const level = context.level(.missing_container_deinit);
    if (level == .off) return;
    // Built the first time a container that would be reported is handed to a
    // callee by address.
    var summary_index: ?summaries.Index = null;
    defer if (summary_index) |*index| index.deinit(context.allocator);
    // Lookups the declarations share; each builds its index once it pays.
    var occurrences: Occurrences = .{};
    defer occurrences.deinit(context.allocator);
    var constants: Constants = .{};
    defer constants.deinit(context.allocator);
    var returns: Returns = .{};
    defer returns.deinit(context.allocator);

    for (context.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_var or declaration_index + 3 >= context.tokens.len or
            context.tokens[declaration_index + 1].tag != .identifier) continue;

        if (!insideFunctionOrTestBody(context, declaration_index)) continue;

        const declaration_end = context.statementEnd(declaration_index) orelse continue;
        if (!isContainerDeclaration(context.source, context.tokens, declaration_index, declaration_end)) continue;

        const scope_end = context.enclosingScopeEnd(declaration_index) orelse continue;
        const container_name = context.tokenText(declaration_index + 1);
        // Every later identifier of the block spelled like the container. The
        // name is an identifier, so any token spelled like it is one.
        const uses = try occurrences.within(context, container_name, declaration_end + 1, scope_end);

        // Check if container is mutated with an allocating method
        var allocator_name: ?[]const u8 = null;
        // The `(` before the allocator argument that names `allocator_name`.
        var allocator_opening: usize = 0;
        var has_mutating_call = false;

        for (uses) |use| {
            const index: usize = use;
            if (index + 2 >= scope_end or context.tokens[index + 1].tag != .period or
                context.tokens[index + 2].tag != .identifier) continue;

            const method_name = context.tokenText(index + 2);
            if (isMutatingMethod(method_name)) {
                has_mutating_call = true;
                if (allocator_name == null and isAllocatingMethod(method_name) and
                    index + 3 < scope_end and context.tokens[index + 3].tag == .l_paren)
                {
                    allocator_name = firstArgumentText(context.source, context.tokens, index + 3);
                    allocator_opening = index + 3;
                }
            }
        }

        if (!has_mutating_call) continue;
        // A leak in a test is reported by `std.testing.allocator` itself.
        if (context.scopes.insideTestBlock(declaration_index)) continue;
        if (allocator_name == null) {
            if (initializerAllocator(context, declaration_index, declaration_end)) |opening| allocator_opening = opening;
        }
        const backing = allocator_name orelse if (allocator_opening != 0)
            firstArgumentText(context.source, context.tokens, allocator_opening)
        else
            null;
        if (isArenaAllocator(backing) or try allocatorAliasesArena(context, &constants, backing, declaration_index)) continue;
        if (backing) |backing_text| {
            if (resources.buildGraphAllocator(context.source, context.tokens, context.scopes, backing_text, declaration_index)) continue;
            if (resources.allocatorFreesWholesale(context, allocator_opening + 1)) continue;
        }

        // Check if container is deinitialized or transferred
        if (try hasDeinitOrTransfer(context, &returns, uses, declaration_end + 1, scope_end)) continue;
        if (try releasedByCallee(context, &summary_index, uses, declaration_end + 1, scope_end)) continue;

        // Construct message and optional quickfix
        var fixes: []const types.Fix = &.{};
        if (allocator_name) |alloc_expr| {
            const line_start = lineStart(context.source, context.tokens[declaration_index].loc.start);
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

/// The `(` of a `try .initCapacity(allocator, n)` initializer, whose first
/// argument is the allocator it hands the container.
fn initializerAllocator(context: RuleRun, declaration_index: usize, declaration_end: usize) ?usize {
    for (context.tokens[declaration_index..declaration_end], declaration_index..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, "initCapacity") and
            context.tokens[index + 1].tag == .l_paren) return index + 1;
    }
    return null;
}

/// Whether `&name` in `[start, end)` goes to a callee whose summary releases
/// or keeps what it points to: `consume(gpa, &list)` that deinits it, or
/// `stash(holder, &list)` that stores `list.*`. `uses` are the tokens
/// spelled `name` in `[start, end)`.
fn releasedByCallee(
    context: RuleRun,
    summary_index: *?summaries.Index,
    uses: []const u32,
    start: usize,
    end: usize,
) !bool {
    const tokens = context.tokens;
    for (uses) |use| {
        // The `&` before the name.
        if (use <= start) continue;
        const index: usize = use - 1;
        if (tokens[index].tag != .ampersand or index + 2 >= end or
            (tokens[index + 2].tag != .r_paren and tokens[index + 2].tag != .comma)) continue;
        const argument = callArgument(tokens, index) orelse continue;
        if (summary_index.* == null) {
            const sources = [_]summaries.Source{.{ .file_index = 0, .source = context.source, .tokens = tokens }};
            summary_index.* = try summaries.build(context.allocator, &sources, context.configuration);
        }
        var callable_start = argument.name;
        while (callable_start >= 2 and tokens[callable_start - 1].tag == .period and
            tokens[callable_start - 2].tag == .identifier) callable_start -= 2;
        const callable = context.source[tokens[callable_start].loc.start..tokens[argument.name].loc.end];
        switch (summary_index.*.?.parameterEffectForCall(context.source, callable, argument.position)) {
            .released, .escaped => return true,
            .borrowed, .unknown => {},
        }
    }
    return false;
}

const CallArgument = struct {
    /// The called function's name token.
    name: usize,
    position: usize,
};

/// The call whose argument list directly holds the argument starting at
/// `index`, and the argument's position in it.
fn callArgument(tokens: []const std.zig.Token, index: usize) ?CallArgument {
    var position: usize = 0;
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_paren, .r_bracket, .r_brace => depth += 1,
            .l_bracket, .l_brace => {
                if (depth == 0) return null;
                depth -= 1;
            },
            .l_paren => {
                if (depth == 0) break;
                depth -= 1;
            },
            .comma => if (depth == 0) {
                position += 1;
            },
            .semicolon => return null,
            else => {},
        }
    } else return null;
    if (cursor == 0 or tokens[cursor - 1].tag != .identifier) return null;
    if (cursor >= 2 and tokens[cursor - 2].tag == .keyword_fn) return null;
    return .{ .name = cursor - 1, .position = position };
}

/// `const temporary = arena_state.allocator();` before the container.
fn allocatorAliasesArena(context: RuleRun, constants: *Constants, allocator_name: ?[]const u8, before: usize) !bool {
    const name = allocator_name orelse return false;
    const constant = try constants.lastBefore(context, name, before) orelse return false;
    for (context.tokens[constant.name + 2 .. constant.end]) |token| {
        if (token.tag == .identifier and std.ascii.findIgnoreCase(tokenText(context.source, token), "arena") != null) return true;
    }
    return false;
}

/// The identifiers spelled like a container in its block. Blocks are
/// scanned until the scans have read as many tokens as the file holds; from
/// then on the file's identifier table, which costs about a pass over the
/// file to build, answers, so a file with few containers never builds it.
const Occurrences = struct {
    table: ?*const syntax_scope.IdentifierTable = null,
    scanned: usize = 0,
    found: std.ArrayList(u32) = .empty,

    fn deinit(occurrences: *Occurrences, allocator: std.mem.Allocator) void {
        occurrences.found.deinit(allocator);
    }

    /// The identifiers spelled exactly `name` in `[start, end)`, in order,
    /// valid until the next call.
    fn within(occurrences: *Occurrences, context: RuleRun, name: []const u8, start: usize, end: usize) ![]const u32 {
        if (occurrences.table == null and occurrences.scanned >= context.tokens.len) {
            occurrences.table = try context.scopes.identifiers();
        }
        if (occurrences.table) |table| return table.within(name, start, end);
        occurrences.scanned += end - start;
        occurrences.found.clearRetainingCapacity();
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, name)) try occurrences.found.append(context.allocator, @intCast(index));
        }
        return occurrences.found.items;
    }
};

/// The `const name =` declarations of the file. A lookup scans back from
/// its container until the scans have read as many tokens as the file
/// holds; from then on the declarations, collected by spelling in one pass,
/// answer.
const Constants = struct {
    /// The name token of each declaration, by its spelling, in order.
    positions: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    built: bool = false,
    scanned: usize = 0,

    const Found = struct { name: usize, end: usize };

    fn deinit(constants: *Constants, allocator: std.mem.Allocator) void {
        var lists = constants.positions.valueIterator();
        while (lists.next()) |list| list.deinit(allocator);
        constants.positions.deinit(allocator);
    }

    /// The last `const name =` named at least six tokens before `before`
    /// whose statement ends, and that end.
    fn lastBefore(constants: *Constants, context: RuleRun, name: []const u8, before: usize) !?Found {
        const tokens = context.tokens;
        if (!constants.built and constants.scanned < tokens.len) {
            var index = before;
            defer constants.scanned += before - index;
            while (index > 1) {
                index -= 1;
                if (!context.tokenIs(index, name) or tokens[index - 1].tag != .keyword_const or
                    index + 5 >= before or tokens[index + 1].tag != .equal) continue;
                const end = context.statementEnd(index) orelse continue;
                return .{ .name = index, .end = end };
            }
            return null;
        }
        if (!constants.built) {
            for (1..tokens.len -| 1) |index| {
                if (tokens[index - 1].tag != .keyword_const or tokens[index + 1].tag != .equal) continue;
                const entry = try constants.positions.getOrPut(context.allocator, context.tokenText(index));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(context.allocator, @intCast(index));
            }
            constants.built = true;
        }
        const positions = (constants.positions.getPtr(name) orelse return null).items;
        // The candidates the scan back would meet, nearest first.
        var remaining = std.sort.partitionPoint(u32, positions, before -| 5, positionBefore);
        while (remaining > 0) {
            remaining -= 1;
            const index: usize = positions[remaining];
            const end = context.statementEnd(index) orelse continue;
            return .{ .name = index, .end = end };
        }
        return null;
    }
};

fn positionBefore(bound: usize, position: u32) bool {
    return position < bound;
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

/// Whether one of `uses`, the tokens spelled like the container in
/// `[start, end)`, releases it or transfers it whole. Every case names the
/// container at one token, so visiting the uses finds what a scan of the
/// block would.
fn hasDeinitOrTransfer(
    context: RuleRun,
    returns: *Returns,
    uses: []const u32,
    start: usize,
    end: usize,
) !bool {
    const tokens = context.tokens;
    for (uses) |use| {
        const index: usize = use;

        // Case 1: container.deinit(...) or container.clearAndFree(...)
        if (index + 2 < end and tokens[index + 1].tag == .period and tokens[index + 2].tag == .identifier) {
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

        // Case 3: stored whole through a field, a dereference or an element:
        // `.list = container`, `holder.list = container`, `dest.* = container`,
        // `slots[i] = container`.
        if (index > start and index >= 3 and index + 1 < end and tokens[index - 1].tag == .equal and
            !continuesPath(tokens[index + 1].tag))
        {
            switch (tokens[index - 2].tag) {
                .period_asterisk, .r_bracket => return true,
                .identifier => if (tokens[index - 3].tag == .period) return true,
                else => {},
            }
        }

        // Case 4: handed whole to a call, which takes its own copy:
        // `queue.push(container)`.
        if (index > 0 and index + 1 < end and
            (tokens[index - 1].tag == .l_paren or tokens[index - 1].tag == .comma) and
            (tokens[index + 1].tag == .r_paren or tokens[index + 1].tag == .comma) and
            callArgument(tokens, index) != null) return true;
    }
    // Case 2: return ... container_name ..., in a `return` statement that
    // starts in the block after the declaration.
    for (uses) |use| {
        const index: usize = use;
        // Sub-property access does not transfer the container backing storage,
        // unless the items are the whole allocation: `return list.items` once
        // `list.items.len == list.capacity` is checked hands over exactly what
        // the caller frees. A return statement holding the use ends at a `;`
        // or `}`, so after this `.items`.
        if (tokens[index + 1].tag == .period and
            (context.tokenIs(index + 2, "items") or context.tokenIs(index + 2, "capacity") or
                context.tokenIs(index + 2, "len")))
        {
            if (!context.tokenIs(index + 2, "items") or index + 3 >= end or tokens[index + 3].tag != .semicolon or
                !checksFullCapacity(context, uses, index)) continue;
        }
        if (try returns.openAt(context, start, index)) return true;
    }
    return false;
}

/// Whether a use of the container before `before` compares its length with
/// its capacity: `list.items.len == list.capacity`, either way round.
fn checksFullCapacity(context: RuleRun, uses: []const u32, before: usize) bool {
    const tokens = context.tokens;
    const name = context.tokenText(before);
    for (uses) |use| {
        const index: usize = use;
        if (index >= before) break;
        if (index + 8 >= tokens.len or tokens[index + 1].tag != .period) continue;
        const items_first = context.tokenIs(index + 2, "items") and tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "len");
        const capacity_first = context.tokenIs(index + 2, "capacity");
        const operator = if (items_first) index + 5 else if (capacity_first) index + 3 else continue;
        if (tokens[operator].tag != .equal_equal or !context.tokenIs(operator + 1, name) or
            tokens[operator + 2].tag != .period) continue;
        if (items_first and context.tokenIs(operator + 3, "capacity")) return true;
        if (capacity_first and context.tokenIs(operator + 3, "items") and operator + 5 < tokens.len and
            tokens[operator + 4].tag == .period and context.tokenIs(operator + 5, "len")) return true;
    }
    return false;
}

/// The file's `return` keywords in order, with a sparse table of the
/// furthest point their statements reach, so whether one starting in a range
/// is still open at a token takes two lookups. Built the first time a use
/// needs it.
const Returns = struct {
    positions: std.ArrayList(u32) = .empty,
    /// Level `k` (the `k`th run of `positions.len` entries) holds, for each
    /// return `i`, the furthest end among returns `i .. i + 2^k`. A statement
    /// with no `;` in its block runs to the end of the container's block,
    /// past every use.
    furthest: std.ArrayList(u32) = .empty,
    built: bool = false,

    fn deinit(returns: *Returns, allocator: std.mem.Allocator) void {
        returns.positions.deinit(allocator);
        returns.furthest.deinit(allocator);
    }

    fn build(returns: *Returns, context: RuleRun) !void {
        const allocator = context.allocator;
        for (context.tokens, 0..) |token, index| {
            if (token.tag != .keyword_return) continue;
            try returns.positions.append(allocator, @intCast(index));
            const statement_end = context.statementEnd(index) orelse std.math.maxInt(u32);
            try returns.furthest.append(allocator, @intCast(statement_end));
        }
        const count = returns.positions.items.len;
        var width: usize = 1;
        while (width * 2 <= count) : (width *= 2) {
            try returns.furthest.ensureUnusedCapacity(allocator, count);
            const previous = returns.furthest.items[returns.furthest.items.len - count ..];
            for (previous, 0..) |reach, index| {
                const next = if (index + width < count) previous[index + width] else reach;
                returns.furthest.appendAssumeCapacity(@max(reach, next));
            }
        }
    }

    /// Whether a `return` at or after `start` and before `index` begins a
    /// statement that reaches past `index`.
    fn openAt(returns: *Returns, context: RuleRun, start: usize, index: usize) !bool {
        if (!returns.built) {
            try returns.build(context);
            returns.built = true;
        }
        const positions = returns.positions.items;
        const first = std.sort.partitionPoint(u32, positions, start, positionBefore);
        const last = std.sort.partitionPoint(u32, positions, index, positionBefore);
        if (first >= last) return false;
        const level = std.math.log2_int(usize, last - first);
        const width = @as(usize, 1) << @intCast(level);
        const reaches = returns.furthest.items[level * positions.len ..][0..positions.len];
        return @max(reaches[first], reaches[last - width]) > index;
    }
};

/// Whether a token after a name keeps naming a part of it: `.items`, `[i]`, `(`.
fn continuesPath(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .period, .period_asterisk, .l_bracket, .l_paren => true,
        else => false,
    };
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

/// Whether the innermost block holding `declaration_index` is a function or
/// test body. The scope index finds a body by parsing its signature, so
/// braces in a return or parameter type (`error{...}!T`, `struct {...}`)
/// do not hide it, and a block after a `fn` type is not one.
fn insideFunctionOrTestBody(context: RuleRun, declaration_index: usize) bool {
    const opening = context.enclosingOpeningBrace(declaration_index) orelse return false;
    return context.scopes.braceKind(opening) == .function;
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

test "missing container deinit checks function bodies after braced signature types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn errorSetReturn(allocator: std.mem.Allocator) error{OutOfMemory}!void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    try list.append(allocator, 1);
        \\}
        \\fn structReturn(allocator: std.mem.Allocator) struct { x: u8 } {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    list.append(allocator, 1) catch {};
        \\    return .{ .x = 0 };
        \\}
        \\fn unionParameter(allocator: std.mem.Allocator, comptime x: union(enum) { a, b }) type {
        \\    _ = x;
        \\    var list: std.ArrayList(u32) = .empty;
        \\    list.append(allocator, 1) catch {};
        \\    return u8;
        \\}
        \\fn callbackBlock(allocator: std.mem.Allocator) !void {
        \\    const callback: *const fn () void = blk: {
        \\        var list: std.ArrayList(u32) = .empty;
        \\        try list.append(allocator, 1);
        \\        break :blk &noop;
        \\    };
        \\    callback();
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    // The first three bodies; the block after a `fn` type is a nested block,
    // which the rule leaves alone like any other.
    try std.testing.expectEqual(3, findings.len);
    const nested_block = std.mem.find(u8, source, "fn callbackBlock").?;
    for (findings) |finding| try std.testing.expect(finding.span.start < nested_block);
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

test "missing container deinit takes returned items filled to capacity as a transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source: [:0]const u8 =
        \\fn full(allocator: std.mem.Allocator, n: usize) ![]u8 {
        \\    var output: std.ArrayList(u8) = try .initCapacity(allocator, n);
        \\    output.appendAssumeCapacity('x');
        \\    std.debug.assert(output.items.len == output.capacity);
        \\    return output.items;
        \\}
        \\fn reversed(allocator: std.mem.Allocator, n: usize) ![]u8 {
        \\    var output: std.ArrayList(u8) = try .initCapacity(allocator, n);
        \\    output.appendAssumeCapacity('x');
        \\    std.debug.assert(output.capacity == output.items.len);
        \\    return output.items;
        \\}
        \\fn unchecked(allocator: std.mem.Allocator, n: usize) ![]u8 {
        \\    var output: std.ArrayList(u8) = try .initCapacity(allocator, n);
        \\    output.appendAssumeCapacity('x');
        \\    return output.items;
        \\}
        \\fn partial(allocator: std.mem.Allocator, n: usize) ![]u8 {
        \\    var output: std.ArrayList(u8) = try .initCapacity(allocator, n);
        \\    output.appendAssumeCapacity('x');
        \\    std.debug.assert(output.items.len == output.capacity);
        \\    return output.items[1..];
        \\}
    ;

    const findings = try support.findings(arena.allocator(), run, source, testConfiguration());

    try std.testing.expectEqual(2, findings.len);
    try std.testing.expectEqual(14, std.mem.countScalar(u8, source[0..findings[0].span.start], '\n') + 1);
    try std.testing.expectEqual(19, std.mem.countScalar(u8, source[0..findings[1].span.start], '\n') + 1);
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

test "build graph allocators and tests need no container deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Lib = struct { builder: *std.Build, fn libs(self: Lib) ![]const u8 {\n" ++
        "    var reserved: std.ArrayList(u8) = try .initCapacity(self.builder.allocator, 2);\n" ++
        "    reserved.appendAssumeCapacity(1);\n" ++
        "    return reserved.items;\n" ++
        "} };\n" ++
        "fn add(b: *std.Build) !void {\n" ++
        "    const alloc = b.allocator;\n" ++
        "    var aliased: std.ArrayList(u8) = .empty;\n" ++
        "    try aliased.append(alloc, 1);\n" ++
        "}\n" ++
        "test \"collects\" {\n" ++
        "    var collected: std.ArrayList(u8) = .empty;\n" ++
        "    try collected.append(std.testing.allocator, 1);\n" ++
        "}\n" ++
        "fn leak(gpa: std.mem.Allocator) !void {\n" ++
        "    var leaked: std.ArrayList(u8) = .empty;\n" ++
        "    try leaked.append(gpa, 1);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, testConfiguration());
    try support.expectSpans(source, found, &.{"leaked"});
}

test "containers stored whole, handed by value, or kept by a callee are transferred" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Holder = struct { list: std.ArrayList(u8) = .empty, map: std.AutoHashMapUnmanaged(u32, u32) = .empty };
        \\fn stored(gpa: std.mem.Allocator, holder: *Holder) void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    list.append(gpa, 1) catch return;
        \\    holder.list = list;
        \\}
        \\fn queued(gpa: std.mem.Allocator, queue: *Queue) !void {
        \\    var tables: std.ArrayList(u8) = .empty;
        \\    try tables.insertSlice(gpa, 0, "ab");
        \\    queue.pending.push(tables);
        \\}
        \\fn stash(holder: *Holder, list: *std.ArrayList(u8)) void {
        \\    holder.list = list.*;
        \\}
        \\fn stashed(gpa: std.mem.Allocator, holder: *Holder) !void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    try list.append(gpa, 1);
        \\    stash(holder, &list);
        \\}
        \\fn consume(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32)) void {
        \\    map.deinit(gpa);
        \\}
        \\fn consumed(gpa: std.mem.Allocator) !void {
        \\    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        \\    try map.put(gpa, 1, 2);
        \\    consume(gpa, &map);
        \\}
        \\fn fill(gpa: std.mem.Allocator, list: *std.ArrayList(u8)) !void {
        \\    try list.append(gpa, 2);
        \\}
        \\fn filled(gpa: std.mem.Allocator, holder: *Holder) !void {
        \\    var leaked: std.ArrayList(u8) = .empty;
        \\    try leaked.append(gpa, 1);
        \\    try fill(gpa, &leaked);
        \\    holder.list.items = leaked.items;
        \\}
    ;
    const found = try support.findings(arena.allocator(), run, source, testConfiguration());
    try support.expectSpans(source, found, &.{"leaked"});
}

test "fixed buffer and arena backed containers need no deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn direct() !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var list: std.ArrayList(u8) = .empty;
        \\    try list.append(fba.allocator(), 1);
        \\}
        \\fn aliased(gpa: std.mem.Allocator) !void {
        \\    var buffer: [64]u8 = undefined;
        \\    var instance: std.heap.FixedBufferAllocator = .init(&buffer);
        \\    const fixed = instance.allocator();
        \\    var list: std.ArrayList(u8) = .empty;
        \\    try list.append(fixed, 1);
        \\    var leaked: std.ArrayList(u8) = .empty;
        \\    try leaked.append(gpa, 1);
        \\}
        \\fn reserved(arena: std.mem.Allocator, count: usize) ![]const u8 {
        \\    var content: std.ArrayList(u8) = try .initCapacity(arena, count);
        \\    content.appendAssumeCapacity(1);
        \\    return try std.mem.join(arena, ",", &.{content.items});
        \\}
    ;
    const found = try support.findings(arena.allocator(), run, source, testConfiguration());
    try support.expectSpans(source, found, &.{"leaked"});
}

test "containers past the scanning budget are judged alike by the indexed lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Each container's scan reads the rest of the function, so the scans pass
    // the file's size within the first few containers, and the identifier
    // table and the collected constants answer for the rest.
    var source: std.Io.Writer.Allocating = .init(allocator);
    try source.writer.writeAll(
        \\const std = @import("std");
        \\fn consume(gpa: std.mem.Allocator, list: *std.ArrayList(u8)) void {
        \\    list.deinit(gpa);
        \\}
        \\fn fill(gpa: std.mem.Allocator, arena_state: *std.heap.ArenaAllocator, flag: bool) !?std.ArrayList(u8) {
        \\    const temporary = arena_state.allocator();
        \\
    );
    var expected: std.ArrayList([]const u8) = .empty;
    for (0..12) |index| {
        try source.writer.print(
            \\    var leaked{0d}: std.ArrayList(u8) = .empty;
            \\    try leaked{0d}.append(gpa, 1);
            \\    var kept{0d}: std.ArrayList(u8) = .empty;
            \\    defer kept{0d}.deinit(gpa);
            \\    try kept{0d}.append(gpa, 1);
            \\    var scratch{0d}: std.ArrayList(u8) = .empty;
            \\    try scratch{0d}.append(temporary, 1);
            \\    var returned{0d}: std.ArrayList(u8) = .empty;
            \\    try returned{0d}.append(gpa, 1);
            \\    if (flag) return returned{0d};
            \\    var consumed{0d}: std.ArrayList(u8) = .empty;
            \\    try consumed{0d}.append(gpa, 1);
            \\    consume(gpa, &consumed{0d});
            \\
        , .{index});
        try expected.append(allocator, try allocator.print("leaked{d}", .{index}));
    }
    try source.writer.writeAll("    return null;\n}\n");
    const text = try allocator.dupeSentinel(u8, source.written(), 0);
    const found = try support.findings(allocator, run, text, testConfiguration());
    try support.expectSpans(text, found, expected.items);
}
