//! Views of a document's shape: document highlights, folding ranges,
//! selection ranges and document links. What each contains is decided in
//! `syntax/structure.zig`; this module converts it to LSP positions and shapes.
const std = @import("std");

const lsp = @import("lsp");

const pathExists = @import("../filesystem.zig").pathExists;
const document_module = @import("../syntax/document.zig");
const syntax_structure = @import("../syntax/structure.zig");
const uri_module = @import("../uri.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Services = services_module.Services;

/// The occurrences of the binding under the cursor in this document, writes
/// (its declaration and assignments) told apart from reads. Null off a
/// binding the scope index resolves, such as a field after `.`.
pub fn documentHighlight(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/documentHighlight"),
) !lsp.ResultType("textDocument/documentHighlight") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const occurrences = try syntax_structure.bindingOccurrences(arena, document, document.byteOffset(params.position)) orelse return null;
    std.mem.sort(syntax_structure.Occurrence, occurrences, {}, struct {
        fn lessThan(_: void, left: syntax_structure.Occurrence, right: syntax_structure.Occurrence) bool {
            return left.span.start < right.span.start;
        }
    }.lessThan);
    const highlights = try arena.alloc(lsp.types.DocumentHighlight, occurrences.len);
    for (occurrences, highlights) |occurrence, *highlight| {
        highlight.* = .{
            .range = document.range(occurrence.span),
            .kind = switch (occurrence.access) {
                .read => .Read,
                .write => .Write,
            },
        };
    }
    return highlights;
}

pub fn foldingRange(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/foldingRange"),
) !lsp.ResultType("textDocument/foldingRange") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const found = try syntax_structure.folds(arena, document);
    const ranges = try arena.alloc(lsp.types.FoldingRange, found.len);
    for (found, ranges) |fold, *range| {
        range.* = .{
            .startLine = fold.start_line,
            .endLine = fold.end_line,
            .kind = switch (fold.kind) {
                .code => null,
                .comment => .comment,
                .imports => .imports,
            },
        };
    }
    return ranges;
}

/// For each position, the token there grown through each syntax node that
/// contains it, out to the whole document.
pub fn selectionRange(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/selectionRange"),
) !lsp.ResultType("textDocument/selectionRange") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const offsets = try arena.alloc(usize, params.positions.len);
    for (params.positions, offsets) |position, *offset| offset.* = document.byteOffset(position);
    const chains = try syntax_structure.selectionChains(arena, document, offsets);
    const selections = try arena.alloc(lsp.types.SelectionRange, chains.len);
    for (chains, selections) |chain, *selection| {
        // Built outermost first, so each range can point at its parent.
        var parent: ?*const lsp.types.SelectionRange = null;
        var index = chain.len;
        while (index > 1) {
            index -= 1;
            const outer = try arena.create(lsp.types.SelectionRange);
            outer.* = .{ .range = document.range(chain[index]), .parent = parent };
            parent = outer;
        }
        selection.* = .{ .range = document.range(chain[0]), .parent = parent };
    }
    return selections;
}

/// Links for the relative files the document names that exist: `@import` of
/// a `.zig` or `.zon` file, `@embedFile`, and a `build.zig.zon` dependency's
/// `.path`, which links to the package's own `build.zig.zon`.
pub fn documentLink(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/documentLink"),
) !lsp.ResultType("textDocument/documentLink") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const document_path = try uri_module.toPath(arena, document.uri) orelse return null;
    const directory = std.Io.Dir.path.dirname(document_path) orelse return null;
    const references = try syntax_structure.fileReferences(arena, document);
    var links: std.ArrayList(lsp.types.DocumentLink) = .empty;
    for (references) |reference| {
        const target_path = switch (reference.kind) {
            .import, .embed => try std.Io.Dir.path.resolveAlloc(arena, &.{ directory, reference.path }),
            .package => try std.Io.Dir.path.resolveAlloc(arena, &.{ directory, reference.path, "build.zig.zon" }),
        };
        if (!try pathExists(services.io, target_path)) continue;
        try links.append(arena, .{
            .range = document.range(reference.span),
            .target = try uri_module.fromPath(arena, target_path),
            .tooltip = target_path,
        });
    }
    return try links.toOwnedSlice(arena);
}
