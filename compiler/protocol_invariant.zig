//! Checks that the compiler patch and the analyzer agree on the wire protocol.
//! The protocol source itself is shared (bootstrap installs
//! `src/compiler/protocol.zig` into the compiler checkout), so what can still
//! drift is the patch's use of it.
const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

const protocol = zig_analyzer.compiler.protocol;
const build_options = zig_analyzer.build_options;
const patch = @embedFile("analysis.patch");

test "patch imports the shared protocol instead of carrying a copy" {
    try std.testing.expect(std.mem.find(u8, patch, "+++ b/src/AnalysisProtocol.zig") == null);
    try std.testing.expect(std.mem.find(u8, patch, "@import(\"AnalysisProtocol.zig\")") != null);
    try std.testing.expect(std.mem.find(u8, patch, "AnalysisProtocol.version") != null);
    try std.testing.expect(std.mem.find(u8, patch, "AnalysisProtocol.port_announcement") != null);
}

test "every protocol declaration the patch names exists" {
    // @typeInfo cannot enumerate declarations, so read the protocol source.
    const protocol_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/compiler/protocol.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(protocol_source);
    var remaining: []const u8 = patch;
    var references: usize = 0;
    while (std.mem.find(u8, remaining, "AnalysisProtocol.")) |start| {
        const name_start = start + "AnalysisProtocol.".len;
        var name_end = name_start;
        while (name_end < remaining.len and (std.ascii.isAlphanumeric(remaining[name_end]) or remaining[name_end] == '_')) {
            name_end += 1;
        }
        const name = remaining[name_start..name_end];
        // Zig file names such as "AnalysisProtocol.zig" are not declarations.
        if (!std.mem.eql(u8, name, "zig")) {
            references += 1;
            if (!declares(protocol_source, name)) {
                std.debug.print("patch references AnalysisProtocol.{s}, which compiler_protocol.zig does not declare\n", .{name});
                return error.UndeclaredProtocolName;
            }
        }
        remaining = remaining[name_end..];
    }
    try std.testing.expect(references > 0);
}

test "every message tag the patch writes is a protocol tag" {
    var remaining: []const u8 = patch;
    var references: usize = 0;
    while (std.mem.find(u8, remaining, ".tag = .")) |start| {
        const name_start = start + ".tag = .".len;
        var name_end = name_start;
        while (name_end < remaining.len and (std.ascii.isAlphanumeric(remaining[name_end]) or remaining[name_end] == '_')) {
            name_end += 1;
        }
        const name = remaining[name_start..name_end];
        references += 1;
        if (std.meta.stringToEnum(protocol.Tag, name) == null) {
            std.debug.print("patch writes tag .{s}, which compiler_protocol.zig does not declare\n", .{name});
            return error.UndeclaredProtocolTag;
        }
        remaining = remaining[name_end..];
    }
    try std.testing.expect(references > 0);
}

test "the patch serves every request the analyzer client sends" {
    // These are the tags `src/compiler/client.zig` writes as requests. The
    // patch must handle each by name, or the backend would drop it silently.
    const requests = [_]protocol.Tag{
        .hello,
        .replace_overlay,
        .remove_overlay,
        .analyze,
        .diagnostics,
        .resolve_symbol,
        .type_members,
        .type_shape,
        .resolved_value,
        .workspace_declarations,
        .workspace_declaration_names,
        .shutdown,
    };
    for (requests) |tag| {
        var buffer: [64]u8 = undefined;
        const handler = try std.mem.print(&buffer, "            .{t} => ", .{tag});
        if (std.mem.find(u8, patch, handler) == null) {
            std.debug.print("patch has no handler for request .{t}\n", .{tag});
            return error.UnservedRequest;
        }
    }
}

test "resolve_symbol is answered with the structures the protocol declares" {
    for ([_][]const u8{ "ResolveSymbolsRequest", "SymbolsResponse", "SymbolResult", "SymbolStatus", "SymbolKind", "StepKind", "QueryHeader", "query_declaration_site" }) |name| {
        var buffer: [96]u8 = undefined;
        const reference = try std.mem.print(&buffer, "AnalysisProtocol.{s}", .{name});
        try std.testing.expect(std.mem.find(u8, patch, reference) != null);
    }
}

test "patch answers hello with the analyzer's Zig version" {
    var buffer: [64]u8 = undefined;
    const zig_version_check = try std.mem.print(
        &buffer,
        "std.mem.eql(u8, zig_version, \"{s}\")",
        .{build_options.zig_version},
    );
    try std.testing.expect(std.mem.find(u8, patch, zig_version_check) != null);

    const zig_version_response = try std.mem.print(
        &buffer,
        "const zig_version = \"{s}\";",
        .{build_options.zig_version},
    );
    try std.testing.expect(std.mem.find(u8, patch, zig_version_response) != null);
}

fn declares(protocol_source: []const u8, name: []const u8) bool {
    var buffer: [128]u8 = undefined;
    const declaration = std.mem.print(&buffer, "pub const {s}", .{name}) catch return false;
    var offset: usize = 0;
    while (std.mem.findPos(u8, protocol_source, offset, declaration)) |index| : (offset = index + declaration.len) {
        const next = index + declaration.len;
        if (next < protocol_source.len and (protocol_source[next] == ' ' or protocol_source[next] == ':')) return true;
    }
    return false;
}
