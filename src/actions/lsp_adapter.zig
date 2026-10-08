const std = @import("std");
const lsp = @import("lsp");
const analysis = @import("../analysis.zig");
const document_module = @import("../syntax/document.zig");
const project_actions = @import("project.zig");

pub fn kind(action_kind: analysis.ActionKind) lsp.types.CodeAction.Kind {
    return switch (action_kind) {
        .quickfix => .quickfix,
        .refactor_extract => .@"refactor.extract",
        .refactor_rewrite => .@"refactor.rewrite",
        .organize_imports => .@"source.organizeImports",
        .fix_all => .@"source.fixAll",
    };
}

pub fn isRequested(
    requested_kinds: ?[]const lsp.types.CodeAction.Kind,
    action_kind: lsp.types.CodeAction.Kind,
) bool {
    const requested = requested_kinds orelse return true;
    for (requested) |requested_kind| {
        if (lsp.types.CodeAction.Kind.eql(requested_kind, action_kind)) return true;
        switch (requested_kind) {
            .refactor => switch (action_kind) {
                .refactor, .@"refactor.extract", .@"refactor.inline", .@"refactor.move", .@"refactor.rewrite" => return true,
                else => {},
            },
            .source => switch (action_kind) {
                .source, .@"source.organizeImports", .@"source.fixAll" => return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

pub fn documentEdit(
    allocator: std.mem.Allocator,
    document: *const document_module.Document,
    source_edits: []const analysis.Edit,
) !lsp.types.WorkspaceEdit {
    const edits = try allocator.alloc(lsp.types.TextEdit, source_edits.len);
    for (source_edits, edits) |source_edit, *edit| {
        edit.* = .{ .range = document.range(source_edit.span), .newText = source_edit.replacement };
    }
    var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
    try changes.map.put(allocator, document.uri, edits);
    return .{ .changes = changes };
}

pub fn projectEdit(
    allocator: std.mem.Allocator,
    documents: *const document_module.Store,
    candidate: project_actions.Candidate,
) !lsp.types.WorkspaceEdit {
    var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
    for (candidate.edits) |file_edit| {
        const document = documents.getConst(file_edit.uri) orelse continue;
        const existing = changes.map.get(file_edit.uri) orelse &.{};
        const edits = try allocator.alloc(lsp.types.TextEdit, existing.len + 1);
        @memcpy(edits[0..existing.len], existing);
        edits[existing.len] = .{
            .range = document.range(file_edit.edit.span),
            .newText = file_edit.edit.replacement,
        };
        try changes.map.put(allocator, file_edit.uri, edits);
    }
    return .{ .changes = changes };
}

test "parent action kinds include their children" {
    try std.testing.expect(isRequested(&.{.refactor}, .@"refactor.extract"));
    try std.testing.expect(isRequested(&.{.source}, .@"source.fixAll"));
    try std.testing.expect(!isRequested(&.{.quickfix}, .@"refactor.extract"));
}

test "document edits convert byte spans to UTF-16 ranges" {
    var document = try document_module.Document.open(
        std.testing.allocator,
        "file:///workspace/main.zig",
        1,
        "const value = \"😀\";\n",
    );
    defer document.deinit();

    const edit = try documentEdit(std.testing.allocator, &document, &.{.{
        .span = .{ .start = 19, .end = 19 },
        .replacement = "!",
    }});
    defer {
        const changes = edit.changes.?;
        const edits = changes.map.get(document.uri).?;
        std.testing.allocator.free(edits);
        var owned_changes = changes;
        owned_changes.map.deinit(std.testing.allocator);
    }
    const edits = edit.changes.?.map.get(document.uri).?;
    try std.testing.expectEqual(@as(u32, 17), edits[0].range.start.character);
}
