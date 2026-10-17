//! Range formatting: `zig fmt` formats the whole document, and only its
//! changes on the requested lines are returned (see `syntax/format_diff.zig`
//! for which changes can be separated safely). A document `zig fmt` cannot
//! parse fails the same way whole-document formatting does.
const std = @import("std");

const lsp = @import("lsp");

const zig_fmt = @import("../compiler/zig_fmt.zig");
const format_diff = @import("../syntax/format_diff.zig");
const services_module = @import("services.zig");

const Services = services_module.Services;

pub fn rangeFormatting(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/rangeFormatting"),
) !lsp.ResultType("textDocument/rangeFormatting") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const formatted = try zig_fmt.format(services.io, arena, document.source);
    if (std.mem.eql(u8, formatted, document.source)) return &.{};
    const span: std.zig.Token.Loc = .{
        .start = document.byteOffset(params.range.start),
        .end = document.byteOffset(params.range.end),
    };
    const edits = try format_diff.editsWithin(arena, document.source, formatted, span);
    const text_edits = try arena.alloc(lsp.types.TextEdit, edits.len);
    for (edits, text_edits) |edit, *text_edit| {
        text_edit.* = .{ .range = document.range(edit.span), .newText = edit.replacement };
    }
    return text_edits;
}
