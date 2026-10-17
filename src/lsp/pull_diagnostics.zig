//! Pull diagnostics: `textDocument/diagnostic` answers with the same merged
//! layers `publishDiagnostics` would carry (see `diagnostics.zig`). It is
//! advertised only to a client that both pulls and accepts
//! `workspace/diagnostic/refresh`, since compiler results arrive after the
//! pull that follows an edit; every other client keeps push diagnostics. A
//! client never gets both, which would show each diagnostic twice.
const std = @import("std");

const lsp = @import("lsp");

const diagnostics = @import("diagnostics.zig");
const services_module = @import("services.zig");

const Services = services_module.Services;
const Report = lsp.ResultType("textDocument/diagnostic");

/// Whether the client pulls diagnostics and can be told to pull again.
pub fn clientPulls(capabilities: lsp.types.ClientCapabilities) bool {
    const text_document = capabilities.textDocument orelse return false;
    if (text_document.diagnostic == null) return false;
    const workspace = capabilities.workspace orelse return false;
    const workspace_diagnostics = workspace.diagnostics orelse return false;
    return workspace_diagnostics.refreshSupport orelse false;
}

/// What the server advertises to a client that pulls: documents only, and
/// a document's diagnostics can change when another file does.
pub const options: lsp.types.ServerCapabilities.DiagnosticOptions = .{ .diagnostic_options = .{
    .identifier = "zig-analyzer",
    .interFileDependencies = true,
    .workspaceDiagnostics = false,
} };

pub fn documentDiagnostic(
    services: Services,
    publisher: *diagnostics.Publisher,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/diagnostic"),
) !Report {
    const uri = params.textDocument.uri;
    const document = services.documents.getConst(uri) orelse return full(null, &.{});
    const current = try publisher.pulled(arena, uri, document.version) orelse current: {
        // Opening or editing a document computes its lint layer; compute it
        // here when that has not happened for this version.
        const shapes = try services.backend.knownShapes(arena, uri);
        const lint = try services.linter.diagnostics(arena, services.documents, document, shapes, services.dependencies);
        try publisher.publishLint(uri, document.version, lint);
        break :current try publisher.pulled(arena, uri, document.version) orelse return full(null, &.{});
    };
    const result_id = try arena.print("{d}", .{current.result_id});
    const unchanged = if (params.previousResultId) |previous| std.mem.eql(u8, previous, result_id) else false;
    if (unchanged) return .{ .related_unchanged_document_diagnostic_report = .{ .resultId = result_id } };
    return full(result_id, current.diagnostics);
}

fn full(result_id: ?[]const u8, items: []const lsp.types.Diagnostic) Report {
    return .{ .related_full_document_diagnostic_report = .{ .resultId = result_id, .items = items } };
}
