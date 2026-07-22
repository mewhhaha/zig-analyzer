const std = @import("std");
const lsp = @import("lsp");
const analysis = @import("../analysis.zig");
const document_module = @import("../document.zig");
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
    if (candidate.created_file) |created_file| {
        return try projectEditWithCreatedFile(allocator, documents, candidate.edits, created_file);
    }
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

fn projectEditWithCreatedFile(
    allocator: std.mem.Allocator,
    documents: *const document_module.Store,
    file_edits: []const project_actions.FileEdit,
    created_file: project_actions.CreatedFile,
) !lsp.types.WorkspaceEdit {
    const DocumentChanges = @typeInfo(@FieldType(lsp.types.WorkspaceEdit, "documentChanges")).optional.child;
    const DocumentChange = @typeInfo(DocumentChanges).pointer.child;
    const EditChanges = @typeInfo(@FieldType(lsp.types.TextDocument.Edit, "edits")).pointer.child;
    const operations = try allocator.alloc(DocumentChange, file_edits.len + 2);
    var initialized_edits: usize = 0;
    errdefer {
        for (operations[1 .. initialized_edits + 1]) |operation| switch (operation) {
            .text_document_edit => |edit| allocator.free(edit.edits),
            else => {},
        };
        allocator.free(operations);
    }
    operations[0] = .{ .create_file = .{ .uri = created_file.uri } };

    const created_edits = try allocator.alloc(EditChanges, 1);
    created_edits[0] = .{ .text_edit = .{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 0 },
        },
        .newText = created_file.source,
    } };
    operations[1] = .{ .text_document_edit = .{
        .textDocument = .{ .uri = created_file.uri, .version = null },
        .edits = created_edits,
    } };
    initialized_edits += 1;

    for (file_edits, 2..) |file_edit, operation_index| {
        const document = documents.getConst(file_edit.uri) orelse return error.DocumentNotOpen;
        const edits = try allocator.alloc(EditChanges, 1);
        edits[0] = .{ .text_edit = .{
            .range = document.range(file_edit.edit.span),
            .newText = file_edit.edit.replacement,
        } };
        operations[operation_index] = .{ .text_document_edit = .{
            .textDocument = .{ .uri = file_edit.uri, .version = document.version },
            .edits = edits,
        } };
        initialized_edits += 1;
    }
    return .{ .documentChanges = operations };
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

test "created-file edits release partial operations when a document is missing" {
    var documents = document_module.Store.init(std.testing.allocator);
    defer documents.deinit();
    try documents.open("file:///workspace/open.zig", 1, "const value = 1;\n");
    const edits = [_]project_actions.FileEdit{
        .{ .uri = "file:///workspace/open.zig", .edit = .{ .span = .{ .start = 0, .end = 0 }, .replacement = "// open\n" } },
        .{ .uri = "file:///workspace/missing.zig", .edit = .{ .span = .{ .start = 0, .end = 0 }, .replacement = "// missing\n" } },
    };

    try std.testing.expectError(error.DocumentNotOpen, projectEditWithCreatedFile(
        std.testing.allocator,
        &documents,
        &edits,
        .{ .uri = "file:///workspace/new.zig", .source = "const created = true;\n" },
    ));
}
