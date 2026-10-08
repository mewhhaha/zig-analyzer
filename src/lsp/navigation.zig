//! Go to definition, type definition and references. Which declaration a name
//! resolves to is decided by `project/module_sites.zig` and
//! `syntax/types.zig`; this module orders the strategies and converts the
//! answers to locations.
const std = @import("std");

const lsp = @import("lsp");

const describe = @import("../project/describe.zig");
const module_sites = @import("../project/module_sites.zig");
const cursor = @import("../syntax/cursor.zig");
const declaration_summary = @import("../syntax/declaration_summary.zig");
const document_module = @import("../syntax/document.zig");
const syntax_types = @import("../syntax/types.zig");
const uri_module = @import("../uri.zig");
const hover_module = @import("hover.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Declaration = document_module.Declaration;
const Services = services_module.Services;

pub fn definition(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/definition"),
) !lsp.ResultType("textDocument/definition") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const byte_offset = document.byteOffset(params.position);
    if (try importedFileDefinition(services, arena, document, byte_offset)) |location| {
        return .{ .definition = .{ .location = location } };
    }
    const identifier_span = document.identifierAt(byte_offset) orelse return null;
    const identifier = document.source[identifier_span.start..identifier_span.end];
    if (identifier_span.start > 0 and document.source[identifier_span.start - 1] == '.') {
        if (try importExpressionMemberDefinition(services, arena, document, identifier_span)) |location| {
            return .{ .definition = .{ .location = location } };
        }
    }
    if (syntax_types.memberReceiver(document.source, identifier_span.start)) |receiver| {
        if (try importedMemberDefinition(services, arena, document, receiver, identifier)) |location| {
            return .{ .definition = .{ .location = location } };
        }
        if (try services.compilerTypeMembers(arena, document, receiver)) |member_names| {
            const resolved = for (member_names) |name| {
                if (std.mem.eql(u8, name, identifier)) break true;
            } else false;
            if (resolved) {
                const separator = std.mem.findScalarLast(u8, receiver, '.') orelse 0;
                const receiver_name = if (separator == 0) receiver else receiver[separator + 1 ..];
                const type_name = syntax_types.declaredTypeName(document.source, document.tokens, receiver_name) orelse receiver_name;
                if (document.declarationNamed(type_name)) |declaration| {
                    return .{ .definition = .{ .location = declarationLocation(document, declaration) } };
                }
            }
        }
    }
    if (try aliasTargetDefinition(services, arena, document, identifier_span)) |location| {
        return .{ .definition = .{ .location = location } };
    }
    if (try importAliasDefinition(services, arena, document, identifier)) |location| {
        return .{ .definition = .{ .location = location } };
    }
    const declaration = document.declarationNamed(identifier) orelse return null;
    return .{ .definition = .{ .location = declarationLocation(document, declaration) } };
}

pub fn typeDefinition(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/typeDefinition"),
) !lsp.ResultType("textDocument/typeDefinition") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const byte_offset = document.byteOffset(params.position);
    const token = document.tokenAt(byte_offset) orelse return null;
    if (token.tag != .identifier) return null;
    const name = document.source[token.loc.start..token.loc.end];

    if (document.declarationNamed(name)) |declaration| {
        if (declaration_summary.isTypeDeclaration(document.source, declaration.span)) {
            return .{ .definition = .{ .location = declarationLocation(document, declaration) } };
        }
    }

    if (syntax_types.declaredTypeName(document.source, document.tokens, name)) |type_name| {
        if (try findTypeDefinition(services, arena, document, type_name)) |location| {
            return .{ .definition = .{ .location = location } };
        }
    }

    if (syntax_types.memberReceiver(document.source, token.loc.start)) |receiver| {
        const separator = std.mem.findScalarLast(u8, receiver, '.') orelse 0;
        const receiver_name = if (separator == 0) receiver else receiver[separator + 1 ..];
        const receiver_type = syntax_types.declaredTypeName(document.source, document.tokens, receiver_name) orelse receiver_name;
        const members = try syntax_types.structMembers(arena, document.source, document.tokens, receiver_type);
        for (members) |member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            if (syntax_types.declaredTypeName(document.source, document.tokens, name)) |member_type| {
                if (try findTypeDefinition(services, arena, document, member_type)) |location| {
                    return .{ .definition = .{ .location = location } };
                }
            }
        }
    }

    if (try hover_module.describeIdentifier(services, arena, document, token.loc)) |description| {
        if (description.type_summary) |summary| {
            const type_name = declaration_summary.extractTypeNameFromSummary(summary);
            if (type_name.len > 0) {
                if (try findTypeDefinition(services, arena, document, type_name)) |location| {
                    return .{ .definition = .{ .location = location } };
                }
            }
        }
    }

    return null;
}

pub fn references(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/references"),
) !lsp.ResultType("textDocument/references") {
    const origin = services.documents.getConst(params.textDocument.uri) orelse return null;
    const identifier_span = origin.identifierAt(origin.byteOffset(params.position)) orelse return null;
    const name = origin.source[identifier_span.start..identifier_span.end];
    if (try origin.scopedIdentifierSpans(arena, identifier_span.start)) |spans| {
        const locations = try arena.alloc(lsp.types.Location, spans.len);
        var location_count: usize = 0;
        for (spans) |span| {
            if (!params.context.includeDeclaration and std.meta.eql(span, spans[0])) continue;
            locations[location_count] = .{ .uri = origin.uri, .range = origin.range(span) };
            location_count += 1;
        }
        return locations[0..location_count];
    }
    var locations: std.ArrayList(lsp.types.Location) = .empty;
    var iterator = services.documents.documents.valueIterator();
    while (iterator.next()) |document| {
        const spans = try document.identifierSpans(arena, name);
        for (spans) |span| {
            if (!params.context.includeDeclaration) {
                if (document.declarationNamed(name)) |declaration| {
                    if (std.meta.eql(span, declaration.span)) continue;
                }
            }
            try locations.append(arena, .{ .uri = document.uri, .range = document.range(span) });
        }
    }
    return try locations.toOwnedSlice(arena);
}

fn declarationLocation(document: *const Document, declaration: Declaration) lsp.types.Location {
    return .{ .uri = document.uri, .range = document.range(declaration.span) };
}

fn targetLocation(allocator: std.mem.Allocator, target: module_sites.Target) !lsp.types.Location {
    return .{
        .uri = try uri_module.fromPath(allocator, target.file.path),
        .range = lsp.offsets.locToRange(target.file.source, target.span, .@"utf-16"),
    };
}

fn findTypeDefinition(
    services: Services,
    arena: std.mem.Allocator,
    document: *const Document,
    type_name: []const u8,
) !?lsp.types.Location {
    if (document.declarationNamed(type_name)) |declaration| return declarationLocation(document, declaration);
    return importAliasDefinition(services, arena, document, type_name);
}

/// The member `name` of the module or container `receiver` names.
fn importedMemberDefinition(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    receiver: []const u8,
    name: []const u8,
) !?lsp.types.Location {
    const view = try describe.moduleView(services.resolver(), allocator, document, receiver) orelse return null;
    for (view.members) |member| {
        if (!std.mem.eql(u8, member.name, name)) continue;
        return try targetLocation(allocator, .{ .file = view.file, .span = member.span });
    }
    return null;
}

/// On the path of an `@import("...")`: the start of the imported file.
fn importedFileDefinition(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    byte_offset: usize,
) !?lsp.types.Location {
    const import_path = try cursor.importPathAt(allocator, document.source, byte_offset) orelse return null;
    return importStartLocation(services, allocator, document, import_path);
}

/// On an import alias: the start of the file it imports.
fn importAliasDefinition(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    alias: []const u8,
) !?lsp.types.Location {
    const import_path = syntax_types.importName(document.source, document.tokens, alias) orelse return null;
    return importStartLocation(services, allocator, document, import_path);
}

fn importStartLocation(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    import_path: []const u8,
) !?lsp.types.Location {
    const document_path = try uri_module.toPath(allocator, document.uri) orelse return null;
    const target = try services.resolver().importedFileStart(allocator, document_path, import_path) orelse return null;
    return try targetLocation(allocator, target);
}

/// On a use of a local `const alias = other.Thing;`: the declaration the alias
/// finally names.
fn aliasTargetDefinition(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    identifier_span: std.zig.Token.Loc,
) !?lsp.types.Location {
    const binding_spans = try document.scopedIdentifierSpans(allocator, identifier_span.start) orelse return null;
    if (binding_spans.len == 0 or std.meta.eql(binding_spans[0], identifier_span)) return null;
    const binding_index = for (document.tokens, 0..) |token, index| {
        if (std.meta.eql(token.loc, binding_spans[0])) break index;
    } else return null;
    const origin = try module_sites.File.ofDocument(allocator, document) orelse return null;
    const target = try services.resolver().constantAliasTarget(allocator, origin, binding_index) orelse return null;
    return try targetLocation(allocator, target);
}

/// On `member` of `@import("file.zig").a.member`: its declaration.
fn importExpressionMemberDefinition(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    identifier_span: std.zig.Token.Loc,
) !?lsp.types.Location {
    const origin = try module_sites.File.ofDocument(allocator, document) orelse return null;
    defer allocator.free(origin.path);
    const target = try services.resolver().importExpressionMember(allocator, origin, identifier_span) orelse return null;
    return try targetLocation(allocator, target);
}
