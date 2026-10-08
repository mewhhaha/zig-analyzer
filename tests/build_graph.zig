//! Build-graph discovery against small fixture projects (`fixtures/projects`):
//! which compile units a build declares, how documents pick one, and how
//! generated and dependency modules are provided without running anything.
//! Needs the host `zig` (it configures each build) but no patched compiler.
const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const projects = @import("projects.zig");

const compile_units = zig_analyzer.compiler.compile_units;
const allocator = std.testing.allocator;
const io = std.testing.io;

/// `select` for the file at `sub_path` of `project`.
fn selectFile(arena: std.mem.Allocator, project: projects.Project, sub_path: []const u8) !compile_units.Selected {
    return compile_units.select(io, arena, try project.path(arena, sub_path), .discover);
}

fn containsArgument(arguments: []const []const u8, needle: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, needle)) return true;
    return false;
}

test "the check step's compile units are preferred over install" {
    var project = try projects.copy(allocator, "check_and_install");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph = (try compile_units.buildGraph(io, project.root, .discover)).?;
    defer graph.release();
    try std.testing.expectEqual(@as(?zig_analyzer.compiler.build_graph.Selection, .check), graph.selection);
    try std.testing.expectEqual(@as(usize, 1), graph.units.len);
    try std.testing.expect(std.mem.find(u8, graph.units[0].name, "checked") != null);

    const checked = try selectFile(arena, project, "src/checked.zig");
    try std.testing.expect(checked.unit != null);
    try std.testing.expectEqualStrings("build-obj", checked.launch.command);
    const root_argument = try arena.print("-Mroot={s}", .{try project.path(arena, "src/checked.zig")});
    try std.testing.expect(containsArgument(checked.launch.arguments, root_argument));

    // Reached through the unit's relative imports.
    const helper = try selectFile(arena, project, "src/helper.zig");
    try std.testing.expectEqualStrings(checked.unit.?, helper.unit.?);
    try std.testing.expectEqualStrings(try project.path(arena, "src/checked.zig"), helper.root_source);

    // Installed but not checked, and unreferenced files, are analyzed alone.
    for ([_][]const u8{ "src/app.zig", "src/unrelated.zig" }) |sub_path| {
        const alone = try selectFile(arena, project, sub_path);
        try std.testing.expect(alone.unit == null);
        try std.testing.expectEqualStrings(try project.path(arena, sub_path), alone.root_source);
        try std.testing.expectEqual(@as(usize, 1), alone.launch.arguments.len);
    }
}

test "install units are the fallback when there is no check step" {
    var project = try projects.copy(allocator, "install_only");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const graph = (try compile_units.buildGraph(io, project.root, .discover)).?;
    defer graph.release();
    try std.testing.expectEqual(@as(?zig_analyzer.compiler.build_graph.Selection, .install), graph.selection);

    const util = try selectFile(arena, project, "src/util.zig");
    try std.testing.expect(util.unit != null);
    try std.testing.expectEqualStrings(try project.path(arena, "src/app.zig"), util.root_source);

    const containing = try graph.unitsContaining(io, arena, try project.path(arena, "src/util.zig"));
    try std.testing.expectEqual(@as(usize, 1), containing.len);
}

test "Options and WriteFile modules are generated without running anything" {
    var project = try projects.copy(allocator, "generated");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const selected = try selectFile(arena, project, "src/main.zig");
    try std.testing.expectEqual(@as(usize, 0), selected.notices.len);
    try std.testing.expect(containsArgument(selected.launch.arguments, "build_options"));
    try std.testing.expect(containsArgument(selected.launch.arguments, "table"));

    const graph = (try compile_units.buildGraph(io, project.root, .discover)).?;
    defer graph.release();
    const unit = graph.units[0];
    var checked_modules: usize = 0;
    for (unit.modules) |module| {
        const generated = switch (module.source) {
            .generated => |generated| generated,
            else => continue,
        };
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, generated.path, arena, .limited(1024 * 1024));
        if (std.mem.eql(u8, module.name, "build_options")) {
            try std.testing.expect(std.mem.find(u8, contents, "pub const answer: u32 = 40;") != null);
            try std.testing.expect(std.mem.find(u8, contents, "pub const label: []const u8 = \"generated\";") != null);
            try std.testing.expect(std.mem.find(u8, generated.path, ".zig-analyzer/generated") != null);
        } else {
            try std.testing.expectEqualStrings("table", module.name);
            try std.testing.expectEqualStrings("pub const bonus: u32 = 2;\n", contents);
        }
        checked_modules += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked_modules);
}

test "dependency modules resolve to the dependency package source" {
    var project = try projects.copy(allocator, "dependency");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const selected = try selectFile(arena, project, "src/main.zig");
    const shared_argument = try arena.print("-Mshared={s}", .{try project.path(arena, "shared/shared.zig")});
    try std.testing.expect(containsArgument(selected.launch.arguments, "shared"));
    try std.testing.expect(containsArgument(selected.launch.arguments, shared_argument));

    const imported = (try compile_units.namedModuleSource(io, allocator, try project.path(arena, "src/main.zig"), "shared", .cached)).?;
    defer allocator.free(imported);
    try std.testing.expectEqualStrings(try project.path(arena, "shared/shared.zig"), imported);
    try std.testing.expect(try compile_units.namedModuleSource(io, allocator, try project.path(arena, "src/main.zig"), "missing", .cached) == null);
}

test "a module generated by running a built program is unavailable and the program never runs" {
    var project = try projects.copy(allocator, "run_generated");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const selected = try selectFile(arena, project, "src/main.zig");
    try std.testing.expect(selected.unit != null);
    try std.testing.expectEqual(@as(usize, 1), selected.notices.len);
    try std.testing.expect(std.mem.find(u8, selected.notices[0].text, "module 'generated'") != null);
    try std.testing.expect(std.mem.find(u8, selected.notices[0].text, "run exe generator") != null);
    try std.testing.expect(std.mem.find(u8, selected.notices[0].text, "never executes") != null);
    try std.testing.expectEqual(.information, selected.notices[0].level);
    try std.testing.expectEqual(@as(usize, 1), selected.unavailable.len);
    try std.testing.expectEqualStrings("generated", selected.unavailable[0].import_name);
    try std.testing.expect(std.mem.find(u8, selected.unavailable[0].step, "run exe generator") != null);
    for (selected.launch.arguments) |argument| {
        try std.testing.expect(!std.mem.startsWith(u8, argument, "-Mgenerated"));
        try std.testing.expect(!std.mem.eql(u8, argument, "generated"));
    }

    // Told once per project, not per document.
    const again = try selectFile(arena, project, "src/main.zig");
    try std.testing.expectEqual(@as(usize, 0), again.notices.len);

    try std.testing.expect(!try project.exists("marker.txt"));
    try std.testing.expect(!try project.exists(".zig-analyzer/generated"));
}

test "a build script that fails to configure falls back to the file alone, reported once" {
    var project = try projects.copy(allocator, "install_only");
    defer project.deinit(allocator);
    try project.write("build.zig", "pub fn build() void { this does not parse }\n");
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const selected = try selectFile(arena, project, "src/app.zig");
    try std.testing.expect(selected.unit == null);
    try std.testing.expectEqualStrings(try project.path(arena, "src/app.zig"), selected.root_source);
    try std.testing.expectEqual(@as(usize, 1), selected.notices.len);
    try std.testing.expect(std.mem.find(u8, selected.notices[0].text, "could not configure the build") != null);

    const again = try selectFile(arena, project, "src/util.zig");
    try std.testing.expect(again.unit == null);
    try std.testing.expectEqual(@as(usize, 0), again.notices.len);
}

test "editing the build script rediscovers the graph" {
    var project = try projects.copy(allocator, "check_and_install");
    defer project.deinit(allocator);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before = try selectFile(arena, project, "src/app.zig");
    try std.testing.expect(before.unit == null);

    const install_only = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/projects/install_only/build.zig", arena, .limited(1024 * 1024));
    try project.write("build.zig", install_only);
    const after = try selectFile(arena, project, "src/app.zig");
    try std.testing.expect(after.unit != null);

    // The language server drops the cached graph after a save.
    try compile_units.forgetBuildGraph(io, try project.path(arena, "src/app.zig"));
    try std.testing.expect(try compile_units.buildGraph(io, project.root, .cached) == null);
}

test "this checkout's compiler examples belong to a compile unit" {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const working = try std.process.currentPathAlloc(io, arena);

    var examples = try std.Io.Dir.cwd().openDir(io, "examples/compiler", .{ .iterate = true });
    defer examples.close(io);
    var iterator = examples.iterate();
    var checked: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = try std.Io.Dir.path.join(arena, &.{ working, "examples/compiler", entry.name });
        const selected = try compile_units.select(io, arena, path, .discover);
        try std.testing.expect(selected.unit != null);
        try std.testing.expectEqualStrings("test-obj", selected.launch.command);
        checked += 1;
    }
    try std.testing.expect(checked >= 7);

    // Examples that no test imports are analyzed on their own.
    const isolated = try std.Io.Dir.path.join(arena, &.{ working, "examples/diagnostics/compiler_error.zig" });
    const alone = try compile_units.select(io, arena, isolated, .discover);
    try std.testing.expect(alone.unit == null);
    try std.testing.expectEqualStrings(isolated, alone.root_source);
}
