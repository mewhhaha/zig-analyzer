//! Describes declarations by following syntax across files: members of
//! imported modules, standard library members, and members reached through
//! constructed types or value chains. The compiler's facts are not consulted
//! here; callers layer them on top.
const std = @import("std");

const declaration_summary = @import("../syntax/declaration_summary.zig");
const document_module = @import("../syntax/document.zig");
const syntax_types = @import("../syntax/types.zig");
const module_sites = @import("module_sites.zig");

const Document = document_module.Document;
const Summary = declaration_summary.Summary;
const describeBinding = declaration_summary.describeBinding;
const Resolver = module_sites.Resolver;

/// The members `receiver` exposes to `document` (see `module_sites`).
pub fn moduleView(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    receiver: []const u8,
) !?module_sites.ModuleView {
    const origin = try module_sites.File.ofDocument(allocator, document) orelse return null;
    return resolver.moduleView(allocator, origin, receiver);
}

/// The container a qualified type expression names, starting from one of
/// `document`'s import aliases.
pub fn importedTypeSite(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    type_expression: []const u8,
) !?module_sites.Site {
    const origin = try module_sites.File.ofDocument(allocator, document) orelse return null;
    return resolver.importedTypeSite(allocator, origin, type_expression);
}

/// The member `member_name` of the value left of the dot, whose type is
/// inferred from how its binding is initialized.
pub fn inferredMember(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    member_span: std.zig.Token.Loc,
    member_name: []const u8,
) !?Summary {
    const receiver_span = syntax_types.receiverIdentifierSpan(document.source, member_span.start) orelse return null;
    const receiver_bindings = try document.scopedIdentifierSpans(allocator, receiver_span.start) orelse return null;
    if (receiver_bindings.len == 0) return null;
    const inferred_type = try bindingTypeExpression(allocator, document, receiver_bindings[0]) orelse return null;
    if (try importedTypeMember(resolver, allocator, document, inferred_type, member_name)) |description| {
        return description;
    }
    const type_name = syntax_types.namedTypeExpression(inferred_type) orelse return null;
    if (std.mem.findScalar(u8, type_name, '.')) |separator| {
        const import_alias = type_name[0..separator];
        if (try moduleView(resolver, allocator, document, import_alias)) |view| {
            const field_span = syntax_types.memberSpan(
                view.file.source,
                view.file.tokens,
                type_name[separator + 1 ..],
                member_name,
            ) orelse return null;
            return try describeBinding(allocator, view.file.source, field_span);
        }
    }
    const field_span = syntax_types.memberSpan(
        document.source,
        document.tokens,
        type_name,
        member_name,
    ) orelse return null;
    return try describeBinding(allocator, document.source, field_span);
}

/// The standard library declaration named in `@import("std").a.b.name`.
pub fn standardLibraryMember(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    identifier_start: usize,
    name: []const u8,
) !?Summary {
    const import_prefix = "@import(\"std\").";
    const prefix_start = std.mem.findLast(u8, document.source[0..identifier_start], import_prefix) orelse return null;
    const module_expression = document.source[prefix_start + import_prefix.len .. identifier_start];
    if (module_expression.len != 0 and module_expression[module_expression.len - 1] != '.') return null;
    const module_name = if (module_expression.len == 0) "" else module_expression[0 .. module_expression.len - 1];
    if (module_name.len != 0 and !syntax_types.isDottedIdentifier(module_name)) return null;
    const path = try resolver.standardLibraryPath(allocator, module_name) orelse return null;
    const file = try resolver.readFile(allocator, path) orelse return null;
    const members = try syntax_types.publicMembers(allocator, file.source, file.tokens);
    for (members) |member| {
        if (!std.mem.eql(u8, member.name, name)) continue;
        return try describeBinding(allocator, file.source, member.span);
    }
    return null;
}

/// The `@import` declaration `name` refers to, in this file or in the module its
/// receiver names.
pub fn importDeclaration(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    identifier_span: std.zig.Token.Loc,
    name: []const u8,
) !?Summary {
    if (document.declarationNamed(name)) |declaration| {
        if (try describeBinding(allocator, document.source, declaration.span)) |description| {
            if (std.mem.find(u8, description.declaration, "@import") != null) return description;
        }
    }
    const receiver = syntax_types.memberReceiver(document.source, identifier_span.start) orelse return null;
    const view = try moduleView(resolver, allocator, document, receiver) orelse return null;
    for (view.members) |member| {
        if (!std.mem.eql(u8, member.name, name)) continue;
        const description = try describeBinding(allocator, view.file.source, member.span) orelse return null;
        if (std.mem.find(u8, description.declaration, "@import") == null) return null;
        return description;
    }
    return null;
}

/// The member of the container a qualified type expression names.
pub fn importedTypeMember(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    type_expression: []const u8,
    member_name: []const u8,
) !?Summary {
    const site = try importedTypeSite(resolver, allocator, document, type_expression) orelse return null;
    return try siteMemberDescription(allocator, site, member_name);
}

/// The member after a receiver that is a constructed type or a call chain such as
/// `arena.allocator().dupe`.
pub fn memberChain(
    resolver: Resolver,
    allocator: std.mem.Allocator,
    document: *const Document,
    member_span: std.zig.Token.Loc,
    member_name: []const u8,
) !?Summary {
    const receiver = syntax_types.qualifiedCallReceiver(document.source, member_span.start) orelse return null;
    const links = try syntax_types.dottedPathSegments(allocator, receiver.expression) orelse return null;
    if (links.len == 0) return null;
    if (syntax_types.importName(document.source, document.tokens, links[0]) != null) {
        // The receiver spells a constructed type, as in `std.ArrayList(u8).empty`.
        return try importedTypeMember(resolver, allocator, document, receiver.expression, member_name);
    }
    // The receiver is a value chain, as in `arena.allocator().dupe`; follow
    // each link's declared result type to the container that owns the member.
    const bindings = try document.scopedIdentifierSpans(allocator, receiver.start) orelse return null;
    if (bindings.len == 0) return null;
    const base_type = try bindingTypeExpression(allocator, document, bindings[0]) orelse return null;
    var site = try importedTypeSite(resolver, allocator, document, base_type) orelse return null;
    for (links[1..]) |link| {
        const declaration = syntax_types.containerDeclarationNamed(site.file.source, site.file.tokens, site.container, link) orelse return null;
        const result_type = switch (declaration.kind) {
            .function => syntax_types.successTypeAt(site.file.source, site.file.tokens, declaration.name_index),
            .field, .constant => typed: {
                const binding = try describeBinding(
                    allocator,
                    site.file.source,
                    site.file.tokens[declaration.name_index].loc,
                ) orelse break :typed null;
                break :typed binding.type_summary;
            },
        } orelse return null;
        site = try resolver.siteWithin(allocator, site.file, result_type) orelse return null;
    }
    return try siteMemberDescription(allocator, site, member_name);
}

/// The type expression of the binding at `binding_span`, inferred or declared.
pub fn bindingTypeExpression(
    allocator: std.mem.Allocator,
    document: *const Document,
    binding_span: std.zig.Token.Loc,
) !?[]const u8 {
    if (try syntax_types.inferredBindingType(allocator, document.source, document.tokens, binding_span)) |inferred| return inferred;
    if (try syntax_types.initializerTypeExpression(allocator, document.source, document.tokens, binding_span)) |constructed| return constructed;
    const binding = try describeBinding(allocator, document.source, binding_span) orelse return null;
    return binding.type_summary;
}

fn siteMemberDescription(
    allocator: std.mem.Allocator,
    site: module_sites.Site,
    member_name: []const u8,
) !?Summary {
    const declaration = syntax_types.containerDeclarationNamed(
        site.file.source,
        site.file.tokens,
        site.container,
        member_name,
    ) orelse return null;
    return try describeBinding(allocator, site.file.source, site.file.tokens[declaration.name_index].loc);
}
