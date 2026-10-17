//! Scaling regression test for the lifecycle and container proof engines.
//!
//! Each case generates a file of `count` and of `4 * count` repetitions of a
//! shape that once made an engine quadratic (one long function, containers
//! nested in one root container, ...), runs only that engine's rules through
//! the file pipeline, or the project pipeline for the checks that need
//! cross-file summaries, and fails when the larger file takes more than
//! `max_ratio` times the CPU time of the smaller one. Linear work takes about
//! four times as long; the quadratic versions took 9 to 60 times as long.
//! Only the rules are timed, on this thread's CPU clock, and the fastest of a
//! few runs counts, so other load on the machine hardly moves the ratio; a
//! ratio over the bound is measured once more before the case fails. The
//! ratio, not the time, is what counts, so the test runs in any build mode.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");
const analysis = zig_analyzer.analysis;
const syntax_scope = zig_analyzer.syntax.scope;
const project_rules = zig_analyzer.project_rules;

const max_ratio = 8.0;
/// Runs of the smaller file, whose short time noise moves most, and of the larger.
const small_runs = 3;
const large_runs = 2;

/// One function whose body repeats `line`, `{0d}` standing for the
/// repetition's number.
const Body = struct {
    /// Declarations before the function, repeated like `line`.
    preamble: []const u8 = "",
    line: []const u8 = "",
    /// Statements after the repetitions, written once.
    tail: []const u8 = "",
};

const Shape = union(enum) {
    body: Body,
    /// Containers owning fields, each nesting two more, all inside one root
    /// container, with the init, cleanup, growth and realloc around them.
    rooted_containers,
    /// Containers inside one root container, each borrowing an element of a
    /// list and iterating a map while helpers declared beside it grow them.
    rooted_helpers: Helpers,
};

const Helpers = struct {
    /// Every container's list is `items` rather than `itemsN`.
    shared_field: bool,
};

const deferred_allocations: Shape = .{ .body = .{
    .line = "const buffer{0d} = try allocator.alloc(u8, 4); defer allocator.free(buffer{0d});",
} };
const leaked_allocations: Shape = .{ .body = .{
    .line = "const buffer{0d} = try allocator.alloc(u8, 4); _ = buffer{0d};",
} };
/// Used only when the function ends, so every allocation lives through it.
const late_allocations: Shape = .{ .body = .{
    .line = "const buffer{0d} = try allocator.alloc(u8, 4); errdefer allocator.free(buffer{0d}); defer use(buffer{0d});",
} };
const error_cleanups: Shape = .{ .body = .{
    .line = "const buffer{0d} = try allocator.alloc(u8, 4); errdefer allocator.free(buffer{0d});" ++
        " var file{0d} = try dir.openFile(io, \"x\", .{{}}); errdefer file{0d}.close(io);",
} };
const owned_fields: Shape = .{ .body = .{
    .line = "var pair{0d}: Pair = undefined; pair{0d}.first = try allocator.dupe(u8, \"x\");" ++
        " pair{0d}.second = try allocator.dupe(u8, \"y\"); usePair(pair{0d});",
} };
const container_views: Shape = .{ .body = .{
    .line = "const view{0d} = list.items; use(view{0d}); try list.append(allocator, 1);",
} };
const entry_pointers: Shape = .{ .body = .{
    .line = "const entry{0d} = map.getPtr({0d}) orelse return list; useEntry(entry{0d}); try map.put(allocator, {0d}, 1);",
} };
const map_iterators: Shape = .{ .body = .{
    .line = "var iterator{0d} = map.iterator(); while (iterator{0d}.next()) |entry| useEntry(entry.value_ptr);",
} };
/// Element pointers last used before a helper grows their list.
const pointers_before_growth: Shape = .{ .body = .{
    .line = "const pointer{0d} = &list.items[0]; pointer{0d}.* = 1; try growList(&list);",
} };
/// Loops without braces over map iterators, then one helper growing the map.
const late_map_growth: Shape = .{ .body = .{
    .line = "var iterator{0d} = map.iterator(); while (iterator{0d}.next()) |entry| useEntry(entry.value_ptr);",
    .tail = "try putEntry(map);",
} };
const unreleased_lists: Shape = .{ .body = .{
    .line = "var list{0d}: std.ArrayList(u8) = .empty; try list{0d}.append(allocator, 1);",
} };
const returned_lists: Shape = .{ .body = .{
    .line = "var list{0d}: std.ArrayList(u8) = .empty; try list{0d}.append(allocator, 1); if (early) return list{0d};",
} };
const deferred_lists: Shape = .{ .body = .{
    .line = "var list{0d}: std.ArrayList(u8) = .empty; defer list{0d}.deinit(allocator); try list{0d}.append(allocator, 1);",
} };
/// File-level copies of a container declaring the same nested names.
const repeated_containers: Shape = .{ .body = .{
    .preamble = "pub const Copy{0d} = struct {{ const Mode = enum {{ fast, safe }};" ++
        " const Options = struct {{ mode: Mode, depth: u8 }};" ++
        " fn pick(options: Options) u8 {{ return if (options.mode == .fast) options.depth else 0; }} }};\n",
} };
const type_info_aliases: Shape = .{ .body = .{
    .preamble = "fn fields{0d}(comptime T: type) usize {{ const info{0d} = @typeInfo(T).@\"struct\"; return info{0d}.fields.len; }}\n",
} };

const Case = struct {
    rules: []const analysis.Rule,
    shape: Shape,
    count: usize,
    /// Runs the project pipeline over the file as a one-file project.
    project: bool = false,
};

const allocation_rules = [_]analysis.Rule{
    .unreleased_allocation,
    .cleanup_after_fallible_operation,
    .mismatched_allocation_release,
    .double_release,
    .use_after_release,
    .overwritten_owning_value,
    .partial_ownership_transfer,
};
const element_rules = [_]analysis.Rule{ .invalidated_element_pointer, .iterator_invalidated_during_loop, .stale_index_map };
const cleanup_rules = [_]analysis.Rule{ .defer_uses_reassigned_binding, .resource_cleanup_on_error_only };
const escape_rules = [_]analysis.Rule{ .returning_deinitialized_view, .returning_arena_allocation };
const binding_rules = [_]analysis.Rule{ .unused_local, .pointless_discard };
const helper_mutation_rules = [_]analysis.Rule{ .invalidated_element_pointer, .iterator_invalidated_during_loop };
const container_rules = [_]analysis.Rule{
    .unresolved_member,
    .missing_switch_prong,
    .missing_struct_field,
    .non_exhaustive_switch_else,
    .unknown_comptime_member,
    .non_exhaustive_error_switch,
};

/// Every case was quadratic before: the old engines took 9 to 60 times as
/// long on the larger file.
const cases = [_]Case{
    .{ .rules = &allocation_rules, .shape = deferred_allocations, .count = 100 },
    .{ .rules = &allocation_rules, .shape = leaked_allocations, .count = 100 },
    .{ .rules = &allocation_rules, .shape = late_allocations, .count = 100 },
    .{ .rules = &allocation_rules, .shape = .rooted_containers, .count = 6 },
    .{ .rules = &.{.invalidated_container_view}, .shape = .rooted_containers, .count = 6 },
    .{ .rules = &.{.invalidated_container_view}, .shape = container_views, .count = 100 },
    .{ .rules = &element_rules, .shape = entry_pointers, .count = 100 },
    .{ .rules = &element_rules, .shape = map_iterators, .count = 100 },
    .{ .rules = &cleanup_rules, .shape = .rooted_containers, .count = 6 },
    .{ .rules = &cleanup_rules, .shape = deferred_allocations, .count = 100 },
    .{ .rules = &cleanup_rules, .shape = error_cleanups, .count = 100 },
    .{ .rules = &.{.missing_errdefer}, .shape = deferred_allocations, .count = 100 },
    .{ .rules = &.{.missing_errdefer}, .shape = owned_fields, .count = 100 },
    .{ .rules = &.{.returning_released_value}, .shape = deferred_allocations, .count = 150 },
    .{ .rules = &escape_rules, .shape = deferred_lists, .count = 100 },
    .{ .rules = &container_rules, .shape = repeated_containers, .count = 60 },
    .{ .rules = &container_rules, .shape = type_info_aliases, .count = 300 },
    .{ .rules = &.{.missing_container_deinit}, .shape = unreleased_lists, .count = 100 },
    .{ .rules = &.{.missing_container_deinit}, .shape = returned_lists, .count = 100 },
    .{ .rules = &binding_rules, .shape = leaked_allocations, .count = 150 },
    .{ .rules = &helper_mutation_rules, .shape = .{ .rooted_helpers = .{ .shared_field = false } }, .count = 200, .project = true },
    .{ .rules = &helper_mutation_rules, .shape = .{ .rooted_helpers = .{ .shared_field = true } }, .count = 100, .project = true },
    .{ .rules = &helper_mutation_rules, .shape = pointers_before_growth, .count = 100, .project = true },
    .{ .rules = &helper_mutation_rules, .shape = late_map_growth, .count = 60, .project = true },
};

fn generate(allocator: std.mem.Allocator, comptime shape: Shape, count: usize) ![:0]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    const out = &text.writer;
    try out.writeAll("const std = @import(\"std\");\n\n");
    switch (shape) {
        .body => |body| {
            if (comptime body.preamble.len != 0) for (0..count) |index| try out.print(body.preamble, .{index});
            try out.writeAll(
                \\const Pair = struct { first: []u8, second: []u8 };
                \\fn use(_: []const u8) void {}
                \\fn usePair(_: Pair) void {}
                \\fn useEntry(_: *u32) void {}
                \\fn growList(list: *std.ArrayList(u8)) !void {
                \\    try list.append(std.heap.page_allocator, 0);
                \\}
                \\fn putEntry(map: *std.AutoHashMapUnmanaged(u32, u32)) !void {
                \\    try map.put(std.heap.page_allocator, 0, 0);
                \\}
                \\pub fn run(
                \\    allocator: std.mem.Allocator,
                \\    io: std.Io,
                \\    dir: std.Io.Dir,
                \\    map: *std.AutoHashMapUnmanaged(u32, u32),
                \\    early: bool,
                \\) !std.ArrayList(u8) {
                \\    _ = .{ io, dir, map, early };
                \\    var list: std.ArrayList(u8) = .empty;
                \\
            );
            if (comptime body.line.len != 0) for (0..count) |index| {
                try out.writeAll("    ");
                try out.print(body.line, .{index});
                try out.writeByte('\n');
            };
            if (comptime body.tail.len != 0) try out.writeAll("    " ++ body.tail ++ "\n");
            try out.writeAll("    return list;\n}\n");
        },
        .rooted_containers => {
            try out.writeAll("const Root = struct {\n    allocator: std.mem.Allocator,\n    title: []u8,\n");
            for (0..count) |index| try writeContainer(out, index, 0);
            try out.writeAll("    fn deinit(self: *Root) void {\n        self.allocator.free(self.title);\n    }\n};\n");
        },
        .rooted_helpers => |helpers| {
            try out.writeAll("const Root = struct {\n");
            for (0..count) |index| try writeHelpers(out, index, helpers.shared_field);
            try out.writeAll("};\n");
        },
    }
    return text.toOwnedSliceSentinel(0);
}

/// One `ThingN` of `rooted_containers`, nesting `ThingNInner` two levels deep.
fn writeContainer(out: *std.Io.Writer, index: usize, depth: usize) !void {
    var name_buffer: [64]u8 = undefined;
    var name: std.Io.Writer = .fixed(&name_buffer);
    try name.print("Thing{d}", .{index});
    for (0..depth) |_| try name.writeAll("Inner");
    const type_name = name.buffered();
    var field_buffer: [64]u8 = undefined;
    const field = std.ascii.lowerString(&field_buffer, type_name);
    try out.print(
        \\const {0s} = struct {{
        \\    allocator: std.mem.Allocator,
        \\    name_{1s}: []u8,
        \\    items_{1s}: std.ArrayList([]u8),
        \\    entries_{1s}: std.ArrayList({0s}Entry),
        \\    const {0s}Entry = struct {{ key_{1s}: []u8, value_{1s}: []u8 }};
        \\
    , .{ type_name, field });
    if (depth < 2) try writeContainer(out, index, depth + 1);
    try out.print(
        \\    fn init(allocator: std.mem.Allocator) !{0s} {{
        \\        const name_{1s} = try allocator.dupe(u8, "name");
        \\        return .{{ .allocator = allocator, .name_{1s} = name_{1s}, .items_{1s} = .empty, .entries_{1s} = .empty }};
        \\    }}
        \\    fn deinit(self: *{0s}) void {{
        \\        self.allocator.free(self.name_{1s});
        \\        for (self.items_{1s}.items) |item| self.allocator.free(item);
        \\        self.items_{1s}.deinit(self.allocator);
        \\        for (self.entries_{1s}.items) |entry| self.allocator.free(entry.key_{1s});
        \\        self.entries_{1s}.deinit(self.allocator);
        \\    }}
        \\    fn add(self: *{0s}, text: []const u8) !void {{
        \\        try self.items_{1s}.append(self.allocator, try self.allocator.dupe(u8, text));
        \\        const key_{1s} = try self.allocator.dupe(u8, text);
        \\        try self.entries_{1s}.append(self.allocator, .{{ .key_{1s} = key_{1s}, .value_{1s} = try self.allocator.dupe(u8, text) }});
        \\    }}
        \\    fn rename(self: *{0s}, text: []const u8) !void {{
        \\        self.name_{1s} = try self.allocator.dupe(u8, text);
        \\        const entry = &self.entries_{1s}.items[0];
        \\        entry.key_{1s} = try self.allocator.dupe(u8, text);
        \\    }}
        \\    fn shrink(self: *{0s}) !void {{
        \\        self.entries_{1s}.items[0] = self.entries_{1s}.items[1];
        \\        self.entries_{1s}.items = try self.allocator.realloc(self.entries_{1s}.items, 1);
        \\    }}
        \\}};
        \\fn use{1s}(allocator: std.mem.Allocator) !void {{
        \\    var thing = try {0s}.init(allocator);
        \\    defer thing.deinit();
        \\    try thing.add("y");
        \\}}
        \\
    , .{ type_name, field });
}

/// One `ThingN` of `rooted_helpers` and the helpers that grow its list
/// and its map.
fn writeHelpers(out: *std.Io.Writer, index: usize, shared_field: bool) !void {
    var field_buffer: [64]u8 = undefined;
    const field = if (shared_field) "items" else try std.mem.print(&field_buffer, "items{d}", .{index});
    try out.print(
        \\    const Thing{0d} = struct {{
        \\        allocator: std.mem.Allocator,
        \\        {1s}: std.ArrayList(u32),
        \\        fn touch(self: *Thing{0d}) !void {{
        \\            const first = &self.{1s}.items[0];
        \\            try grow{0d}(self.allocator, &self.{1s});
        \\            first.* = 1;
        \\        }}
        \\        fn walk(self: *Thing{0d}, map: *std.AutoHashMapUnmanaged(u32, u32)) !void {{
        \\            var iterator = map.iterator();
        \\            while (iterator.next()) |entry| {{
        \\                try put{0d}(self.allocator, map);
        \\                _ = entry;
        \\            }}
        \\        }}
        \\    }};
        \\    fn grow{0d}(allocator: std.mem.Allocator, list: *std.ArrayList(u32)) !void {{
        \\        try list.append(allocator, 1);
        \\    }}
        \\    fn put{0d}(allocator: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32)) !void {{
        \\        try map.put(allocator, 1, 1);
        \\    }}
        \\
    , .{ index, field });
}

/// The fastest of `runs` runs of the rules `configuration` enables over
/// `source`, in nanoseconds of this thread's CPU time. Tokens, tree and
/// scope index are built outside the clock: they are linear, and would hide
/// the rules' share.
fn cpuTime(io: std.Io, configuration: analysis.Configuration, source: [:0]const u8, runs: usize) !u64 {
    const allocator = std.testing.allocator;
    const tokens = try zig_analyzer.syntax.tokens.tokenize(allocator, source);
    defer allocator.free(tokens);
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    var fastest: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        // A fresh index each run: the identifier table it builds on demand is rule work.
        var scopes = try syntax_scope.Index.init(allocator, source, tokens);
        defer scopes.deinit();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const start = std.Io.Clock.cpu_thread.now(io);
        _ = try analysis.findingsWith(arena.allocator(), source, configuration, .{ .tokens = tokens, .tree = &tree, .scopes = &scopes });
        const elapsed = start.durationTo(std.Io.Clock.cpu_thread.now(io)).nanoseconds;
        fastest = @min(fastest, @as(u64, @intCast(@max(elapsed, 1))));
    }
    return fastest;
}

/// `cpuTime` for whole-project analysis of `source` as a one-file project.
/// The project pipeline tokenizes, indexes and summarizes the file itself,
/// so that linear work is timed too.
fn projectCpuTime(io: std.Io, configuration: analysis.Configuration, source: [:0]const u8, runs: usize) !u64 {
    const files = [_]project_rules.SourceFile{.{ .path = "main.zig", .source = source }};
    var fastest: u64 = std.math.maxInt(u64);
    for (0..runs) |_| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const start = std.Io.Clock.cpu_thread.now(io);
        _ = try project_rules.findings(arena.allocator(), &files, configuration);
        const elapsed = start.durationTo(std.Io.Clock.cpu_thread.now(io)).nanoseconds;
        fastest = @min(fastest, @as(u64, @intCast(@max(elapsed, 1))));
    }
    return fastest;
}

fn growthRatio(io: std.Io, comptime case: Case) !f64 {
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .off);
    for (case.rules) |rule| configuration.levels[@backingInt(rule)] = .warning;
    const small = try generate(std.testing.allocator, case.shape, case.count);
    defer std.testing.allocator.free(small);
    const large = try generate(std.testing.allocator, case.shape, case.count * 4);
    defer std.testing.allocator.free(large);
    const time = if (case.project) projectCpuTime else cpuTime;
    const small_time = try time(io, configuration, small, small_runs);
    const large_time = try time(io, configuration, large, large_runs);
    return @as(f64, @floatFromInt(large_time)) / @as(f64, @floatFromInt(small_time));
}

test "the lifecycle and container engines scale linearly with the input" {
    const io = std.testing.io;
    inline for (cases) |case| {
        var ratio = try growthRatio(io, case);
        if (ratio > max_ratio) ratio = @min(ratio, try growthRatio(io, case));
        if (ratio > max_ratio) {
            const shape = switch (case.shape) {
                .body => |body| if (body.line.len != 0) body.line else body.preamble,
                .rooted_containers => "rooted containers",
                .rooted_helpers => |helpers| if (helpers.shared_field) "rooted helper mutations of `items`" else "rooted helper mutations",
            };
            std.debug.print("{s} on {d} and {d} repetitions of `{s}`: {d:.1}x slower on the larger file (at most {d:.0}x)\n", .{
                case.rules[0].code(),
                case.count,
                case.count * 4,
                shape,
                ratio,
                max_ratio,
            });
            return error.SuperlinearRule;
        }
    }
}
