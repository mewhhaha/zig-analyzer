//! Code actions: fixes attached to findings, rule-wide and file-wide fix-alls,
//! suppressions, rewrites, native and workspace actions. The edits come from
//! `src/actions` and the rule fixes; this module decides which are offered for
//! the requested range and kinds, and converts them to workspace edits.
const std = @import("std");

const lsp = @import("lsp");

const action_lsp = @import("../actions/lsp_adapter.zig");
const project_actions = @import("../actions/project.zig");
const registry = @import("../actions/registry.zig");
const analysis = @import("../analysis.zig");
const document_module = @import("../syntax/document.zig");
const text_edits = @import("../syntax/text_edits.zig");
const diagnostics = @import("diagnostics.zig");
const rename = @import("rename.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Services = services_module.Services;
const Kind = lsp.types.CodeAction.Kind;

pub fn codeAction(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/codeAction"),
) !lsp.ResultType("textDocument/codeAction") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    var lint_configuration = try services.linter.configuration(arena, document);
    if (action_lsp.isRequested(params.context.only, .@"source.organizeImports")) {
        lint_configuration.levels[@backingInt(analysis.Rule.unsorted_imports)] = .warning;
    }
    const findings = try services.documentFindings(arena, document, lint_configuration);
    var offers: Offers = .{
        .services = services,
        .arena = arena,
        .document = document,
        .only = params.context.only,
        .requested_span = .{
            .start = document.byteOffset(params.range.start),
            .end = document.byteOffset(params.range.end),
        },
    };

    for (findings) |finding| {
        try offers.fixes(finding, findings);
        try offers.rewrites(finding);
        try offers.styleRename(finding);
        try offers.suppressions(finding);
    }
    try offers.nativeActions();
    try offers.workspaceActions();
    try offers.extraction();
    try offers.fixAllSafe();
    return try offers.actions.toOwnedSlice(arena);
}

/// The actions offered so far for one request, and what has been offered
/// already so the same fix-all or suppression is not listed twice.
const Offers = struct {
    services: Services,
    arena: std.mem.Allocator,
    document: *const Document,
    only: ?[]const Kind,
    requested_span: std.zig.Token.Loc,
    actions: std.ArrayList(lsp.types.CodeAction.Result) = .empty,
    fix_all_edits: std.ArrayList(analysis.Edit) = .empty,
    line_suppressions: std.ArrayList(OfferedSuppression) = .empty,
    file_suppressions: std.ArrayList(OfferedSuppression) = .empty,
    rule_fix_alls: std.ArrayList(analysis.Rule) = .empty,

    const OfferedSuppression = struct { rule: analysis.Rule, at: usize };

    fn requested(offers: Offers, kind: Kind) bool {
        return action_lsp.isRequested(offers.only, kind);
    }

    fn overlaps(offers: Offers, span: std.zig.Token.Loc) bool {
        return spansOverlap(offers.requested_span, span);
    }

    fn add(offers: *Offers, title: []const u8, kind: Kind, preferred: bool, edit: lsp.types.WorkspaceEdit) !void {
        try offers.actions.append(offers.arena, .{ .code_action = .{
            .title = title,
            .kind = kind,
            .isPreferred = preferred,
            .edit = edit,
        } });
    }

    fn documentEdit(offers: Offers, source_edits: []const analysis.Edit) !lsp.types.WorkspaceEdit {
        return action_lsp.documentEdit(offers.arena, offers.document, source_edits);
    }

    /// The fixes a finding carries, each with its diagnostic, plus one
    /// rule-wide fix-all the first time a fix-all fix is in range.
    fn fixes(offers: *Offers, finding: analysis.Finding, all_findings: []const analysis.Finding) !void {
        const arena = offers.arena;
        for (finding.fixes) |fix| {
            if (fix.fix_all) try offers.fix_all_edits.appendSlice(arena, fix.edits);
            const kind = action_lsp.kind(fix.kind);
            if (!offers.requested(kind)) continue;
            if (fix.kind != .organize_imports and fix.kind != .fix_all and !offers.overlaps(finding.span)) continue;
            const finding_diagnostics = try arena.alloc(lsp.types.Diagnostic, 1);
            finding_diagnostics[0] = try diagnostics.findingDiagnostic(arena, offers.document, finding);
            try offers.actions.append(arena, .{ .code_action = .{
                .title = fix.title,
                .kind = kind,
                .diagnostics = if (fix.kind == .organize_imports) null else finding_diagnostics,
                .isPreferred = fix.preferred,
                .edit = try offers.documentEdit(fix.edits),
            } });
            if (fix.fix_all and offers.overlaps(finding.span)) try offers.ruleFixAll(finding.rule, all_findings);
        }
    }

    fn ruleFixAll(offers: *Offers, rule: analysis.Rule, all_findings: []const analysis.Finding) !void {
        const arena = offers.arena;
        for (offers.rule_fix_alls.items) |offered| {
            if (offered == rule) return;
        }
        try offers.rule_fix_alls.append(arena, rule);
        var rule_edits: std.ArrayList(analysis.Edit) = .empty;
        for (all_findings) |other| {
            if (other.rule != rule) continue;
            for (other.fixes) |other_fix| {
                if (other_fix.fix_all) try rule_edits.appendSlice(arena, other_fix.edits);
            }
        }
        const safe_edits = try text_edits.nonOverlapping(arena, rule_edits.items);
        if (safe_edits.len == 0) return;
        if (!offers.requested(.@"source.fixAll") and !offers.requested(.quickfix)) return;
        try offers.add(
            try arena.print("Fix all '{s}' in this file", .{rule.code()}),
            .@"source.fixAll",
            false,
            try offers.documentEdit(safe_edits),
        );
    }

    /// Rewrites that replace the code a finding points at.
    fn rewrites(offers: *Offers, finding: analysis.Finding) !void {
        if (!offers.overlaps(finding.span)) return;
        for (try registry.rewrites.forFinding(offers.arena, offers.document.source, finding)) |rewrite| {
            const kind = action_lsp.kind(rewrite.kind);
            if (!offers.requested(kind)) continue;
            try offers.add(rewrite.title, kind, rewrite.preferred, try offers.documentEdit(rewrite.edits));
        }
    }

    /// Renaming a declaration to the name its style finding suggests.
    fn styleRename(offers: *Offers, finding: analysis.Finding) !void {
        if (finding.rule != .non_idiomatic_name and finding.rule != .underscore_private_name and
            finding.rule != .redundant_qualified_name) return;
        if (!offers.overlaps(finding.span) or !offers.requested(.@"refactor.rewrite")) return;
        const arena = offers.arena;
        const document = offers.document;
        const new_name = try registry.naming.suggestedStyleName(arena, document.source, finding.span, finding.rule) orelse return;
        const maybe_edit = rename.workspaceEdit(offers.services, arena, document, finding.span, new_name) catch |err| switch (err) {
            error.RequestFailed => return,
            else => return err,
        };
        const edit = maybe_edit orelse return;
        try offers.add(
            try arena.print("Rename '{s}' to '{s}'", .{ document.source[finding.span.start..finding.span.end], new_name }),
            .@"refactor.rewrite",
            false,
            edit,
        );
    }

    fn suppressions(offers: *Offers, finding: analysis.Finding) !void {
        if (!offers.overlaps(finding.span) or !offers.requested(.quickfix)) return;
        const arena = offers.arena;
        const suppression = try analysis.suppressionEdits(arena, offers.document.source, finding.rule, finding.span.start);
        if (!suppressionOffered(offers.line_suppressions.items, finding.rule, suppression.line.span.start)) {
            try offers.line_suppressions.append(arena, .{ .rule = finding.rule, .at = suppression.line.span.start });
            try offers.add(
                try arena.print("Suppress '{s}' on this line", .{finding.rule.code()}),
                .quickfix,
                false,
                try offers.documentEdit(&.{suppression.line}),
            );
        }
        if (!suppressionOffered(offers.file_suppressions.items, finding.rule, suppression.file.span.start)) {
            try offers.file_suppressions.append(arena, .{ .rule = finding.rule, .at = suppression.file.span.start });
            try offers.add(
                try arena.print("Suppress '{s}' in this file", .{finding.rule.code()}),
                .quickfix,
                false,
                try offers.documentEdit(&.{suppression.file}),
            );
        }
    }

    /// Single-file actions from `src/actions`, shaped by the compiler's
    /// resolved types when known.
    fn nativeActions(offers: *Offers) !void {
        const document = offers.document;
        const resolved_shapes = try offers.services.backend.knownShapes(offers.arena, document.uri);
        const native_actions = try registry.actions(offers.arena, document.source, offers.requested_span, resolved_shapes);
        for (native_actions) |native_action| {
            const kind = action_lsp.kind(native_action.kind);
            if (!offers.requested(kind)) continue;
            try offers.add(native_action.title, kind, native_action.preferred, try offers.documentEdit(native_action.edits));
        }
    }

    /// Actions that edit several files, over the open documents.
    fn workspaceActions(offers: *Offers) !void {
        const arena = offers.arena;
        const document = offers.document;
        var open_documents: std.ArrayList(project_actions.OpenDocument) = .empty;
        var document_iterator = offers.services.documents.documents.valueIterator();
        while (document_iterator.next()) |open_document| {
            try open_documents.append(arena, .{ .uri = open_document.uri, .source = open_document.source });
        }
        const workspace_actions = try project_actions.actions(
            arena,
            document.uri,
            document.source,
            offers.requested_span,
            open_documents.items,
        );
        for (workspace_actions) |workspace_action| {
            const kind = action_lsp.kind(workspace_action.kind);
            if (!offers.requested(kind)) continue;
            try offers.add(
                workspace_action.title,
                kind,
                false,
                try action_lsp.projectEdit(arena, offers.services.documents, workspace_action),
            );
        }
    }

    fn extraction(offers: *Offers) !void {
        if (!offers.requested(.@"refactor.extract")) return;
        const document = offers.document;
        const extraction_edit = try registry.rewrites.extractExpression(
            offers.arena,
            document.source,
            &document.tree,
            offers.requested_span,
        ) orelse return;
        try offers.add(
            extraction_edit.title,
            .@"refactor.extract",
            extraction_edit.preferred,
            try offers.documentEdit(extraction_edit.edits),
        );
    }

    /// One action applying every safe fix-all edit of the file.
    fn fixAllSafe(offers: *Offers) !void {
        if (!offers.requested(.@"source.fixAll")) return;
        const safe_edits = try text_edits.nonOverlapping(offers.arena, offers.fix_all_edits.items);
        if (safe_edits.len == 0) return;
        try offers.actions.append(offers.arena, .{ .code_action = .{
            .title = "Fix all safe zig-analyzer findings",
            .kind = .@"source.fixAll",
            .edit = try offers.documentEdit(safe_edits),
        } });
    }
};

fn spansOverlap(left: std.zig.Token.Loc, right: std.zig.Token.Loc) bool {
    if (left.start == left.end) return right.start <= left.start and left.start <= right.end;
    return left.start < right.end and right.start < left.end;
}

fn suppressionOffered(offered: []const Offers.OfferedSuppression, rule: analysis.Rule, at: usize) bool {
    for (offered) |entry| {
        if (entry.rule == rule and entry.at == at) return true;
    }
    return false;
}

test "a cursor inside a span overlaps it and an adjacent span does not" {
    try std.testing.expect(spansOverlap(.{ .start = 4, .end = 4 }, .{ .start = 2, .end = 6 }));
    try std.testing.expect(spansOverlap(.{ .start = 3, .end = 5 }, .{ .start = 4, .end = 9 }));
    try std.testing.expect(!spansOverlap(.{ .start = 3, .end = 5 }, .{ .start = 5, .end = 9 }));
}
