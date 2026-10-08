//! A running patched-compiler backend seen as a set of domain queries. The
//! session owns the child process and the protocol connection; callers get
//! qualified-name lookups, resolved type shapes, comptime values, and
//! diagnostics, never raw protocol messages.
const std = @import("std");

const types = @import("../rules/types.zig");
const symbol_query = @import("../syntax/symbol_query.zig");
const backend_bootstrap = @import("bootstrap.zig");
const build_graph = @import("build_graph.zig");
const compiler_client = @import("client.zig");
const backend_process = @import("process.zig");
const protocol = @import("protocol.zig");
const zig_environment = @import("zig_environment.zig");

pub const ResolvedShape = types.ResolvedShape;
pub const ResolvedValue = compiler_client.ResolvedValue;
pub const Symbol = compiler_client.Symbol;
pub const Process = backend_process.Process;
pub const DocumentFacts = protocol.DocumentFacts;

pub const Session = struct {
    allocator: std.mem.Allocator,
    process: Process,
    client: compiler_client.Client,
    /// Counts compiles: it changes whenever an overlay edit triggers one, so
    /// anything derived from compiler facts is stale once it differs.
    epoch: u32 = 0,
    declaration_cache: ?Declarations = null,

    /// Spawns the backend for the compile unit `launch` describes.
    /// `cache_root` is the absolute directory whose `.zig-analyzer`
    /// subdirectory holds the compiler caches (the workspace or project root).
    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        launch: build_graph.Launch,
        cache_root: []const u8,
    ) !Session {
        return startWithin(io, allocator, environ, launch, cache_root, compiler_client.default_response_deadline_ms);
    }

    /// Like `start`, but every wait on the backend (its first compile and each
    /// later request) gives up after `deadline_ms`.
    pub fn startWithin(
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        launch: build_graph.Launch,
        cache_root: []const u8,
        deadline_ms: i64,
    ) !Session {
        var backend = (try backend_bootstrap.findBackend(io, allocator)) orelse return error.CompilerBackendNotFound;
        defer backend.deinit(allocator);
        const process = try Process.start(io, allocator, environ, .{
            .backend_binary = backend.binary_path,
            .launch = launch,
            .cache_root = cache_root,
            .zig_lib_directory = try zig_environment.libDirectory(io),
        });
        return attachWithin(allocator, process, deadline_ms);
    }

    /// Connects to and handshakes with an already started backend and waits
    /// for its first compile. Takes ownership of `started`, stopping it on
    /// failure.
    pub fn attach(allocator: std.mem.Allocator, started: Process) !Session {
        return attachWithin(allocator, started, compiler_client.default_response_deadline_ms);
    }

    fn attachWithin(allocator: std.mem.Allocator, started: Process, deadline_ms: i64) !Session {
        var process = started;
        errdefer process.stop();
        if (process.port == 0) _ = try process.awaitPort(@min(deadline_ms, backend_process.default_deadline_ms));
        var client = try compiler_client.Client.connect(process.io, allocator, process.port);
        errdefer client.deinit();
        client.response_deadline_ms = deadline_ms;
        client.handshake(&process.authentication_token) catch |err| {
            std.log.warn("compiler protocol handshake failed: {t}", .{err});
            process.logBackendOutput("compiler backend output after the failed handshake");
            return err;
        };
        try process.awaitUpdate(client.response_deadline_ms);
        process.resetUpdate();
        return .{ .allocator = allocator, .process = process, .client = client };
    }

    pub fn deinit(session: *Session) void {
        session.client.shutdown() catch |err| std.log.warn("failed to send compiler protocol shutdown: {t}", .{err});
        session.client.deinit();
        session.dropDeclarations();
        session.process.stop();
        session.* = undefined;
    }

    /// Replaces the overlay of `uri` and recompiles.
    pub fn replaceOverlay(
        session: *Session,
        uri: []const u8,
        document_version: i32,
        source: []const u8,
    ) !DocumentFacts {
        const facts = try session.stageOverlay(uri, document_version, source);
        try session.update();
        return facts;
    }

    /// Replaces the overlay of `uri` without recompiling. Stage every overlay
    /// of a batch, then call `update` once: each recompile costs a full
    /// incremental update.
    pub fn stageOverlay(
        session: *Session,
        uri: []const u8,
        document_version: i32,
        source: []const u8,
    ) !DocumentFacts {
        return session.client.replaceOverlay(uri, document_version, source);
    }

    /// Recompiles with the overlays staged so far.
    pub fn update(session: *Session) !void {
        session.recompiling();
        try session.process.requestUpdate(session.client.response_deadline_ms);
    }

    pub fn removeOverlay(session: *Session, uri: []const u8) !void {
        session.recompiling();
        try session.client.removeOverlay(uri);
        try session.process.requestUpdate(session.client.response_deadline_ms);
    }

    /// The most recent bytes the backend wrote to stderr, for failure reports.
    pub fn backendOutput(session: *const Session, buffer: []u8) []const u8 {
        return session.process.stderrTail(buffer);
    }

    pub fn diagnostics(session: *Session, allocator: std.mem.Allocator) !std.zig.ErrorBundle {
        return try session.client.diagnostics(allocator);
    }

    /// Qualified names of every analyzed declaration. Owned by the session and
    /// valid until the next overlay edit or `deinit`; use `copyDeclarations`
    /// to keep them longer.
    pub fn declarations(session: *Session) ![]const []const u8 {
        return (try session.loadDeclarations()).names;
    }

    /// The caller owns the slice and every name in it.
    pub fn copyDeclarations(session: *Session, allocator: std.mem.Allocator) ![]const []const u8 {
        const names = (try session.loadDeclarations()).names;
        const copies = try allocator.alloc([]const u8, names.len);
        var copied: usize = 0;
        errdefer {
            for (copies[0..copied]) |name| allocator.free(name);
            allocator.free(copies);
        }
        for (names, copies) |name, *copy| {
            copy.* = try allocator.dupe(u8, name);
            copied += 1;
        }
        return copies;
    }

    /// The first analyzed declaration named `name`, or ending in `.name`.
    /// Same ownership as `declarations`.
    pub fn qualifiedName(session: *Session, name: []const u8) !?[]const u8 {
        return (try session.loadDeclarations()).find(name);
    }

    /// Fields of the enum, tagged union, or struct the compiler resolved for
    /// `name`; null when the name is unknown or its type has no such shape.
    /// Fields belong to `allocator`; `type_name` is `name`.
    pub fn resolveShape(session: *Session, allocator: std.mem.Allocator, name: []const u8) !?ResolvedShape {
        const qualified = try session.qualifiedName(name) orelse return null;
        var shape = session.client.typeShape(allocator, qualified) catch |err| switch (err) {
            error.SemanticsUnavailable => return null,
            else => return err,
        };
        const kind: ResolvedShape.Kind = switch (shape.kind) {
            .enumeration => .enumeration,
            .tagged_union => .tagged_union,
            .structure => .structure,
            _ => {
                shape.deinit(allocator);
                return null;
            },
        };
        return .{ .type_name = name, .kind = kind, .fields = shape.fields };
    }

    /// The comptime-resolved type and value of the declaration named `name`,
    /// or null when it is unknown or not resolvable.
    pub fn resolveValue(session: *Session, allocator: std.mem.Allocator, name: []const u8) !?ResolvedValue {
        const qualified = try session.qualifiedName(name) orelse return null;
        return session.client.resolvedValue(allocator, qualified) catch |err| switch (err) {
            error.SemanticsUnavailable => null,
            else => err,
        };
    }

    /// Names of the members the compiler resolved for the type `name`; falls
    /// back to asking about `name` unqualified when no declaration matches.
    pub fn typeMembers(session: *Session, allocator: std.mem.Allocator, name: []const u8) !?[]const []const u8 {
        const qualified = try session.qualifiedName(name) orelse name;
        return session.client.typeMembers(allocator, qualified) catch |err| switch (err) {
            error.SemanticsUnavailable => null,
            else => err,
        };
    }

    /// Which declaration each query about `uri` names. A document the compile
    /// does not contain has no answers: `error.SemanticsUnavailable`.
    pub fn resolveSymbols(
        session: *Session,
        allocator: std.mem.Allocator,
        uri: []const u8,
        queries: []const symbol_query.Query,
    ) ![]Symbol {
        return session.client.resolveSymbols(allocator, uri, queries);
    }

    fn recompiling(session: *Session) void {
        session.epoch +%= 1;
        session.dropDeclarations();
    }

    fn loadDeclarations(session: *Session) !*const Declarations {
        if (session.declaration_cache) |*cached| return cached;
        session.declaration_cache = try Declarations.load(session.allocator, &session.client);
        return &session.declaration_cache.?;
    }

    fn dropDeclarations(session: *Session) void {
        if (session.declaration_cache) |*cached| cached.deinit();
        session.declaration_cache = null;
    }
};

/// The workspace's qualified declaration names plus one index answering "which
/// declaration is `Name` / `module.Name`" for every dotted suffix.
const Declarations = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,
    by_suffix: std.StringHashMapUnmanaged([]const u8),

    fn load(allocator: std.mem.Allocator, client: *compiler_client.Client) !Declarations {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        const names = client.workspaceDeclarations(arena.allocator()) catch |err| {
            arena.deinit();
            return err;
        };
        return build(arena, names);
    }

    fn build(arena_state: std.heap.ArenaAllocator, names: []const []const u8) !Declarations {
        var arena = arena_state;
        errdefer arena.deinit();
        var by_suffix: std.StringHashMapUnmanaged([]const u8) = .empty;
        try by_suffix.ensureTotalCapacity(arena.allocator(), @intCast(names.len * 2));
        for (names) |name| {
            // Every suffix that starts at a '.' boundary, including the whole
            // name; the first declaration to claim a suffix keeps it.
            var start: usize = 0;
            while (true) {
                const entry = try by_suffix.getOrPut(arena.allocator(), name[start..]);
                if (!entry.found_existing) entry.value_ptr.* = name;
                start = (std.mem.findScalarPos(u8, name, start, '.') orelse break) + 1;
            }
        }
        return .{ .arena = arena, .names = names, .by_suffix = by_suffix };
    }

    fn deinit(declarations: *Declarations) void {
        declarations.arena.deinit();
        declarations.* = undefined;
    }

    fn find(declarations: *const Declarations, name: []const u8) ?[]const u8 {
        return declarations.by_suffix.get(name);
    }
};

test "qualified names match whole names and dotted suffixes only" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const names = [_][]const u8{ "root.Color", "root.shapes.Point", "root.other.Point", "root.Pointer" };
    var declarations = try Declarations.build(arena, &names);
    defer declarations.deinit();

    try std.testing.expectEqualStrings("root.Color", declarations.find("Color").?);
    try std.testing.expectEqualStrings("root.Color", declarations.find("root.Color").?);
    try std.testing.expectEqualStrings("root.shapes.Point", declarations.find("Point").?);
    try std.testing.expectEqualStrings("root.other.Point", declarations.find("other.Point").?);
    try std.testing.expectEqualStrings("root.Pointer", declarations.find("Pointer").?);
    try std.testing.expect(declarations.find("olor") == null);
    try std.testing.expect(declarations.find("hapes.Point") == null);
    try std.testing.expect(declarations.find("Missing") == null);
}
