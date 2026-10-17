//! The one table of resource acquire/release knowledge: which calls hand out a
//! resource, which call gives it back, and how the declared `contracts.resources`
//! pairs join the built-in ones. Rules that reason about cleanup (missing,
//! discarded, error-only, late, unawaited tasks, unflushed writers) ask here
//! instead of keeping their own list.
const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const Syntax = @import("context.zig").Syntax;
const syntax_scope = @import("../syntax/scope.zig");
const tokens_util = @import("../syntax/tokens.zig");
const types = @import("types.zig");

pub const Kind = enum {
    /// File or directory handle opened through `std.Io.Dir`.
    io_handle,
    /// `std.Thread.spawn`, joined or detached.
    thread,
    /// Container or allocator whose `init` owns memory until `deinit`.
    managed,
    /// A pair declared in `contracts.resources`.
    contract,
};

pub const Pair = struct {
    /// Method or function name of the acquiring call.
    acquisition: []const u8,
    /// Method name that releases the resource.
    release: []const u8,
    alternative_release: ?[]const u8 = null,
    /// Text before the acquiring call's final `.` that a contract requires; built-in pairs accept any receiver.
    receiver: ?[]const u8 = null,
    kind: Kind,
};

const io_handles = [_][]const u8{
    "openFile",
    "createFile",
    "openFileAbsolute",
    "createFileAbsolute",
    "openDir",
    "openDirAbsolute",
};

const builtin = blk: {
    var pairs: [io_handles.len + 3]Pair = undefined;
    for (io_handles, 0..) |name, index| pairs[index] = .{ .acquisition = name, .release = "close", .kind = .io_handle };
    pairs[io_handles.len] = .{ .acquisition = "spawn", .release = "join", .alternative_release = "detach", .kind = .thread };
    pairs[io_handles.len + 1] = .{ .acquisition = "init", .release = "deinit", .kind = .managed };
    pairs[io_handles.len + 2] = .{ .acquisition = "initCapacity", .release = "deinit", .kind = .managed };
    break :blk pairs;
};

/// Type names that make an `init` call an owning resource.
pub const managed_types = [_][]const u8{
    "ArrayList",
    "ArrayHashMap",
    "AutoHashMap",
    "StringHashMap",
    "ArenaAllocator",
    "GeneralPurposeAllocator",
    // `std.Io.Writer.Allocating`, which owns the bytes written to it.
    "Allocating",
};

/// Calls that return a raw OS handle which must be closed.
pub const os_handle_acquisitions = [_][]const u8{
    "open",
    "openat",
    "socket",
    "dup",
    "dup2",
    "eventfd",
    "inotify_init1",
};

/// Method names whose call ends the life of the value they act on.
pub const release_methods = [_][]const u8{ "free", "destroy", "close", "deinit", "join", "detach", "unlock" };

/// What owns an `std.Io` task: the `Future` that `io.async` and
/// `io.concurrent` return, or a `Group` or `Select` that spawns tasks itself.
pub const TaskOwner = enum { future, group, select };

/// Whether calling `name` on a `Group` or `Select` spawns a task into it.
pub fn spawnsTask(name: []const u8) bool {
    return std.mem.eql(u8, name, "async") or std.mem.eql(u8, name, "concurrent");
}

/// Whether calling `name` on the owner finishes its pending tasks: `await`
/// or `cancel`, and for a `Select` also `awaitMany` and `cancelDiscard`.
pub fn finishesTask(owner: TaskOwner, name: []const u8) bool {
    if (std.mem.eql(u8, name, "await") or std.mem.eql(u8, name, "cancel")) return true;
    return owner == .select and (std.mem.eql(u8, name, "awaitMany") or std.mem.eql(u8, name, "cancelDiscard"));
}

/// Whether calling `name` on a buffered `std.Io` writer hands its buffered
/// bytes to the sink: the interface's `flush`, and the file writer's `end`
/// and `seekTo`, which flush first.
pub fn flushesWriter(name: []const u8) bool {
    return std.mem.eql(u8, name, "flush") or std.mem.eql(u8, name, "end") or std.mem.eql(u8, name, "seekTo");
}

/// Mutex methods that take a lock, with the method that gives it back. The
/// `std.Io` forms take the `Io` instance as their only argument.
const lock_pairs = [_]struct { lock: []const u8, unlock: []const u8 }{
    .{ .lock = "lock", .unlock = "unlock" },
    .{ .lock = "lockUncancelable", .unlock = "unlock" },
    .{ .lock = "lockShared", .unlock = "unlockShared" },
    .{ .lock = "lockSharedUncancelable", .unlock = "unlockShared" },
};

/// The unlock method for a mutex lock method, or null when `method` takes no lock.
pub fn lockRelease(method: []const u8) ?[]const u8 {
    for (lock_pairs) |pair| if (std.mem.eql(u8, method, pair.lock)) return pair.unlock;
    return null;
}

/// Methods whose result keeps the resource it is called on, or takes it over:
/// readers, writers and iterators over a handle, and the ownership moves of
/// managed containers. Returning or storing such a result transfers the resource;
/// any other method result (`readPositionalAll`, `stat`) leaves it with the caller.
const transferring_methods = [_][]const u8{
    "reader",
    "readerStreaming",
    "writer",
    "writerStreaming",
    "iterate",
    "iterateAssumeFirstIteration",
    "walk",
    "getHandle",
    "allocator",
    "toOwnedSlice",
    "toOwnedSliceSentinel",
    "moveToUnmanaged",
    "toUnmanaged",
    "toManaged",
};

pub fn methodTransfersResource(method: []const u8) bool {
    for (transferring_methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

/// Allocator methods whose result is released with `free` or `destroy`.
/// `print` and `printSentinel` are shared with writers; `uniqueAllocationRelease`
/// leaves them out.
const allocation_methods = [_]struct { method: []const u8, release: []const u8, shared_name: bool = false }{
    .{ .method = "alloc", .release = "free" },
    .{ .method = "allocSentinel", .release = "free" },
    .{ .method = "alignedAlloc", .release = "free" },
    .{ .method = "dupe", .release = "free" },
    .{ .method = "dupeZ", .release = "free" },
    .{ .method = "dupeSentinel", .release = "free" },
    .{ .method = "print", .release = "free", .shared_name = true },
    .{ .method = "printSentinel", .release = "free", .shared_name = true },
    .{ .method = "realloc", .release = "free" },
    .{ .method = "create", .release = "destroy" },
};

/// Allocator methods that take an element count, with the argument position
/// counted from the end of the call.
pub const SizedAllocation = struct { method: []const u8, length_from_end: usize = 1 };

pub const sized_allocations = [_]SizedAllocation{
    .{ .method = "alloc" },
    .{ .method = "allocSentinel", .length_from_end = 2 },
    .{ .method = "alignedAlloc" },
    .{ .method = "realloc" },
};

/// Whether the allocator expression `path`, as written at `use_index`, is the
/// arena `std.Build` owns: `b.allocator` on a `*std.Build`, the allocator of a
/// field or binding declared with a `Build` type (`self.builder.allocator`,
/// `step.owner.allocator`), or a local alias of one. The build graph frees it,
/// so its allocations need no release.
pub fn buildGraphAllocator(
    source: []const u8,
    tokens: []const std.zig.Token,
    scopes: *const syntax_scope.Index,
    path: []const u8,
    use_index: usize,
) bool {
    var current = path;
    var position = use_index;
    // At most one alias, `const alloc = b.allocator;`, sits between the use and the build allocator.
    for (0..2) |_| {
        const dot = std.mem.findScalarLast(u8, current, '.') orelse {
            const binding = scopes.findBindingNamed(current, position) orelse return false;
            current = aliasedPath(source, tokens, binding.token_index) orelse return false;
            position = binding.token_index;
            continue;
        };
        if (!std.mem.eql(u8, current[dot + 1 ..], "allocator")) return false;
        const owner_path = current[0..dot];
        const root_end = std.mem.findScalar(u8, owner_path, '.') orelse owner_path.len;
        const root = scopes.findBindingNamed(owner_path[0..root_end], position) orelse return false;
        if (declaredTypeNamesBuild(source, tokens, root.token_index)) return true;
        const owner_dot = std.mem.findScalarLast(u8, owner_path, '.') orelse return false;
        return fieldTypeNamesBuild(source, tokens, owner_path[owner_dot + 1 ..]);
    }
    return false;
}

/// Whether the allocator argument starting at `first` comes from an arena or a
/// `FixedBufferAllocator` instance, which give back their memory all at once:
/// `fba.allocator()`, or a `const` alias of it.
pub fn allocatorFreesWholesale(context: RuleRun, first: usize) bool {
    const tokens = context.tokens;
    var instance = first;
    if (!allocatorCall(context, first)) {
        if (tokens[first + 1].tag != .r_paren and tokens[first + 1].tag != .comma) return false;
        const alias = context.scopes.findBinding(first) orelse return false;
        const declaration = alias.token_index;
        if (declaration == 0 or tokens[declaration - 1].tag != .keyword_const or tokens[declaration + 1].tag != .equal or
            !allocatorCall(context, declaration + 2) or tokens[declaration + 7].tag != .semicolon) return false;
        instance = declaration + 2;
    }
    const binding = context.scopes.findBinding(instance) orelse return false;
    // The instance's type or initializer, up to the first argument or the end
    // of its declaration or parameter.
    for (tokens[binding.token_index + 1 ..], binding.token_index + 1..) |token, index| switch (token.tag) {
        .semicolon, .comma, .r_paren, .l_brace, .r_brace, .eof => return false,
        .identifier => if (context.tokenIs(index, "FixedBufferAllocator") or context.tokenIs(index, "ArenaAllocator")) return true,
        else => {},
    };
    return false;
}

/// `instance.allocator()` starting at `index`.
fn allocatorCall(context: RuleRun, index: usize) bool {
    const tokens = context.tokens;
    return index + 4 < tokens.len and tokens[index].tag == .identifier and tokens[index + 1].tag == .period and
        context.tokenIs(index + 2, "allocator") and tokens[index + 3].tag == .l_paren and tokens[index + 4].tag == .r_paren;
}

/// The dotted path a `const name = a.b;` declaration at `binding_index` aliases.
fn aliasedPath(source: []const u8, tokens: []const std.zig.Token, binding_index: usize) ?[]const u8 {
    if (binding_index + 2 >= tokens.len or tokens[binding_index + 1].tag != .equal) return null;
    var end = binding_index + 2;
    while (end + 2 < tokens.len and tokens[end].tag == .identifier and tokens[end + 1].tag == .period) end += 2;
    if (tokens[end].tag != .identifier or end + 1 >= tokens.len or tokens[end + 1].tag != .semicolon) return null;
    return source[tokens[binding_index + 2].loc.start..tokens[end].loc.end];
}

/// Whether the `name: Type` declaration at `binding_index` spells `Build` in its type.
fn declaredTypeNamesBuild(source: []const u8, tokens: []const std.zig.Token, binding_index: usize) bool {
    if (binding_index + 1 >= tokens.len or tokens[binding_index + 1].tag != .colon) return false;
    for (tokens[binding_index + 2 ..]) |token| switch (token.tag) {
        .comma, .r_paren, .equal, .semicolon, .l_brace, .r_brace => return false,
        .identifier => if (tokens_util.tokenIs(source, token, "Build")) return true,
        else => {},
    };
    return false;
}

/// Whether some field or parameter named `name` is declared with a `Build` type.
fn fieldTypeNamesBuild(source: []const u8, tokens: []const std.zig.Token, name: []const u8) bool {
    for (tokens, 0..) |token, index| {
        if (token.tag == .identifier and tokens_util.tokenIs(source, token, name) and
            declaredTypeNamesBuild(source, tokens, index)) return true;
    }
    return false;
}

/// The release for an allocator method, or null when the method does not allocate.
pub fn allocationRelease(method: []const u8) ?[]const u8 {
    for (allocation_methods) |entry| if (std.mem.eql(u8, method, entry.method)) return entry.release;
    return null;
}

/// `allocationRelease` for rules that cannot prove the receiver is an allocator:
/// skips the names that writers share (`print`).
pub fn uniqueAllocationRelease(method: []const u8) ?[]const u8 {
    for (allocation_methods) |entry| {
        if (!entry.shared_name and std.mem.eql(u8, method, entry.method)) return entry.release;
    }
    return null;
}

pub fn isReleaseMethod(name: []const u8) bool {
    for (release_methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

/// The pair acquired by calling `name` on `receiver` (the text before the call's
/// final `.`, null for a bare call). Declared contracts win over built-in pairs.
pub fn lookup(configuration: types.Configuration, name: []const u8, receiver: ?[]const u8) ?Pair {
    if (contract(configuration, name, receiver)) |pair| return pair;
    for (builtin) |pair| if (std.mem.eql(u8, pair.acquisition, name)) return pair;
    return null;
}

/// The declared `contracts.resources` pair acquired by this call, if any. A
/// qualified contract (`Db.open`) needs the same receiver; a bare one (`open`) a bare call.
pub fn contract(configuration: types.Configuration, name: []const u8, receiver: ?[]const u8) ?Pair {
    for (configuration.resource_contracts) |declared| {
        const separator = std.mem.findScalarLast(u8, declared.acquire, '.');
        const acquired_name = if (separator) |position| declared.acquire[position + 1 ..] else declared.acquire;
        if (!std.mem.eql(u8, acquired_name, name)) continue;
        if (separator) |position| {
            const actual = receiver orelse continue;
            if (!std.mem.eql(u8, declared.acquire[0..position], actual)) continue;
        } else if (receiver != null) continue;
        const release_separator = std.mem.findScalarLast(u8, declared.release, '.');
        return .{
            .acquisition = acquired_name,
            .release = if (release_separator) |position| declared.release[position + 1 ..] else declared.release,
            .receiver = if (separator) |position| declared.acquire[0..position] else null,
            .kind = .contract,
        };
    }
    return null;
}

/// Source text of the dotted path before the call at `call_index`, e.g. `Db` for `Db.open(`.
pub fn callReceiver(source: []const u8, tokens: []const std.zig.Token, call_index: usize) ?[]const u8 {
    if (call_index < 2 or tokens[call_index - 1].tag != .period or tokens[call_index - 2].tag != .identifier) return null;
    var start = call_index - 2;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return source[tokens[start].loc.start..tokens[call_index - 2].loc.end];
}

/// Whether the call at `call_index` really acquires `pair`: `init` only owns
/// memory next to a managed type, `spawn` only on a thread; `start` bounds the
/// initializer that is searched for those hints.
pub fn acquires(pair: Pair, source: []const u8, tokens: []const std.zig.Token, start: usize, call_index: usize) bool {
    switch (pair.kind) {
        .thread => return namesAny(source, tokens, start, call_index, &.{"Thread"}),
        .managed => return namesAny(source, tokens, start, call_index, &managed_types),
        .io_handle, .contract => return true,
    }
}

fn namesAny(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize, names: []const []const u8) bool {
    for (tokens[start..end]) |token| {
        if (token.tag != .identifier) continue;
        for (names) |name| if (tokens_util.tokenIs(source, token, name)) return true;
    }
    return false;
}

/// The first resource acquired by a call inside `tokens[start..end]`.
pub fn acquiredIn(context: RuleRun, start: usize, end: usize) ?Pair {
    // The hints `acquires` looks for in `[start, call)`, extended as the
    // calls advance so that a long initializer is read once.
    var hinted_until = start;
    var names_thread = false;
    var names_managed = false;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 1 >= end or context.tokens[index + 1].tag != .l_paren) continue;
        const pair = lookup(context.configuration, context.tokenText(index), callReceiver(context.source, context.tokens, index)) orelse continue;
        while (hinted_until < index) : (hinted_until += 1) {
            names_thread = names_thread or namesAny(context.source, context.tokens, hinted_until, hinted_until + 1, &.{"Thread"});
            names_managed = names_managed or namesAny(context.source, context.tokens, hinted_until, hinted_until + 1, &managed_types);
        }
        const acquired = switch (pair.kind) {
            .thread => names_thread,
            .managed => names_managed,
            .io_handle, .contract => true,
        };
        if (acquired) return pair;
    }
    return null;
}

test "built-in pairs cover io handles threads and managed containers" {
    const defaults = types.Configuration.defaults();
    try std.testing.expectEqualStrings("close", lookup(defaults, "openDirAbsolute", null).?.release);
    try std.testing.expectEqualStrings("detach", lookup(defaults, "spawn", "std.Thread").?.alternative_release.?);
    try std.testing.expectEqual(Kind.managed, lookup(defaults, "initCapacity", "std.ArrayList").?.kind);
    try std.testing.expect(lookup(defaults, "openIterableDir", null) == null);
}

test "lock pairs and transferring methods" {
    try std.testing.expectEqualStrings("unlock", lockRelease("lockUncancelable").?);
    try std.testing.expectEqualStrings("unlockShared", lockRelease("lockShared").?);
    try std.testing.expect(lockRelease("tryLock") == null);
    try std.testing.expect(methodTransfersResource("reader"));
    try std.testing.expect(!methodTransfersResource("readPositionalAll"));
}

test "build graph allocators are found through bindings fields and aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Lib = struct { builder: *std.Build, owner: *Other };\n" ++
        "fn f(b: *std.Build, lib: Lib, gpa: std.mem.Allocator) void { const alias = b.allocator; _ = .{ alias, lib, gpa }; }";
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var scopes = try syntax_scope.Index.init(arena.allocator(), source, tokens);
    // The `gpa` in `.{ alias, lib, gpa }`, where every binding is visible.
    const use = tokens.len - 5;
    try std.testing.expect(tokens_util.tokenIs(source, tokens[use], "gpa"));
    try std.testing.expect(buildGraphAllocator(source, tokens, &scopes, "b.allocator", use));
    try std.testing.expect(buildGraphAllocator(source, tokens, &scopes, "lib.builder.allocator", use));
    try std.testing.expect(buildGraphAllocator(source, tokens, &scopes, "alias", use));
    try std.testing.expect(!buildGraphAllocator(source, tokens, &scopes, "lib.owner.allocator", use));
    try std.testing.expect(!buildGraphAllocator(source, tokens, &scopes, "gpa", use));
    try std.testing.expect(!buildGraphAllocator(source, tokens, &scopes, "b.graph", use));
}

test "declared contracts win and respect their receiver" {
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{
        .{ .acquire = "Db.open", .release = "Db.close" },
        .{ .acquire = "connect", .release = "disconnect" },
    };
    const qualified = lookup(configuration, "open", "Db").?;
    try std.testing.expectEqualStrings("close", qualified.release);
    try std.testing.expectEqual(Kind.contract, qualified.kind);
    try std.testing.expect(lookup(configuration, "open", "Other") == null);
    try std.testing.expect(lookup(configuration, "open", null) == null);
    try std.testing.expectEqualStrings("disconnect", lookup(configuration, "connect", null).?.release);
    try std.testing.expect(lookup(configuration, "connect", "Db") == null);
}

test "allocation releases distinguish shared writer names" {
    try std.testing.expectEqualStrings("destroy", allocationRelease("create").?);
    try std.testing.expect(uniqueAllocationRelease("print") == null);
    try std.testing.expectEqualStrings("free", allocationRelease("print").?);
    try std.testing.expect(allocationRelease("append") == null);
}

test "task owners and buffered writers name their releases" {
    try std.testing.expect(spawnsTask("concurrent") and !spawnsTask("await"));
    try std.testing.expect(finishesTask(.future, "cancel") and !finishesTask(.group, "cancelDiscard"));
    try std.testing.expect(finishesTask(.select, "cancelDiscard") and finishesTask(.select, "awaitMany"));
    try std.testing.expect(flushesWriter("end") and !flushesWriter("writeAll"));
}

test "acquiredIn applies declared pairs inside an initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const source: [:0]const u8 = "const connection = try Db.open();";
    const tokens = try tokens_util.tokenize(arena.allocator(), source);
    var syntax = try Syntax.init(arena.allocator(), source, tokens);
    var found: std.ArrayList(types.Finding) = .empty;
    const context = syntax.ruleRun(arena.allocator(), configuration, &found);
    try std.testing.expectEqualStrings("Db", callReceiver(source, tokens, 6).?);
    try std.testing.expectEqualStrings("close", acquiredIn(context, 3, 9).?.release);
    try std.testing.expect(acquiredIn(context, 3, 4) == null);
}
