//! What request handlers read from the server: the open documents, the
//! compiler worker's cached facts, the linter and the module resolver. Feature
//! modules take this instead of the whole `Server`, so they cannot reach its
//! lifecycle state.
const std = @import("std");

const analysis = @import("../analysis.zig");
const compiler_session = @import("../compiler/session.zig");
const module_sites = @import("../project/module_sites.zig");
const document_module = @import("../syntax/document.zig");
const syntax_types = @import("../syntax/types.zig");
const compiler_backend = @import("compiler_backend.zig");
const diagnostics = @import("diagnostics.zig");

const Document = document_module.Document;

pub const Services = struct {
    io: std.Io,
    documents: *const document_module.Store,
    backend: *compiler_backend.CompilerBackend,
    linter: diagnostics.Linter,
    dependencies: *diagnostics.Dependencies,

    pub fn resolver(services: Services) module_sites.Resolver {
        return .{ .io = services.io };
    }

    /// Every rule finding for `document` under `lint_configuration`, using the
    /// compiler facts already known for it.
    pub fn documentFindings(
        services: Services,
        allocator: std.mem.Allocator,
        document: *const Document,
        lint_configuration: analysis.Configuration,
    ) ![]analysis.Finding {
        const shapes = try services.backend.knownShapes(allocator, document.uri);
        return services.linter.findings(allocator, services.documents, document, lint_configuration, shapes, services.dependencies);
    }

    pub fn compilerDeclarations(
        services: Services,
        allocator: std.mem.Allocator,
        document: *const Document,
    ) ![]const []const u8 {
        return services.backend.declarations(allocator, document.uri, document.version);
    }

    /// The member names the compiler resolved for the type `receiver` (a
    /// dotted path whose last segment names a type or a value of one) has.
    pub fn compilerTypeMembers(
        services: Services,
        allocator: std.mem.Allocator,
        document: *const Document,
        receiver: []const u8,
    ) !?[]const []const u8 {
        const type_name = declaredReceiverType(document, receiver);
        return services.backend.typeMembers(allocator, document.uri, document.version, type_name);
    }

    pub fn resolvedShape(
        services: Services,
        allocator: std.mem.Allocator,
        document: *const Document,
        type_name: []const u8,
    ) !?analysis.ResolvedShape {
        return services.backend.resolveShape(allocator, document.uri, document.version, type_name);
    }

    pub fn resolvedValue(
        services: Services,
        allocator: std.mem.Allocator,
        document: *const Document,
        name: []const u8,
    ) !?compiler_session.ResolvedValue {
        return services.backend.resolveValue(allocator, document.uri, document.version, name);
    }
};

/// The type a member-access receiver such as `a.b.value` stands for: the
/// declared type of its last segment, else the segment itself.
pub fn declaredReceiverType(document: *const Document, receiver: []const u8) []const u8 {
    const separator = std.mem.findScalarLast(u8, receiver, '.') orelse 0;
    const receiver_name = if (separator == 0) receiver else receiver[separator + 1 ..];
    return syntax_types.declaredTypeName(document.source, document.tokens, receiver_name) orelse receiver_name;
}
