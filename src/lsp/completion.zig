//! Completion: format placeholders inside print strings, import paths inside
//! `@import("...")`, members after a dot, and declarations elsewhere.
const std = @import("std");

const lsp = @import("lsp");

const analysis = @import("../analysis.zig");
const describe = @import("../project/describe.zig");
const cursor = @import("../syntax/cursor.zig");
const document_module = @import("../syntax/document.zig");
const syntax_types = @import("../syntax/types.zig");
const uri_module = @import("../uri.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Declaration = document_module.Declaration;
const Services = services_module.Services;
const Item = lsp.types.completion.Item;

/// Most items returned when the compiler contributes workspace declarations.
const item_limit = 4096;

const format_placeholders = [_]struct { label: []const u8, detail: []const u8 }{
    .{ .label = "{s}", .detail = "string or byte slice" },
    .{ .label = "{d}", .detail = "decimal integer" },
    .{ .label = "{x}", .detail = "hexadecimal integer" },
    .{ .label = "{c}", .detail = "character" },
    .{ .label = "{any}", .detail = "default formatting" },
    .{ .label = "{!}", .detail = "error union" },
    .{ .label = "{?}", .detail = "optional" },
};

pub fn completion(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/completion"),
) !lsp.ResultType("textDocument/completion") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    var completions: std.ArrayList(Item) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const byte_offset = document.byteOffset(params.position);
    if (cursor.formatStringAt(document.source, byte_offset)) {
        for (format_placeholders) |placeholder| try completions.append(arena, .{
            .label = placeholder.label,
            .kind = .Snippet,
            .detail = placeholder.detail,
        });
        return .{ .completion_items = try completions.toOwnedSlice(arena) };
    }
    if (cursor.importStringPrefix(document.source, byte_offset)) |prefix| {
        return .{ .completion_items = try importPathCompletions(services, arena, document, prefix) };
    }
    if (syntax_types.memberReceiver(document.source, byte_offset)) |receiver| {
        const syntax_members = try syntaxMembers(services, arena, document, receiver);
        for (syntax_members) |member| {
            try seen.put(arena, member.name, {});
            try completions.append(arena, .{
                .label = member.name,
                .kind = memberKind(member),
                .detail = memberDetail(member),
            });
        }
        if (syntax_members.len != 0) {
            return .{ .completion_items = try completions.toOwnedSlice(arena) };
        }
        if (try services.compilerTypeMembers(arena, document, receiver)) |member_names| {
            for (member_names) |name| {
                if (!syntax_types.isIdentifier(name) or seen.contains(name)) continue;
                try seen.put(arena, name, {});
                try completions.append(arena, .{
                    .label = name,
                    .kind = .Field,
                    .detail = "compiler-resolved member",
                });
            }
        }
        return .{ .completion_items = try completions.toOwnedSlice(arena) };
    }
    for (document.declarations) |declaration| {
        if (seen.contains(declaration.name)) continue;
        try seen.put(arena, declaration.name, {});
        try completions.append(arena, .{
            .label = declaration.name,
            .kind = declarationKind(declaration.kind),
            .detail = declarationDetail(declaration.kind),
        });
    }
    for (try services.compilerDeclarations(arena, document)) |fully_qualified_name| {
        if (completions.items.len == item_limit) break;
        if (!isRelatedCompilerDeclaration(document, fully_qualified_name)) continue;
        const name = analysis.declarationBaseName(fully_qualified_name);
        if (!syntax_types.isIdentifier(name) or seen.contains(name)) continue;
        try seen.put(arena, name, {});
        try completions.append(arena, .{
            .label = name,
            .kind = .Variable,
            .detail = fully_qualified_name,
        });
    }
    return .{ .completion_items = try completions.toOwnedSlice(arena) };
}

/// The members `receiver` exposes: a module's, or the fields and declarations
/// of the struct it is declared as.
fn syntaxMembers(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    receiver: []const u8,
) ![]const syntax_types.Member {
    if (try describe.moduleView(services.resolver(), allocator, document, receiver)) |view| return view.members;
    const receiver_name = std.mem.findScalarLast(u8, receiver, '.') orelse 0;
    const name = if (receiver_name == 0) receiver else receiver[receiver_name + 1 ..];
    const type_name = syntax_types.declaredTypeName(document.source, document.tokens, name);
    return try syntax_types.structMembers(allocator, document.source, document.tokens, type_name orelse return &.{});
}

fn importPathCompletions(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    prefix: []const u8,
) ![]const Item {
    const document_path = try uri_module.toPath(allocator, document.uri);
    const candidates = try services.resolver().importCandidates(allocator, document_path orelse "", prefix);
    const items = try allocator.alloc(Item, candidates.len);
    for (candidates, items) |candidate, *item| item.* = switch (candidate.kind) {
        .module => .{ .label = candidate.name, .kind = .Module, .detail = "Zig module" },
        .directory => .{ .label = candidate.name, .kind = .Folder, .detail = "directory" },
        .file => .{ .label = candidate.name, .kind = .File, .detail = "Zig source file" },
    };
    return items;
}

/// A compiler declaration is worth offering when it mentions a top-level name
/// of this document (names too short or `std` would match everything).
fn isRelatedCompilerDeclaration(document: *const Document, fully_qualified_name: []const u8) bool {
    for (document.declarations) |declaration| {
        if (declaration.brace_depth != 0 or declaration.name.len < 3) continue;
        if (std.mem.eql(u8, declaration.name, "std")) continue;
        if (std.mem.find(u8, fully_qualified_name, declaration.name) != null) return true;
    }
    return false;
}

fn declarationDetail(kind: Declaration.Kind) []const u8 {
    return switch (kind) {
        .constant => "const",
        .variable => "var",
        .function => "fn",
    };
}

fn declarationKind(kind: Declaration.Kind) Item.Kind {
    return switch (kind) {
        .constant => .Constant,
        .variable => .Variable,
        .function => .Function,
    };
}

fn memberKind(member: syntax_types.Member) Item.Kind {
    return switch (member.kind) {
        .function => .Function,
        .method => .Method,
        .constant => .Constant,
        .variable => .Variable,
        .field => .Field,
    };
}

fn memberDetail(member: syntax_types.Member) []const u8 {
    return switch (member.kind) {
        .function => if (member.public) "pub fn" else "fn",
        .method => "fn",
        .constant => if (member.public) "pub const" else "const",
        .variable => if (member.public) "pub var" else "var",
        .field => "field",
    };
}
