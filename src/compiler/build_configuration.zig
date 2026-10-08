//! Build-graph discovery. Runs the project's build script through the host
//! `zig build --print-configuration-path` (the configure phase only: it
//! builds nothing and runs no program), loads the serialized
//! `std.Build.Configuration` it names, and reads the compile units out of it.
//!
//! Units come from the compile steps reachable from the `check` top-level step
//! or, when that holds none, from `install`. Generated module sources are
//! produced by `generated_sources.zig` when that needs no execution.
const std = @import("std");

const bootstrap = @import("bootstrap.zig");
const build_graph = @import("build_graph.zig");
const generated_sources = @import("generated_sources.zig");
const zig_environment = @import("zig_environment.zig");

const Configuration = std.Build.Configuration;
const BuildGraph = build_graph.BuildGraph;
const Resolved = generated_sources.Resolved;

/// How long the configure phase may take, dependency fetching included.
const configure_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(300), .clock = .awake } };
/// Bytes of the build script's error output kept in a failure message.
const failure_message_bytes = 1500;
const max_units = 64;

/// Discovers the compile units of the build in `build_root` (absolute). The
/// graph is returned even when the build script cannot be configured; then
/// `failure` says why and `units` is empty. The caller owns one reference.
pub fn discover(io: std.Io, backing: std.mem.Allocator, build_root: []const u8) !*BuildGraph {
    const graph = try BuildGraph.create(backing);
    errdefer graph.release();
    const arena = graph.arena.allocator();
    graph.build_root = try arena.dupe(u8, build_root);
    loadUnits(io, graph, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => |failure| graph.failure = try arena.print("{t}", .{failure}),
    };
    return graph;
}

/// Reads the configuration into `graph`. Configure errors that carry a
/// message set `graph.failure` and succeed.
fn loadUnits(io: std.Io, graph: *BuildGraph, arena: std.mem.Allocator) !void {
    const configuration_path = (try configurationPath(io, graph, arena)) orelse return;
    var file = try std.Io.Dir.cwd().openFile(io, configuration_path, .{});
    defer file.close(io);
    const conf = try arena.create(Configuration);
    conf.* = try Configuration.loadFile(arena, io, file);

    var extractor: Extractor = .{
        .io = io,
        .arena = arena,
        .conf = conf,
        .build_root = graph.build_root,
        .generated_root = try std.Io.Dir.path.join(arena, &.{ graph.build_root, bootstrap.generated_directory }),
    };
    try extractor.indexGeneratedFiles();
    for ([_]build_graph.Selection{ .check, .install }) |selection| {
        const compile_steps = try extractor.compileStepsUnder(@tagName(selection));
        var units: std.ArrayList(build_graph.Unit) = .empty;
        var seen: std.AutoHashMapUnmanaged(SeenKey, void) = .empty;
        for (compile_steps) |compile_index| {
            if (units.items.len == max_units) break;
            const unit = (try extractor.unit(compile_index)) orelse continue;
            const key = try extractor.seenKey(compile_index);
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            try units.append(arena, unit);
        }
        if (units.items.len == 0) continue;
        graph.selection = selection;
        graph.units = units.items;
        break;
    }
    graph.notices = extractor.notices.items;
    if (graph.selection == null) {
        graph.failure = "neither the check nor the install step builds a Zig compile unit";
    }
}

/// Runs the configure phase. Null, with `graph.failure` set, when it fails.
fn configurationPath(io: std.Io, graph: *BuildGraph, arena: std.mem.Allocator) !?[]const u8 {
    const zig_exe = zig_environment.executable(io) catch |err| {
        graph.failure = try arena.print("no usable zig compiler: {t}", .{err});
        return null;
    };
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ zig_exe, "build", "--color", "off", "--print-configuration-path" },
        .cwd = .{ .path = graph.build_root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = configure_timeout,
    }) catch |err| {
        graph.failure = try arena.print("running 'zig build' failed: {t}", .{err});
        return null;
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        const message = std.mem.trim(u8, result.stderr, " \r\n");
        graph.failure = try arena.dupe(u8, message[0..@min(message.len, failure_message_bytes)]);
        return null;
    }
    const printed = std.mem.trim(u8, result.stdout, " \r\n");
    return try std.Io.Dir.path.resolveAlloc(arena, &.{ graph.build_root, printed });
}

/// Two compile steps over the same root module analyze the same code, so only
/// the first of each kind class (test or not) becomes a unit.
const SeenKey = struct {
    root_module: Configuration.Module.Index,
    test_kind: bool,
};

const Extractor = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    conf: *const Configuration,
    build_root: []const u8,
    generated_root: []const u8,
    /// Which step owns each generated file.
    owners: std.AutoHashMapUnmanaged(Configuration.GeneratedFileIndex, Configuration.Step.Index) = .empty,
    /// What each generation step produced, so it runs once.
    produced: std.AutoHashMapUnmanaged(Configuration.Step.Index, Resolved) = .empty,
    notices: std.ArrayList(build_graph.Notice) = .empty,
    /// Unavailable modules already announced, as `name step`: one notice each,
    /// however many compile units import them.
    announced: std.StringHashMapUnmanaged(void) = .empty,

    fn seenKey(x: *Extractor, compile_index: Configuration.Step.Index) !SeenKey {
        const compile = x.compileStep(compile_index);
        return .{ .root_module = compile.root_module, .test_kind = compile.flags3.kind.isTest() };
    }

    fn compileStep(x: *const Extractor, index: Configuration.Step.Index) Configuration.Step.Compile {
        return index.ptr(x.conf).extended.get(x.conf.extra).compile;
    }

    /// The compile steps among the dependencies, transitively, of the
    /// top-level step called `name`, in dependency order.
    fn compileStepsUnder(x: *Extractor, name: []const u8) ![]const Configuration.Step.Index {
        const conf = x.conf;
        var start: ?Configuration.Step.Index = null;
        for (conf.steps, 0..) |step, index| {
            if (step.extended.tag(conf) == .top_level and std.mem.eql(u8, step.name.slice(conf), name)) {
                start = @as(Configuration.Step.Index, @fromBackingInt(@intCast(index)));
            }
        }
        var compiles: std.ArrayList(Configuration.Step.Index) = .empty;
        const first = start orelse return compiles.items;
        var visited: std.array_hash_map.Auto(Configuration.Step.Index, void) = .empty;
        try visited.put(x.arena, first, {});
        var next: usize = 0;
        while (next < visited.count()) : (next += 1) {
            const index = visited.keys()[next];
            const step = index.ptr(conf);
            if (step.extended.tag(conf) == .compile) try compiles.append(x.arena, index);
            for (step.deps.slice(conf)) |dependency| try visited.put(x.arena, dependency, {});
        }
        return compiles.items;
    }

    fn indexGeneratedFiles(x: *Extractor) !void {
        const conf = x.conf;
        for (conf.steps, 0..) |step, step_number| {
            const index: Configuration.Step.Index = @fromBackingInt(@intCast(step_number));
            const extended = step.extended.get(conf.extra);
            switch (extended) {
                .options => |options| try x.owners.put(x.arena, options.generated_file, index),
                .write_file => |write_file| try x.owners.put(x.arena, write_file.generated_directory, index),
                .config_header => |config_header| try x.owners.put(x.arena, config_header.generated_dir, index),
                .translate_c => |translate_c| try x.owners.put(x.arena, translate_c.output_file, index),
                .obj_copy => |obj_copy| try x.owners.put(x.arena, obj_copy.output_file, index),
                .run => |run| {
                    for ([_]?Configuration.Step.Run.CapturedStream{ run.captured_stdout.value, run.captured_stderr.value }) |captured| {
                        if (captured) |stream| try x.owners.put(x.arena, stream.generated_file, index);
                    }
                    for (run.args.slice) |argument| {
                        if (argument.get(conf).generated.value) |generated| try x.owners.put(x.arena, generated, index);
                    }
                },
                .compile => |compile_step| {
                    for ([_]?Configuration.GeneratedFileIndex{
                        compile_step.emit_directory.value, compile_step.generated_docs.value,
                        compile_step.generated_asm.value,  compile_step.generated_bin.value,
                        compile_step.generated_pdb.value,  compile_step.generated_implib.value,
                        compile_step.generated_h.value,
                    }) |generated| {
                        if (generated) |file| try x.owners.put(x.arena, file, index);
                    }
                },
                else => {},
            }
        }
    }

    /// The unit for `compile_index`, or null when its root module has no
    /// usable source.
    fn unit(x: *Extractor, compile_index: Configuration.Step.Index) !?build_graph.Unit {
        const conf = x.conf;
        const compile_step = x.compileStep(compile_index);
        const step_name = compile_index.ptr(conf).name.slice(conf);

        // Breadth first from the root, like the build runner, so names come
        // out the same: the root is `root`, others keep the name of their
        // first import and gain a number when it is taken.
        var order: std.array_hash_map.Auto(Configuration.Module.Index, []const u8) = .empty;
        try order.put(x.arena, compile_step.root_module, "root");
        var used_names: std.StringHashMapUnmanaged(void) = .empty;
        try used_names.put(x.arena, "root", {});
        var next: usize = 0;
        while (next < order.count()) : (next += 1) {
            const module = order.keys()[next].get(conf);
            if (module.import_table == .invalid) continue;
            const imports = module.import_table.get(conf).imports.mal;
            for (imports.items(.name), imports.items(.module)) |import_name, imported| {
                if (order.contains(imported)) continue;
                var candidate: []const u8 = import_name.slice(conf);
                var suffix: usize = 0;
                while (used_names.contains(candidate)) : (suffix += 1) {
                    candidate = try x.arena.print("{s}{d}", .{ import_name.slice(conf), suffix });
                }
                try used_names.put(x.arena, candidate, {});
                try order.put(x.arena, imported, candidate);
            }
        }

        const modules = try x.arena.alloc(build_graph.Module, order.count());
        for (order.keys(), order.values(), modules) |index, name, *out| {
            out.* = try x.moduleOf(index, name, order.keys());
        }
        if (modules[0].source.path() == null) {
            try x.notices.append(x.arena, .{ .level = .warning, .text = try x.arena.print(
                "compile unit '{s}' is skipped: its root module has no analyzable source",
                .{step_name},
            ) });
            return null;
        }
        return .{
            .name = step_name,
            .kind = switch (compile_step.flags3.kind) {
                .exe => .exe,
                .lib => .lib,
                .obj => .obj,
                .@"test" => .@"test",
                .test_obj => .test_obj,
            },
            .modules = modules,
        };
    }

    fn moduleOf(
        x: *Extractor,
        index: Configuration.Module.Index,
        name: []const u8,
        graph_order: []const Configuration.Module.Index,
    ) !build_graph.Module {
        const conf = x.conf;
        const configured = index.get(conf);
        var imports: std.ArrayList(build_graph.Import) = .empty;
        if (configured.import_table != .invalid) {
            const table = configured.import_table.get(conf).imports.mal;
            for (table.items(.name), table.items(.module)) |import_name, imported| {
                const position = std.mem.findScalar(Configuration.Module.Index, graph_order, imported).?;
                try imports.append(x.arena, .{ .name = try x.arena.dupe(u8, import_name.slice(conf)), .module = @intCast(position) });
            }
        }

        const source: build_graph.Source = if (configured.root_source_file.unwrap()) |lazy_path| switch (try x.resolve(lazy_path)) {
            .file => |file| .{ .file = file },
            .generated => |generated| .{ .generated = generated },
            .unavailable => |unavailable| unavailable: {
                const announcement = try x.arena.print("{s} {s}", .{ name, unavailable.step });
                if (!(try x.announced.getOrPut(x.arena, announcement)).found_existing) {
                    try x.notices.append(x.arena, .{ .level = .information, .text = try x.arena.print(
                        "module '{s}' is unavailable: step '{s}' {s}; analysis continues without it",
                        .{ name, unavailable.step, unavailable.reason },
                    ) });
                }
                break :unavailable .{ .unavailable = unavailable };
            },
        } else .none;

        return .{
            .name = try x.arena.dupe(u8, name),
            .source = source,
            .imports = imports.items,
            .target = try x.target(configured),
            .optimize = switch (configured.flags.optimize) {
                .debug => .debug,
                .safe => .safe,
                .fast => .fast,
                .small => .small,
                .default => null,
            },
            .link_libc = configured.flags2.link_libc == .true,
        };
    }

    fn target(x: *Extractor, configured: Configuration.Module) !?build_graph.Target {
        const resolved = configured.resolved_target.get(x.conf) orelse return null;
        const query = resolved.unwrapQuery(x.conf) orelse return null;
        return .{ .triple = try query.zigTriple(x.arena), .cpu = try query.serializeCpuAlloc(x.arena) };
    }

    /// Resolves a lazy path, producing the file it names when a generation
    /// step the analyzer can carry out makes it.
    pub fn resolve(x: *Extractor, index: Configuration.LazyPath.Index) error{OutOfMemory}!Resolved {
        const conf = x.conf;
        switch (index.get(conf)) {
            .source_path => |source_path| {
                const root = try x.packageRoot(source_path.owner);
                return .{ .file = try std.Io.Dir.path.resolveAlloc(x.arena, &.{ root, source_path.sub_path.slice(conf) }) };
            },
            .relative => |relative| {
                const sub_path = relative.sub_path.slice(conf);
                const base = switch (relative.flags.base) {
                    .cwd, .build_root => x.build_root,
                    .zig_lib => zig_environment.libDirectory(x.io) catch return .unavailableBecause("zig lib directory", "is unknown"),
                    else => return .unavailableBecause("cache path", "lives in a build cache directory"),
                };
                return .{ .file = try std.Io.Dir.path.resolveAlloc(x.arena, &.{ base, sub_path }) };
            },
            .generated => |generated| {
                const owner = x.owners.get(generated.index) orelse
                    return .unavailableBecause("unknown step", "no step produces this file");
                const produced = try x.produce(owner);
                const base = switch (produced) {
                    .unavailable => return produced,
                    .file => |file| file,
                    .generated => |from| from.path,
                };
                var path = base;
                for (0..generated.flags.up) |_| path = std.Io.Dir.path.dirname(path) orelse path;
                const joined = try std.Io.Dir.path.resolveAlloc(x.arena, &.{ path, generated.sub_path.slice(conf) });
                return .{ .generated = .{ .path = joined, .step = owner.ptr(conf).name.slice(conf) } };
            },
        }
    }

    fn packageRoot(x: *const Extractor, owner: Configuration.Package.Index) ![]const u8 {
        const package = owner.get(x.conf) orelse return x.build_root;
        return std.Io.Dir.path.resolveAlloc(x.arena, &.{ x.build_root, package.root_path.slice(x.conf) });
    }

    /// Runs the generation step `owner` if the analyzer can without executing
    /// anything, once.
    fn produce(x: *Extractor, owner: Configuration.Step.Index) error{OutOfMemory}!Resolved {
        if (x.produced.get(owner)) |known| return known;
        const conf = x.conf;
        const step = owner.ptr(conf);
        const name = step.name.slice(conf);
        // A step that depends on itself resolves to unavailable.
        try x.produced.put(x.arena, owner, .unavailableBecause(name, "depends on its own output"));
        const result: Resolved = switch (step.extended.tag(conf)) {
            .options => try generated_sources.options(x.io, x.arena, conf, owner, x.generated_root, x),
            .write_file => try generated_sources.writeFile(x.io, x.arena, conf, owner, x.generated_root, x),
            .run => run: {
                const runs_built_program = step.extended.get(conf.extra).run.producer.value != null;
                break :run .unavailableBecause(name, if (runs_built_program)
                    "runs a program built by the project, which the analyzer never executes"
                else
                    "runs an external command, which the analyzer never executes");
            },
            .translate_c => .unavailableBecause(name, "translates C, which the analyzer does not run"),
            .config_header => .unavailableBecause(name, "writes a configuration header, which the analyzer does not generate"),
            .compile => .unavailableBecause(name, "needs a compiled artifact, which the analyzer does not build"),
            else => .unavailableBecause(name, "is a step the analyzer does not run"),
        };
        try x.produced.put(x.arena, owner, result);
        return result;
    }
};
