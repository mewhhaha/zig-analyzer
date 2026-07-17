const std = @import("std");
const analysis = @import("zig_analyzer").analysis;

const generated_program_count = 600;
const metamorphic_stride = 5;
const mutation_seed_count = 48;
const mutations_per_seed = 16;
const largest_robustness_input = 4096;

fn everythingOnConfiguration() analysis.Configuration {
    var configuration = analysis.Configuration.defaults();
    for (&configuration.levels) |*level| level.* = .warning;
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
        const piece = try std.fmt.allocPrint(builder.allocator, format, arguments);
        try builder.text.appendSlice(builder.allocator, piece);
    }

    fn functionName(builder: *ProgramBuilder) ![]const u8 {
        builder.sequence += 1;
        const quality = quality_names[builder.random.uintLessThan(usize, quality_names.len)];
        const subject = subject_names[builder.random.uintLessThan(usize, subject_names.len)];
        return std.fmt.allocPrint(builder.allocator, "{s}{c}{s}{d}", .{
            quality, std.ascii.toUpper(subject[0]), subject[1..], builder.sequence,
        });
    }

    fn localName(builder: *ProgramBuilder) ![]const u8 {
        builder.sequence += 1;
        const quality = quality_names[builder.random.uintLessThan(usize, quality_names.len)];
        const subject = subject_names[builder.random.uintLessThan(usize, subject_names.len)];
        return std.fmt.allocPrint(builder.allocator, "{s}_{s}_{d}", .{ quality, subject, builder.sequence });
    }

    fn smallLength(builder: *ProgramBuilder) u32 {
        return builder.random.intRangeAtMost(u32, 1, 96);
    }
};

fn emitReleasedBuffer(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
    const buffer = try builder.localName();
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
    const gate = try builder.functionName();
    const buffer = try builder.localName();
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
    const function = try builder.functionName();
    const buffer = try builder.localName();
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
    const scratch = try builder.localName();
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
    try builder.append(
        \\fn {s}(values: []const u32) u64 {{
        \\    var total: u64 = 0;
        \\    var index: usize = 0;
        \\    while (index < values.len) : (index += 1) {{
        \\        total += values[index];
        \\    }}
        \\    return total;
        \\}}
        \\
    , .{function});
}

fn emitExhaustiveSwitch(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
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
    try builder.append(
        \\fn {s}(allocator: std.mem.Allocator, count: usize) !usize {{
        \\    var entries: std.ArrayList(u32) = .empty;
        \\    defer entries.deinit(allocator);
        \\    var round: usize = 0;
        \\    while (round < count) : (round += 1) {{
        \\        try entries.append(allocator, @intCast(round));
        \\    }}
        \\    return entries.items.len;
        \\}}
        \\
    , .{function});
}

fn emitPureCompute(builder: *ProgramBuilder) !void {
    const function = try builder.functionName();
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
    try builder.append(
        \\fn {s}(message: []const u8) error{{Empty}}!usize {{
        \\    if (message.len == 0) return error.Empty;
        \\    return message.len;
        \\}}
        \\
    , .{function});
}

const templates = [_]*const fn (*ProgramBuilder) anyerror!void{
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
};

fn generateCleanProgram(allocator: std.mem.Allocator, seed: u64) ![:0]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var builder = ProgramBuilder.init(allocator, prng.random());
    try builder.append("const std = @import(\"std\");\n", .{});
    const function_count = builder.random.intRangeAtMost(usize, 3, 8);
    var round: usize = 0;
    while (round < function_count) : (round += 1) {
        const template = templates[builder.random.uintLessThan(usize, templates.len)];
        try template(&builder);
    }
    return builder.text.toOwnedSliceSentinel(allocator, 0);
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
    for (found, rules) |finding, *rule| rule.* = @intFromEnum(finding.rule);
    std.mem.sort(u16, rules, {}, std.sort.asc(u16));
    return rules;
}

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
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    const rendered = try tree.renderAlloc(allocator);
    return try allocator.dupeZ(u8, rendered);
}

fn insertProbeComment(allocator: std.mem.Allocator, source: [:0]const u8, random: std.Random) ![:0]const u8 {
    var line_starts: std.ArrayList(usize) = .empty;
    try line_starts.append(allocator, 0);
    for (source, 0..) |byte, index| {
        if (byte == '\n' and index + 1 < source.len) try line_starts.append(allocator, index + 1);
    }
    const at = line_starts.items[random.uintLessThan(usize, line_starts.items.len)];
    return std.fmt.allocPrintSentinel(allocator, "{s}// probe comment\n{s}", .{
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
        var round: usize = 0;
        while (round < mutations_per_seed) : (round += 1) {
            const mutated = try mutateBytes(allocator, pristine, random);
            _ = try analysis.findings(allocator, mutated, configuration);
        }
    }
}

fn mutateBytes(allocator: std.mem.Allocator, source: [:0]const u8, random: std.Random) ![:0]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(allocator, source);
    const mutation_count = random.intRangeAtMost(usize, 1, 8);
    var applied: usize = 0;
    while (applied < mutation_count) : (applied += 1) {
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
                try bytes.appendSlice(allocator, bytes.items[from .. from + length]);
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
