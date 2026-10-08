//! Read-only views of a document: symbols, semantic tokens, inlay hints,
//! signature help, code lenses, call hierarchy and formatting. What each view
//! contains is decided in `syntax/` (annotations, cursor queries); this module
//! converts it to LSP positions and shapes.
const std = @import("std");

const lsp = @import("lsp");

const zig_fmt = @import("../compiler/zig_fmt.zig");
const annotations = @import("../syntax/annotations.zig");
const cursor = @import("../syntax/cursor.zig");
const document_module = @import("../syntax/document.zig");
const hover = @import("hover.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Declaration = document_module.Declaration;
const Services = services_module.Services;

/// Index order is `annotations.TokenClass`.
pub const semantic_token_types: []const []const u8 = &.{
    "variable",
    "function",
    "keyword",
    "comment",
    "string",
    "number",
    "macro",
};

/// Bit order is the `annotations.Modifier` constants.
pub const semantic_token_modifiers: []const []const u8 = &.{ "declaration", "readonly", "static" };

pub fn documentSymbol(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/documentSymbol"),
) !lsp.ResultType("textDocument/documentSymbol") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const symbols = try arena.alloc(lsp.types.DocumentSymbol, document.declarations.len);
    for (document.declarations, symbols) |declaration, *symbol| {
        const range = document.range(declaration.span);
        symbol.* = .{
            .name = declaration.name,
            .kind = symbolKind(declaration.kind),
            .range = range,
            .selectionRange = range,
        };
    }
    return .{ .document_symbols = symbols };
}

pub fn workspaceSymbol(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("workspace/symbol"),
) !lsp.ResultType("workspace/symbol") {
    var symbols: std.ArrayList(lsp.types.SymbolInformation) = .empty;
    var iterator = services.documents.documents.valueIterator();
    while (iterator.next()) |document| {
        for (document.declarations) |declaration| {
            if (params.query.len != 0 and std.mem.find(u8, declaration.name, params.query) == null) continue;
            try symbols.append(arena, .{
                .name = declaration.name,
                .kind = symbolKind(declaration.kind),
                .location = .{
                    .uri = document.uri,
                    .range = document.range(declaration.span),
                },
            });
        }
    }
    return .{ .symbol_informations = try symbols.toOwnedSlice(arena) };
}

pub fn semanticTokensFull(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/semanticTokens/full"),
) !lsp.ResultType("textDocument/semanticTokens/full") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    return .{ .data = try semanticTokens(document, arena, null) };
}

pub fn semanticTokensRange(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/semanticTokens/range"),
) !lsp.ResultType("textDocument/semanticTokens/range") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    return .{ .data = try semanticTokens(document, arena, params.range) };
}

pub fn inlayHint(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/inlayHint"),
) !lsp.ResultType("textDocument/inlayHint") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    return try inlayHints(document, arena, params.range);
}

pub fn signatureHelp(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/signatureHelp"),
) !lsp.ResultType("textDocument/signatureHelp") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const call = cursor.callAt(document.source, document.byteOffset(params.position)) orelse return null;
    const label = cursor.functionSignature(document.source, call.name) orelse return null;
    const signatures = try arena.alloc(lsp.types.SignatureHelp.Signature, 1);
    signatures[0] = .{ .label = label };
    return .{
        .signatures = signatures,
        .activeSignature = 0,
        .activeParameter = call.active_parameter,
    };
}

/// One lens per top-level constant the compiler resolved to a type.
pub fn codeLens(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/codeLens"),
) !lsp.ResultType("textDocument/codeLens") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    var lenses: std.ArrayList(lsp.types.code_lens.Response) = .empty;
    for (document.declarations) |declaration| {
        if (declaration.kind != .constant) continue;
        const shape = try services.resolvedShape(arena, document, declaration.name) orelse continue;
        const arguments = try arena.alloc(std.json.Value, 2);
        arguments[0] = .{ .string = document.uri };
        arguments[1] = .{ .string = declaration.name };
        try lenses.append(arena, .{
            .range = document.range(declaration.span),
            .command = .{
                .title = try arena.print(
                    "resolved {s}: {d} {s}",
                    .{
                        hover.resolvedShapeKindName(shape.kind),
                        shape.fields.len,
                        if (shape.fields.len == 1) "member" else "members",
                    },
                ),
                .tooltip = "Show the compiler-resolved comptime type",
                .command = "zig-analyzer.peekResolvedType",
                .arguments = arguments,
            },
        });
    }
    return try lenses.toOwnedSlice(arena);
}

pub fn prepareCallHierarchy(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/prepareCallHierarchy"),
) !lsp.ResultType("textDocument/prepareCallHierarchy") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const identifier = document.identifierAt(document.byteOffset(params.position)) orelse return null;
    const name = document.source[identifier.start..identifier.end];
    const location = functionNamed(services, name) orelse return null;
    const items = try arena.alloc(lsp.types.call_hierarchy.Item, 1);
    items[0] = callHierarchyItem(location.document, location.declaration);
    return items;
}

pub fn incomingCalls(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("callHierarchy/incomingCalls"),
) !lsp.ResultType("callHierarchy/incomingCalls") {
    var calls: std.ArrayList(lsp.types.call_hierarchy.IncomingCall) = .empty;
    var iterator = services.documents.documents.valueIterator();
    while (iterator.next()) |document| {
        const tokens = document.tokens;
        for (tokens, 0..) |token, index| {
            if (token.tag != .identifier or !std.mem.eql(u8, document.source[token.loc.start..token.loc.end], params.item.name) or
                index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren or
                index > 0 and (tokens[index - 1].tag == .keyword_fn or tokens[index - 1].tag == .period)) continue;
            const caller = cursor.functionContainingToken(document.declarations, tokens, index) orelse continue;
            const ranges = try arena.alloc(lsp.types.Range, 1);
            ranges[0] = document.range(token.loc);
            try calls.append(arena, .{
                .from = callHierarchyItem(document, caller),
                .fromRanges = ranges,
            });
        }
    }
    return try calls.toOwnedSlice(arena);
}

pub fn outgoingCalls(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("callHierarchy/outgoingCalls"),
) !lsp.ResultType("callHierarchy/outgoingCalls") {
    const document = services.documents.getConst(params.item.uri) orelse return null;
    const declaration = document.declarationNamed(params.item.name) orelse return null;
    if (declaration.kind != .function) return null;
    const tokens = document.tokens;
    const body = cursor.functionBodyTokenBounds(tokens, declaration) orelse return null;
    var calls: std.ArrayList(lsp.types.call_hierarchy.OutgoingCall) = .empty;
    for (tokens[body.opening + 1 .. body.closing], body.opening + 1..) |token, index| {
        if (token.tag != .identifier or index + 1 >= body.closing or tokens[index + 1].tag != .l_paren or
            index > 0 and tokens[index - 1].tag == .period) continue;
        const callee_name = document.source[token.loc.start..token.loc.end];
        const callee = functionNamed(services, callee_name) orelse continue;
        const ranges = try arena.alloc(lsp.types.Range, 1);
        ranges[0] = document.range(token.loc);
        try calls.append(arena, .{
            .to = callHierarchyItem(callee.document, callee.declaration),
            .fromRanges = ranges,
        });
    }
    return try calls.toOwnedSlice(arena);
}

/// One whole-document edit replacing the text with `zig fmt`'s output, or no
/// edit when it already matches.
pub fn formatting(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/formatting"),
) !lsp.ResultType("textDocument/formatting") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const formatted = try zig_fmt.format(services.io, arena, document.source);
    if (std.mem.eql(u8, formatted, document.source)) return &.{};
    const edits = try arena.alloc(lsp.types.TextEdit, 1);
    edits[0] = .{
        .range = document.range(.{ .start = 0, .end = document.source.len }),
        .newText = formatted,
    };
    return edits;
}

const FunctionLocation = struct {
    document: *const Document,
    declaration: Declaration,
};

/// The only function called `name` among the open documents.
fn functionNamed(services: Services, name: []const u8) ?FunctionLocation {
    var selected: ?FunctionLocation = null;
    var iterator = services.documents.documents.valueIterator();
    while (iterator.next()) |document| {
        const declaration = document.declarationNamed(name) orelse continue;
        if (declaration.kind != .function) continue;
        if (selected != null) return null;
        selected = .{ .document = document, .declaration = declaration };
    }
    return selected;
}

fn callHierarchyItem(document: *const Document, declaration: Declaration) lsp.types.call_hierarchy.Item {
    return .{
        .name = declaration.name,
        .kind = .Function,
        .detail = cursor.functionSignature(document.source, declaration.name),
        .uri = document.uri,
        .range = document.range(declaration.span),
        .selectionRange = document.range(declaration.span),
    };
}

fn symbolKind(kind: Declaration.Kind) lsp.types.SymbolKind {
    return switch (kind) {
        .constant => .Constant,
        .variable => .Variable,
        .function => .Function,
    };
}

fn semanticTokens(
    document: *const Document,
    allocator: std.mem.Allocator,
    requested_range: ?lsp.types.Range,
) ![]u32 {
    var encoded: std.ArrayList(u32) = .empty;
    errdefer encoded.deinit(allocator);
    var previous_line: u32 = 0;
    var previous_character: u32 = 0;
    var tokenizer = std.zig.Tokenizer.init(document.source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const token_class = annotations.tokenClass(document, token) orelse continue;
        const range = document.range(token.loc);
        if (range.start.line != range.end.line) continue;
        if (requested_range) |limit| {
            if (range.end.line < limit.start.line or range.start.line > limit.end.line) continue;
            if (range.end.line == limit.start.line and range.end.character < limit.start.character) continue;
            if (range.start.line == limit.end.line and range.start.character > limit.end.character) continue;
        }
        const delta_line = range.start.line - previous_line;
        const delta_character = if (delta_line == 0)
            range.start.character - previous_character
        else
            range.start.character;
        try encoded.appendSlice(allocator, &.{
            delta_line,
            delta_character,
            range.end.character - range.start.character,
            @backingInt(token_class),
            annotations.tokenModifiers(document, token),
        });
        previous_line = range.start.line;
        previous_character = range.start.character;
    }
    return try encoded.toOwnedSlice(allocator);
}

fn inlayHints(
    document: *const Document,
    allocator: std.mem.Allocator,
    requested_range: lsp.types.Range,
) ![]const lsp.types.InlayHint {
    const found = try annotations.hints(allocator, document);
    defer allocator.free(found);
    var converted: std.ArrayList(lsp.types.InlayHint) = .empty;
    errdefer converted.deinit(allocator);
    for (found) |hint| {
        const position = document.range(.{ .start = hint.offset, .end = hint.offset }).start;
        if (!positionInRange(position, requested_range)) continue;
        try converted.append(allocator, .{
            .position = position,
            .label = .{ .string = hint.label },
            .kind = switch (hint.kind) {
                .type => .Type,
                .parameter => .Parameter,
            },
            .paddingLeft = if (hint.kind == .type) true else null,
            .paddingRight = if (hint.kind == .parameter) true else null,
        });
    }
    return try converted.toOwnedSlice(allocator);
}

fn positionInRange(position: lsp.types.Position, range: lsp.types.Range) bool {
    if (position.line < range.start.line or position.line > range.end.line) return false;
    if (position.line == range.start.line and position.character < range.start.character) return false;
    if (position.line == range.end.line and position.character > range.end.character) return false;
    return true;
}

test "semantic tokens encode keywords declarations and numbers" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const answer = 42;\n",
    );
    defer document.deinit();
    const encoded = try semanticTokens(&document, std.testing.allocator, null);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u32, &.{
        0, 0, 5, 2, 0,
        0, 6, 6, 0, 7,
        0, 9, 2, 5, 0,
    }, encoded);
}

test "inlay hints outside the requested range are dropped" {
    var document = try Document.open(
        std.testing.allocator,
        "file:///fixture.zig",
        1,
        "const answer = 42;\nconst enabled = true;\n",
    );
    defer document.deinit();
    const hints = try inlayHints(&document, std.testing.allocator, .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 21 },
    });
    defer std.testing.allocator.free(hints);
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings(": bool", hints[0].label.string);
    try std.testing.expect(hints[0].paddingLeft.?);
}
