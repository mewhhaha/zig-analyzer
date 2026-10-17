//! Baseline files: findings recorded once (`check --write-baseline`) and not
//! reported by later checks (`check --baseline`), so a project can turn a
//! rule on without first fixing every existing finding. A finding is keyed by
//! its file's path relative to the project root, its rule, a fingerprint of
//! its line's text with whitespace normalized, and its position among the
//! findings of the file that share those, rather than by line number, so
//! edits elsewhere in the file keep the baseline valid. Editing the line
//! itself reports the finding again.
const std = @import("std");
const analysis = @import("../analysis.zig");

const format_version = 1;

/// The identity of one finding in a baseline.
pub const Key = struct {
    path: []const u8,
    rule: analysis.Rule,
    fingerprint: u64,
    occurrence: u32,

    fn hash(key: Key) u64 {
        return keyHash(key.path, key.rule.code(), key.fingerprint, key.occurrence);
    }
};

fn keyHash(path: []const u8, rule_code: []const u8, fingerprint: u64, occurrence: u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    // Paths are compared with `/` separators, so a baseline written on one
    // system holds on another.
    for (path) |byte| hasher.update(&.{if (byte == '\\') '/' else byte});
    hasher.update(&.{0});
    hasher.update(rule_code);
    hasher.update(std.mem.asBytes(&fingerprint));
    hasher.update(std.mem.asBytes(&occurrence));
    return hasher.final();
}

/// The findings a baseline file records.
pub const Baseline = struct {
    keys: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn contains(baseline: Baseline, key: Key) bool {
        return baseline.keys.contains(key.hash());
    }
};

const StoredFinding = struct {
    path: []const u8,
    rule: []const u8,
    fingerprint: []const u8,
    occurrence: u32,
};

const Stored = struct {
    version: u32,
    findings: []const StoredFinding,
};

/// Reads the baseline file at `path`; the result lives in `allocator`.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Baseline {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, InvalidBaseline }!Baseline {
    const parsed = std.json.parseFromSlice(Stored, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidBaseline,
    };
    defer parsed.deinit();
    if (parsed.value.version != format_version) return error.InvalidBaseline;
    var baseline: Baseline = .{};
    try baseline.keys.ensureTotalCapacity(allocator, @intCast(parsed.value.findings.len));
    for (parsed.value.findings) |finding| {
        const fingerprint = std.fmt.parseInt(u64, finding.fingerprint, 16) catch |err| switch (err) {
            error.Overflow, error.InvalidCharacter => return error.InvalidBaseline,
        };
        baseline.keys.putAssumeCapacity(keyHash(finding.path, finding.rule, fingerprint, finding.occurrence), {});
    }
    return baseline;
}

/// Writes `keys` to the baseline file at `path`, sorted so that the file
/// changes only where findings do.
pub fn write(io: std.Io, allocator: std.mem.Allocator, path: []const u8, keys: []Key) !void {
    std.mem.sort(Key, keys, {}, struct {
        fn lessThan(_: void, left: Key, right: Key) bool {
            switch (std.mem.order(u8, left.path, right.path)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            switch (std.mem.order(u8, left.rule.code(), right.rule.code())) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (left.fingerprint != right.fingerprint) return left.fingerprint < right.fingerprint;
            return left.occurrence < right.occurrence;
        }
    }.lessThan);
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored = try arena.alloc(StoredFinding, keys.len);
    for (keys, stored) |key, *finding| {
        const normalized = try arena.dupe(u8, key.path);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        finding.* = .{
            .path = normalized,
            .rule = key.rule.code(),
            .fingerprint = try arena.print("{x:0>16}", .{key.fingerprint}),
            .occurrence = key.occurrence,
        };
    }
    var encoded: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(Stored{ .version = format_version, .findings = stored }, .{ .whitespace = .indent_2 }, &encoded.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory, // an allocating writer fails only on allocation
    };
    try encoded.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded.written() });
}

/// What a check does with the findings a baseline covers, shared by the
/// passes that report findings, which may run on several threads.
pub const Policy = struct {
    /// Findings recorded by `--baseline`, which are not reported.
    known: ?Baseline = null,
    /// `--write-baseline`: every finding is recorded instead of reported.
    record: bool = false,
    /// Where `Scope.finish` gathers recorded keys; thread-safe.
    allocator: std.mem.Allocator = std.heap.smp_allocator,
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    recorded: std.ArrayList(Key) = .empty,
    covered: std.atomic.Value(usize) = .init(0),

    pub fn active(policy: *const Policy) bool {
        return policy.known != null or policy.record;
    }

    pub fn deinit(policy: *Policy) void {
        policy.recorded.deinit(policy.allocator);
    }
};

/// The baseline decisions for the findings one pass reports in one file, in
/// the order it reports them.
pub const Scope = struct {
    policy: *Policy,
    path: []const u8,
    source: []const u8,
    occurrences: std.AutoHashMapUnmanaged(Slot, u32) = .empty,
    /// Keys recorded for `--write-baseline`, in `Policy.record` mode.
    recorded: std.ArrayList(Key) = .empty,
    /// Findings the baseline covered, which the pass leaves unreported.
    covered: usize = 0,

    const Slot = struct { rule: analysis.Rule, fingerprint: u64 };

    pub fn init(policy: *Policy, path: []const u8, source: []const u8) Scope {
        return .{ .policy = policy, .path = path, .source = source };
    }

    pub fn deinit(scope: *Scope, allocator: std.mem.Allocator) void {
        scope.occurrences.deinit(allocator);
        scope.recorded.deinit(allocator);
    }

    /// Hands the scope's counts and recorded keys to the policy.
    pub fn finish(scope: *const Scope) !void {
        const policy = scope.policy;
        if (!policy.active()) return;
        _ = policy.covered.fetchAdd(scope.covered, .monotonic);
        if (scope.recorded.items.len == 0) return;
        const io = policy.io.?;
        policy.mutex.lockUncancelable(io);
        defer policy.mutex.unlock(io);
        try policy.recorded.appendSlice(policy.allocator, scope.recorded.items);
    }

    /// Whether the finding of `rule` at `offset` is covered by the baseline
    /// and so not reported; in record mode it is recorded and covered.
    pub fn covers(scope: *Scope, allocator: std.mem.Allocator, rule: analysis.Rule, offset: usize) !bool {
        if (!scope.policy.active()) return false;
        const fingerprint = lineFingerprint(scope.source, offset);
        const occurrence = try scope.occurrences.getOrPut(allocator, .{ .rule = rule, .fingerprint = fingerprint });
        if (!occurrence.found_existing) occurrence.value_ptr.* = 0;
        const key: Key = .{ .path = scope.path, .rule = rule, .fingerprint = fingerprint, .occurrence = occurrence.value_ptr.* };
        occurrence.value_ptr.* += 1;
        const covered = if (scope.policy.record) record: {
            try scope.recorded.append(allocator, key);
            break :record true;
        } else scope.policy.known.?.contains(key);
        if (covered) scope.covered += 1;
        return covered;
    }
};

/// The hash of the line holding `offset`, with leading and trailing
/// whitespace dropped and each run of inner whitespace read as one space.
pub fn lineFingerprint(source: []const u8, offset: usize) u64 {
    const bounded = @min(offset, source.len);
    const start = if (std.mem.findScalarLast(u8, source[0..bounded], '\n')) |newline| newline + 1 else 0;
    const end = if (std.mem.findScalarPos(u8, source, bounded, '\n')) |newline| newline else source.len;
    const line = std.mem.trim(u8, source[start..end], " \t\r");
    var hasher = std.hash.Wyhash.init(0);
    var in_space = false;
    for (line) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\r') {
            in_space = true;
            continue;
        }
        if (in_space) hasher.update(" ");
        in_space = false;
        hasher.update(&.{byte});
    }
    return hasher.final();
}

test "fingerprints ignore indentation and spacing but not the text" {
    const first = "fn run() void {\n    foo(a,  b);\n}\n";
    const moved = "\n\nfn run() void {\n\t\tfoo(a, b);   \n}\n";
    const edited = "fn run() void {\n    foo(a, c);\n}\n";
    const fingerprint = lineFingerprint(first, std.mem.find(u8, first, "foo").?);
    try std.testing.expectEqual(fingerprint, lineFingerprint(moved, std.mem.find(u8, moved, "b)").?));
    try std.testing.expect(fingerprint != lineFingerprint(edited, std.mem.find(u8, edited, "foo").?));
}

test "a recorded baseline covers the same findings after unrelated edits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = "_ = x;\n_ = x;\nconst a = 1;\n";
    const after = "const added = 0;\n_ = x;\nconst a = 1;\n_ = x;\n_ = x;\n";

    var record_policy: Policy = .{ .record = true };
    var recording = Scope.init(&record_policy, "src/main.zig", before);
    var offset: usize = 0;
    while (std.mem.findPos(u8, before, offset, "_ = x;")) |found| : (offset = found + 1) {
        try std.testing.expect(try recording.covers(arena, .never_mutated_var, found));
    }
    try std.testing.expectEqual(@as(usize, 2), recording.recorded.items.len);

    var written: std.Io.Writer.Allocating = .init(arena);
    const keys = recording.recorded.items;
    const stored = try arena.alloc(StoredFinding, keys.len);
    for (keys, stored) |key, *finding| finding.* = .{
        .path = key.path,
        .rule = key.rule.code(),
        .fingerprint = try arena.print("{x:0>16}", .{key.fingerprint}),
        .occurrence = key.occurrence,
    };
    try std.json.Stringify.value(Stored{ .version = format_version, .findings = stored }, .{}, &written.writer);
    const baseline = try parse(arena, written.written());

    var check_policy: Policy = .{ .known = baseline };
    var checking = Scope.init(&check_policy, "src/main.zig", after);
    var covered: usize = 0;
    var reported: usize = 0;
    offset = 0;
    while (std.mem.findPos(u8, after, offset, "_ = x;")) |found| : (offset = found + 1) {
        if (try checking.covers(arena, .never_mutated_var, found)) covered += 1 else reported += 1;
    }
    // The two recorded occurrences stay covered; the third is new.
    try std.testing.expectEqual(@as(usize, 2), covered);
    try std.testing.expectEqual(@as(usize, 1), reported);
    // Another rule or file on the same line is not covered.
    try std.testing.expect(!try checking.covers(arena, .unused_import, std.mem.find(u8, after, "_ = x;").?));
    var other = Scope.init(&check_policy, "src/other.zig", after);
    try std.testing.expect(!try other.covers(arena, .never_mutated_var, std.mem.find(u8, after, "_ = x;").?));
}

test "malformed baselines are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{
        "[]",
        "{\"version\":2,\"findings\":[]}",
        "{\"version\":1,\"findings\":[{\"path\":\"a.zig\",\"rule\":\"x\",\"fingerprint\":\"zz\",\"occurrence\":0}]}",
    }) |bytes| {
        try std.testing.expectError(error.InvalidBaseline, parse(arena_state.allocator(), bytes));
    }
}
