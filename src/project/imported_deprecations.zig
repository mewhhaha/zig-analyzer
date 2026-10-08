//! Deprecation findings for declarations a file reaches through imports. The
//! language server and the CLI both run them through this one wiring: which
//! files count as sources, how imports resolve, and which findings survive.
const std = @import("std");
const analysis = @import("../analysis.zig");
const declarations = analysis.deprecated_declarations;
const zig_environment = @import("../compiler/zig_environment.zig");

pub const Source = declarations.Source;

/// A file whose imports are checked.
pub const File = struct {
    path: []const u8,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
};

pub const ImportedDeprecations = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    index: declarations.Index,

    /// Pinned: the index keeps a pointer into `resolver`, so initialize in
    /// place and do not move.
    pub fn init(imported: *ImportedDeprecations, io: std.Io, allocator: std.mem.Allocator) void {
        imported.* = .{
            .allocator = allocator,
            .resolver = .{ .io = io },
            .index = undefined,
        };
        imported.index = .init(allocator, imported.resolver.loader());
    }

    pub fn deinit(imported: *ImportedDeprecations) void {
        imported.index.deinit();
        imported.* = undefined;
    }

    /// Registers a file's current contents; they take precedence over disk, so
    /// unsaved dependencies are seen as the user sees them.
    pub fn addSource(imported: *ImportedDeprecations, source: Source) !void {
        try imported.index.addSource(source);
    }

    /// Appends the deprecated-declaration findings of `file`. Translate-c
    /// output is skipped and suppression comments are honoured.
    pub fn check(
        imported: *ImportedDeprecations,
        file: File,
        configuration: analysis.Configuration,
        findings: *std.ArrayList(analysis.Finding),
    ) !void {
        if (configuration.level(.deprecated_declaration) == .off or analysis.isTranslateCOutput(file.source)) return;
        const first_new = findings.items.len;
        try imported.index.run(.{
            .allocator = imported.allocator,
            .source = file.source,
            .tokens = file.tokens,
            .configuration = configuration,
            .findings = findings,
        }, file.path, true);
        const suppressions = try analysis.Suppressions.init(imported.allocator, file.source);
        defer suppressions.deinit(imported.allocator);
        // Only the findings just produced were not already filtered.
        var added = findings.items[first_new..];
        var kept: usize = 0;
        for (added) |finding| {
            if (suppressions.isSuppressed(finding.rule, finding.span.start)) continue;
            added[kept] = finding;
            kept += 1;
        }
        findings.shrinkRetainingCapacity(first_new + kept);
    }

    /// Paths of the files the last `check` read through imports. The caller
    /// owns the slice; the paths belong to the index.
    pub fn dependencyPaths(imported: *const ImportedDeprecations, allocator: std.mem.Allocator) ![]const []const u8 {
        return imported.index.dependencyPaths(allocator);
    }
};

/// Resolves `@import("std")` through the Zig installation (discovered once per
/// process) and relative `.zig` imports against the importing file. Missing
/// toolchains and unreadable files only drop diagnostics, never fail a check.
const Resolver = struct {
    io: std.Io,

    fn loader(resolver: *Resolver) declarations.Loader {
        return .{ .context = resolver, .resolve = resolve, .load = load };
    }

    fn resolve(raw_context: *anyopaque, allocator: std.mem.Allocator, current: []const u8, spelling: []const u8) !?[]const u8 {
        const resolver: *Resolver = @ptrCast(@alignCast(raw_context));
        if (std.mem.eql(u8, spelling, "std")) {
            const directory = zig_environment.libDirectory(resolver.io) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.ZigEnvironmentUnavailable, error.ZigEnvironmentMalformed => return null,
            };
            return try std.Io.Dir.path.join(allocator, &.{ directory, "std", "std.zig" });
        }
        if (std.mem.endsWith(u8, spelling, ".zig")) {
            if (std.Io.Dir.path.isAbsolute(spelling)) return null;
            return try std.Io.Dir.path.resolveAlloc(allocator, &.{ std.Io.Dir.path.dirname(current) orelse ".", spelling });
        }
        // A textual addModule call does not prove this compilation's import map.
        // Named build modules require resolved compilation bindings.
        return null;
    }

    fn load(raw_context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !?declarations.Source {
        const resolver: *Resolver = @ptrCast(@alignCast(raw_context));
        const bytes = std.Io.Dir.cwd().readFileAlloc(resolver.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return null,
        };
        defer allocator.free(bytes);
        return .{ .path = path, .source = try allocator.dupeSentinel(u8, bytes, 0), .owned_source = true };
    }
};

test "imported deprecations see unsaved dependencies and honour suppressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var imported: ImportedDeprecations = undefined;
    imported.init(std.testing.io, allocator);
    defer imported.deinit();

    const dependency_path = "/tmp/zig-analyzer-imported-deprecations-test/dependency.zig";
    try imported.addSource(.{
        .path = dependency_path,
        .source = "/// Deprecated; use current\npub fn old() void {}\n",
    });
    const configuration = analysis.Configuration.defaults();
    const main_source: [:0]const u8 = "const api = @import(\"dependency.zig\");\npub fn run() void { api.old(); }\n";
    const tokens = try @import("../syntax/tokens.zig").tokenize(allocator, main_source);
    var findings: std.ArrayList(analysis.Finding) = .empty;
    try imported.check(.{
        .path = "/tmp/zig-analyzer-imported-deprecations-test/main.zig",
        .source = main_source,
        .tokens = tokens,
    }, configuration, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expect(std.mem.find(u8, findings.items[0].message, "use current") != null);

    const suppressed_source: [:0]const u8 =
        "const api = @import(\"dependency.zig\");\n" ++
        "pub fn run() void {\n// zig-analyzer: disable-next-line deprecated-declaration\napi.old(); }\n";
    const suppressed_tokens = try @import("../syntax/tokens.zig").tokenize(allocator, suppressed_source);
    var suppressed: std.ArrayList(analysis.Finding) = .empty;
    try imported.check(.{
        .path = "/tmp/zig-analyzer-imported-deprecations-test/suppressed.zig",
        .source = suppressed_source,
        .tokens = suppressed_tokens,
    }, configuration, &suppressed);
    try std.testing.expectEqual(@as(usize, 0), suppressed.items.len);
}
