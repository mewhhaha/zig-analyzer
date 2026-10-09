//! Readies the build graphs a project check consults while resolving named
//! modules (`@import("name")`). Configuring a build runs its script, which
//! takes a fraction of a second to many seconds, so the check finds the
//! distinct build roots it needs, restores each one's stored module table
//! when its build inputs are unchanged, and configures the rest concurrently.
const std = @import("std");

const compile_units = @import("../compiler/compile_units.zig");
const tokens_util = @import("../syntax/tokens.zig");
const check_cache = @import("check_cache.zig");

/// Build configurations run at once. Each is a `zig build` process, so this
/// bounds the process count rather than the thread count.
const max_parallel_configurations = 8;

pub const File = struct {
    /// Absolute path.
    path: []const u8,
    source: []const u8,
    tokens: []const std.zig.Token,
};

/// The nearest build roots of the files that import a named module at the top
/// level, each once, in the order the files first need them. Owned by `arena`.
pub fn neededRoots(io: std.Io, arena: std.mem.Allocator, files: []const File) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    var seen_roots: std.StringHashMapUnmanaged(void) = .empty;
    // Directories already walked up to a build root (or to none).
    var directories: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    for (files) |file| {
        if (!importsNamedModule(file)) continue;
        const directory = std.Io.Dir.path.dirname(file.path) orelse continue;
        const known = try directories.getOrPut(arena, directory);
        if (!known.found_existing) {
            known.value_ptr.* = try compile_units.nearestBuildRoot(io, arena, file.path);
        }
        const root = known.value_ptr.* orelse continue;
        if ((try seen_roots.getOrPut(arena, root)).found_existing) continue;
        try roots.append(arena, root);
    }
    return roots.items;
}

/// Whether `file` has a top-level `@import("name")` of a module the build
/// defines. `std`, `builtin` and `root` are not looked up in the build.
fn importsNamedModule(file: File) bool {
    var depth: usize = 0;
    for (file.tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .builtin => {
                if (depth != 0 or index + 3 >= file.tokens.len or
                    !tokens_util.tokenIs(file.source, token, "@import") or
                    file.tokens[index + 1].tag != .l_paren or
                    file.tokens[index + 2].tag != .string_literal) continue;
                const literal = tokens_util.tokenText(file.source, file.tokens[index + 2]);
                if (literal.len < 2) continue;
                const name = literal[1 .. literal.len - 1];
                if (std.mem.endsWith(u8, name, ".zig")) continue;
                if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin") or std.mem.eql(u8, name, "root")) continue;
                return true;
            },
            else => {},
        }
    }
    return false;
}

const Shared = struct {
    io: std.Io,
    cache: check_cache.Cache,
    roots: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
};

/// Configures (or restores) the build of every root in `roots`, so lookups in
/// `.modules` mode find them ready. Failures are not reported here: a root
/// that cannot be prepared is looked up, and fails the same way, later.
pub fn prepare(io: std.Io, cache: check_cache.Cache, roots: []const []const u8) !void {
    if (roots.len == 0) return;
    var shared: Shared = .{ .io = io, .cache = cache, .roots = roots };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const workers = @min(roots.len, max_parallel_configurations);
    for (1..workers) |_| group.concurrent(io, work, .{&shared}) catch break;
    work(&shared);
    try group.await(io);
}

fn work(shared: *Shared) void {
    while (true) {
        const index = shared.next.fetchAdd(1, .monotonic);
        if (index >= shared.roots.len) return;
        prepareRoot(shared.io, shared.cache, shared.roots[index]) catch |err| switch (err) {
            error.Canceled => return,
            else => std.log.warn("build modules for '{s}' unavailable: {t}", .{ shared.roots[index], err }),
        };
    }
}

fn prepareRoot(io: std.Io, cache: check_cache.Cache, root: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const digest = try compile_units.buildDigest(io, arena, root);
    if (try cache.loadBuildModules(io, arena, root, digest)) |table| {
        if (try compile_units.restoreNamedModules(io, root, table)) return;
    }
    const graph = (try compile_units.buildGraph(io, root, .modules)) orelse return;
    graph.release();
    if (try compile_units.exportNamedModules(io, arena, root)) |table| {
        try cache.storeBuildModules(io, arena, root, digest, table);
    }
}
