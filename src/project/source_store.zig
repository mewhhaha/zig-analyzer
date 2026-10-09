//! Parsed files read from disk, shared by the lookups that run on every
//! keystroke (imported deprecations, module members): a dependency is read,
//! tokenized and scope-indexed once, and reused until it changes on disk. A
//! file counts as changed when its modification time, size or inode differ, so
//! a save is seen the next time anything asks for the file.
const std = @import("std");

const syntax_scope = @import("../syntax/scope.zig");
const tokens_util = @import("../syntax/tokens.zig");

const max_source_bytes = 16 * 1024 * 1024;
/// Source bytes kept before unused files are dropped.
const retained_bytes_limit = 192 * 1024 * 1024;

const Stamp = struct {
    modified: i96,
    size: u64,
    inode: u64,
};

/// One parsed file. Held by the store and by every caller that acquired it.
pub const Parsed = struct {
    references: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    scopes: syntax_scope.Index,
    stamp: Stamp,

    pub fn release(file: *Parsed) void {
        if (file.references.fetchSub(1, .acq_rel) != 1) return;
        const backing = file.arena.child_allocator;
        var arena = file.arena;
        arena.deinit();
        backing.destroy(file);
    }

    fn retain(file: *Parsed) *Parsed {
        _ = file.references.fetchAdd(1, .monotonic);
        return file;
    }
};

pub const Store = struct {
    /// Must be safe to use from several threads.
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    files: std.StringHashMapUnmanaged(*Parsed) = .empty,
    retained_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(store: *Store) void {
        var files = store.files.iterator();
        while (files.next()) |entry| {
            store.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.release();
        }
        store.files.deinit(store.allocator);
        store.* = undefined;
    }

    /// The current contents of the file at `path`, or null when it cannot be
    /// read. The caller releases the file.
    pub fn acquire(store: *Store, io: std.Io, path: []const u8) !?*Parsed {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => return null,
        };
        if (stat.kind != .file or stat.size > max_source_bytes) return null;
        const stamp: Stamp = .{ .modified = stat.mtime.nanoseconds, .size = stat.size, .inode = @intCast(stat.inode) };
        {
            try store.mutex.lock(io);
            defer store.mutex.unlock(io);
            if (store.files.get(path)) |known| {
                if (std.meta.eql(known.stamp, stamp)) return known.retain();
            }
        }
        // Parsing takes long enough to do without holding the store.
        const parsed = try parse(store.allocator, io, path, stamp) orelse return null;
        errdefer parsed.release();
        try store.mutex.lock(io);
        defer store.mutex.unlock(io);
        const entry = try store.files.getOrPut(store.allocator, path);
        if (entry.found_existing) {
            store.retained_bytes -|= entry.value_ptr.*.source.len;
            entry.value_ptr.*.release();
        } else {
            entry.key_ptr.* = try store.allocator.dupe(u8, path);
        }
        entry.value_ptr.* = parsed;
        store.retained_bytes += parsed.source.len;
        if (store.retained_bytes > retained_bytes_limit) store.dropOthers(parsed);
        return parsed.retain();
    }

    /// Forgets every file but `keep`; holders keep the ones they use alive.
    fn dropOthers(store: *Store, keep: *Parsed) void {
        var kept_bytes: usize = 0;
        var files = store.files.iterator();
        while (files.next()) |entry| {
            if (entry.value_ptr.* == keep) {
                kept_bytes += keep.source.len;
                continue;
            }
            store.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.release();
            store.files.removeByPtr(entry.key_ptr);
        }
        store.retained_bytes = kept_bytes;
    }
};

fn parse(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stamp: Stamp) !?*Parsed {
    const file = try allocator.create(Parsed);
    errdefer allocator.destroy(file);
    file.arena = .init(allocator);
    errdefer file.arena.deinit();
    const arena = file.arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_source_bytes)) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return null,
    };
    const source = try arena.dupeSentinel(u8, bytes, 0);
    arena.free(bytes);
    const tokens = try tokens_util.tokenize(arena, source);
    file.* = .{
        .arena = file.arena,
        .path = try arena.dupe(u8, path),
        .source = source,
        .tokens = tokens,
        .scopes = try syntax_scope.Index.init(arena, source, tokens),
        .stamp = stamp,
    };
    return file;
}

test "a changed file is parsed again and an unchanged one is shared" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "dependency.zig", .data = "pub const first = 1;" });
    const path = try temporary.dir.realPathFileAlloc(io, "dependency.zig", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const first = (try store.acquire(io, path)).?;
    defer first.release();
    const again = (try store.acquire(io, path)).?;
    defer again.release();
    try std.testing.expect(first == again);

    try temporary.dir.writeFile(io, .{ .sub_path = "dependency.zig", .data = "pub const second_value = 22;" });
    const changed = (try store.acquire(io, path)).?;
    defer changed.release();
    try std.testing.expect(changed != first);
    try std.testing.expectEqualStrings("pub const second_value = 22;", changed.source);
    try std.testing.expectEqualStrings("pub const first = 1;", first.source);
    try std.testing.expect(try store.acquire(io, "/nonexistent/missing.zig") == null);
}
