//! The committed rule documents must match what `zig build rule-docs` renders
//! from the catalog; the build runs this from the repository root.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

test "rule documents match the catalog" {
    try zig_analyzer.rule_docs.sync(std.testing.io, std.testing.allocator, std.Io.Dir.cwd(), .check);
}
