//! The wire protocol between the analyzer and its patched Zig compiler. This
//! file is the single source of truth: backend bootstrap installs it verbatim
//! into the compiler checkout as `src/AnalysisProtocol.zig`, so it must stay
//! free of analyzer-only imports.
const std = @import("std");

/// Bump whenever a struct layout, tag value, or message order changes.
pub const version: u16 = 7;

/// The backend prints this prefix followed by the bound TCP port and a newline
/// on stderr once its listener is ready. The analyzer requests port 0 and
/// reads the port from this line.
pub const port_announcement = "zig-analyzer-protocol-port ";

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

/// `resolve_symbol` asks, for a batch of queries against one document, which
/// declaration each names. The body is a `ResolveSymbolsRequest`, the
/// document URI, then `query_count` queries. A query is a `QueryHeader`
/// followed by `step_count` steps (a `Step` and `name_length` name bytes
/// each): zero or more `scope` steps naming the containers that enclose the
/// occurrence (outermost first, each declared in the one before; the file's
/// root container is implicit), then `name`, `call` and `index` steps
/// evaluating the receiver of a member access, then one `target` step with the
/// member name to resolve. The response is a `SymbolsResponse` followed by one
/// `SymbolResult` (and its file name bytes) per query.
pub const ResolveSymbolsRequest = extern struct {
    uri_length: u32,
    query_count: u32,
};

pub const QueryHeader = extern struct {
    flags: u16,
    step_count: u16,
};

/// `QueryHeader.flags`: the target is looked up only among the members of the
/// innermost `scope` container (the occurrence declares it) instead of by
/// lexical lookup through the enclosing containers.
pub const query_declaration_site: u16 = 1;

pub const StepKind = enum(u8) {
    /// A container, declared by name in the previous one, that encloses the
    /// occurrence.
    scope,
    /// A name looked up lexically (first step) or as a member of the value or
    /// type the previous steps produced.
    name,
    /// Calls the function the previous steps produced.
    call,
    /// Indexes the array, slice, or pointer the previous steps produced.
    index,
    /// The member to resolve; always the last step.
    target,
    _,
};

pub const Step = extern struct {
    kind: StepKind,
    reserved: u8 = 0,
    name_length: u16,
};

pub const SymbolsResponse = extern struct {
    result_count: u32,
};

pub const SymbolStatus = enum(u16) {
    /// The query names the declaration in the result.
    resolved,
    /// The compiler could not evaluate the receiver (a local it cannot type,
    /// an unsupported expression, an analysis error).
    unresolved,
    /// The receiver resolved to a container that has no such member.
    absent,
    /// The receiver depends on a generic instantiation.
    generic,
    _,
};

pub const SymbolKind = enum(u16) {
    none,
    /// A `const`, `var`, or `fn` declaration of a container.
    declaration,
    /// A struct, union, or enum field.
    field,
    _,
};

/// The name token of the declaration found, in the file named by the
/// `file_length` bytes that follow.
pub const SymbolResult = extern struct {
    status: SymbolStatus,
    kind: SymbolKind,
    start: u32,
    end: u32,
    file_length: u32,
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
    std.debug.assert(@sizeOf(ResolveSymbolsRequest) == 8);
    std.debug.assert(@sizeOf(QueryHeader) == 4);
    std.debug.assert(@sizeOf(Step) == 4);
    std.debug.assert(@sizeOf(SymbolsResponse) == 4);
    std.debug.assert(@sizeOf(SymbolResult) == 16);
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
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SymbolResult));
}

test "unknown protocol tags remain representable" {
    const unknown: Tag = @fromBackingInt(@intCast(65535));
    try std.testing.expectEqual(@as(u16, 65535), @backingInt(unknown));
}
