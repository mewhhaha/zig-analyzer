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
    emitMultilineHeaders,
    emitLabeledBlock,
    emitLabeledSwitch,
    emitInlineElse,
    emitDeclLiterals,
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

const dirty_templates = [_]*const fn (*ProgramBuilder) anyerror!void{
    emitDirtyCounter,
    emitDirtyLastElement,
    emitDirtyBitMix,
    emitDirtyAppendLoops,
    emitDirtyCopies,
    emitDirtySliceMutation,
    emitDirtyTesting,
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
    files[0].source = "const part0 = @import(\"part0.zig\");\n";
    const found = try project_rules.findings(allocator, files, everythingOnConfiguration());
    try std.testing.expect(found.len != 0);
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
