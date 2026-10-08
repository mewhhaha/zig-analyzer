//! Root sources that build.zig configures with different target or optimize options.
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenIs = tokens_util.tokenIs;
const matchingToken = tokens_util.matchingToken;

pub const rules = [_]types.Rule{.conflicting_build_options};
const import_graph = @import("import_graph.zig");
const resolveImportPath = import_graph.resolveImportPath;
const stringValue = import_graph.stringValue;

pub fn find(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.conflicting_build_options) == .off) return;
    var roots: std.StringHashMapUnmanaged(struct { signature: []const u8, file_index: usize }) = .empty;
    defer {
        var it = roots.iterator();
        while (it.next()) |entry| {
            run.allocator.free(entry.key_ptr.*);
            run.allocator.free(entry.value_ptr.signature);
        }
        roots.deinit(run.allocator);
    }
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = reported.keyIterator();
        while (it.next()) |key| run.allocator.free(key.*);
        reported.deinit(run.allocator);
    }
    for (run.files, 0..) |file, file_index| {
        if (!std.mem.eql(u8, std.Io.Dir.path.basename(file.path), "build.zig")) continue;
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .identifier or !tokenIs(file.source, token, "root_source_file") or index + 6 >= file.tokens.len) continue;
            var string_index = index + 1;
            while (string_index < file.tokens.len and string_index - index < 12 and file.tokens[string_index].tag != .string_literal) : (string_index += 1) {}
            if (string_index >= file.tokens.len or string_index - index >= 12) continue;
            const root_spelling = stringValue(file.source, file.tokens[string_index]) orelse continue;
            if (!std.mem.endsWith(u8, root_spelling, ".zig")) continue;
            const block = enclosingInitializer(file.tokens, index) orelse continue;
            const signature = try optionSignature(run.allocator, file.source, file.tokens, block.opening + 1, block.closing);
            if (std.mem.eql(u8, signature, "target=<default>;optimize=<default>")) {
                run.allocator.free(signature);
                continue;
            }
            const root_path = try resolveImportPath(run.allocator, file.path, root_spelling);
            const gop = try roots.getOrPut(run.allocator, root_path);
            if (gop.found_existing) {
                run.allocator.free(root_path);
                defer run.allocator.free(signature);
                const first = gop.value_ptr.*;
                if (std.mem.eql(u8, first.signature, signature)) continue;
                const conflict_key = try run.allocator.print("{s}\x00{s}", .{ gop.key_ptr.*, signature });
                const rep_gop = try reported.getOrPut(run.allocator, conflict_key);
                if (rep_gop.found_existing) {
                    run.allocator.free(conflict_key);
                    continue;
                }
                rep_gop.value_ptr.* = {};
                try run.report(.{
                    .file_index = file_index,
                    .rule = .conflicting_build_options,
                    .span = file.tokens[string_index].loc,
                    .message = try run.allocator.print(
                        "root source '{s}' is configured with both '{s}' and '{s}'; semantic results may differ between compile units",
                        .{ gop.key_ptr.*, first.signature, signature },
                    ),
                });
            } else {
                gop.value_ptr.* = .{ .signature = signature, .file_index = file_index };
            }
        }
    }
}

const Block = struct { opening: usize, closing: usize };

fn enclosingInitializer(tokens: []const std.zig.Token, index: usize) ?Block {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        if (tokens[cursor].tag == .r_brace) depth += 1;
        if (tokens[cursor].tag != .l_brace) continue;
        if (depth != 0) {
            depth -= 1;
            continue;
        }
        const closing = matchingToken(tokens, cursor, .l_brace, .r_brace) orelse return null;
        return .{ .opening = cursor, .closing = closing };
    }
    return null;
}

fn optionSignature(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
) ![]const u8 {
    const target = optionValue(source, tokens, start, end, "target") orelse "<default>";
    const optimize = optionValue(source, tokens, start, end, "optimize") orelse "<default>";
    return try allocator.print("target={s};optimize={s}", .{ target, optimize });
}

fn optionValue(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize, name: []const u8) ?[]const u8 {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(source, token, name) or index + 2 >= end or tokens[index + 1].tag != .equal) continue;
        var value_end = index + 2;
        while (value_end < end and tokens[value_end].tag != .comma) : (value_end += 1) {}
        if (value_end == index + 2) return null;
        return std.mem.trim(u8, source[tokens[index + 2].loc.start..tokens[value_end - 1].loc.end], " \t\r\n");
    }
    return null;
}
