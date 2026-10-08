//! Hover, type-at-position and the commands built on them. The syntax-side
//! descriptions come from `project/describe.zig`; this module orders them with
//! the compiler's facts and renders the result.
const std = @import("std");

const lsp = @import("lsp");

const analysis = @import("../analysis.zig");
const describe = @import("../project/describe.zig");
const declaration_summary = @import("../syntax/declaration_summary.zig");
const document_module = @import("../syntax/document.zig");
const language_reference = @import("../syntax/language_reference.zig");
const syntax_types = @import("../syntax/types.zig");
const hover_markdown = @import("hover_markdown.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Services = services_module.Services;
const Summary = declaration_summary.Summary;
const describeBinding = declaration_summary.describeBinding;
const describeTypedMemberNamed = declaration_summary.describeTypedMemberNamed;
const describeEnumTagNamed = declaration_summary.describeEnumTagNamed;

pub fn hover(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("textDocument/hover"),
) !lsp.ResultType("textDocument/hover") {
    const document = services.documents.getConst(params.textDocument.uri) orelse return null;
    const token = document.tokenAt(document.byteOffset(params.position)) orelse return null;
    const spelling = document.source[token.loc.start..token.loc.end];
    const content: hover_markdown.Content = if (try language_reference.describe(arena, spelling, token.tag)) |language| .{
        .declaration = language.syntax,
        .type_summary = language.type_summary orelse language.category,
        .documentation = language.summary,
        .reference = .{
            .label = "Zig language reference",
            .url = language.reference,
        },
    } else if (token.tag == .identifier)
        .ofSummary(try describeIdentifier(services, arena, document, token.loc) orelse return null)
    else
        return null;
    return .{
        .contents = .{ .markup_content = .{
            .kind = .markdown,
            .value = try hover_markdown.default_markdown_renderer.render(arena, content),
        } },
        .range = document.range(token.loc),
    };
}

/// The type of the token at `position` as the hover shows it.
pub fn typeAtPosition(
    services: Services,
    arena: std.mem.Allocator,
    document: *const Document,
    position: lsp.types.Position,
) !?[]const u8 {
    const byte_offset = document.byteOffset(position);
    const token = document.tokenAt(byte_offset) orelse return null;
    const spelling = document.source[token.loc.start..token.loc.end];

    if (try language_reference.describe(arena, spelling, token.tag)) |language| {
        return language.type_summary orelse language.category;
    }

    if (token.tag == .identifier) {
        if (try describeIdentifier(services, arena, document, token.loc)) |description| {
            if (description.type_summary) |summary| return summary;
            return description.declaration;
        }
        if (document.declarationNamed(spelling)) |declaration| {
            if (declaration_summary.isTypeDeclaration(document.source, declaration.span)) {
                return "type";
            }
        }
    }

    return declaration_summary.inferredLiteralType(spelling, token.tag);
}

pub fn executeCommand(
    services: Services,
    arena: std.mem.Allocator,
    params: lsp.ParamsType("workspace/executeCommand"),
) !lsp.ResultType("workspace/executeCommand") {
    if (std.mem.eql(u8, params.command, "zig-analyzer.peekResolvedType")) {
        const arguments = params.arguments orelse return error.InvalidParams;
        if (arguments.len != 2) return error.InvalidParams;
        const uri = switch (arguments[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const type_name = switch (arguments[1]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const document = services.documents.getConst(uri) orelse return error.InvalidParams;
        const shape = try services.resolvedShape(arena, document, type_name) orelse return null;
        return .{ .string = try renderResolvedShape(arena, type_name, shape) };
    }
    if (std.mem.eql(u8, params.command, "zig-analyzer.typeAtPosition")) {
        const arguments = params.arguments orelse return error.InvalidParams;
        if (arguments.len != 3) return error.InvalidParams;
        const uri = switch (arguments[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const document = services.documents.getConst(uri) orelse return error.InvalidParams;
        const position: lsp.types.Position = .{
            .line = try commandPositionComponent(arguments[1]),
            .character = try commandPositionComponent(arguments[2]),
        };
        const type_string = try typeAtPosition(services, arena, document, position) orelse return null;
        return .{ .string = type_string };
    }
    return error.InvalidParams;
}

fn commandPositionComponent(value: std.json.Value) error{InvalidParams}!u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidParams,
        else => error.InvalidParams,
    };
}

/// What to say about the identifier at `identifier_span`: the compiler's facts
/// first, then what syntax across files can prove.
pub fn describeIdentifier(
    services: Services,
    allocator: std.mem.Allocator,
    document: *const Document,
    identifier_span: std.zig.Token.Loc,
) !?Summary {
    const resolver = services.resolver();
    const name = document.source[identifier_span.start..identifier_span.end];
    if (try services.resolvedShape(allocator, document, name)) |shape| {
        if (try describe.importDeclaration(resolver, allocator, document, identifier_span, name)) |origin| {
            if (shape.fields.len == 0) return .{
                .declaration = origin.declaration,
                .type_summary = "compiler-resolved comptime type",
                .documentation = origin.documentation,
            };
            return .{
                .declaration = try allocator.print("{s}\n{s}", .{
                    origin.declaration,
                    try renderResolvedShape(allocator, name, shape),
                }),
                .type_summary = "compiler-resolved comptime type",
                .documentation = origin.documentation,
            };
        }
        return .{
            .declaration = try renderResolvedShape(allocator, name, shape),
            .type_summary = "compiler-resolved comptime type",
        };
    }
    if (try services.resolvedValue(allocator, document, name)) |resolved| {
        const type_summary = try allocator.print(
            "{s} = {s}",
            .{ resolved.type_name, resolved.value },
        );
        if (document.declarationNamed(name)) |declaration| {
            if (try describeBinding(allocator, document.source, declaration.span)) |binding| {
                var description = binding;
                description.type_summary = type_summary;
                return description;
            }
        }
        return .{ .declaration = name, .type_summary = type_summary };
    }
    if (try describe.standardLibraryMember(resolver, allocator, document, identifier_span.start, name)) |description| {
        return description;
    }
    if (try describe.memberChain(resolver, allocator, document, identifier_span, name)) |description| {
        return description;
    }
    if (syntax_types.memberReceiver(document.source, identifier_span.start)) |receiver| {
        if (try describe.moduleView(resolver, allocator, document, receiver)) |view| {
            for (view.members) |member| {
                if (!std.mem.eql(u8, member.name, name)) continue;
                return try describeBinding(allocator, view.file.source, member.span);
            }
        }
        const receiver_separator = std.mem.findScalarLast(u8, receiver, '.') orelse 0;
        const receiver_name = if (receiver_separator == 0) receiver else receiver[receiver_separator + 1 ..];
        const type_name = syntax_types.declaredTypeName(document.source, document.tokens, receiver_name);
        if (type_name) |resolved_type| {
            const members = try syntax_types.structMembers(allocator, document.source, document.tokens, resolved_type);
            for (members) |member| {
                if (!std.mem.eql(u8, member.name, name)) continue;
                return try describeBinding(allocator, document.source, member.span);
            }
        }
        if (try describe.inferredMember(resolver, allocator, document, identifier_span, name)) |description| {
            return description;
        }
        if (std.mem.eql(u8, name, "len")) {
            return .{ .declaration = "len: usize", .type_summary = "usize" };
        }
        if (try describeTypedMemberNamed(allocator, document.source, name)) |description| return description;
        if (try services.compilerTypeMembers(allocator, document, receiver)) |member_names| {
            for (member_names) |member_name| {
                if (!std.mem.eql(u8, member_name, name)) continue;
                if (document.declarationNamed(name)) |declaration| {
                    return try describeBinding(allocator, document.source, declaration.span);
                }
                return try describeTypedMemberNamed(allocator, document.source, name);
            }
            return null;
        }
    }
    if (try document.scopedIdentifierSpans(allocator, identifier_span.start)) |spans| {
        if (spans.len != 0) {
            if (try describeBinding(allocator, document.source, spans[0])) |binding| {
                var description = binding;
                if (description.type_summary == null) {
                    description.type_summary = try syntax_types.inferredBindingType(
                        allocator,
                        document.source,
                        document.tokens,
                        spans[0],
                    );
                }
                return description;
            }
        }
    }
    if (document.declarationNamed(name)) |declaration| {
        return try describeBinding(allocator, document.source, declaration.span);
    }
    if (try describeTypedMemberNamed(allocator, document.source, name)) |description| return description;
    return try describeEnumTagNamed(allocator, document.source, name);
}

pub fn resolvedShapeKindName(kind: analysis.ResolvedShape.Kind) []const u8 {
    return switch (kind) {
        .enumeration => "enum",
        .tagged_union => "tagged union",
        .structure => "struct",
    };
}

pub fn renderResolvedShape(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    shape: analysis.ResolvedShape,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("const {s} = {s} {{\n", .{
        type_name,
        switch (shape.kind) {
            .enumeration => "enum",
            .tagged_union => "union(enum)",
            .structure => "struct",
        },
    });
    for (shape.fields) |field| {
        switch (shape.kind) {
            .enumeration => try writer.writer.print("    {s},\n", .{field}),
            .tagged_union, .structure => try writer.writer.print("    {s}: <compiler-resolved>,\n", .{field}),
        }
    }
    try writer.writer.writeAll("};");
    return try writer.toOwnedSlice();
}
