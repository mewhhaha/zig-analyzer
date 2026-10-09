//! The compiler backend as the language server uses it: a background worker
//! that owns the compiler `Session`, keeps its own snapshot of every open
//! document, and turns document edits into compiler results.
//!
//! The foreground (the request loop) talks to it through a narrow API:
//!
//!  * `documentChanged` / `documentClosed` queue work. Jobs are coalesced per
//!    document, so an edit to one document never replaces the pending edit of
//!    another, and the worker waits `debounce_ms` of quiet before compiling.
//!  * The query functions (`declarations`, `typeMembers`, `resolveShape`,
//!    `resolveValue`) answer only for a document version the compiler has
//!    analyzed, and never wait for a running compile: when the worker is busy
//!    they report "no answer".
//!  * `knownShapes` reads the shapes of the last compile from a cache of their
//!    own, so lint findings that depend on them stay stable while it is busy.
//!
//! When a compile finishes, the worker recomputes the lint layer with the
//! compiler's facts and hands both layers to the `Publisher`, which merges and
//! writes them (see `lsp_diagnostics.zig`). Results for a document that was
//! edited or closed in the meantime are dropped.
const std = @import("std");
const analysis = @import("../analysis.zig");
const build_graph = @import("../compiler/build_graph.zig");
const compile_units = @import("../compiler/compile_units.zig");
const compiler_session = @import("../compiler/session.zig");
const document_module = @import("../syntax/document.zig");
const lsp_diagnostics = @import("diagnostics.zig");
const pathExists = @import("../filesystem.zig").pathExists;
const syntax_types = @import("../syntax/types.zig");
const uri_module = @import("../uri.zig");

const Document = document_module.Document;
const Session = compiler_session.Session;

/// Quiet time after the last edit before the compiler is asked to analyze.
pub const default_debounce_ms: i64 = 100;

pub const Options = struct {
    debounce_ms: i64 = default_debounce_ms,
    /// False for a server that must never start a compiler (syntax only).
    enabled: bool = true,
};

pub const Reason = enum {
    /// The text changed; keep the running compiler.
    edited,
    /// The file was saved: make sure the compiler analyzes it, re-rooting the
    /// compile at this document when it is not part of the current one.
    saved,
    /// `build.zig` or `build.zig.zon` changed: start a fresh compiler.
    build_changed,
};

/// What a running compiler analyzes, for callers that need to run the same
/// analysis again elsewhere (rename compares compile units).
pub const Compile = struct {
    /// The compile unit's name, or null when a lone file is analyzed. Several
    /// units can share a name; `root_source` tells them apart.
    unit: ?[]u8,
    /// Absolute path of the file the compile is rooted at.
    root_source: []u8,
    /// `Launch.fingerprint` of the arguments the compiler was started with:
    /// units sharing a name and a root still differ in their options.
    launch: u64,
    /// The directory whose `.zig-analyzer` subdirectory holds the caches.
    cache_root: []u8,
    /// Imports of this unit that name modules the analyzer cannot provide.
    unavailable: []build_graph.UnavailableImport,

    fn deinit(compile: *Compile, allocator: std.mem.Allocator) void {
        if (compile.unit) |unit| allocator.free(unit);
        allocator.free(compile.root_source);
        allocator.free(compile.cache_root);
        for (compile.unavailable) |entry| {
            allocator.free(entry.import_name);
            allocator.free(entry.step);
            allocator.free(entry.reason);
        }
        allocator.free(compile.unavailable);
        compile.* = undefined;
    }
};

pub const CompilerBackend = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    options: Options,
    linter: lsp_diagnostics.Linter,
    publisher: *lsp_diagnostics.Publisher,

    // The queue between the foreground and the worker. `queue_mutex` is only
    // ever held for a few instructions.
    queue_mutex: std.Io.Mutex = .init,
    queue_condition: std.Io.Condition = .init,
    idle_condition: std.Io.Condition = .init,
    pending: std.StringHashMapUnmanaged(Job) = .empty,
    // Backend.deinit frees these owned URIs and then releases the list.
    // zig-analyzer: disable-next-line incomplete-owned-field-cleanup
    closed: std.ArrayList([]u8) = .empty,
    /// Newest event (edit or close) per document; a result is only published
    /// while its job is still the newest event for its document.
    latest: std.StringHashMapUnmanaged(u64) = .empty,
    revision: u64 = 0,
    busy: bool = false,
    stopping: bool = false,
    /// The document the compile is rooted at, readable without the session.
    root_uri: ?[]u8 = null,
    future: ?std.Io.Future(void) = null,

    // Everything below belongs to the worker while it holds `session_mutex`;
    // queries from the foreground only ever `tryLock` it.
    session_mutex: std.Io.Mutex = .init,
    documents: document_module.Store,
    compiler: ?Session = null,
    /// What the running compiler was started for.
    compile: ?Compile = null,
    /// Open documents the current compile analyzes, with the version it saw.
    analyzed: std.StringHashMapUnmanaged(i32) = .empty,
    start_attempted: bool = false,
    restart_available: bool = true,

    shapes_mutex: std.Io.Mutex = .init,
    shapes: std.StringHashMapUnmanaged(CachedShapes) = .empty,

    const Job = struct {
        uri: []u8,
        source: []u8,
        version: i32,
        revision: u64,
        restart: bool,
        refresh_root: bool,

        fn deinit(job: *Job, allocator: std.mem.Allocator) void {
            allocator.free(job.uri);
            allocator.free(job.source);
            job.* = undefined;
        }
    };

    /// Pinned: the worker holds a pointer to the backend, so initialize in
    /// place and do not move.
    pub fn init(
        backend: *CompilerBackend,
        io: std.Io,
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        options: Options,
        linter: lsp_diagnostics.Linter,
        publisher: *lsp_diagnostics.Publisher,
    ) !void {
        backend.* = .{
            .io = io,
            .allocator = allocator,
            .environ = environ,
            .options = options,
            .linter = linter,
            .publisher = publisher,
            .documents = .init(allocator),
        };
        if (options.enabled) backend.future = try io.concurrent(run, .{backend});
    }

    pub fn deinit(backend: *CompilerBackend) void {
        backend.queue_mutex.lockUncancelable(backend.io);
        backend.stopping = true;
        backend.queue_condition.signal(backend.io);
        backend.queue_mutex.unlock(backend.io);
        if (backend.future) |*future| future.cancel(backend.io);

        var pending = backend.pending.valueIterator();
        while (pending.next()) |job| job.deinit(backend.allocator);
        backend.pending.deinit(backend.allocator);
        for (backend.closed.items) |uri| backend.allocator.free(uri);
        backend.closed.deinit(backend.allocator);
        var latest = backend.latest.keyIterator();
        while (latest.next()) |uri| backend.allocator.free(uri.*);
        backend.latest.deinit(backend.allocator);
        if (backend.root_uri) |uri| backend.allocator.free(uri);
        if (backend.compiler) |*session| session.deinit();
        backend.forgetCompile();
        var analyzed = backend.analyzed.keyIterator();
        while (analyzed.next()) |uri| backend.allocator.free(uri.*);
        backend.analyzed.deinit(backend.allocator);
        backend.clearShapes();
        backend.shapes.deinit(backend.allocator);
        backend.documents.deinit();
        backend.* = undefined;
    }

    // ---- foreground: queue work -------------------------------------------

    /// `document` changed (or was saved); the worker will bring the compiler up
    /// to date after the debounce. Replaces any pending job for the same
    /// document only.
    pub fn documentChanged(backend: *CompilerBackend, document: *const Document, reason: Reason) !void {
        if (!backend.options.enabled) return;
        const uri = try backend.allocator.dupe(u8, document.uri);
        errdefer backend.allocator.free(uri);
        const source = try backend.allocator.dupe(u8, document.source);
        errdefer backend.allocator.free(source);

        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        backend.revision += 1;
        var job: Job = .{
            .uri = uri,
            .source = source,
            .version = document.version,
            .revision = backend.revision,
            .restart = reason == .build_changed,
            .refresh_root = reason == .saved,
        };
        try backend.noteLatest(uri, job.revision);
        if (backend.pending.fetchRemove(uri)) |previous| {
            var replaced = previous.value;
            job.restart = job.restart or replaced.restart;
            job.refresh_root = job.refresh_root or replaced.refresh_root;
            replaced.deinit(backend.allocator);
        }
        try backend.pending.put(backend.allocator, uri, job);
        backend.queue_condition.signal(backend.io);
    }

    /// `uri` was closed: its pending work is dropped and the worker forgets
    /// the snapshot and the compiler's overlay.
    pub fn documentClosed(backend: *CompilerBackend, uri: []const u8) !void {
        if (!backend.options.enabled) return;
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        if (backend.pending.fetchRemove(uri)) |previous| {
            var dropped = previous.value;
            dropped.deinit(backend.allocator);
        }
        if (backend.latest.fetchRemove(uri)) |removed| backend.allocator.free(removed.key);
        for (backend.closed.items) |closed_uri| if (std.mem.eql(u8, closed_uri, uri)) return;
        const owned = try backend.allocator.dupe(u8, uri);
        errdefer backend.allocator.free(owned);
        try backend.closed.append(backend.allocator, owned);
        backend.queue_condition.signal(backend.io);
    }

    fn noteLatest(backend: *CompilerBackend, uri: []const u8, revision: u64) !void {
        if (backend.latest.getPtr(uri)) |known| {
            known.* = revision;
            return;
        }
        const key = try backend.allocator.dupe(u8, uri);
        errdefer backend.allocator.free(key);
        try backend.latest.put(backend.allocator, key, revision);
    }

    /// Blocks until no work is queued or running. For tests and shutdown
    /// paths; the request loop never calls it.
    pub fn waitIdle(backend: *CompilerBackend) void {
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        while (backend.hasWork() or backend.busy) backend.idle_condition.waitUncancelable(backend.io, &backend.queue_mutex);
    }

    fn hasWork(backend: *const CompilerBackend) bool {
        return backend.pending.count() != 0 or backend.closed.items.len != 0;
    }

    /// The URI of the document the compile is rooted at (the one most recently
    /// analyzed), if any. Never waits for a compile.
    pub fn compileRoot(backend: *CompilerBackend, allocator: std.mem.Allocator) !?[]u8 {
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        const uri = backend.root_uri orelse return null;
        return try allocator.dupe(u8, uri);
    }

    // ---- foreground: queries ----------------------------------------------

    /// Qualified names of every declaration the compiler analyzed, for the
    /// analyzed `version` of `uri`; empty otherwise or while it is busy.
    pub fn declarations(
        backend: *CompilerBackend,
        allocator: std.mem.Allocator,
        uri: []const u8,
        version: i32,
    ) ![]const []const u8 {
        const session = backend.acquire(uri, version) orelse return &.{};
        defer backend.release();
        return session.copyDeclarations(allocator) catch |err| {
            backend.fail(err, uri);
            return &.{};
        };
    }

    /// Member names the compiler resolved for `type_name`.
    pub fn typeMembers(
        backend: *CompilerBackend,
        allocator: std.mem.Allocator,
        uri: []const u8,
        version: i32,
        type_name: []const u8,
    ) !?[]const []const u8 {
        const session = backend.acquire(uri, version) orelse return null;
        defer backend.release();
        return session.typeMembers(allocator, type_name) catch |err| {
            backend.fail(err, uri);
            return null;
        };
    }

    pub fn resolveShape(
        backend: *CompilerBackend,
        allocator: std.mem.Allocator,
        uri: []const u8,
        version: i32,
        type_name: []const u8,
    ) !?analysis.ResolvedShape {
        const session = backend.acquire(uri, version) orelse return null;
        defer backend.release();
        return session.resolveShape(allocator, type_name) catch |err| {
            backend.fail(err, uri);
            return null;
        };
    }

    pub fn resolveValue(
        backend: *CompilerBackend,
        allocator: std.mem.Allocator,
        uri: []const u8,
        version: i32,
        name: []const u8,
    ) !?compiler_session.ResolvedValue {
        const session = backend.acquire(uri, version) orelse return null;
        defer backend.release();
        return session.resolveValue(allocator, name) catch |err| {
            backend.fail(err, uri);
            return null;
        };
    }

    /// The type shapes of the newest compile of `uri`, whatever version it
    /// analyzed. Lint findings use these so they do not come and go while the
    /// compiler is busy; the worker republishes once a compile catches up.
    pub fn knownShapes(backend: *CompilerBackend, allocator: std.mem.Allocator, uri: []const u8) ![]const analysis.ResolvedShape {
        backend.shapes_mutex.lockUncancelable(backend.io);
        defer backend.shapes_mutex.unlock(backend.io);
        const cached = backend.shapes.get(uri) orelse return &.{};
        return try copyResolvedShapes(allocator, cached.shapes);
    }

    /// Whether the compiler has analyzed exactly `version` of `uri` and is idle.
    pub fn isAnalyzed(backend: *CompilerBackend, uri: []const u8, version: i32) bool {
        _ = backend.acquire(uri, version) orelse return false;
        backend.release();
        return true;
    }

    /// The session if the compiler analyzed exactly `version` of `uri` and is
    /// not busy. Pair with `release`.
    fn acquire(backend: *CompilerBackend, uri: []const u8, version: i32) ?*Session {
        if (!backend.session_mutex.tryLock()) return null;
        if (backend.compiler) |*session| {
            if (backend.analyzed.get(uri)) |analyzed_version| {
                if (analyzed_version == version) return session;
            }
        }
        backend.session_mutex.unlock(backend.io);
        return null;
    }

    pub fn release(backend: *CompilerBackend) void {
        backend.session_mutex.unlock(backend.io);
    }

    /// Like `acquire`, but for a user-initiated request that can afford to
    /// wait: polls for up to `wait_ms` while the worker compiles. Null when the
    /// compiler is off, never analyzed this version, or stayed busy. Pair with
    /// `release`; the worker is blocked meanwhile.
    pub fn acquireWithin(backend: *CompilerBackend, uri: []const u8, version: i32, wait_ms: u32) ?*Session {
        if (!backend.options.enabled) return null;
        var waited: u32 = 0;
        while (true) {
            if (backend.acquire(uri, version)) |session| return session;
            if (waited >= wait_ms) return null;
            backend.io.sleep(.fromMilliseconds(poll_ms), .awake) catch return null;
            waited += poll_ms;
        }
    }

    const poll_ms = 10;

    /// What the compiler held by `acquireWithin` was started for.
    pub fn activeCompile(backend: *const CompilerBackend) ?Compile {
        return backend.compile;
    }

    // ---- worker -----------------------------------------------------------

    fn run(backend: *CompilerBackend) void {
        while (true) {
            backend.queue_mutex.lockUncancelable(backend.io);
            while (!backend.hasWork() and !backend.stopping) {
                backend.queue_condition.waitUncancelable(backend.io, &backend.queue_mutex);
            }
            if (backend.stopping) {
                backend.queue_mutex.unlock(backend.io);
                return;
            }
            const observed_revision = backend.revision;
            backend.queue_mutex.unlock(backend.io);

            backend.io.sleep(.fromMilliseconds(backend.options.debounce_ms), .awake) catch return;

            backend.queue_mutex.lockUncancelable(backend.io);
            if (backend.stopping) {
                backend.queue_mutex.unlock(backend.io);
                return;
            }
            if (backend.revision != observed_revision) {
                // More edits arrived during the quiet period: wait again.
                backend.queue_mutex.unlock(backend.io);
                continue;
            }
            var batch = backend.takeBatch() catch |err| {
                std.log.err("compiler backend could not take its queue: {t}", .{err});
                backend.queue_mutex.unlock(backend.io);
                return;
            };
            backend.busy = true;
            backend.queue_mutex.unlock(backend.io);

            backend.process(&batch);
            batch.deinit(backend.allocator);

            backend.queue_mutex.lockUncancelable(backend.io);
            backend.busy = false;
            if (!backend.hasWork()) backend.idle_condition.broadcast(backend.io);
            backend.queue_mutex.unlock(backend.io);
        }
    }

    const Batch = struct {
        /// Oldest edit first.
        jobs: []Job,
        closed: [][]u8,

        fn deinit(batch: *Batch, allocator: std.mem.Allocator) void {
            for (batch.jobs) |*job| job.deinit(allocator);
            allocator.free(batch.jobs);
            for (batch.closed) |uri| allocator.free(uri);
            allocator.free(batch.closed);
            batch.* = undefined;
        }
    };

    /// Moves the queue's contents out. Called with `queue_mutex` held.
    fn takeBatch(backend: *CompilerBackend) !Batch {
        const jobs = try backend.allocator.alloc(Job, backend.pending.count());
        errdefer backend.allocator.free(jobs);
        var values = backend.pending.valueIterator();
        var index: usize = 0;
        while (values.next()) |job| : (index += 1) jobs[index] = job.*;
        backend.pending.clearRetainingCapacity();
        std.mem.sort(Job, jobs, {}, struct {
            fn lessThan(_: void, left: Job, right: Job) bool {
                return left.revision < right.revision;
            }
        }.lessThan);
        const closed = try backend.closed.toOwnedSlice(backend.allocator);
        return .{ .jobs = jobs, .closed = closed };
    }

    fn process(backend: *CompilerBackend, batch: *const Batch) void {
        backend.session_mutex.lockUncancelable(backend.io);
        defer backend.session_mutex.unlock(backend.io);
        var scratch: std.heap.ArenaAllocator = .init(backend.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        var rebuild = false;
        var refresh_root = false;
        for (batch.jobs) |job| {
            rebuild = rebuild or job.restart;
            refresh_root = refresh_root or job.refresh_root;
        }
        for (batch.jobs) |job| if (job.restart) backend.forgetBuildGraph(arena, job.uri);
        if (rebuild or (refresh_root and backend.compiler == null)) backend.restart();
        backend.removeClosed(batch.closed);
        for (batch.jobs) |job| {
            backend.documents.open(job.uri, job.version, job.source) catch |err| {
                std.log.warn("compiler backend could not snapshot '{s}': {t}", .{ job.uri, err });
            };
        }
        const fresh = backend.compiler == null;
        if (batch.jobs.len != 0) backend.ensureCompiler(arena, batch.jobs[0].uri);
        backend.syncOverlays(arena, batch.jobs, if (fresh) .all_open else .jobs_only);
        if (refresh_root and backend.compiler != null) {
            for (batch.jobs) |job| {
                if (!job.refresh_root or backend.analyzedAt(job.uri, job.version)) continue;
                // The saved document is not part of this compile: root a new
                // one at it, with every other open document replayed into it.
                backend.restart();
                backend.ensureCompiler(arena, job.uri);
                backend.syncOverlays(arena, &.{job}, .all_open);
                break;
            }
        }
        backend.publishResults(arena, batch.jobs);
    }

    const Replay = enum { jobs_only, all_open };

    /// Sends the snapshots of `jobs` to the compiler, and with `.all_open`
    /// those of every other open document too (a fresh compiler must see every
    /// unsaved buffer), then recompiles once. Documents outside the compile
    /// unit are refused by the compiler and cost nothing.
    fn syncOverlays(backend: *CompilerBackend, arena: std.mem.Allocator, jobs: []const Job, replay: Replay) void {
        var uris: std.ArrayList([]const u8) = .empty;
        for (jobs) |job| uris.append(arena, job.uri) catch return;
        if (replay == .all_open) {
            var documents = backend.documents.documents.valueIterator();
            next: while (documents.next()) |document| {
                for (jobs) |job| if (std.mem.eql(u8, job.uri, document.uri)) continue :next;
                uris.append(arena, document.uri) catch return;
            }
        }
        const session = if (backend.compiler) |*active| active else return;
        var staged: std.ArrayList([]const u8) = .empty;
        for (uris.items) |uri| {
            const document = backend.documents.getConst(uri) orelse continue;
            _ = session.stageOverlay(uri, document.version, document.source) catch |err| switch (err) {
                error.SemanticsUnavailable => {
                    backend.forgetAnalyzed(uri);
                    continue;
                },
                else => {
                    backend.fail(err, uri);
                    return;
                },
            };
            staged.append(arena, uri) catch return;
        }
        if (staged.items.len == 0) return;
        session.update() catch |err| {
            backend.fail(err, staged.items[0]);
            return;
        };
        for (staged.items) |uri| {
            const document = backend.documents.getConst(uri) orelse continue;
            backend.markAnalyzed(uri, document.version) catch |err| backend.fail(err, uri);
        }
    }

    fn publishResults(backend: *CompilerBackend, arena: std.mem.Allocator, jobs: []const Job) void {
        var bundle: ?std.zig.ErrorBundle = null;
        defer if (bundle) |*owned| owned.deinit(backend.allocator);
        for (jobs) |job| {
            if (backend.compiler == null) return;
            if (!backend.analyzedAt(job.uri, job.version) or !backend.isNewest(job)) continue;
            const document = backend.documents.getConst(job.uri) orelse continue;
            const shapes = backend.shapesFor(arena, document);
            const session = if (backend.compiler) |*active| active else return;
            if (bundle == null) {
                bundle = session.diagnostics(backend.allocator) catch |err| {
                    backend.fail(err, job.uri);
                    return;
                };
            }
            const unavailable: []const build_graph.UnavailableImport = if (backend.compile) |active| active.unavailable else &.{};
            const compiler_layer = lsp_diagnostics.compilerDiagnostics(document, bundle.?, arena, unavailable) catch |err| {
                std.log.warn("compiler diagnostics for '{s}' unavailable: {t}", .{ job.uri, err });
                continue;
            };
            const lint_layer = backend.linter.diagnostics(arena, &backend.documents, document, shapes, null) catch |err| {
                std.log.warn("lint diagnostics for '{s}' unavailable: {t}", .{ job.uri, err });
                continue;
            };
            backend.publisher.publishCompiled(job.uri, job.version, lint_layer, compiler_layer) catch |err| {
                std.log.warn("could not publish diagnostics for '{s}': {t}", .{ job.uri, err });
            };
        }
    }

    /// Whether `job` is still the newest event for its document.
    fn isNewest(backend: *CompilerBackend, job: Job) bool {
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        const newest = backend.latest.get(job.uri) orelse return false;
        return newest == job.revision;
    }

    fn analyzedAt(backend: *const CompilerBackend, uri: []const u8, version: i32) bool {
        const analyzed_version = backend.analyzed.get(uri) orelse return false;
        return analyzed_version == version;
    }

    /// Starts the compiler for the compile unit that contains `uri`, once.
    fn ensureCompiler(backend: *CompilerBackend, arena: std.mem.Allocator, uri: []const u8) void {
        if (backend.compiler != null or backend.start_attempted) return;
        backend.start_attempted = true;
        if (backend.documents.getConst(uri) == null) return;
        backend.startCompiler(arena, uri) catch |err| backend.fail(err, uri);
    }

    fn startCompiler(backend: *CompilerBackend, arena: std.mem.Allocator, uri: []const u8) !void {
        const document_path = try uri_module.toPath(arena, uri) orelse return;
        if (!try pathExists(backend.io, document_path)) return;
        const project = try backend.linter.configurations.forFile(document_path);
        const selected = try compile_units.select(backend.io, arena, document_path, .discover);
        for (selected.notices) |notice| {
            switch (notice.level) {
                .warning => std.log.warn("{s}", .{notice.text}),
                .information => std.log.info("{s}", .{notice.text}),
            }
            backend.linter.showMessage(arena, switch (notice.level) {
                .warning => .Warning,
                .information => .Info,
            }, notice.text) catch |err| std.log.warn("could not show a build message: {t}", .{err});
        }
        var compile: Compile = .{
            .unit = null,
            .root_source = &.{},
            .launch = selected.launch.fingerprint(),
            .cache_root = &.{},
            .unavailable = &.{},
        };
        errdefer compile.deinit(backend.allocator);
        if (selected.unit) |unit| compile.unit = try backend.allocator.dupe(u8, unit);
        compile.root_source = try backend.allocator.dupe(u8, selected.root_source);
        compile.cache_root = try backend.allocator.dupe(u8, project.root);
        compile.unavailable = try copyUnavailable(backend.allocator, selected.unavailable);
        backend.compiler = try Session.start(backend.io, backend.allocator, backend.environ, selected.launch, project.root);
        backend.compile = compile;
    }

    fn copyUnavailable(allocator: std.mem.Allocator, imports: []const build_graph.UnavailableImport) ![]build_graph.UnavailableImport {
        const copies = try allocator.alloc(build_graph.UnavailableImport, imports.len);
        var copied: usize = 0;
        errdefer {
            for (copies[0..copied]) |entry| {
                allocator.free(entry.import_name);
                allocator.free(entry.step);
                allocator.free(entry.reason);
            }
            allocator.free(copies);
        }
        for (imports, copies) |entry, *copy| {
            copy.* = .{ .import_name = try allocator.dupe(u8, entry.import_name), .step = "", .reason = "" };
            copied += 1;
            copy.step = try allocator.dupe(u8, entry.step);
            copy.reason = try allocator.dupe(u8, entry.reason);
        }
        return copies;
    }

    fn forgetCompile(backend: *CompilerBackend) void {
        if (backend.compile) |*compile| compile.deinit(backend.allocator);
        backend.compile = null;
    }

    /// `build.zig` or `build.zig.zon` changed: the next compiler start
    /// configures the build again.
    fn forgetBuildGraph(backend: *const CompilerBackend, arena: std.mem.Allocator, uri: []const u8) void {
        const path = uri_module.toPath(arena, uri) catch return orelse return;
        compile_units.forgetBuildGraph(backend.io, path) catch |err| {
            std.log.warn("could not drop the cached build graph for '{s}': {t}", .{ uri, err });
        };
    }

    fn markAnalyzed(backend: *CompilerBackend, uri: []const u8, version: i32) !void {
        if (backend.analyzed.getPtr(uri)) |known| {
            known.* = version;
        } else {
            const key = try backend.allocator.dupe(u8, uri);
            errdefer backend.allocator.free(key);
            try backend.analyzed.put(backend.allocator, key, version);
        }
        const root = try backend.allocator.dupe(u8, uri);
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        if (backend.root_uri) |previous| backend.allocator.free(previous);
        backend.root_uri = root;
    }

    fn forgetAnalyzed(backend: *CompilerBackend, uri: []const u8) void {
        if (backend.analyzed.fetchRemove(uri)) |removed| backend.allocator.free(removed.key);
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        if (backend.root_uri) |root| {
            if (std.mem.eql(u8, root, uri)) {
                backend.allocator.free(root);
                backend.root_uri = null;
            }
        }
    }

    fn removeClosed(backend: *CompilerBackend, closed: []const []u8) void {
        for (closed) |uri| {
            _ = backend.documents.close(uri);
            backend.forgetAnalyzed(uri);
            backend.forgetShapes(uri);
            if (backend.compiler) |*session| session.removeOverlay(uri) catch |err| {
                backend.fail(err, uri);
            };
        }
    }

    /// Stops the compiler and forgets everything derived from it. The next
    /// job starts a new one.
    fn restart(backend: *CompilerBackend) void {
        if (backend.compiler) |*session| session.deinit();
        backend.compiler = null;
        backend.forgetCompile();
        backend.clearAnalyzed();
        backend.clearShapes();
        backend.start_attempted = false;
        backend.restart_available = true;
    }

    /// A compiler request failed: log, drop the session, and allow exactly one
    /// automatic restart before the backend stays off until a rebuild or save.
    pub fn fail(backend: *CompilerBackend, err: anyerror, document_uri: []const u8) void {
        if (err == error.Canceled) return;
        std.log.warn("compiler backend request failed for '{s}': {t}; syntax service remains active", .{ document_uri, err });
        if (backend.compiler) |*session| {
            var output_buffer: [2048]u8 = undefined;
            const output = std.mem.trimEnd(u8, session.backendOutput(&output_buffer), "\n");
            if (output.len != 0) std.log.warn("compiler backend stderr:\n{s}", .{output});
            session.deinit();
        }
        backend.compiler = null;
        backend.forgetCompile();
        backend.clearAnalyzed();
        backend.clearShapes();
        const restart_available = backend.restart_available;
        backend.restart_available = false;
        backend.start_attempted = !restart_available;
    }

    fn clearAnalyzed(backend: *CompilerBackend) void {
        var analyzed = backend.analyzed.keyIterator();
        while (analyzed.next()) |uri| backend.allocator.free(uri.*);
        backend.analyzed.clearRetainingCapacity();
        backend.queue_mutex.lockUncancelable(backend.io);
        defer backend.queue_mutex.unlock(backend.io);
        if (backend.root_uri) |root| backend.allocator.free(root);
        backend.root_uri = null;
    }

    // ---- shapes -----------------------------------------------------------

    const CachedShapes = struct {
        document_version: i32,
        compiler_epoch: u32,
        storage: std.heap.ArenaAllocator,
        shapes: []const analysis.ResolvedShape,
    };

    /// The shapes for the type names `document` writes, resolved by the
    /// compiler and cached per document version and compile.
    fn shapesFor(backend: *CompilerBackend, arena: std.mem.Allocator, document: *const Document) []const analysis.ResolvedShape {
        const session = if (backend.compiler) |*active| active else return &.{};
        if (backend.cachedShapes(arena, document, session.epoch) catch null) |cached| return cached;
        const names = syntax_types.shapeCandidates(arena, document.source, document.tokens) catch return &.{};
        var resolved: std.ArrayList(analysis.ResolvedShape) = .empty;
        for (names) |name| {
            const shape = session.resolveShape(arena, name) catch |err| {
                backend.fail(err, document.uri);
                return resolved.items;
            } orelse continue;
            resolved.append(arena, shape) catch return resolved.items;
        }
        backend.storeShapes(document, session.epoch, resolved.items) catch |err| {
            std.log.warn("could not cache compiler shapes for '{s}': {t}", .{ document.uri, err });
        };
        return resolved.items;
    }

    fn cachedShapes(
        backend: *CompilerBackend,
        arena: std.mem.Allocator,
        document: *const Document,
        epoch: u32,
    ) !?[]const analysis.ResolvedShape {
        backend.shapes_mutex.lockUncancelable(backend.io);
        defer backend.shapes_mutex.unlock(backend.io);
        const cached = backend.shapes.get(document.uri) orelse return null;
        if (cached.document_version != document.version or cached.compiler_epoch != epoch) return null;
        return try copyResolvedShapes(arena, cached.shapes);
    }

    fn storeShapes(
        backend: *CompilerBackend,
        document: *const Document,
        epoch: u32,
        shapes: []const analysis.ResolvedShape,
    ) !void {
        var storage: std.heap.ArenaAllocator = .init(backend.allocator);
        errdefer storage.deinit();
        const stored = try copyResolvedShapes(storage.allocator(), shapes);
        const cached: CachedShapes = .{
            .document_version = document.version,
            .compiler_epoch = epoch,
            .storage = storage,
            .shapes = stored,
        };
        backend.shapes_mutex.lockUncancelable(backend.io);
        defer backend.shapes_mutex.unlock(backend.io);
        if (backend.shapes.getPtr(document.uri)) |previous| {
            previous.storage.deinit();
            previous.* = cached;
            return;
        }
        const key = try backend.allocator.dupe(u8, document.uri);
        errdefer backend.allocator.free(key);
        try backend.shapes.put(backend.allocator, key, cached);
    }

    fn forgetShapes(backend: *CompilerBackend, uri: []const u8) void {
        backend.shapes_mutex.lockUncancelable(backend.io);
        defer backend.shapes_mutex.unlock(backend.io);
        if (backend.shapes.fetchRemove(uri)) |removed| {
            backend.allocator.free(removed.key);
            var cached = removed.value;
            cached.storage.deinit();
        }
    }

    fn clearShapes(backend: *CompilerBackend) void {
        backend.shapes_mutex.lockUncancelable(backend.io);
        defer backend.shapes_mutex.unlock(backend.io);
        var entries = backend.shapes.iterator();
        while (entries.next()) |entry| {
            entry.value_ptr.storage.deinit();
            backend.allocator.free(entry.key_ptr.*);
        }
        backend.shapes.clearRetainingCapacity();
    }
};

fn copyResolvedShapes(
    allocator: std.mem.Allocator,
    shapes: []const analysis.ResolvedShape,
) ![]const analysis.ResolvedShape {
    const copied = try allocator.alloc(analysis.ResolvedShape, shapes.len);
    for (shapes, copied) |shape, *destination| {
        const fields = try allocator.alloc([]const u8, shape.fields.len);
        for (shape.fields, fields) |field, *copied_field| copied_field.* = try allocator.dupe(u8, field);
        destination.* = .{
            .type_name = try allocator.dupe(u8, shape.type_name),
            .kind = shape.kind,
            .fields = fields,
        };
    }
    return copied;
}

/// A backend over a recording transport, for tests that need no compiler.
const TestHarness = struct {
    sink: lsp_diagnostics.TestSink,
    configurations: @import("../project/config.zig").Store,
    sources: @import("../project/source_store.zig").Store,
    publisher: lsp_diagnostics.Publisher,
    backend: CompilerBackend,

    fn start(harness: *TestHarness, options: Options) !void {
        harness.sink = .init();
        harness.configurations = .init(std.testing.io, std.testing.allocator);
        harness.sources = .init(std.testing.allocator);
        harness.publisher = .init(std.testing.io, std.testing.allocator, &harness.sink.transport);
        try harness.backend.init(
            std.testing.io,
            std.testing.allocator,
            .empty,
            options,
            .{ .io = std.testing.io, .transport = &harness.sink.transport, .configurations = &harness.configurations, .sources = &harness.sources },
            &harness.publisher,
        );
    }

    fn stop(harness: *TestHarness) void {
        harness.backend.deinit();
        harness.publisher.deinit();
        harness.sources.deinit();
        harness.configurations.deinit();
    }
};

test "edits to different documents within the debounce are all kept" {
    var harness: TestHarness = undefined;
    try harness.start(.{ .debounce_ms = 40 });
    defer harness.stop();
    var first = try Document.open(std.testing.allocator, "file:///workspace/a.zig", 1, "const a = 1;\n");
    defer first.deinit();
    var second = try Document.open(std.testing.allocator, "file:///workspace/b.zig", 1, "const b = 1;\n");
    defer second.deinit();

    try harness.backend.documentChanged(&first, .edited);
    try harness.backend.documentChanged(&second, .edited);
    var first_again = try Document.open(std.testing.allocator, "file:///workspace/a.zig", 2, "const a = 2;\n");
    defer first_again.deinit();
    try harness.backend.documentChanged(&first_again, .edited);
    harness.backend.waitIdle();

    try std.testing.expectEqual(@as(i32, 2), harness.backend.documents.getConst("file:///workspace/a.zig").?.version);
    try std.testing.expectEqual(@as(i32, 1), harness.backend.documents.getConst("file:///workspace/b.zig").?.version);
}

test "a closed document drops its pending edit and its snapshot" {
    var harness: TestHarness = undefined;
    try harness.start(.{ .debounce_ms = 40 });
    defer harness.stop();
    var kept = try Document.open(std.testing.allocator, "file:///workspace/kept.zig", 1, "const kept = 1;\n");
    defer kept.deinit();
    var closed = try Document.open(std.testing.allocator, "file:///workspace/closed.zig", 1, "const closed = 1;\n");
    defer closed.deinit();

    try harness.backend.documentChanged(&closed, .edited);
    harness.backend.waitIdle();
    try std.testing.expect(harness.backend.documents.getConst(closed.uri) != null);
    try harness.backend.documentChanged(&kept, .edited);
    try harness.backend.documentChanged(&closed, .edited);
    try harness.backend.documentClosed(closed.uri);
    harness.backend.waitIdle();

    try std.testing.expect(harness.backend.documents.getConst(closed.uri) == null);
    try std.testing.expect(harness.backend.documents.getConst(kept.uri) != null);
}

test "a result only publishes while its job is the newest event for the document" {
    var harness: TestHarness = undefined;
    try harness.start(.{ .enabled = false });
    defer harness.stop();
    try harness.backend.noteLatest("file:///workspace/a.zig", 3);
    const job: CompilerBackend.Job = .{ .uri = "", .source = "", .version = 1, .revision = 3, .restart = false, .refresh_root = false };
    var stale = job;
    stale.uri = @constCast("file:///workspace/a.zig");
    try std.testing.expect(harness.backend.isNewest(stale));
    stale.revision = 2;
    try std.testing.expect(!harness.backend.isNewest(stale));
    stale.revision = 3;
    stale.uri = @constCast("file:///workspace/closed.zig");
    try std.testing.expect(!harness.backend.isNewest(stale));
}

test "compiler type shapes stay cached for the analyzed document version" {
    var harness: TestHarness = undefined;
    try harness.start(.{ .enabled = false });
    defer harness.stop();
    var document = try Document.open(std.testing.allocator, "file:///cached.zig", 1, "const State = enum { ready };\n");
    defer document.deinit();
    const shapes = [_]analysis.ResolvedShape{.{ .type_name = "State", .kind = .enumeration, .fields = &.{"ready"} }};
    try harness.backend.storeShapes(&document, 7, &shapes);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cached = (try harness.backend.cachedShapes(arena, &document, 7)).?;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("State", cached[0].type_name);
    try std.testing.expectEqualStrings("ready", cached[0].fields[0]);
    try std.testing.expect((try harness.backend.cachedShapes(arena, &document, 8)) == null);

    // Lint findings keep the last known shapes while a newer version compiles.
    const known = try harness.backend.knownShapes(arena, document.uri);
    try std.testing.expectEqual(@as(usize, 1), known.len);
    try document.applyChanges(2, &.{.{ .text_document_content_change_whole_document = .{ .text = "const State = enum { waiting };\n" } }});
    try std.testing.expect((try harness.backend.cachedShapes(arena, &document, 7)) == null);
    try std.testing.expectEqual(@as(usize, 1), (try harness.backend.knownShapes(arena, document.uri)).len);
}

test "compiler failures preserve syntax and allow one controlled restart" {
    std.testing.log_level = .err;
    var harness: TestHarness = undefined;
    try harness.start(.{ .enabled = false });
    defer harness.stop();

    harness.backend.start_attempted = true;
    harness.backend.restart_available = true;
    harness.backend.fail(error.CompilerConnectionLost, "file:///workspace/src/main.zig");
    try std.testing.expect(!harness.backend.restart_available);
    try std.testing.expect(!harness.backend.start_attempted);

    harness.backend.start_attempted = true;
    harness.backend.fail(error.CompilerConnectionLost, "file:///workspace/src/main.zig");
    try std.testing.expect(!harness.backend.restart_available);
    try std.testing.expect(harness.backend.start_attempted);
}
