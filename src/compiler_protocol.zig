const std = @import("std");

pub const current_version: u16 = @import("build_options").compiler_protocol_version;

pub const Header = extern struct {
    body_length: u32,
    request_id: u32,
    generation: u32,
    tag: Tag,
    reserved: u16 = 0,
};

pub const Tag = enum(u16) {
    hello,
    hello_response,
    register_compile_unit,
    replace_overlay,
    remove_overlay,
    analyze,
    diagnostics,
    document_facts,
    resolve_symbol,
    type_members,
    workspace_declarations,
    cancel,
    shutdown,
    response_error,
    workspace_declaration_names,
    type_shape,
    resolved_value,
    _,
};

pub const Hello = extern struct {
    protocol_version: u16,
    zig_version_length: u16,
    authentication_token_length: u16,
    reserved: u16 = 0,
};

pub const HelloResponse = extern struct {
    protocol_version: u16,
    status: HandshakeStatus,
    zig_version_length: u16,
    reserved: u16 = 0,
};

pub const HandshakeStatus = enum(u16) {
    accepted,
    incompatible_protocol,
    incompatible_zig,
    authentication_failed,
    _,
};

pub const WorkspaceSummary = extern struct {
    type_count: u32,
    declaration_count: u32,
    analysis_unit_count: u32,
    last_generation: u32,
};

pub const ReplaceOverlayRequest = extern struct {
    uri_length: u32,
    source_length: u32,
    document_version: i32,
    reserved: u32 = 0,
};

pub const AnalyzeRequest = extern struct {
    uri_length: u32,
    expected_document_version: i32,
};

pub const RemoveOverlayRequest = extern struct {
    uri_length: u32,
};

pub const TypeMembersRequest = extern struct {
    name_length: u32,
};

pub const TypeShape = extern struct {
    kind: TypeShapeKind,
    reserved: u16 = 0,
    field_count: u32,
    names_length: u32,
};

pub const ResolvedValue = extern struct {
    type_length: u32,
    value_length: u32,
};

pub const TypeShapeKind = enum(u16) {
    enumeration,
    tagged_union,
    structure,
    _,
};

pub const DocumentFacts = extern struct {
    document_version: i32,
    declaration_count: u32,
    syntax_error_count: u32,
    reserved: u32 = 0,
    source_hash: u64,
};

pub const ErrorResponse = extern struct {
    code: ErrorCode,
    reserved: u16 = 0,
    observed_generation: u32,
    message_length: u32,
};

pub const DeclarationList = extern struct {
    declaration_count: u32,
    names_length: u32,
};

pub const DiagnosticBundle = extern struct {
    extra_length: u32,
    string_bytes_length: u32,
};

pub const SourceSpan = extern struct {
    start: u32,
    end: u32,
};

pub const ErrorCode = enum(u16) {
    incompatible_protocol,
    incompatible_zig,
    authentication_failed,
    stale_generation,
    unknown_compile_unit,
    unavailable,
    malformed_request,
    internal_failure,
    _,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 16);
    std.debug.assert(@sizeOf(Hello) == 8);
    std.debug.assert(@sizeOf(HelloResponse) == 8);
    std.debug.assert(@sizeOf(SourceSpan) == 8);
    std.debug.assert(@sizeOf(WorkspaceSummary) == 16);
    std.debug.assert(@sizeOf(ReplaceOverlayRequest) == 16);
    std.debug.assert(@sizeOf(AnalyzeRequest) == 8);
    std.debug.assert(@sizeOf(RemoveOverlayRequest) == 4);
    std.debug.assert(@sizeOf(TypeMembersRequest) == 4);
    std.debug.assert(@sizeOf(TypeShape) == 12);
    std.debug.assert(@sizeOf(ResolvedValue) == 8);
    std.debug.assert(@sizeOf(DocumentFacts) == 24);
    std.debug.assert(@sizeOf(ErrorResponse) == 12);
    std.debug.assert(@sizeOf(DeclarationList) == 8);
    std.debug.assert(@sizeOf(DiagnosticBundle) == 8);
}

test "protocol structures have stable wire sizes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Hello));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(HelloResponse));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SourceSpan));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(WorkspaceSummary));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DocumentFacts));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(ErrorResponse));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DeclarationList));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(DiagnosticBundle));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TypeShape));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ResolvedValue));
}

test "unknown protocol tags remain representable" {
    const unknown: Tag = @enumFromInt(65535);
    try std.testing.expectEqual(@as(u16, 65535), @intFromEnum(unknown));
}
