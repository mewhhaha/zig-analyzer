const std = @import("std");
const analysis = @import("zig_analyzer").analysis;
const project_rules = @import("zig_analyzer").project_rules;
const compile_batch = @import("fuzz/compile_batch.zig");
const round_trip = @import("fuzz/round_trip.zig");

const generated_program_count = 600;
const profile_program_count = 150;
const fix_program_count = 100;
const metamorphic_stride = 5;
const mutation_seed_count = 48;
const mutations_per_seed = 16;
const largest_robustness_input = 4096;

fn everythingOnConfiguration() analysis.Configuration {
    var configuration = analysis.Configuration.defaults();
    @memset(&configuration.levels, .warning);
    return configuration;
}

const quality_names = [_][]const u8{
    "parsed", "cached", "pending", "measured", "trimmed", "sorted", "active", "spare",
};
const subject_names = [_][]const u8{
    "budget", "ledger", "packet", "banner", "window", "recipe", "signal", "ticket",
};

const ProgramBuilder = struct {
    allocator: std.mem.Allocator,
    random: std.Random,
    text: std.ArrayList(u8),
    sequence: usize = 0,

    fn init(allocator: std.mem.Allocator, random: std.Random) ProgramBuilder {
        return .{ .allocator = allocator, .random = random, .text = .empty };
    }

    fn append(builder: *ProgramBuilder, comptime format: []const u8, arguments: anytype) !void {
        const piece = try builder.allocator.print(format, arguments);
        defer builder.allocator.free(piece);
        try builder.text.appendSlice(builder.allocator, piece);
    }

    fn functionName(builder: *ProgramBuilder) ![]const u8 {
        builder.sequence += 1;
        const quality = quality_names[builder.random.uintLessThan(usize, quality_names.len)];
        const subject = subject_names[builder.random.uintLessThan(usize, subject_names.len)];
        return builder.allocator.print("{s}{c}{s}{d}", .{
            quality, std.ascii.toUpper(subject[0]), subject[1..], builder.sequence,
        });
    }

    fn localName(builder: *ProgramBuilder) ![]const u8 {
        builder.sequence += 1;
        const quality = quality_names[builder.random.uintLessThan(usize, quality_names.len)];
        const subject = subject_names[builder.random.uintLessThan(usize, subject_names.len)];
        return builder.allocator.print("{s}_{s}_{d}", .{ quality, subject, builder.sequence });
    }

    fn smallLength(builder: *ProgramBuilder) u32 {
        return builder.random.intRangeAtMost(u32, 1, 96);
    }
};

fn emitReleasedBuffer(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator) !u8 {{
        \\    const {s} = try allocator.alloc(u8, {d});
        \\    defer allocator.free({s});
        \\    {s}[0] = {d};
        \\    return {s}[0];
        \\}}
        \\
    , .{
        function, buffer,                                    builder.smallLength(), buffer,
        buffer,   builder.random.intRangeAtMost(u8, 1, 200), buffer,
    });
}

fn emitOwnershipReturn(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const gate = try builder.functionName();
    defer builder.allocator.free(gate);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(flag: bool) !void {{
        \\    if (flag) return error.Rejected;
        \\}}
        \\fn {s}(allocator: std.mem.Allocator, flag: bool) ![]u8 {{
        \\    const {s} = try allocator.alloc(u8, {d});
        \\    errdefer allocator.free({s});
        \\    try {s}(flag);
        \\    return {s};
        \\}}
        \\
    , .{ gate, function, buffer, builder.smallLength(), buffer, gate, buffer });
}

fn emitHelperRelease(builder: *ProgramBuilder) !void {
    const helper = try builder.functionName();
    defer builder.allocator.free(helper);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, {s}: []u8) void {{
        \\    allocator.free({s});
        \\}}
        \\fn {s}(allocator: std.mem.Allocator) !void {{
        \\    const {s} = try allocator.alloc(u8, {d});
        \\    {s}[0] = {d};
        \\    {s}(allocator, {s});
        \\}}
        \\
    , .{
        helper, buffer,                buffer, function,
        buffer, builder.smallLength(), buffer, builder.random.intRangeAtMost(u8, 1, 200),
        helper, buffer,
    });
}

fn emitArenaScratch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const scratch = try builder.localName();
    defer builder.allocator.free(scratch);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator) !usize {{
        \\    var arena = std.heap.ArenaAllocator.init(allocator);
        \\    defer arena.deinit();
        \\    const {s} = try arena.allocator().alloc(u8, {d});
        \\    {s}[0] = {d};
        \\    return {s}.len;
        \\}}
        \\
    , .{
        function,                                  scratch, builder.smallLength(), scratch,
        builder.random.intRangeAtMost(u8, 1, 200), scratch,
    });
}

fn emitBoundedSum(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32) u64 {{
        \\    var total: u64 = 0;
        \\    for (values) |value| {{
        \\        total += value;
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{function});
}

fn emitExhaustiveSwitch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const first = builder.random.intRangeAtMost(u8, 1, 100);
    try builder.append(
        \\const Phase{d} = enum {{ idle, busy, done }};
        \\fn {s}(phase: Phase{d}) u8 {{
        \\    return switch (phase) {{
        \\        .idle => {d},
        \\        .busy => {d},
        \\        .done => {d},
        \\    }};
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, first, first +| 1, first +| 2 });
}

fn emitOptionalGuard(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32) u32 {{
        \\    if (values.len == 0) return {d};
        \\    return values[0];
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 0, 200) });
}

fn emitListAppend(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, count: usize) !usize {{
        \\    var entries: std.ArrayList(u32) = .empty;
        \\    defer entries.deinit(allocator);
        \\    for (0..count) |round| {{
        \\        try entries.append(allocator, @intCast(round));
        \\    }}
        \\    return entries.items.len;
        \\}}
        \\
    , .{function});
}

fn emitPureCompute(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(left: u32, right: u32) u32 {{
        \\    const wider = left +| right;
        \\    if (wider > {d}) return {d};
        \\    return wider;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u16, 100, 60000), builder.random.intRangeAtMost(u8, 0, 99) });
}

fn emitEarlyReturn(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(message: []const u8) error{{Empty}}!usize {{
        \\    if (message.len == 0) return error.Empty;
        \\    return message.len;
        \\}}
        \\
    , .{function});
}

/// The shapes `zig fmt` produces for long headers: a trailing comma puts every
/// parameter, capture source and argument on its own line.
fn emitMultilineHeaders(builder: *ProgramBuilder) !void {
    const sum = try builder.functionName();
    defer builder.allocator.free(sum);
    const call = try builder.functionName();
    defer builder.allocator.free(call);
    const keys = try builder.localName();
    defer builder.allocator.free(keys);
    try builder.append(
        \\fn {s}(
        \\    {s}: []const u32,
        \\    weights: []const u32,
        \\) u64 {{
        \\    var total: u64 = 0;
        \\    for (
        \\        {s},
        \\        weights,
        \\    ) |key, weight| {{
        \\        total += key * weight;
        \\    }}
        \\    return total;
        \\}}
        \\fn {s}(first: []const u32) u64 {{
        \\    return {s}(
        \\        first,
        \\        first,
        \\    );
        \\}}
        \\
    , .{ sum, keys, keys, call, sum });
}

fn emitLabeledBlock(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(count: u8) u8 {{
        \\    return clamp: {{
        \\        if (count > {d}) break :clamp {d};
        \\        break :clamp count;
        \\    }};
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 3, 9), builder.random.intRangeAtMost(u8, 1, 3) });
}

fn emitLabeledSwitch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(start: u8) u8 {{
        \\    return state: switch (start) {{
        \\        0 => {d},
        \\        1 => continue :state 0,
        \\        else => continue :state 1,
        \\    }};
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200) });
}

fn emitInlineElse(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Shape{d} = union(enum) {{ circle: u32, square: u32 }};
        \\fn {s}(shape: Shape{d}) u32 {{
        \\    return switch (shape) {{
        \\        inline else => |side| side * side,
        \\    }};
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence });
}

fn emitDeclLiterals(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Settings{d} = struct {{
        \\    level: u8 = {d},
        \\    /// The settings used when a caller names none.
        \\    pub const standard: Settings{d} = .{{}};
        \\}};
        \\fn {s}(allocator: std.mem.Allocator) !usize {{
        \\    const settings: Settings{d} = .standard;
        \\    var entries: std.ArrayList(u8) = .empty;
        \\    defer entries.deinit(allocator);
        \\    try entries.append(allocator, settings.level);
        \\    return entries.items.len;
        \\}}
        \\
    , .{ builder.sequence, builder.random.intRangeAtMost(u8, 1, 9), builder.sequence, function, builder.sequence });
}

fn emitSingleElementShortcut(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32) u32 {{
        \\    if (values.len == 1) return values[0];
        \\    return {d};
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 0, 200) });
}

/// Sums that cannot wrap: two lengths, a narrow count plus a length, and an
/// asserted bound.
fn emitBoundedSums(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(head: []const u8, tail: []const u8, count: u16, limit: usize) bool {{
        \\    std.debug.assert(count + tail.len <= limit + {d});
        \\    return head.len + tail.len <= limit;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 0, 200) });
}

/// A switch on a qualified type whose last segment names a nested enum.
fn emitQualifiedSwitch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Ranking{d} = struct {{
        \\    const Order = enum {{ lt, eq, gt, unordered }};
        \\    fn rank(order: std.math.Order) Order {{
        \\        return switch (order) {{
        \\            .lt => .lt,
        \\            .eq => .eq,
        \\            .gt => .gt,
        \\        }};
        \\    }}
        \\}};
        \\fn {s}(left: u32, right: u32) bool {{
        \\    return Ranking{d}.rank(std.math.order(left, right)) == .lt;
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence });
}

/// Same-named functions in sibling containers: a bare call names the one in
/// its own container.
fn emitSiblingCalls(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Level{d} = enum {{ low, mid, high }};
        \\const Meter{d} = struct {{
        \\    fn reading() Level{d} {{
        \\        return .mid;
        \\    }}
        \\}};
        \\const Dial{d} = struct {{
        \\    const Notch = enum {{ off, on }};
        \\    fn reading() Notch {{
        \\        return .on;
        \\    }}
        \\    fn {s}() u8 {{
        \\        return switch (reading()) {{
        \\            .off => 0,
        \\            .on => {d},
        \\        }};
        \\    }}
        \\}};
        \\
    , .{
        builder.sequence, builder.sequence,                          builder.sequence, builder.sequence,
        function,         builder.random.intRangeAtMost(u8, 1, 200),
    });
}

/// A prong item that is a comptime constant rather than a tag.
fn emitConstantProng(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const first = builder.random.intRangeAtMost(u8, 1, 100);
    try builder.append(
        \\const Gear{d} = enum {{ low, high }};
        \\const default_gear_{d}: Gear{d} = .low;
        \\fn {s}(gear: Gear{d}) u8 {{
        \\    return switch (gear) {{
        \\        default_gear_{d} => {d},
        \\        .high => {d},
        \\    }};
        \\}}
        \\
    , .{
        builder.sequence, builder.sequence, builder.sequence, function,
        builder.sequence, builder.sequence, first,            first +| 1,
    });
}

/// Members reached through an error set merged with `||` and a comptime
/// field.
fn emitMergedMembers(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const LoadError{d} = error{{Corrupt}} || std.mem.Allocator.Error;
        \\const Stamp{d} = struct {{
        \\    comptime version: u8 = {d},
        \\    value: u8,
        \\}};
        \\fn {s}(stamp: Stamp{d}, failure: LoadError{d}) u8 {{
        \\    if (failure == LoadError{d}.OutOfMemory) return 0;
        \\    return stamp.version +| stamp.value;
        \\}}
        \\
    , .{
        builder.sequence, builder.sequence, builder.random.intRangeAtMost(u8, 1, 9), function,
        builder.sequence, builder.sequence, builder.sequence,
    });
}

/// A system call retried only while it reports an interruption, which
/// `unbounded-loop` accepts as bounded.
fn emitInterruptedRetry(builder: *ProgramBuilder) !void {
    const attempt = try builder.functionName();
    defer builder.allocator.free(attempt);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(value: u32) std.posix.E {{
        \\    return if (value == {d}) .SUCCESS else .INTR;
        \\}}
        \\fn {s}(value: u32) error{{Unexpected}}!void {{
        \\    while (true) {{
        \\        switch ({s}(value)) {{
        \\            .SUCCESS => return,
        \\            .INTR, .AGAIN => {{}},
        \\            else => return error.Unexpected,
        \\        }}
        \\    }}
        \\}}
        \\
    , .{ attempt, builder.random.intRangeAtMost(u8, 0, 9), function, attempt });
}

/// An empty loop repeating a fallible step until it reports no progress.
fn emitProgressStep(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Countdown{d} = struct {{
        \\    remaining: u32,
        \\
        \\    fn step(countdown: *Countdown{d}) error{{Stalled}}!bool {{
        \\        if (countdown.remaining > {d}) return error.Stalled;
        \\        if (countdown.remaining == 0) return false;
        \\        countdown.remaining -= 1;
        \\        return true;
        \\    }}
        \\}};
        \\fn {s}(countdown: *Countdown{d}) error{{Stalled}}!void {{
        \\    while (try countdown.step()) {{}}
        \\}}
        \\
    , .{ builder.sequence, builder.sequence, builder.random.intRangeAtMost(u16, 100, 999), function, builder.sequence });
}

fn emitFlushingHelper(builder: *ProgramBuilder) !void {
    const helper = try builder.functionName();
    defer builder.allocator.free(helper);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    const writer = try builder.localName();
    defer builder.allocator.free(writer);
    try builder.append(
        \\fn {s}(out: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {{
        \\    try out.print("{{d}}\n", .{{value}});
        \\    try out.flush();
        \\}}
        \\fn {s}(io: std.Io, file: std.Io.File) std.Io.Writer.Error!void {{
        \\    var {s}: [{d}]u8 = undefined;
        \\    var {s} = file.writer(io, &{s});
        \\    try {s}(&{s}.interface, {d});
        \\}}
        \\
    , .{ helper, function, buffer, builder.smallLength() + 16, writer, buffer, helper, writer, builder.smallLength() });
}

fn emitCancelledGroup(builder: *ProgramBuilder) !void {
    const worker = try builder.functionName();
    defer builder.allocator.free(worker);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const group = try builder.localName();
    defer builder.allocator.free(group);
    try builder.append(
        \\fn {s}(value: u32) void {{
        \\    std.mem.doNotOptimizeAway(value);
        \\}}
        \\fn {s}(io: std.Io, values: []const u32) std.Io.Cancelable!void {{
        \\    var {s}: std.Io.Group = .init;
        \\    defer {s}.cancel(io);
        \\    for (values) |value| {s}.async(io, {s}, .{{value}});
        \\    try {s}.await(io);
        \\}}
        \\
    , .{ worker, function, group, group, group, worker, group });
}

/// A returned initializer of a type spelled differently from the return type
/// only coerces to it; it does not repeat the result location's type.
fn emitCoercedReturn(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    try builder.append(
        \\const Range{d} = struct {{ low: u32, high: u32 }};
        \\const Interval{d} = Range{d};
        \\fn {s}(low: u32) ?Interval{d} {{
        \\    if (low > {d}) return null;
        \\    return Range{d}{{ .low = low, .high = low + 1 }};
        \\}}
        \\
    , .{ id, id, id, function, id, builder.random.intRangeAtMost(u16, 10, 900), id });
}

/// A namespace with typed state and a C-style constant.
fn emitPrivateNamespace(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const limits_{d} = struct {{
        \\    const MAX_ENTRIES: u32 = {d};
        \\    var calls: u32 = 0;
        \\    /// The value, at most `MAX_ENTRIES`.
        \\    pub fn clamp(value: u32) u32 {{
        \\        return @min(value, MAX_ENTRIES);
        \\    }}
        \\}};
        \\fn {s}(value: u32) u32 {{
        \\    limits_{d}.calls += 1;
        \\    return limits_{d}.clamp(value);
        \\}}
        \\
    , .{ builder.sequence, builder.random.intRangeAtMost(u16, 8, 4096), function, builder.sequence, builder.sequence });
}

/// A test may poll without a stated bound; the discipline rules hold
/// production code only.
fn emitPollingTest(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(pending: *u32) bool {{
        \\    if (pending.* == 0) return false;
        \\    pending.* -= 1;
        \\    return true;
        \\}}
        \\test "{s} drains its counter" {{
        \\    var pending: u32 = {d};
        \\    while ({s}(&pending)) {{}}
        \\    try std.testing.expectEqual(@as(u32, 0), pending);
        \\}}
        \\
    , .{ function, function, builder.random.intRangeAtMost(u8, 1, 9), function });
}

/// Both branches leave the function, so the `else` marks them as peers.
fn emitSymmetricExits(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(flag: bool, value: u32) u32 {{
        \\    if (flag) {{
        \\        return value;
        \\    }} else {{
        \\        return {d};
        \\    }}
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200) });
}

/// A view formatted into a local buffer that only its length leaves.
fn emitFormattedLength(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(value: u32) !usize {{
        \\    var {s}: [{d}]u8 = undefined;
        \\    const text = try std.mem.print(&{s}, "{{d}}", .{{value}});
        \\    return text.len;
        \\}}
        \\
    , .{ function, buffer, builder.random.intRangeAtMost(u8, 16, 64), buffer });
}

/// An undefined local written by the loop body before the continue
/// expression first reads it.
fn emitLoopCarriedStep(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const step = try builder.localName();
    defer builder.allocator.free(step);
    try builder.append(
        \\fn {s}(values: []const u8) usize {{
        \\    var offset: usize = 0;
        \\    var {s}: usize = undefined;
        \\    while (offset < values.len) : (offset += {s}) {{
        \\        {s} = @as(usize, values[offset] % {d}) + 1;
        \\    }}
        \\    return offset;
        \\}}
        \\
    , .{ function, step, step, step, builder.random.intRangeAtMost(u8, 2, 9) });
}

/// A deferred release guarded by a flag the explicit release clears.
fn emitGuardedRelease(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const pool = try builder.localName();
    defer builder.allocator.free(pool);
    const id = builder.sequence;
    try builder.append(
        \\const Pool{d} = struct {{
        \\    items: std.ArrayList(u8) = .empty,
        \\    fn deinit(self: *Pool{d}, allocator: std.mem.Allocator) void {{
        \\        self.items.deinit(allocator);
        \\        self.* = undefined;
        \\    }}
        \\}};
        \\fn {s}(allocator: std.mem.Allocator, value: u8) !usize {{
        \\    var {s}: Pool{d} = .{{}};
        \\    var alive = true;
        \\    defer if (alive) {s}.deinit(allocator);
        \\    try {s}.items.append(allocator, value +| {d});
        \\    const count = {s}.items.len;
        \\    {s}.deinit(allocator);
        \\    alive = false;
        \\    return count;
        \\}}
        \\
    , .{ id, id, function, pool, id, pool, pool, builder.random.intRangeAtMost(u8, 1, 9), pool, pool });
}

/// A value a by-value `for` capture copies out before the slice is reallocated.
fn emitCapturedBeforeRealloc(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const found = try builder.localName();
    defer builder.allocator.free(found);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, values: []u32) ![]u32 {{
        \\    const count = values.len;
        \\    const {s} = for (values) |value| {{
        \\        if (value > {d}) break value;
        \\    }} else 0;
        \\    const grown = try allocator.realloc(values, count + 1);
        \\    grown[count] = {s};
        \\    return grown;
        \\}}
        \\
    , .{ function, found, builder.random.intRangeAtMost(u16, 1, 900), found });
}

/// A slice of a local array pushed onto an outliving stack and popped again
/// before the array expires.
fn emitScopedPush(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const binders = try builder.localName();
    defer builder.allocator.free(binders);
    const id = builder.sequence;
    try builder.append(
        \\const Frames{d} = struct {{
        \\    stack: std.ArrayList([]const u32) = .empty,
        \\}};
        \\fn {s}(allocator: std.mem.Allocator, frames: *Frames{d}, value: u32) !usize {{
        \\    var {s}: [{d}]u32 = undefined;
        \\    @memset(&{s}, value);
        \\    try frames.stack.append(allocator, {s}[0..]);
        \\    defer _ = frames.stack.pop();
        \\    return frames.stack.items.len;
        \\}}
        \\
    , .{ id, function, id, binders, builder.random.intRangeAtMost(u8, 2, 9), binders, binders });
}

/// A struct declared undefined and then written field by field.
/// A `var` mutated only through a slice of one of its fields.
fn emitFieldSliceMutation(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const length = builder.random.intRangeAtMost(u8, 2, 16);
    try builder.append(
        \\const Block{d} = struct {{ bytes: [{d}]u8 = @splat(0) }};
        \\fn {s}(seed: u8) u8 {{
        \\    var block: Block{d} = .{{}};
        \\    @memset(block.bytes[1..], seed);
        \\    return block.bytes[{d}];
        \\}}
        \\
    , .{ builder.sequence, length, function, builder.sequence, length - 1 });
}

/// An allocator implementation whose own type is named `Allocator`, and a
/// test's debug print of a single character, which has no `writeByte`.
fn emitAllocatorImplementation(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const counting_{d} = struct {{
        \\    const Allocator = struct {{
        \\        parent: std.mem.Allocator,
        \\        count: usize = 0,
        \\        fn note(context: *anyopaque) void {{
        \\            const self: *Allocator = @ptrCast(@alignCast(context));
        \\            self.count += 1;
        \\        }}
        \\    }};
        \\}};
        \\fn {s}(parent: std.mem.Allocator) usize {{
        \\    var counting: counting_{d}.Allocator = .{{ .parent = parent }};
        \\    counting_{d}.Allocator.note(&counting);
        \\    return counting.count;
        \\}}
        \\test "{s} counts one note" {{
        \\    std.debug.print("\n", .{{}});
        \\    try std.testing.expectEqual(@as(usize, 1), {s}(std.testing.allocator));
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, builder.sequence, function, function });
}

fn emitFieldwiseStruct(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Span{d} = struct {{ start: usize, end: usize }};
        \\fn {s}(start: usize, length: usize) Span{d} {{
        \\    var span: Span{d} = undefined;
        \\    span.start = start;
        \\    span.end = start +| length;
        \\    return span;
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, builder.sequence });
}

/// A scenario for an allocation-failure sweep exists to fail and release each
/// allocation in turn, which one arena would hide.
fn emitFailureSweep(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator) !void {{
        \\    const first = try allocator.alloc(u8, {d});
        \\    defer allocator.free(first);
        \\    const second = try allocator.alloc(u8, {d});
        \\    defer allocator.free(second);
        \\    const third = try allocator.alloc(u8, {d});
        \\    defer allocator.free(third);
        \\    @memset(first, 0);
        \\    @memset(second, 1);
        \\    @memset(third, 2);
        \\}}
        \\test "{s} releases every failed allocation" {{
        \\    try std.testing.checkAllAllocationFailures(std.testing.allocator, {s}, .{{}});
        \\}}
        \\
    , .{ function, builder.smallLength(), builder.smallLength(), builder.smallLength(), function, function });
}

/// An errdefer cleanup cannot return its own error: the function is already
/// returning one.
fn emitErrdeferCleanup(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    try builder.append(
        \\const Journal{d} = struct {{
        \\    open: bool = false,
        \\    fn begin(journal: *Journal{d}) !void {{
        \\        if (journal.open) return error.Busy;
        \\        journal.open = true;
        \\    }}
        \\    fn end(journal: *Journal{d}) !void {{
        \\        if (!journal.open) return error.Closed;
        \\        journal.open = false;
        \\    }}
        \\}};
        \\fn {s}(journal: *Journal{d}, limit: u32) !void {{
        \\    try journal.begin();
        \\    errdefer journal.end() catch {{}};
        \\    if (limit > {d}) return error.Rejected;
        \\    try journal.end();
        \\}}
        \\
    , .{ id, id, id, function, id, builder.random.intRangeAtMost(u8, 1, 200) });
}

/// std.json hands `jsonStringify` its `*std.json.Stringify`, whose `print`
/// is not the writer's.
fn emitJsonStringify(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    try builder.append(
        \\const Report{d} = struct {{
        \\    bytes: []const u8,
        \\    /// Writes the bytes as one JSON string.
        \\    pub fn jsonStringify(report: Report{d}, writer: anytype) !void {{
        \\        try writer.print("{{s}}", .{{report.bytes}});
        \\    }}
        \\}};
        \\fn {s}(report: Report{d}) usize {{
        \\    return report.bytes.len + {d};
        \\}}
        \\
    , .{ id, id, function, id, builder.random.intRangeAtMost(u8, 1, 200) });
}

/// A zero appended as a counted element is data, not a terminator.
fn emitCountedZero(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, values: []const u32) ![]u32 {{
        \\    const grown = try allocator.alloc(u32, values.len + 1);
        \\    @memcpy(grown[0..values.len], values);
        \\    grown[values.len] = 0;
        \\    return grown;
        \\}}
        \\
    , .{function});
}

/// Recursion a checked depth counter bounds, and a stack drained by its
/// length.
fn emitBoundedRecursion(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const drain = try builder.functionName();
    defer builder.allocator.free(drain);
    try builder.append(
        \\fn {s}(values: []const u32, index: usize, depth: usize) u64 {{
        \\    if (depth >= {d} or index >= values.len) return 0;
        \\    return values[index] + {s}(values, index + 1, depth + 1);
        \\}}
        \\fn {s}(stack: *std.ArrayList(u32)) u64 {{
        \\    var total: u64 = 0;
        \\    while (stack.items.len != 0) {{
        \\        total += stack.pop().?;
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 8, 64), function, drain });
}

/// Recursion counting a by-value depth down from a constant its only caller
/// passes, and recursion over a type's optional payloads and fields.
fn emitCountdownRecursion(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const walker = try builder.functionName();
    defer builder.allocator.free(walker);
    try builder.append(
        \\const Walk{d} = struct {{
        \\    fn sum(values: []const u32) u64 {{
        \\        return visit(values, {d});
        \\    }}
        \\    fn visit(values: []const u32, remaining: usize) u64 {{
        \\        if (remaining == 0 or remaining > values.len) return 0;
        \\        return values[remaining - 1] + visit(values, remaining - 1);
        \\    }}
        \\}};
        \\fn {s}(values: []const u32) u64 {{
        \\    return Walk{d}.sum(values);
        \\}}
        \\fn {s}(value: anytype) usize {{
        \\    switch (@typeInfo(@TypeOf(value))) {{
        \\        .optional => return if (value) |inner| 1 + {s}(inner) else 0,
        \\        .@"struct" => |info| {{
        \\            var total: usize = 0;
        \\            inline for (info.field_names) |name| total += {s}(@field(value, name));
        \\            return total;
        \\        }},
        \\        else => return 1,
        \\    }}
        \\}}
        \\
    , .{ builder.sequence, builder.random.intRangeAtMost(u8, 8, 64), function, builder.sequence, walker, walker, walker });
}

/// A boolean mode a test passes as a literal; production code would name it.
fn emitTestedMode(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const half = builder.random.intRangeAtMost(u8, 1, 9);
    try builder.append(
        \\fn {s}(value: u32, halve: bool) u32 {{
        \\    return if (halve) value / 2 else value;
        \\}}
        \\test "{s} halves on request" {{
        \\    try std.testing.expectEqual(@as(u32, {d}), {s}({d}, true));
        \\}}
        \\
    , .{ function, function, half, function, @as(u16, half) * 2 });
}

/// Indexing bounded by a loop range that starts past zero, by a comparison
/// with the length, and indexing inside a helper only a test calls.
fn emitStatedIndexBounds(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const lookup = try builder.functionName();
    defer builder.allocator.free(lookup);
    const id = builder.sequence;
    try builder.append(
        \\fn {s}(offsets: []u32, bias: u32) u32 {{
        \\    var total: u32 = 0;
        \\    for (offsets) |*offset| {{
        \\        offset.* +%= bias;
        \\    }}
        \\    for (1..offsets.len) |index| offsets[index] +%= offsets[index - 1];
        \\    for (offsets) |offset| {{
        \\        total +%= offset;
        \\    }}
        \\    return total;
        \\}}
        \\fn {s}(values: []const u8, index: usize, bias: u8) u8 {{
        \\    var result: u8 = bias;
        \\    result +%= {d};
        \\    result *%= 3;
        \\    result ^= bias;
        \\    result +%= 1;
        \\    result *%= 5;
        \\    result +%= if (index < values.len) values[index] else 0;
        \\    return result;
        \\}}
        \\const Fixture{d} = struct {{
        \\    fn scenario(values: []const u8, index: usize) u8 {{
        \\        var result: u8 = 0;
        \\        result +%= 1;
        \\        result *%= 3;
        \\        result +%= 2;
        \\        result *%= 5;
        \\        result +%= 4;
        \\        return result +% values[index];
        \\    }}
        \\}};
        \\test "fixture {d} reads the first value" {{
        \\    try std.testing.expect(Fixture{d}.scenario(&.{{ 1, 2 }}, 0) != 0);
        \\}}
        \\
    , .{ function, lookup, builder.random.intRangeAtMost(u8, 1, 9), id, id, id });
}

/// A failure translated where only one error is possible, and a fallible
/// predicate tested on the spot.
fn emitSingleErrorTranslation(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const predicate = try builder.functionName();
    defer builder.allocator.free(predicate);
    const check = try builder.functionName();
    defer builder.allocator.free(check);
    try builder.append(
        \\fn {s}(left: usize, right: usize) error{{TooLarge}}!usize {{
        \\    const total = std.math.add(usize, left, right) catch return error.TooLarge;
        \\    return total / {d};
        \\}}
        \\fn {s}(left: usize, right: usize) error{{TooLarge}}!bool {{
        \\    const total = try {s}(left, right);
        \\    return total > 1;
        \\}}
        \\fn {s}(left: usize, right: usize) bool {{
        \\    if (!({s}(left, right) catch false)) return false;
        \\    return left > right;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 2, 9), predicate, function, check, predicate });
}

/// An aggregate whose fields come from an arena it owns: freeing the arena
/// releases every field.
fn emitArenaAggregate(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Labels{d} = struct {{
        \\    arena: std.heap.ArenaAllocator,
        \\    title: []u8,
        \\    caption: []u8,
        \\
        \\    /// Copies both labels into an arena the result owns.
        \\    pub fn init(allocator: std.mem.Allocator, title: []const u8, caption: []const u8) !Labels{d} {{
        \\        var arena = std.heap.ArenaAllocator.init(allocator);
        \\        errdefer arena.deinit();
        \\        const labels = arena.allocator();
        \\        const owned_title = try labels.dupe(u8, title);
        \\        const owned_caption = try labels.dupe(u8, caption);
        \\        return .{{ .arena = arena, .title = owned_title, .caption = owned_caption }};
        \\    }}
        \\
        \\    /// Releases both labels with the arena.
        \\    pub fn deinit(self: *Labels{d}) void {{
        \\        self.arena.deinit();
        \\        self.* = undefined;
        \\    }}
        \\}};
        \\
    , .{ sequence, sequence, sequence });
}

/// Fields initialized one at a time, each released by an errdefer on its path.
fn emitPartialInitialization(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const sequence = builder.sequence;
    try builder.append(
        \\const Window{d} = struct {{ samples: []u32, totals: []u32 }};
        \\fn {s}(allocator: std.mem.Allocator, count: usize) !Window{d} {{
        \\    var window: Window{d} = undefined;
        \\    window.samples = try allocator.alloc(u32, count);
        \\    errdefer allocator.free(window.samples);
        \\    window.totals = try allocator.alloc(u32, count);
        \\    return window;
        \\}}
        \\
    , .{ sequence, function, sequence, sequence });
}

/// A pointer to an array from a slice allocation, released with `destroy`.
fn emitArrayBlock(builder: *ProgramBuilder) !void {
    const allocate = try builder.functionName();
    defer builder.allocator.free(allocate);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const block = try builder.localName();
    defer builder.allocator.free(block);
    const length = builder.smallLength();
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator) error{{OutOfMemory}}!*align(64) [{d}]u8 {{
        \\    const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(64), {d});
        \\    @memset(bytes, 0);
        \\    return bytes[0..{d}];
        \\}}
        \\fn {s}(allocator: std.mem.Allocator) !u8 {{
        \\    const {s} = try {s}(allocator);
        \\    defer allocator.destroy({s});
        \\    {s}[0] = {d};
        \\    return {s}[0];
        \\}}
        \\
    , .{
        allocate, length,                                    length,   length,
        function, block,                                     allocate, block,
        block,    builder.random.intRangeAtMost(u8, 1, 200), block,
    });
}

/// A `std.Io` mutex held across a fallible update and released by `defer`.
fn emitIoMutexCounter(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Tally{d} = struct {{
        \\    mutex: std.Io.Mutex = .init,
        \\    total: u64 = 0,
        \\
        \\    /// Adds a sample while holding the lock.
        \\    pub fn add(self: *Tally{d}, io: std.Io, value: u32) !void {{
        \\        try self.mutex.lock(io);
        \\        defer self.mutex.unlock(io);
        \\        self.total = try std.math.add(u64, self.total, value);
        \\    }}
        \\}};
        \\
    , .{ sequence, sequence });
}

/// A buffer shrunk in place and resliced to its new length, and one released
/// through a full-length reslice, both under a deferred `free`.
fn emitResizedReslice(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    const length = builder.smallLength() + 1;
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, count: usize) !usize {{
        \\    var {s} = try allocator.alloc(u8, {d});
        \\    defer allocator.free({s});
        \\    if (allocator.resize({s}, {d})) {s} = {s}[0..{d}];
        \\    const scratch = try allocator.alloc(u8, count);
        \\    defer allocator.free(scratch[0..count]);
        \\    @memset(scratch, 0);
        \\    return {s}.len + scratch.len;
        \\}}
        \\
    , .{ function, buffer, length, buffer, buffer, length - 1, buffer, buffer, length - 1, buffer });
}

/// A copy released by hand before an early error, then handed to the caller.
fn emitReleasedBeforeError(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const copy = try builder.localName();
    defer builder.allocator.free(copy);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, text: []const u8) ![]u8 {{
        \\    const {s} = try allocator.dupe(u8, text);
        \\    if ({s}.len > {d}) {{
        \\        allocator.free({s});
        \\        return error.TooLong;
        \\    }}
        \\    return {s};
        \\}}
        \\
    , .{ function, copy, copy, builder.smallLength(), copy, copy });
}

/// Input consumed in chunks: a bounded copy per chunk with the remainder
/// sliced from a running offset, sums bounded by the loop condition or made of
/// lengths, and a cursor that starts at zero compared before it advances.
fn emitChunkedCopy(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const search = try builder.functionName();
    defer builder.allocator.free(search);
    const pack = try builder.functionName();
    defer builder.allocator.free(pack);
    try builder.append(
        \\fn {s}(out: []u8, seed: u8) void {{
        \\    var block: [8]u8 = @splat(seed);
        \\    var i: usize = 0;
        \\    while (i < out.len) : (block[0] +%= {d}) {{
        \\        const n = @min(block.len, out.len - i);
        \\        @memcpy(out[i..][0..n], block[0..n]);
        \\        i += n;
        \\    }}
        \\}}
        \\fn {s}(haystack: []const u8, needle: []const u8, limit: usize) ?usize {{
        \\    if (needle.len > haystack.len) return null;
        \\    var i: usize = 0;
        \\    while (i <= haystack.len - needle.len) : (i += 1) {{
        \\        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return @min(limit, haystack.len + needle.len);
        \\    }}
        \\    return null;
        \\}}
        \\fn {s}(buffer: []u8, header: []const u8, body: []const u8) error{{NoSpaceLeft}}!usize {{
        \\    var written: usize = 0;
        \\    if (written + header.len > buffer.len) return error.NoSpaceLeft;
        \\    @memcpy(buffer[written..][0..header.len], header);
        \\    written += header.len;
        \\    if (written + body.len > buffer.len) return error.NoSpaceLeft;
        \\    @memcpy(buffer[written..][0..body.len], body);
        \\    written += body.len;
        \\    return written;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 9), search, pack });
}

/// A tuple of two iterator calls, a pointer restored from a widened integer
/// and a rotation bounded by the shift that produced it.
fn emitIteratorPair(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const restore = try builder.functionName();
    defer builder.allocator.free(restore);
    const rotate = try builder.functionName();
    defer builder.allocator.free(rotate);
    try builder.append(
        \\fn {s}(text: []const u8) ?[2][]const u8 {{
        \\    var it = std.mem.splitScalar(u8, text, '.');
        \\    return .{{ it.first(), it.next() orelse return null }};
        \\}}
        \\fn {s}(user_data: u128) *const u8 {{
        \\    return @ptrFromInt(@as(usize, @intCast(user_data)));
        \\}}
        \\fn {s}(state: u64, word: u32) u32 {{
        \\    const rot: u32 = @intCast(state >> 59);
        \\    return word >> @as(u5, @intCast(rot)) | word << {d};
        \\}}
        \\
    , .{ function, restore, rotate, builder.random.intRangeAtMost(u8, 1, 31) });
}

/// Empty catches with no caller left to tell: a deferred flush and a cleanup
/// on the path that returns the original error.
fn emitFailurePathCleanup(builder: *ProgramBuilder) !void {
    const release = try builder.functionName();
    defer builder.allocator.free(release);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(value: u32) error{{Busy}}!void {{
        \\    if (value == {d}) return error.Busy;
        \\}}
        \\fn {s}(value: u32, writer: *std.Io.Writer) error{{Busy}}!u32 {{
        \\    defer writer.flush() catch {{}};
        \\    {s}(value) catch |err| {{
        \\        {s}(value + 1) catch {{}};
        \\        return err;
        \\    }};
        \\    return value;
        \\}}
        \\
    , .{ release, builder.random.intRangeAtMost(u8, 1, 9), function, release, release });
}

/// `catch unreachable` and `orelse unreachable` on invariants the code
/// establishes: compile-time-known arguments and a stated precondition.
fn emitStatedInvariants(builder: *ProgramBuilder) !void {
    const parse = try builder.functionName();
    defer builder.allocator.free(parse);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(text: []const u8) error{{Empty}}!usize {{
        \\    if (text.len == 0) return error.Empty;
        \\    return text.len;
        \\}}
        \\fn {s}(text: []const u8) usize {{
        \\    const fixed = {s}("{d}") catch unreachable;
        \\    // Callers pass the text a separator was found in.
        \\    const separator = std.mem.findScalar(u8, text, ',') orelse unreachable;
        \\    return fixed + separator;
        \\}}
        \\
    , .{ parse, function, parse, builder.random.intRangeAtMost(u8, 1, 200) });
}

/// Tests that assert by construction: a reference list, one in a `comptime`
/// block, and a declaration check.
fn emitReferenceTests(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}() u32 {{
        \\    return {d};
        \\}}
        \\test {{
        \\    _ = {s};
        \\    comptime {{
        \\        _ = {s};
        \\    }}
        \\}}
        \\test {{
        \\    std.testing.refAllDecls(@This());
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200), function, function });
}

/// A test releasing each allocation from the leak-checking allocator.
fn emitLeakCheckedTest(builder: *ProgramBuilder) !void {
    try builder.append(
        \\test "generated {d} releases each allocation" {{
        \\    const allocator = std.testing.allocator;
        \\    const first = try allocator.alloc(u8, {d});
        \\    defer allocator.free(first);
        \\    const second = try allocator.alloc(u8, {d});
        \\    defer allocator.free(second);
        \\    const third = try allocator.alloc(u8, {d});
        \\    defer allocator.free(third);
        \\    try std.testing.expect(first.len + second.len + third.len > 0);
        \\}}
        \\
    , .{ builder.sequence, builder.smallLength(), builder.smallLength(), builder.smallLength() });
    builder.sequence += 1;
}

/// Failures with one meaning collapsed to absence, translated to a writer's
/// error, and kept by a predicate's `else`.
fn emitSingleMeaningFailures(builder: *ProgramBuilder) !void {
    const parse = try builder.functionName();
    defer builder.allocator.free(parse);
    const render = try builder.functionName();
    defer builder.allocator.free(render);
    const predicate = try builder.functionName();
    defer builder.allocator.free(predicate);
    const id = builder.sequence;
    try builder.append(
        \\fn {s}(text: []const u8, limit: u32) ?u32 {{
        \\    const value = std.fmt.parseInt(u32, text, 10) catch 0;
        \\    return std.math.add(u32, value, limit) catch null;
        \\}}
        \\fn {s}(writer: *std.Io.Writer, gpa: std.mem.Allocator) std.Io.Writer.Error!void {{
        \\    const scratch = gpa.alloc(u8, {d}) catch return error.WriteFailed;
        \\    defer gpa.free(scratch);
        \\    @memset(scratch, 'x');
        \\    try writer.writeAll(scratch);
        \\}}
        \\const Stage{d} = enum {{ ready, waiting, done }};
        \\const StageError{d} = error{{Canceled}};
        \\fn {s}(stage: Stage{d}) StageError{d}!bool {{
        \\    return switch (stage) {{
        \\        .done => true,
        \\        else => false,
        \\    }};
        \\}}
        \\
    , .{ parse, render, builder.smallLength(), id, id, predicate, id, id });
}

/// Constants whose values document themselves, a C-style constant table, an
/// addition-chain local, a first doc sentence that says more than the name
/// and a qualified `...Data` type.
fn emitSelfDescribingConstants(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    try builder.append(
        \\pub const max_entries_{d} = {d};
        \\pub const Limit{d} = u32;
        \\/// Poll events.
        \\pub const POLL{d} = struct {{
        \\    pub const IN = 0x001;
        \\    pub const OUT = IN << 2;
        \\}};
        \\/// Shaper{d} that counts entries.
        \\pub const Shaper{d} = struct {{ count: Limit{d} }};
        \\/// Image formats.
        \\pub const image_{d} = struct {{
        \\    /// Packed image bytes.
        \\    pub const ImageData = struct {{ bytes: u32 }};
        \\}};
        \\fn {s}(value: u32) u32 {{
        \\    const _10 = value +% value;
        \\    return _10 +% POLL{d}.OUT +% max_entries_{d};
        \\}}
        \\
    , .{ id, builder.random.intRangeAtMost(u16, 8, 4096), id, id, id, id, id, id, function, id, id });
}

/// A type whose nested type declares its own `deinit` first, with a union
/// payload freed through a `switch` capture and a field set through a nested
/// literal: the outer `deinit` releases every field.
fn emitNestedCleanup(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Shelf{d} = struct {{
        \\    allocator: std.mem.Allocator,
        \\    label: Label,
        \\    pair: Pair,
        \\    slots: std.ArrayList(Slot),
        \\
        \\    const Slot = struct {{
        \\        codes: std.ArrayList(u32),
        \\
        \\        fn deinit(slot: *Slot, allocator: std.mem.Allocator) void {{
        \\            slot.codes.deinit(allocator);
        \\            slot.* = undefined;
        \\        }}
        \\    }};
        \\    const Label = union(enum) {{ named: []u8, numbered: u32 }};
        \\    const Pair = struct {{ left: []u8, count: usize }};
        \\
        \\    /// Copies the name into the label and the pair.
        \\    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Shelf{d} {{
        \\        const left = try allocator.dupe(u8, name);
        \\        errdefer allocator.free(left);
        \\        const named = try allocator.dupe(u8, name);
        \\        return .{{
        \\            .allocator = allocator,
        \\            .label = .{{ .named = named }},
        \\            .pair = .{{ .left = left, .count = {d} }},
        \\            .slots = .empty,
        \\        }};
        \\    }}
        \\
        \\    /// Releases the slots, the label and the pair.
        \\    pub fn deinit(self: *Shelf{d}) void {{
        \\        for (self.slots.items) |*slot| slot.deinit(self.allocator);
        \\        self.slots.deinit(self.allocator);
        \\        switch (self.label) {{
        \\            .named => |name| self.allocator.free(name),
        \\            .numbered => {{}},
        \\        }}
        \\        self.allocator.free(self.pair.left);
        \\        self.* = undefined;
        \\    }}
        \\}};
        \\
    , .{ sequence, sequence, builder.random.intRangeAtMost(u8, 1, 9), sequence });
}

/// A container handed on whole through a pointer parameter's field.
fn emitHandedContainer(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Inbox{d} = struct {{
        \\    pending: std.ArrayList(u8) = .empty,
        \\}};
        \\fn {s}(allocator: std.mem.Allocator, inbox: *Inbox{d}) !usize {{
        \\    var fresh: std.ArrayList(u8) = .empty;
        \\    try fresh.append(allocator, {d});
        \\    inbox.pending.deinit(allocator);
        \\    inbox.pending = fresh;
        \\    return inbox.pending.items.len;
        \\}}
        \\
    , .{ sequence, function, sequence, builder.random.intRangeAtMost(u8, 1, 200) });
}

/// A writer flushed before an early return and after its last write.
fn emitFlushedEarlyExit(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(io: std.Io, file: std.Io.File, quiet: bool) std.Io.Writer.Error!void {{
        \\    var {s}: [{d}]u8 = undefined;
        \\    var file_writer = file.writer(io, &{s});
        \\    const out = &file_writer.interface;
        \\    if (quiet) {{
        \\        try out.writeAll("quiet\n");
        \\        try out.flush();
        \\        return;
        \\    }}
        \\    for (0..{d}) |index| {{
        \\        try out.print("{{d}}\n", .{{index}});
        \\    }}
        \\    try out.flush();
        \\}}
        \\
    , .{ function, buffer, builder.smallLength() + 16, buffer, builder.random.intRangeAtMost(u8, 1, 9) });
}

/// A write before an `if`/`else` and a `switch` that flush in every branch.
fn emitFlushedEveryBranch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const buffer = try builder.localName();
    defer builder.allocator.free(buffer);
    try builder.append(
        \\fn {s}(io: std.Io, file: std.Io.File, verbose: bool, mode: enum {{ plain, wide, none }}) std.Io.Writer.Error!void {{
        \\    var {s}: [{d}]u8 = undefined;
        \\    var file_writer = file.writer(io, &{s});
        \\    const out = &file_writer.interface;
        \\    try out.writeAll("head\n");
        \\    if (verbose) {{
        \\        try out.print("{{d}}\n", .{{{d}}});
        \\        try out.flush();
        \\    }} else {{
        \\        try out.flush();
        \\    }}
        \\    try out.writeAll("tail\n");
        \\    switch (mode) {{
        \\        .plain => try out.flush(),
        \\        .wide => {{
        \\            try out.writeAll("wide\n");
        \\            try out.flush();
        \\        }},
        \\        .none => unreachable,
        \\    }}
        \\}}
        \\
    , .{ function, buffer, builder.smallLength() + 16, buffer, builder.random.intRangeAtMost(u8, 1, 9) });
}

/// A capture named like the var it initializes, mutated later, and a table
/// built in a labeled `comptime` block whose address is returned.
fn emitShadowedInitializers(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Slot{d} = struct {{ id: u32 = 0 }};
        \\fn takeSlot{d}(pending: ?*const Slot{d}) u32 {{
        \\    var slot: Slot{d} = if (pending) |slot| slot: {{
        \\        break :slot slot.*;
        \\    }} else .{{}};
        \\    if (slot.id == 0) slot.id = {d};
        \\    return slot.id;
        \\}}
        \\fn table{d}(comptime count: usize) []const u8 {{
        \\    const result = comptime result: {{
        \\        var result: [count]u8 = undefined;
        \\        for (&result, 0..) |*byte, index| byte.* = @intCast(index);
        \\        break :result result;
        \\    }};
        \\    return &result;
        \\}}
        \\
    , .{ sequence, sequence, sequence, sequence, builder.random.intRangeAtMost(u8, 1, 9), sequence });
}

/// An undefined local that an errdefer block reads after its first
/// statement; the block runs only once the local is set.
fn emitErrdeferBlockRead(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const value = try builder.localName();
    defer builder.allocator.free(value);
    try builder.append(
        \\fn {s}(failures: *u32, last: *u8, input: []const u8) !u8 {{
        \\    var {s}: u8 = undefined;
        \\    errdefer {{
        \\        failures.* += 1;
        \\        last.* = {s};
        \\    }}
        \\    {s} = if (input.len > 0) input[0] else 0;
        \\    if ({s} > {d}) return error.Rejected;
        \\    return {s};
        \\}}
        \\
    , .{ function, value, value, value, value, builder.random.intRangeAtMost(u8, 1, 200), value });
}

/// A function whose parameter has a struct type: the pointer field it only
/// reads is no parameter, and `[]const u8` in its body declares no `u8`.
fn emitFullCapacityItemsReturn(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, text: []const u8) ![]u8 {{
        \\    var output: std.ArrayList(u8) = try .initCapacity(allocator, text.len);
        \\    errdefer comptime unreachable;
        \\    for (text) |byte| output.appendAssumeCapacity(byte);
        \\    std.debug.assert(output.items.len == output.capacity);
        \\    return output.items;
        \\}}
        \\
    , .{function});
}

fn emitStructParameterSize(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Header{d} = struct {{
        \\    tag: u8,
        \\    const size = @sizeOf(u32);
        \\}};
        \\fn {s}(allocator: std.mem.Allocator, args: struct {{ header: *Header{d}, label: []const u8 }}) ![]u8 {{
        \\    var parts: std.ArrayList([]const u8) = .empty;
        \\    defer parts.deinit(allocator);
        \\    try parts.append(allocator, args.label);
        \\    const size = @sizeOf(u8) + Header{d}.size;
        \\    const bytes = try allocator.alloc(u8, size);
        \\    @memset(bytes, args.header.tag);
        \\    return bytes;
        \\}}
        \\
    , .{ id, function, id, id });
}

/// A field reset to an empty literal before it is filled again.
fn emitResetField(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\const Note{d} = struct {{
        \\    allocator: std.mem.Allocator,
        \\    text: []const u8 = "",
        \\
        \\    /// Releases the text when one was copied.
        \\    pub fn deinit(self: *const Note{d}) void {{
        \\        if (self.text.len > 0) self.allocator.free(self.text);
        \\    }}
        \\
        \\    /// Copies `source` unless it is empty.
        \\    pub fn fill(self: *Note{d}, source: []const u8) !void {{
        \\        self.text = "";
        \\        if (source.len > 0) self.text = try self.allocator.dupe(u8, source);
        \\    }}
        \\}};
        \\
    , .{ sequence, sequence, sequence });
}

/// Length guards on the left of `or` protect the index on its right, whichever
/// way round they compare.
fn emitShortCircuitLengthGuards(builder: *ProgramBuilder) !void {
    const sequence = builder.sequence;
    builder.sequence += 1;
    try builder.append(
        \\/// Whether `name` spells a sized integer type.
        \\pub fn isIntegerName{d}(name: []const u8) bool {{
        \\    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
        \\    return {d} > name.len or name.len <= {d} or name[0] != '0';
        \\}}
        \\
    , .{ sequence, builder.random.intRangeAtMost(u8, 1, 9), builder.random.intRangeAtMost(u8, 0, 9) });
}

/// Guard clauses whose body drops to the next line, and a labeled block after
/// a condition `zig fmt` continued: none of them can make a later line look
/// guarded.
fn emitGuardClauses(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32, limit: u32) error{{Empty}}!u64 {{
        \\    if (values.len == 0)
        \\        return error.Empty;
        \\    var total: u64 = 0;
        \\    for (values) |value| {{
        \\        if (value > limit)
        \\            continue;
        \\        total += value;
        \\    }}
        \\    if (total > {d} and
        \\        values.len > 1)
        \\    rounded: {{
        \\        if (total % 2 == 0) break :rounded;
        \\        total += 1;
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u16, 10, 900) });
}

/// A public method's receiver is API, whatever its body reads.
fn emitPublicReader(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Gauge{d} = struct {{
        \\    level: u32,
        \\
        \\    /// The current level.
        \\    pub fn read(gauge: *Gauge{d}) u32 {{
        \\        return gauge.level;
        \\    }}
        \\}};
        \\fn {s}(level: u32) u32 {{
        \\    var gauge: Gauge{d} = .{{ .level = level }};
        \\    return gauge.read() +| {d};
        \\}}
        \\
    , .{ builder.sequence, builder.sequence, function, builder.sequence, builder.random.intRangeAtMost(u8, 1, 9) });
    builder.sequence += 1;
}

/// A dump helper writes to stderr on purpose.
fn emitDumpHelper(builder: *ProgramBuilder) !void {
    try builder.append(
        \\fn dumpTotals{d}(values: []const u32) void {{
        \\    for (values) |value| std.debug.print("{{d}}\n", .{{value}});
        \\}}
        \\
    , .{builder.sequence});
    builder.sequence += 1;
}

/// Prongs a comment documents, and the one-status-per-row table of a C
/// status enum, stay separate.
fn emitStatusTable(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const value = builder.random.intRangeAtMost(u8, 1, 200);
    try builder.append(
        \\const Status{d} = enum {{ SUCCESS, AGAIN, INTR, BADF, FAULT }};
        \\fn {s}(status: Status{d}) error{{Retry}}!u8 {{
        \\    return switch (status) {{
        \\        .SUCCESS => {d},
        \\        // Interrupted calls are retried like busy ones.
        \\        .AGAIN => error.Retry,
        \\        .INTR => error.Retry,
        \\        .BADF => unreachable,
        \\        .FAULT => unreachable,
        \\    }};
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, value });
    builder.sequence += 1;
}

/// Shapes that look like no-ops or one-pass loops but are written on purpose:
/// a checked `getOrPut` counter, a loop expression with an `else`, a table
/// row starting at `* 0`, a breakable `while (true)` block and an asserted
/// lower bound.
fn emitDeliberateShapes(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, words: []const u32) !u32 {{
        \\    var counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        \\    defer counts.deinit(allocator);
        \\    for (words) |word| {{
        \\        const gop = try counts.getOrPut(allocator, word);
        \\        if (!gop.found_existing) gop.value_ptr.* = 0;
        \\        gop.value_ptr.* += 1;
        \\    }}
        \\    const first = for (words) |word| {{
        \\        if (word > {d}) break word;
        \\    }} else 0;
        \\    const offsets = [_]u32{{ first * 0, first * 1, first * 2 }};
        \\    var total: u32 = 0;
        \\    while (true) {{
        \\        if (words.len == 0) break;
        \\        total +|= offsets[1];
        \\        break;
        \\    }}
        \\    std.debug.assert(words.len >= 0);
        \\    return total +| counts.count();
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 2, 9) });
}

const templates = [_]*const fn (*ProgramBuilder) anyerror!void{
    emitFormattedLength,
    emitLoopCarriedStep,
    emitFieldwiseStruct,
    emitReleasedBuffer,
    emitOwnershipReturn,
    emitHelperRelease,
    emitArenaScratch,
    emitBoundedSum,
    emitExhaustiveSwitch,
    emitOptionalGuard,
    emitListAppend,
    emitPureCompute,
    emitEarlyReturn,
    emitMultilineHeaders,
    emitLabeledBlock,
    emitLabeledSwitch,
    emitInlineElse,
    emitDeclLiterals,
    emitSingleElementShortcut,
    emitBoundedSums,
    emitQualifiedSwitch,
    emitSiblingCalls,
    emitConstantProng,
    emitMergedMembers,
    emitFlushingHelper,
    emitInterruptedRetry,
    emitProgressStep,
    emitCancelledGroup,
    emitCoercedReturn,
    emitSymmetricExits,
    emitPrivateNamespace,
    emitPollingTest,
    emitGuardedRelease,
    emitCapturedBeforeRealloc,
    emitScopedPush,
    emitFailureSweep,
    emitErrdeferCleanup,
    emitJsonStringify,
    emitCountedZero,
    emitBoundedRecursion,
    emitCountdownRecursion,
    emitTestedMode,
    emitStatedIndexBounds,
    emitSingleErrorTranslation,
    emitDeliberateShapes,
    emitGuardClauses,
    emitPublicReader,
    emitDumpHelper,
    emitStatusTable,
    emitArenaAggregate,
    emitPartialInitialization,
    emitArrayBlock,
    emitIoMutexCounter,
    emitResizedReslice,
    emitReleasedBeforeError,
    emitChunkedCopy,
    emitIteratorPair,
    emitFailurePathCleanup,
    emitStatedInvariants,
    emitReferenceTests,
    emitLeakCheckedTest,
    emitSingleMeaningFailures,
    emitFieldSliceMutation,
    emitAllocatorImplementation,
    emitSelfDescribingConstants,
    emitNestedCleanup,
    emitHandedContainer,
    emitFlushedEarlyExit,
    emitResetField,
    emitShortCircuitLengthGuards,
    emitFlushedEveryBranch,
    emitShadowedInitializers,
    emitErrdeferBlockRead,
    emitStructParameterSize,
    emitFullCapacityItemsReturn,
};

/// Programs that break idioms, so the fix gates see more than clean code
/// produces under the stricter rules. Each one compiles as written.
fn emitDirtyCounter(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(count: usize) usize {{
        \\    var total: usize = 0;
        \\    var index: usize = 0;
        \\    while (index < count) : (index += 1) {{
        \\        total += {d};
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 9) });
}

fn emitDirtyLastElement(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(list: *std.ArrayList(u8)) u8 {{
        \\    const before = list.items[list.items.len - 1];
        \\    list.items[list.items.len - 1] = '/';
        \\    list.items[list.items.len - 1] += {d};
        \\    return before;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 9) });
}

fn emitDirtyBitMix(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(value: u32, mask: u32) u32 {{
        \\    const mixed = value ^ value >> {d};
        \\    const folded = value & mask == mask;
        \\    return if (folded) mixed else value | value << {d};
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 31), builder.random.intRangeAtMost(u8, 1, 31) });
}

fn emitDirtyAppendLoops(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(gpa: std.mem.Allocator, items: []const u32) !std.ArrayList(u32) {{
        \\    var list: std.ArrayList(u32) = .empty;
        \\    errdefer list.deinit(gpa);
        \\    for (items) |item| {{
        \\        try list.append(gpa, item);
        \\    }}
        \\    for (0..{d}) |number| {{
        \\        try list.append(gpa, @intCast(number));
        \\    }}
        \\    return list;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 2, 20) });
}

fn emitDirtyCopies(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(dst: []u8, src: []const u8) void {{
        \\    for (dst, src) |*d, s| d.* = s;
        \\    var local: [4]u8 = undefined;
        \\    const fixed = [_]u8{{ 1, 2, 3, {d} }};
        \\    for (0..local.len) |j| {{
        \\        local[j] = fixed[j];
        \\    }}
        \\    dst[0] = local[0];
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 9) });
}

fn emitDirtySliceMutation(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(src: []const u8) u8 {{
        \\    var padded: [{d}]u8 = undefined;
        \\    @memset(padded[0..], 0);
        \\    @memcpy(padded[0..src.len], src);
        \\    return padded[0];
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 64, 128) });
}

fn emitDirtyTesting(builder: *ProgramBuilder) !void {
    try builder.append(
        \\test "generated {d}" {{
        \\    const actual: []const u8 = "ready";
        \\    try std.testing.expect(std.mem.eql(u8, actual, "ready"));
        \\    try std.testing.expect(std.mem.eql(u8, "ready", actual));
        \\}}
        \\
    , .{builder.sequence});
    builder.sequence += 1;
}

fn emitDirtyCasts(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(narrow: u16) u32 {{
        \\    const wide: u32 = @as(u32, narrow);
        \\    const small: u8 = @as(u8, {d});
        \\    return @as(u32, wide + small);
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200) });
}

fn emitDirtyUnwraps(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(maybe: ?u32, other: ?u32) u32 {{
        \\    if (maybe) |value| {{
        \\        _ = value;
        \\        return maybe.? + {d};
        \\    }}
        \\    return (other orelse unreachable) + 1;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200) });
}

fn emitDirtyNamedTest(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(value: u32) u32 {{
        \\    return value +| {d};
        \\}}
        \\test "{s}" {{
        \\    try std.testing.expect({s}(1) > 0);
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 200), function, function });
}

fn emitDirtyReturnedInitializers(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    try builder.append(
        \\const Point{d} = struct {{
        \\    x: i32 = 0,
        \\    y: i32 = {d},
        \\    const Self = @This();
        \\    fn origin() Self {{
        \\        return Self{{}};
        \\    }}
        \\    fn parsed(text: []const u8) error{{Empty}}!?Point{d} {{
        \\        if (text.len == 0) return error.Empty;
        \\        return Point{d}{{ .x = @intCast(text.len) }};
        \\    }}
        \\}};
        \\fn {s}(text: []const u8) !i32 {{
        \\    const point = (try Point{d}.parsed(text)) orelse Point{d}.origin();
        \\    return point.x + point.y;
        \\}}
        \\
    , .{ id, builder.random.intRangeAtMost(u8, 1, 9), id, id, function, id, id });
}

fn emitDirtyAffixes(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(prefix: []const u8, root: []const u8) bool {{
        \\    if (std.mem.endsWith(u8, root, "{c}")) return true;
        \\    return prefix.len == 0 or !std.mem.endsWith(u8, prefix, "/") or std.mem.startsWith(u8, root, "-") == false;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 'a', 'z') });
}

fn emitDirtyErrorExpectation(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u8) !void {{
        \\    if (values.len > {d}) return error.TooLong;
        \\}}
        \\test "{s} rejects long input" {{
        \\    {s}(&.{{ 1, 2, 3, 4 }}) catch |err| {{
        \\        try std.testing.expectEqual(error.TooLong, err);
        \\        return;
        \\    }};
        \\    return error.TestExpectedError;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 0, 3), function, function });
}

/// `catch unreachable` in a `defer` of a fallible function, where `try`
/// cannot propagate.
fn emitDirtyDeferredUnreachable(builder: *ProgramBuilder) !void {
    const release = try builder.functionName();
    defer builder.allocator.free(release);
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(value: u32) error{{Busy}}!void {{
        \\    if (value == {d}) return error.Busy;
        \\}}
        \\fn {s}(value: u32) error{{Busy}}!u32 {{
        \\    defer {s}(value) catch unreachable;
        \\    try {s}(value + 1);
        \\    return value;
        \\}}
        \\
    , .{ release, builder.random.intRangeAtMost(u8, 1, 9), function, release, release });
}

/// `expect(actual == literal)` over a length, an optional and a call, which
/// `expectEqual` must still compile for.
fn emitDirtyFieldExpectations(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const id = builder.sequence;
    const value = builder.random.intRangeAtMost(u8, 1, 200);
    try builder.append(
        \\const Record{d} = struct {{ value: ?u32 = null, items: []const u8 = "ab" }};
        \\fn {s}() u32 {{
        \\    return {d};
        \\}}
        \\test "generated {d} expectations" {{
        \\    const record: Record{d} = .{{}};
        \\    const value = record.value;
        \\    try std.testing.expect(record.items.len == 2);
        \\    try std.testing.expect(value == null);
        \\    try std.testing.expect({s}() == {d});
        \\}}
        \\
    , .{ id, function, value, id, id, function, value });
    builder.sequence += 1;
}

/// An unbraced body after a condition `zig fmt` continued onto a second line.
fn emitDirtyContinuedGuard(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32, limit: u32) u64 {{
        \\    var total: u64 = 0;
        \\    for (values) |value| {{
        \\        if (value > limit and
        \\            value % {d} == 0)
        \\            total += value;
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 2, 9) });
}

/// A defer block holding one statement that spans lines.
fn emitDirtyDeferredReset(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\const Span{d} = struct {{ start: usize, len: usize }};
        \\fn {s}(span: *Span{d}, length: usize) usize {{
        \\    defer {{
        \\        span.* = .{{
        \\            .start = span.start +| length,
        \\            .len = {d},
        \\        }};
        \\    }}
        \\    return span.len;
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, builder.random.intRangeAtMost(u8, 0, 9) });
    builder.sequence += 1;
}

/// An unused import set off by a blank line.
fn emitDirtyUnusedImport(builder: *ProgramBuilder) !void {
    try builder.append(
        \\
        \\const unused_{d} = @import("builtin");
        \\
    , .{builder.sequence});
    builder.sequence += 1;
}

/// A main path nested under a condition whose else branch only returns.
fn emitDirtyNestedMainPath(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    try builder.append(
        \\fn {s}(values: []const u32) error{{Empty}}!u32 {{
        \\    var first: u32 = 0;
        \\    if (values.len != 0) {{
        \\        first = values[0];
        \\    }} else {{
        \\        return error.Empty;
        \\    }}
        \\    return first +| {d};
        \\}}
        \\
    , .{ function, builder.random.intRangeAtMost(u8, 1, 9) });
}

/// Adjacent prongs with one body.
fn emitDirtyRepeatedProngs(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    defer builder.allocator.free(function);
    const value = builder.random.intRangeAtMost(u8, 1, 200);
    try builder.append(
        \\const Pace{d} = enum {{ fast, turbo, safe }};
        \\fn {s}(pace: Pace{d}) u8 {{
        \\    return switch (pace) {{
        \\        .fast => {d},
        \\        .turbo => {d},
        \\        .safe => 0,
        \\    }};
        \\}}
        \\
    , .{ builder.sequence, function, builder.sequence, value, value });
    builder.sequence += 1;
}

const dirty_templates = [_]*const fn (*ProgramBuilder) anyerror!void{
    emitDirtyCounter,
    emitDirtyLastElement,
    emitDirtyBitMix,
    emitDirtyAppendLoops,
    emitDirtyCopies,
    emitDirtySliceMutation,
    emitDirtyTesting,
    emitDirtyCasts,
    emitDirtyUnwraps,
    emitDirtyNamedTest,
    emitDirtyReturnedInitializers,
    emitDirtyAffixes,
    emitDirtyErrorExpectation,
    emitDirtyDeferredUnreachable,
    emitDirtyContinuedGuard,
    emitDirtyDeferredReset,
    emitDirtyUnusedImport,
    emitDirtyNestedMainPath,
    emitDirtyRepeatedProngs,
    emitDirtyFieldExpectations,
};

fn generateCleanProgram(allocator: std.mem.Allocator, seed: u64) ![:0]const u8 {
    return generateProgram(allocator, seed, &templates);
}

/// Clean templates plus the idiom-breaking ones, for the fix gates.
fn generateDirtyProgram(allocator: std.mem.Allocator, seed: u64) ![:0]const u8 {
    return generateProgram(allocator, seed, &(templates ++ dirty_templates));
}

fn generateProgram(
    allocator: std.mem.Allocator,
    seed: u64,
    available: []const *const fn (*ProgramBuilder) anyerror!void,
) ![:0]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var builder = ProgramBuilder.init(allocator, prng.random());
    const function_count = builder.random.intRangeAtMost(usize, 3, 8);
    for (0..function_count) |_| {
        const template = available[builder.random.uintLessThan(usize, available.len)];
        try template(&builder);
    }
    // The import is only clean when something uses it.
    const body = builder.text.items;
    const header = if (std.mem.find(u8, body, "std.") != null) "const std = @import(\"std\");\n" else "";
    return allocator.printSentinel("{s}{s}", .{ header, body }, 0);
}

fn reportFindings(source: []const u8, label: []const u8, found: []const analysis.Finding) void {
    std.debug.print("--- {s} ---\n{s}\n", .{ label, source });
    for (found) |finding| {
        std.debug.print("{s}: {s} [{d}..{d}]\n", .{
            @tagName(finding.rule), finding.message, finding.span.start, finding.span.end,
        });
    }
}

fn sortedRules(allocator: std.mem.Allocator, found: []const analysis.Finding) ![]u16 {
    const rules = try allocator.alloc(u16, found.len);
    for (found, rules) |finding, *rule| rule.* = @backingInt(finding.rule);
    std.mem.sort(u16, rules, {}, std.sort.asc(u16));
    return rules;
}

/// The allocator should be an arena because comparison allocations share the
/// caller's per-iteration lifetime and are reclaimed together.
fn expectSameRules(
    allocator: std.mem.Allocator,
    original_source: []const u8,
    original: []const analysis.Finding,
    transformed_source: []const u8,
    label: []const u8,
    transformed: []const analysis.Finding,
) !void {
    const original_rules = try sortedRules(allocator, original);
    const transformed_rules = try sortedRules(allocator, transformed);
    if (std.mem.eql(u16, original_rules, transformed_rules)) return;
    reportFindings(original_source, "original", original);
    reportFindings(transformed_source, label, transformed);
    return error.FindingsChangedUnderTransform;
}

fn parseAndRender(allocator: std.mem.Allocator, source: [:0]const u8) ![:0]const u8 {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const rendered = try tree.renderAlloc(allocator);
    return try allocator.dupeSentinel(u8, rendered, 0);
}

fn insertProbeComment(allocator: std.mem.Allocator, source: [:0]const u8, random: std.Random) ![:0]const u8 {
    var line_starts: std.ArrayList(usize) = .empty;
    defer line_starts.deinit(allocator);
    try line_starts.append(allocator, 0);
    for (source, 0..) |byte, index| {
        if (byte == '\n' and index + 1 < source.len) try line_starts.append(allocator, index + 1);
    }
    const at = line_starts.items[random.uintLessThan(usize, line_starts.items.len)];
    return allocator.printSentinel("{s}// probe comment\n{s}", .{
        source[0..at], source[at..],
    }, 0);
}

fn renameIdentifier(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    from: []const u8,
    to: []const u8,
) ![:0]const u8 {
    var pieces: std.ArrayList(u8) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    var consumed: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try pieces.appendSlice(allocator, source[consumed..token.loc.start]);
        const text = source[token.loc.start..token.loc.end];
        if (token.tag == .identifier and std.mem.eql(u8, text, from)) {
            try pieces.appendSlice(allocator, to);
        } else {
            try pieces.appendSlice(allocator, text);
        }
        consumed = token.loc.end;
    }
    try pieces.appendSlice(allocator, source[consumed..]);
    return pieces.toOwnedSliceSentinel(allocator, 0);
}

test "generated clean programs raise no default findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = analysis.Configuration.defaults();
    var seed: u64 = 0;
    while (seed < generated_program_count) : (seed += 1) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        const found = try analysis.findings(allocator, source, configuration);
        if (found.len != 0) {
            std.debug.print("seed {d} produced findings on clean-by-construction code\n", .{seed});
            reportFindings(source, "generated", found);
            return error.FalsePositiveOnCleanProgram;
        }
    }
}

const profile_names = [_][]const u8{ "official", "idiomatic", "strict", "modernize", "disciplined" };

fn profileConfiguration(allocator: std.mem.Allocator, profile: []const u8) !analysis.Configuration {
    const text = try allocator.print("{{\"lints\":{{\"profile\":\"{s}\"}}}}", .{profile});
    const configuration = try analysis.parseConfiguration(allocator, text);
    if (configuration.warning) |warning| {
        std.debug.print("profile {s}: {s}\n", .{ profile, warning });
        return error.InvalidProfile;
    }
    return configuration;
}

test "generated clean programs raise no findings under any lint profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var configuration_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer configuration_arena.deinit();
    var configurations: [profile_names.len]analysis.Configuration = undefined;
    const defaults = analysis.Configuration.defaults();
    for (profile_names, &configurations) |name, *configuration| {
        configuration.* = try profileConfiguration(configuration_arena.allocator(), name);
        // A profile that enabled nothing would make the check vacuous.
        try std.testing.expect(!std.mem.eql(analysis.Level, &configuration.levels, &defaults.levels));
    }
    var reported: std.EnumSet(analysis.Rule) = .empty;
    var seed: u64 = 0;
    while (seed < profile_program_count) : (seed += 1) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        try std.testing.expect(try round_trip.isFormatted(allocator, source));
        for (profile_names, configurations) |name, configuration| {
            const found = try analysis.findings(allocator, source, configuration);
            for (found) |finding| {
                if (reported.contains(finding.rule)) continue;
                reported.insert(finding.rule);
                std.debug.print("false positive on clean-by-construction code: seed {d} under the {s} profile\n", .{ seed, name });
                reportFindings(source, "generated", &.{finding});
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), reported.count());
}

test "fixes of every rule on generated programs parse, lower and compile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var corpus: compile_batch.Corpus = .init(std.testing.allocator);
    defer corpus.deinit();
    var verdict: round_trip.Verdict = .{ .corpus = &corpus };
    const everything = everythingOnConfiguration();
    var seed: u64 = 0;
    while (seed < fix_program_count) : (seed += 1) {
        defer _ = arena_state.reset(.retain_capacity);
        const source = try generateDirtyProgram(arena, seed);
        const label = try arena.print("seed {d}", .{seed});
        try round_trip.checkEveryReportingRule(arena, &verdict, label, source, everything);
        try round_trip.checkCombined(arena, &verdict, label, source, everything);
    }
    try std.testing.expectEqual(@as(usize, 0), verdict.failures);
    try std.testing.expectEqual(@as(usize, 0), verdict.unformatted);
    // The idiom-breaking templates must reach the rules they are written for.
    for ([_]analysis.Rule{
        .prefer_range_for,
        .prefer_array_list_last,
        .prefer_append_slice,
        .prefer_memcpy,
        .prefer_testing_expect_equal_strings,
        .unused_private_declaration,
        .needless_cast,
        .redundant_optional_unwrap,
        .unsafe_orelse_unreachable,
        .prefer_doctest,
        .unbraced_multiline_if,
        .needless_defer_block,
        .unused_import,
        .prefer_early_return,
        .combine_identical_switch_prongs,
    }) |rule| {
        if (verdict.fixed_rules.contains(rule)) continue;
        std.debug.print("no generated program had a fix for {s}\n", .{rule.code()});
        return error.RuleNeverReached;
    }
    const outcome = try compile_batch.check(std.testing.allocator, std.testing.io, &corpus);
    std.debug.print("fuzz fix gate: {d} programs ({d} already erroneous, {d} skipped), {d} fix results, {d} rules fixed\n", .{
        outcome.programs, outcome.erroneous, outcome.skipped, outcome.variants, verdict.fixed_rules.count(),
    });
    try std.testing.expectEqual(@as(usize, 0), outcome.failures);
}

const project_count = 40;

/// A small clean project: `main.zig` and two to four modules whose public
/// functions are documented and referenced from `main.zig`, each module built
/// from the clean templates.
fn generateProject(allocator: std.mem.Allocator, seed: u64) ![]const project_rules.SourceFile {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x70726f6a);
    const random = prng.random();
    const module_count = random.intRangeAtMost(usize, 2, 4);
    const files = try allocator.alloc(project_rules.SourceFile, module_count + 1);
    var main_imports: std.ArrayList(u8) = .empty;
    var main_uses: std.ArrayList(u8) = .empty;
    for (files[1..], 0..) |*file, module_index| {
        const module = try allocator.print("part{d}", .{module_index});
        const body = try generateProgram(allocator, seed * 8 + module_index, &templates);
        // Public, documented functions the main file references.
        var publicized: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "fn ")) {
                const name_end = std.mem.findScalar(u8, line, '(').?;
                const name = line["fn ".len..name_end];
                try publicized.print(allocator, "/// Generated function {s}.\npub {s}\n", .{ name, line });
                try main_uses.print(allocator, "    _ = {s}.{s};\n", .{ module, name });
            } else if (std.mem.startsWith(u8, line, "const ") and !std.mem.startsWith(u8, line, "const std ")) {
                // Types the public functions mention must be nameable too.
                try publicized.print(allocator, "/// Generated type.\npub {s}\n", .{line});
            } else {
                try publicized.print(allocator, "{s}\n", .{line});
            }
        }
        const path = try allocator.print("{s}.zig", .{module});
        const source = try allocator.dupeSentinel(u8, std.mem.trimEnd(u8, publicized.items, "\n"), 0);
        file.* = .{ .path = path, .source = source };
        try main_imports.print(allocator, "const {s} = @import(\"{s}.zig\");\n", .{ module, module });
    }
    files[0] = .{
        .path = "main.zig",
        .source = try allocator.printSentinel(
            "{s}\n/// Touches every module.\npub fn main() void {{\n{s}}}\n",
            .{ main_imports.items, main_uses.items },
            0,
        ),
    };
    return files;
}

test "generated clean projects raise no findings through the project pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var configuration_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer configuration_arena.deinit();
    var configurations: [profile_names.len + 1]analysis.Configuration = undefined;
    configurations[0] = analysis.Configuration.defaults();
    for (profile_names, configurations[1..]) |name, *configuration| {
        configuration.* = try profileConfiguration(configuration_arena.allocator(), name);
    }
    var reported: std.EnumSet(analysis.Rule) = .empty;
    var seed: u64 = 0;
    while (seed < project_count) : (seed += 1) {
        defer _ = arena.reset(.retain_capacity);
        const files = try generateProject(allocator, seed);
        for (configurations) |configuration| {
            for (files) |file| {
                try std.testing.expect(try round_trip.isFormatted(allocator, file.source));
                for (try analysis.findings(allocator, file.source, configuration)) |finding| {
                    try reportProjectFalsePositive(&reported, seed, file.path, file.source, finding);
                }
            }
            for (try project_rules.findings(allocator, files, configuration)) |entry| {
                const file = files[entry.file_index];
                try reportProjectFalsePositive(&reported, seed, file.path, file.source, entry.finding);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), reported.count());
}

fn reportProjectFalsePositive(
    reported: *std.EnumSet(analysis.Rule),
    seed: u64,
    path: []const u8,
    source: []const u8,
    finding: analysis.Finding,
) !void {
    // The templates allocate in ordinary functions, which the disciplined
    // profile exists to forbid; every other rule must stay quiet.
    if (finding.rule == .allocation_after_init) return;
    if (reported.contains(finding.rule)) return;
    reported.insert(finding.rule);
    std.debug.print("false positive on a clean project: seed {d}, {s}\n", .{ seed, path });
    reportFindings(source, path, &.{finding});
}

test "a seeded project defect is still reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var files = try allocator.dupe(project_rules.SourceFile, try generateProject(allocator, 0));
    files[0].source =
        \\const part0 = @import("part0.zig");
        \\/// Walks without a bound.
        \\pub fn walk(depth: u32) u32 {
        \\    return walk(depth + 1);
        \\}
        \\
    ;
    const found = try project_rules.findings(allocator, files, everythingOnConfiguration());
    for (found) |entry| {
        if (entry.file_index == 0 and entry.finding.rule == .recursive_call) return;
    }
    return error.TestExpectedSeededFinding;
}

test "every rule survives generated projects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = everythingOnConfiguration();
    var seed: u64 = 0;
    while (seed < project_count) : (seed += 1) {
        defer _ = arena.reset(.retain_capacity);
        const files = try generateProject(allocator, seed);
        for (files) |file| _ = try analysis.findings(allocator, file.source, configuration);
        _ = try project_rules.findings(allocator, files, configuration);
    }
}

test "formatting preserves default findings on generated programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = analysis.Configuration.defaults();
    var seed: u64 = 0;
    while (seed < generated_program_count) : (seed += metamorphic_stride) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        const rendered = try parseAndRender(allocator, source);
        const original = try analysis.findings(allocator, source, configuration);
        const transformed = try analysis.findings(allocator, rendered, configuration);
        try expectSameRules(allocator, source, original, rendered, "zig fmt", transformed);
    }
}

test "line comments preserve default findings on generated programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = analysis.Configuration.defaults();
    var prng = std.Random.DefaultPrng.init(0x636f6d6d656e74);
    var seed: u64 = 0;
    while (seed < generated_program_count) : (seed += metamorphic_stride) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        const commented = try insertProbeComment(allocator, source, prng.random());
        const original = try analysis.findings(allocator, source, configuration);
        const transformed = try analysis.findings(allocator, commented, configuration);
        try expectSameRules(allocator, source, original, commented, "comment probe", transformed);
    }
}

test "renaming the allocator parameter preserves default findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = analysis.Configuration.defaults();
    var seed: u64 = 0;
    while (seed < generated_program_count) : (seed += metamorphic_stride) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        const renamed = try renameIdentifier(allocator, source, "allocator", "memory_source");
        const original = try analysis.findings(allocator, source, configuration);
        const transformed = try analysis.findings(allocator, renamed, configuration);
        try expectSameRules(allocator, source, original, renamed, "rename", transformed);
    }
}

test "a seeded leak is still reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leaking_source: [:0]const u8 =
        \\const std = @import("std");
        \\fn keepTally(allocator: std.mem.Allocator) !void {
        \\    const tally = try allocator.alloc(u8, 16);
        \\    tally[0] = 1;
        \\}
    ;
    const found = try analysis.findings(allocator, leaking_source, analysis.Configuration.defaults());
    for (found) |finding| {
        if (finding.rule == .unreleased_allocation) return;
    }
    reportFindings(leaking_source, "seeded leak", found);
    return error.HarnessCannotSeeSeededLeak;
}

test "identical input yields identical findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = everythingOnConfiguration();
    var seed: u64 = 0;
    while (seed < generated_program_count) : (seed += metamorphic_stride) {
        defer _ = arena.reset(.retain_capacity);
        const source = try generateCleanProgram(allocator, seed);
        const first = try analysis.findings(allocator, source, configuration);
        const second = try analysis.findings(allocator, source, configuration);
        try std.testing.expectEqual(first.len, second.len);
        for (first, second) |left, right| {
            try std.testing.expectEqual(left.rule, right.rule);
            try std.testing.expectEqual(left.span.start, right.span.start);
            try std.testing.expectEqual(left.span.end, right.span.end);
        }
    }
}

test "byte mutations never crash the rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const configuration = everythingOnConfiguration();
    var prng = std.Random.DefaultPrng.init(0x6d757461746521);
    const random = prng.random();
    var seed: u64 = 0;
    while (seed < mutation_seed_count) : (seed += 1) {
        defer _ = arena.reset(.retain_capacity);
        const pristine = try generateCleanProgram(allocator, seed);
        for (0..mutations_per_seed) |_| {
            const mutated = try mutateBytes(allocator, pristine, random);
            _ = try analysis.findings(allocator, mutated, configuration);
        }
    }
}

fn mutateBytes(allocator: std.mem.Allocator, source: [:0]const u8, random: std.Random) ![:0]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(allocator, source);
    const mutation_count = random.intRangeAtMost(usize, 1, 8);
    for (0..mutation_count) |_| {
        if (bytes.items.len == 0) break;
        switch (random.uintLessThan(u8, 4)) {
            0 => bytes.items[random.uintLessThan(usize, bytes.items.len)] =
                random.int(u8),
            1 => bytes.shrinkRetainingCapacity(random.uintLessThan(usize, bytes.items.len + 1)),
            2 => {
                const at = random.uintLessThan(usize, bytes.items.len + 1);
                try bytes.insert(allocator, at, random.int(u8));
            },
            3 => {
                const from = random.uintLessThan(usize, bytes.items.len);
                const length = random.uintLessThan(usize, @min(64, bytes.items.len - from) + 1);
                try bytes.ensureUnusedCapacity(allocator, length);
                bytes.appendSliceAssumeCapacity(bytes.items[from .. from + length]);
            },
            else => unreachable,
        }
    }
    return bytes.toOwnedSliceSentinel(allocator, 0);
}

test "rules survive arbitrary bytes" {
    try std.testing.fuzz({}, arbitraryBytesProbe, .{});
}

fn arbitraryBytesProbe(_: void, smith: *std.testing.Smith) !void {
    var source_buf: [largest_robustness_input]u8 = undefined;
    const length = smith.sliceWeightedBytes(source_buf[0 .. source_buf.len - 1], &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .value(u8, ' ', 6),
        .rangeAtMost(u8, '\t', '\n', 6),
    });
    source_buf[length] = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try analysis.findings(arena.allocator(), source_buf[0..length :0], everythingOnConfiguration());
}

test "rules survive generated token soup" {
    try std.testing.fuzz({}, tokenSoupProbe, .{});
}

fn tokenSoupProbe(_: void, smith: *std.testing.Smith) !void {
    var token_smith = std.zig.TokenSmith.gen(smith);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try analysis.findings(arena.allocator(), token_smith.source(), everythingOnConfiguration());
}
