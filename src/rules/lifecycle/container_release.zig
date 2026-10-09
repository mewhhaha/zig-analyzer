//! Containers, arenas and owning structs used or released again after `deinit`.
//!
//! The allocation engine tracks `alloc`/`dupe` results; this pass covers the
//! values that release themselves with `deinit`: any std container (identified
//! through `container_types`), an `ArenaAllocator`, and local structs with a
//! `deinit` method. It reports under `use_after_release` and `double_release`.

const std = @import("std");
const RuleRun = @import("../context.zig").RuleRun;
const types = @import("../types.zig");
const support = @import("../test_support.zig");
const container_types = @import("../container_types.zig");
const reach = @import("reach.zig");
const views = @import("invalidated_container_view.zig");

pub fn run(context: RuleRun) !void {
    const use_level = context.level(.use_after_release);
    const double_level = context.level(.double_release);
    if (use_level == .off and double_level == .off) return;
    var owners = try ownerTypes(context);
    defer owners.deinit(context.allocator);
    for (context.tokens, 0..) |token, declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration + 3 >= context.tokens.len or
            context.tokens[declaration + 1].tag != .identifier or
            (context.tokens[declaration + 2].tag != .equal and context.tokens[declaration + 2].tag != .colon)) continue;
        const declaration_end = context.statementEnd(declaration) orelse continue;
        const subject = releasable(context, &owners, declaration, declaration_end) orelse continue;
        const scope_opening = context.enclosingOpeningBrace(declaration) orelse continue;
        const scope_end = context.matchingToken(scope_opening, .l_brace, .r_brace) orelse continue;
        try checkReleases(context, declaration + 1, declaration_end + 1, scope_end, subject, use_level, double_level);
        if (subject == .arena) try checkArenaAllocations(context, declaration + 1, declaration_end + 1, scope_end, use_level);
        if (subject != .arena) try checkCopies(context, declaration + 1, declaration_end + 1, scope_end, double_level);
    }
}

/// File-local type names mapped to whether the type declares `deinit`; the
/// first declaration of a name wins.
const Owners = std.StringHashMapUnmanaged(bool);

fn ownerTypes(context: RuleRun) !Owners {
    var owners: Owners = .empty;
    errdefer owners.deinit(context.allocator);
    for (context.tokens, 0..) |token, name_index| {
        if (token.tag != .identifier or name_index == 0 or context.tokens[name_index - 1].tag != .keyword_const) continue;
        const entry = try owners.getOrPut(context.allocator, context.tokenText(name_index));
        if (entry.found_existing) continue;
        entry.value_ptr.* = false;
        var opening = name_index + 1;
        while (opening < context.tokens.len and opening - name_index < 8 and context.tokens[opening].tag != .l_brace) : (opening += 1) {}
        if (opening >= context.tokens.len or context.tokens[opening].tag != .l_brace) continue;
        const closing = context.matchingToken(opening, .l_brace, .r_brace) orelse continue;
        for (context.tokens[opening + 1 .. closing], opening + 1..) |inner, function_index| {
            if (inner.tag == .keyword_fn and function_index + 1 < closing and context.tokenIs(function_index + 1, "deinit")) {
                entry.value_ptr.* = true;
                break;
            }
        }
    }
    return owners;
}

const Subject = enum { container, arena, owner };

fn subjectNoun(subject: Subject) []const u8 {
    return switch (subject) {
        .container => "container",
        .arena => "arena",
        .owner => "value",
    };
}

/// What kind of self-releasing value a declaration holds, if any.
fn releasable(context: RuleRun, owners: *const Owners, declaration: usize, declaration_end: usize) ?Subject {
    if (container_types.declaredKind(context.source, context.tokens, declaration, declaration_end) != null) return .container;
    const start = declaration + 2;
    if (headNames(context, start, declaration_end, "ArenaAllocator")) return .arena;
    if (ownerTypeName(context, declaration, declaration_end)) |name| {
        if (owners.get(name) orelse false) return .owner;
    }
    return null;
}

fn headNames(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name)) return true;
        if (token.tag == .l_paren or token.tag == .l_brace) return false;
    }
    return false;
}

/// `: T` annotation, `T{..}` or `T.init(..)` head of a declaration.
fn ownerTypeName(context: RuleRun, declaration: usize, declaration_end: usize) ?[]const u8 {
    var cursor = declaration + 2;
    if (context.tokens[cursor].tag == .colon) {
        cursor += 1;
    } else if (context.tokens[cursor].tag == .equal) {
        cursor += 1;
        if (cursor < declaration_end and context.tokens[cursor].tag == .keyword_try) cursor += 1;
    } else return null;
    if (cursor + 1 >= declaration_end or context.tokens[cursor].tag != .identifier) return null;
    const next = context.tokens[cursor + 1].tag;
    if (next == .l_brace or next == .period or next == .equal) return context.tokenText(cursor);
    return null;
}

const Mention = struct { index: usize, kind: enum { release, assignment, use } };

fn checkReleases(
    context: RuleRun,
    name_index: usize,
    start: usize,
    scope_end: usize,
    subject: Subject,
    use_level: types.Level,
    double_level: types.Level,
) !void {
    const name = context.tokenText(name_index);
    for (context.tokens[start..scope_end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.tokens[index - 1].tag == .period) continue;
        const release = releaseCall(context, index, scope_end) orelse continue;
        const keyword = statementKeyword(context, index);
        if (keyword == .keyword_errdefer) continue;
        if (keyword == .keyword_defer) continue;
        const call_end = reach.callEnd(context, release) orelse continue;
        var fresh = false;
        // The first later mention that control flow can reach decides.
        var cursor = call_end + 1;
        while (cursor < scope_end) : (cursor += 1) {
            if (!context.tokenIs(cursor, name) or context.tokens[cursor].tag != .identifier or
                context.tokens[cursor - 1].tag == .period or !reach.mutationReaches(context, index, cursor)) continue;
            if (context.tokens[cursor - 1].tag == .keyword_const or context.tokens[cursor - 1].tag == .keyword_var) {
                fresh = true;
                break;
            }
            if (cursor + 1 < scope_end and context.tokens[cursor + 1].tag == .equal) {
                fresh = true;
                break;
            }
            if (releaseCall(context, cursor, scope_end) != null) {
                if (statementKeyword(context, cursor) == .keyword_errdefer) continue;
                try context.emit(.{
                    .rule = .double_release,
                    .level = double_level,
                    .span = context.tokens[cursor].loc,
                    .message = try context.allocator.print(
                        "{s} '{s}' is already deinitialized; this releases it a second time",
                        .{ subjectNoun(subject), name },
                    ),
                });
            } else {
                if (reach.harmlessUse(context, cursor)) continue;
                try context.emit(.{
                    .rule = .use_after_release,
                    .level = use_level,
                    .span = context.tokens[cursor].loc,
                    .message = try context.allocator.print(
                        "{s} '{s}' is used after its deinit",
                        .{ subjectNoun(subject), name },
                    ),
                });
            }
            break;
        }
        if (fresh) continue;
        // A `defer deinit` registered before the explicit release (or reached
        // after it) releases the value a second time.
        if (deferredReleaseAfter(context, name, name_index, index, scope_end)) |deferred| {
            try context.emit(.{
                .rule = .double_release,
                .level = double_level,
                .span = context.tokens[index].loc,
                .message = try context.allocator.print(
                    "{s} '{s}' is deinitialized here and again by the deferred deinit at line {d}",
                    .{ subjectNoun(subject), name, lineOf(context, deferred) },
                ),
            });
        }
    }
}

/// The method token when `name_index` starts `name.deinit(`.
fn releaseCall(context: RuleRun, name_index: usize, end: usize) ?usize {
    if (name_index + 3 >= end or context.tokens[name_index + 1].tag != .period or
        !context.tokenIs(name_index + 2, "deinit") or context.tokens[name_index + 3].tag != .l_paren) return null;
    return name_index + 2;
}

fn statementKeyword(context: RuleRun, index: usize) ?std.zig.Token.Tag {
    const keyword = reach.deferKeyword(context, index) orelse return null;
    return context.tokens[keyword].tag;
}

fn deferredReleaseAfter(context: RuleRun, name: []const u8, declaration: usize, release: usize, scope_end: usize) ?usize {
    for (context.tokens[declaration..scope_end], declaration..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or index == release or
            context.tokens[index - 1].tag == .period or releaseCall(context, index, scope_end) == null) continue;
        const keyword = reach.deferKeyword(context, index) orelse continue;
        if (context.tokens[keyword].tag != .keyword_defer) continue;
        if (keyword < release) {
            // Registered earlier: runs on every exit from its own scope, which encloses the release.
            const defer_scope = context.enclosingOpeningBrace(keyword) orelse continue;
            const defer_end = context.matchingToken(defer_scope, .l_brace, .r_brace) orelse continue;
            if (release < defer_end and release > defer_scope and !reassignedBetween(context, name, release, defer_end)) return index;
        } else if (reach.mutationReaches(context, release, keyword) and !reassignedBetween(context, name, release, keyword)) {
            return index;
        }
    }
    return null;
}

fn reassignedBetween(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and context.tokenIs(index, name) and index + 1 < end and
            context.tokens[index + 1].tag == .equal and context.tokens[index - 1].tag != .period) return true;
    }
    return false;
}

fn lineOf(context: RuleRun, index: usize) usize {
    return std.mem.countScalar(u8, context.source[0..context.tokens[index].loc.start], '\n') + 1;
}

/// `const b = a;` followed by deinit of both: the copy and the original share
/// the same storage.
fn checkCopies(
    context: RuleRun,
    name_index: usize,
    start: usize,
    scope_end: usize,
    double_level: types.Level,
) !void {
    const name = context.tokenText(name_index);
    for (context.tokens[start..scope_end], start..) |token, copy| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or copy + 4 >= scope_end or
            context.tokens[copy + 1].tag != .identifier or context.tokens[copy + 2].tag != .equal or
            !context.tokenIs(copy + 3, name) or context.tokens[copy + 4].tag != .semicolon) continue;
        const copy_name = context.tokenText(copy + 1);
        const original_release = firstPlainRelease(context, name, copy + 5, scope_end) orelse continue;
        const copy_release = firstPlainRelease(context, copy_name, copy + 5, scope_end) orelse continue;
        if (reassignedBetween(context, name, copy + 5, scope_end) or reassignedBetween(context, copy_name, copy + 5, scope_end)) continue;
        const later = @max(original_release, copy_release);
        const later_name = if (later == copy_release) copy_name else name;
        const other_name = if (later == copy_release) name else copy_name;
        try context.emit(.{
            .rule = .double_release,
            .level = double_level,
            .span = context.tokens[later].loc,
            .message = try context.allocator.print(
                "'{s}' is a by-value copy of '{s}', which is also deinitialized; releasing both frees the same storage twice",
                .{ later_name, other_name },
            ),
        });
    }
}

/// A `name.deinit(` that is a plain call or a `defer`, not an `errdefer`.
fn firstPlainRelease(context: RuleRun, name: []const u8, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.tokens[index - 1].tag == .period or
            releaseCall(context, index, end) == null or statementKeyword(context, index) == .keyword_errdefer) continue;
        return index;
    }
    return null;
}

/// Allocations from an arena's allocator that are read after `arena.deinit()`.
fn checkArenaAllocations(
    context: RuleRun,
    arena_index: usize,
    start: usize,
    scope_end: usize,
    use_level: types.Level,
) !void {
    const arena = context.tokenText(arena_index);
    var release: ?usize = null;
    for (context.tokens[start..scope_end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, arena) or context.tokens[index - 1].tag == .period or
            releaseCall(context, index, scope_end) == null or statementKeyword(context, index) != null) continue;
        release = index;
        break;
    }
    const release_index = release orelse return;
    const release_end = context.statementEnd(release_index) orelse return;
    for (context.tokens[start..release_index], start..) |token, declaration| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or context.tokens[declaration + 1].tag != .identifier) continue;
        const declaration_end = context.statementEnd(declaration) orelse continue;
        if (declaration_end >= release_index) continue;
        const allocator = views.allocationReceiver(context, declaration + 2, declaration_end) orelse continue;
        const owner = views.arenaForAllocatorAlias(context, allocator, declaration) orelse continue;
        if (!std.mem.eql(u8, owner, arena)) continue;
        const binding = context.tokenText(declaration + 1);
        const use = firstUse(context, binding, release_index, release_end + 1, scope_end) orelse continue;
        try context.emit(.{
            .rule = .use_after_release,
            .level = use_level,
            .span = context.tokens[use].loc,
            .message = try context.allocator.print(
                "allocation '{s}' belongs to arena '{s}', which is already deinitialized",
                .{ binding, arena },
            ),
        });
    }
}

fn firstUse(context: RuleRun, name: []const u8, release: usize, start: usize, end: usize) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or context.tokens[index - 1].tag == .period or
            !reach.mutationReaches(context, release, index)) continue;
        if (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var) return null;
        if (index + 1 < end and context.tokens[index + 1].tag == .equal) return null;
        if (reach.harmlessUse(context, index)) continue;
        return index;
    }
    return null;
}

fn expectRules(source: [:0]const u8, expected: []const types.Rule) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    try support.expectRules(found, expected);
}

test "a container used after deinit reports use-after-release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; l.deinit(gpa); try l.append(gpa, 1); }",
        &.{.use_after_release},
    );
}

test "a hash map used after deinit reports use-after-release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var m: std.AutoHashMapUnmanaged(u32, u32) = .empty; m.deinit(gpa); try m.put(gpa, 1, 1); }",
        &.{.use_after_release},
    );
}

test "an explicit deinit plus a deferred deinit is a double release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; defer l.deinit(gpa); try l.append(gpa, 1); l.deinit(gpa); }",
        &.{.double_release},
    );
}

test "two explicit deinits are a double release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) void { var l: std.ArrayList(u8) = .empty; l.deinit(gpa); l.deinit(gpa); }",
        &.{.double_release},
    );
}

test "reinitializing between releases is fine" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; l.deinit(gpa); l = .empty; try l.append(gpa, 1); l.deinit(gpa); }",
        &.{},
    );
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; l.deinit(gpa); l = .empty; defer l.deinit(gpa); try l.append(gpa, 1); }",
        &.{},
    );
}

test "a release in a returning branch does not taint the sibling branch" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator, c: bool) !void { var l: std.ArrayList(u8) = .empty; if (c) { l.deinit(gpa); return; } else { try l.append(gpa, 1); } l.deinit(gpa); }",
        &.{},
    );
    try expectRules(
        "fn f(gpa: std.mem.Allocator, c: bool) !void { var l: std.ArrayList(u8) = .empty; if (c) { l.deinit(gpa); } else { try l.append(gpa, 1); l.deinit(gpa); } }",
        &.{},
    );
}

test "arena allocations used after arena deinit report" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var arena = std.heap.ArenaAllocator.init(gpa); const a = arena.allocator(); const s = try a.dupe(u8, \"x\"); arena.deinit(); _ = s[0]; }",
        &.{.use_after_release},
    );
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var arena = std.heap.ArenaAllocator.init(gpa); const a = arena.allocator(); const s = try a.dupe(u8, \"x\"); consume(s); arena.deinit(); }",
        &.{},
    );
}

test "deinit through a by-value copy of an owning struct is a double release" {
    try expectRules(
        "const Owner = struct { n: u8, fn deinit(o: *Owner) void { _ = o; } };\n" ++
            "fn f() void { var a: Owner = .{ .n = 0 }; const b = a; a.deinit(); b.deinit(); }",
        &.{.double_release},
    );
    try expectRules(
        "const Owner = struct { n: u8, fn deinit(o: *Owner) void { _ = o; } };\n" ++
            "fn f() void { var a: Owner = .{ .n = 0 }; const b = a; a.deinit(); _ = b; }",
        &.{},
    );
}

test "deinit inside defer and errdefer blocks is not an explicit release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; errdefer { l.deinit(gpa); } try l.append(gpa, 1); }",
        &.{},
    );
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; var m: std.ArrayList(u8) = .empty; defer { l.deinit(gpa); m.deinit(gpa); } try l.append(gpa, 1); }",
        &.{},
    );
    try expectRules(
        "fn f(gpa: std.mem.Allocator) !void { var l: std.ArrayList(u8) = .empty; errdefer |e| { _ = e; l.deinit(gpa); } try l.append(gpa, 1); }",
        &.{},
    );
}

test "deinit inside a conditional defer is not an explicit release" {
    try expectRules(
        "fn f(gpa: std.mem.Allocator, keep: bool) !void { var l: std.ArrayList(u8) = .empty; var done = keep; defer if (!done) { l.deinit(gpa); }; try l.append(gpa, 1); done = true; }",
        &.{},
    );
}
