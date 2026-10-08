const std = @import("std");
const build_options = @import("build_options");
const symbol_query = @import("../syntax/symbol_query.zig");
const protocol = @import("protocol.zig");

/// How long the analyzer waits on the compiler backend before declaring it
/// hung: responses to protocol requests, and process exit during shutdown.
pub const default_response_deadline_ms: i64 = 60_000;

/// A backend hello reply carries a Zig version string such as
/// "0.17.0+zig-analyzer.1"; anything near the reader buffer size is garbage.
const max_zig_version_length = 256;

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    read_buffer: []u8,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    next_request_id: u32 = 1,
    generation: u32 = 0,
    response_deadline_ms: i64 = default_response_deadline_ms,

    pub fn connect(io: std.Io, allocator: std.mem.Allocator, port: u16) !Client {
        const address: std.Io.net.IpAddress = .{ .ip6 = .loopback(port) };
        const stream = try address.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);
        const read_buffer = try allocator.alloc(u8, 4096);
        return .{
            .io = io,
            .allocator = allocator,
            .read_buffer = read_buffer,
            .stream = stream,
            .reader = stream.reader(io, read_buffer),
            .writer = stream.writer(io, &.{}),
        };
    }

    pub fn deinit(client: *Client) void {
        client.stream.close(client.io);
        client.allocator.free(client.read_buffer);
        client.* = undefined;
    }

    pub fn handshake(client: *Client, authentication_token: []const u8) !void {
        try client.probeHandshake(
            build_options.zig_version,
            protocol.version,
            authentication_token,
        );
    }

    /// Sends a hello with arbitrary versions. Production code uses
    /// `handshake`; tests use this to prove the backend rejects mismatches.
    pub fn probeHandshake(
        client: *Client,
        zig_version: []const u8,
        protocol_version: u16,
        authentication_token: []const u8,
    ) !void {
        if (zig_version.len > std.math.maxInt(u16)) return error.ZigVersionTooLong;
        if (authentication_token.len > std.math.maxInt(u16)) return error.AuthenticationTokenTooLong;
        const hello: protocol.Hello = .{
            .protocol_version = protocol_version,
            .zig_version_length = @intCast(zig_version.len),
            .authentication_token_length = @intCast(authentication_token.len),
        };
        const result = try client.roundTrip(.hello, hello, &.{ zig_version, authentication_token }, .hello_response, HelloReader{});
        switch (result.status) {
            .accepted => {},
            .incompatible_protocol => return error.IncompatibleProtocol,
            .incompatible_zig => return error.IncompatibleZig,
            .authentication_failed => return error.AuthenticationFailed,
            _ => return error.UnknownHandshakeStatus,
        }
        if (!result.zig_version_matches) return error.IncompatibleZig;
    }

    pub fn workspaceSummary(client: *Client) !protocol.WorkspaceSummary {
        return client.roundTrip(.workspace_declarations, {}, &.{}, .workspace_declarations, readSummary);
    }

    pub fn replaceOverlay(
        client: *Client,
        uri: []const u8,
        document_version: i32,
        source: []const u8,
    ) !protocol.DocumentFacts {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        if (source.len > std.math.maxInt(u32)) return error.SourceTooLong;
        const request: protocol.ReplaceOverlayRequest = .{
            .uri_length = @intCast(uri.len),
            .source_length = @intCast(source.len),
            .document_version = document_version,
        };
        return client.roundTrip(.replace_overlay, request, &.{ uri, source }, .document_facts, readDocumentFacts);
    }

    pub fn analyzeOverlay(client: *Client, uri: []const u8, document_version: i32) !protocol.DocumentFacts {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        const request: protocol.AnalyzeRequest = .{
            .uri_length = @intCast(uri.len),
            .expected_document_version = document_version,
        };
        return client.roundTrip(.analyze, request, &.{uri}, .document_facts, readDocumentFacts);
    }

    pub fn removeOverlay(client: *Client, uri: []const u8) !void {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        const request: protocol.RemoveOverlayRequest = .{ .uri_length = @intCast(uri.len) };
        return client.roundTrip(.remove_overlay, request, &.{uri}, .remove_overlay, readRemoveAck);
    }

    /// Qualified names of every analyzed declaration. The caller owns the
    /// slice and each name.
    pub fn workspaceDeclarations(client: *Client, allocator: std.mem.Allocator) ![]const []const u8 {
        return client.roundTrip(.workspace_declaration_names, {}, &.{}, .workspace_declaration_names, NameListReader{ .allocator = allocator });
    }

    pub fn diagnostics(client: *Client, allocator: std.mem.Allocator) !std.zig.ErrorBundle {
        return client.roundTrip(.diagnostics, {}, &.{}, .diagnostics, ErrorBundleReader{ .allocator = allocator });
    }

    pub fn typeMembers(client: *Client, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        const request = try nameRequest(name);
        return client.roundTrip(.type_members, request, &.{name}, .type_members, NameListReader{ .allocator = allocator });
    }

    pub fn typeShape(client: *Client, allocator: std.mem.Allocator, name: []const u8) !TypeShape {
        const request = try nameRequest(name);
        return client.roundTrip(.type_shape, request, &.{name}, .type_shape, TypeShapeReader{ .allocator = allocator });
    }

    pub fn resolvedValue(client: *Client, allocator: std.mem.Allocator, name: []const u8) !ResolvedValue {
        const request = try nameRequest(name);
        return client.roundTrip(.resolved_value, request, &.{name}, .resolved_value, ResolvedValueReader{ .allocator = allocator });
    }

    /// Which declaration each query of `queries`, all about the document
    /// `uri`, names. Results and their file names belong to `allocator`.
    pub fn resolveSymbols(
        client: *Client,
        allocator: std.mem.Allocator,
        uri: []const u8,
        queries: []const symbol_query.Query,
    ) ![]Symbol {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        if (queries.len > std.math.maxInt(u32)) return error.TooManyQueries;
        const encoded = try encodeQueries(allocator, queries);
        defer allocator.free(encoded);
        const request: protocol.ResolveSymbolsRequest = .{
            .uri_length = @intCast(uri.len),
            .query_count = @intCast(queries.len),
        };
        return client.roundTrip(
            .resolve_symbol,
            request,
            &.{ uri, encoded },
            .resolve_symbol,
            SymbolsReader{ .allocator = allocator, .count = queries.len },
        );
    }

    /// The backend does not answer shutdown; it closes the connection.
    pub fn shutdown(client: *Client) !void {
        var watchdog = try client.armWatchdog();
        defer client.disarmWatchdog(&watchdog);
        try writeRequest(&client.writer.interface, client.takeRequestId(), client.generation, .shutdown, {}, &.{});
    }

    /// The one request/response primitive: frames `request` (a fixed extern
    /// struct, or `{}`, followed by raw `tail` byte runs) under `tag`, waits
    /// for the response under the connection watchdog, checks the request id,
    /// records the backend generation, maps protocol errors, and hands the
    /// response body to `read_body`, which must consume exactly
    /// `header.body_length` bytes. `read_body` is a function
    /// `(*std.Io.Reader, Header) !T` or a value with such a `read` method.
    fn roundTrip(
        client: *Client,
        tag: protocol.Tag,
        request: anytype,
        tail: []const []const u8,
        expected: protocol.Tag,
        read_body: anytype,
    ) !BodyResult(@TypeOf(read_body)) {
        var watchdog = try client.armWatchdog();
        defer client.disarmWatchdog(&watchdog);
        const request_id = client.takeRequestId();
        try writeRequest(&client.writer.interface, request_id, client.generation, tag, request, tail);
        const header = try readResponseHeader(&client.reader.interface, request_id);
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != expected) return error.UnexpectedResponse;
        return try readBody(read_body, &client.reader.interface, header);
    }

    const Watchdog = std.Io.Future(error{Canceled}!void);

    fn armWatchdog(client: *Client) std.Io.ConcurrentError!Watchdog {
        return client.io.concurrent(disconnectAfterDeadline, .{
            client.io,
            client.stream,
            client.response_deadline_ms,
        });
    }

    fn disarmWatchdog(client: *Client, watchdog: *Watchdog) void {
        watchdog.cancel(client.io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    /// Runs concurrently with one backend request; the response cancels it.
    /// If the deadline passes first, shutting the socket down unblocks the
    /// pending read with error.EndOfStream so the caller's failure path
    /// (log + syntax fallback) takes over instead of hanging forever.
    fn disconnectAfterDeadline(
        io: std.Io,
        stream: std.Io.net.Stream,
        deadline_ms: i64,
    ) error{Canceled}!void {
        try io.sleep(.fromMilliseconds(deadline_ms), .awake);
        std.log.warn("compiler backend did not respond within {d} ms; disconnecting it", .{deadline_ms});
        stream.shutdown(io, .both) catch |err| {
            std.log.warn("failed to disconnect unresponsive compiler backend: {t}", .{err});
        };
    }

    fn takeRequestId(client: *Client) u32 {
        const request_id = client.next_request_id;
        client.next_request_id +%= 1;
        if (client.next_request_id == 0) client.next_request_id = 1;
        return request_id;
    }

    fn readProtocolError(client: *Client, header: protocol.Header) !noreturn {
        if (header.body_length < @sizeOf(protocol.ErrorResponse)) return error.MalformedResponse;
        const response = try client.reader.interface.takeStruct(protocol.ErrorResponse, .little);
        const expected_length: u64 = @sizeOf(protocol.ErrorResponse) + @as(u64, response.message_length);
        if (header.body_length != expected_length) return error.MalformedResponse;
        // discardAll rather than take: the message length comes off the wire
        // and take asserts it fits the reader buffer.
        try client.reader.interface.discardAll(response.message_length);
        return switch (response.code) {
            .incompatible_protocol => error.IncompatibleProtocol,
            .incompatible_zig => error.IncompatibleZig,
            .authentication_failed => error.AuthenticationFailed,
            .stale_generation => error.StaleGeneration,
            .unknown_compile_unit => error.UnknownCompileUnit,
            .unavailable => error.SemanticsUnavailable,
            .malformed_request => error.MalformedRequest,
            .internal_failure => error.CompilerFailure,
            _ => error.UnknownCompilerError,
        };
    }
};

pub const TypeShape = struct {
    kind: protocol.TypeShapeKind,
    fields: []const []const u8,

    pub fn deinit(shape: *TypeShape, allocator: std.mem.Allocator) void {
        for (shape.fields) |field| allocator.free(field);
        allocator.free(shape.fields);
        shape.* = undefined;
    }
};

pub const ResolvedValue = struct {
    type_name: []const u8,
    value: []const u8,

    pub fn deinit(resolved: *ResolvedValue, allocator: std.mem.Allocator) void {
        allocator.free(resolved.type_name);
        allocator.free(resolved.value);
        resolved.* = undefined;
    }
};

/// A declaration the compiler named for a query, or why it could not.
pub const Symbol = struct {
    status: protocol.SymbolStatus,
    kind: protocol.SymbolKind,
    /// The file declaring it, as the compiler spells the path.
    file: []const u8,
    /// Byte span of the declaration's name token in `file`.
    start: u32,
    end: u32,

    /// Whether both name the same declaration.
    pub fn same(symbol: Symbol, other: Symbol) bool {
        return symbol.status == .resolved and other.status == .resolved and symbol.kind == other.kind and
            symbol.start == other.start and symbol.end == other.end and std.mem.eql(u8, symbol.file, other.file);
    }
};

fn encodeQueries(allocator: std.mem.Allocator, queries: []const symbol_query.Query) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    errdefer encoded.deinit();
    const writer = &encoded.writer;
    for (queries) |query| {
        if (query.steps.len > std.math.maxInt(u16)) return error.QueryTooLong;
        try writer.writeStruct(protocol.QueryHeader{
            .flags = if (query.declaration_site) protocol.query_declaration_site else 0,
            .step_count = @intCast(query.steps.len),
        }, .little);
        for (query.steps) |step| {
            if (step.name.len > std.math.maxInt(u16)) return error.QueryTooLong;
            try writer.writeStruct(protocol.Step{
                .kind = switch (step.kind) {
                    .scope => .scope,
                    .name => .name,
                    .call => .call,
                    .index => .index,
                    .target => .target,
                },
                .name_length = @intCast(step.name.len),
            }, .little);
            try writer.writeAll(step.name);
        }
    }
    return encoded.toOwnedSlice();
}

/// Serializes one request: header, the optional fixed struct, then the raw
/// byte runs, and flushes.
fn writeRequest(
    writer: *std.Io.Writer,
    request_id: u32,
    generation: u32,
    tag: protocol.Tag,
    request: anytype,
    tail: []const []const u8,
) !void {
    var body_length: u64 = if (@TypeOf(request) == void) 0 else @sizeOf(@TypeOf(request));
    for (tail) |part| body_length += part.len;
    if (body_length > std.math.maxInt(u32)) return error.RequestTooLong;
    try writer.writeStruct(protocol.Header{
        .body_length = @intCast(body_length),
        .request_id = request_id,
        .generation = generation,
        .tag = tag,
    }, .little);
    if (@TypeOf(request) != void) try writer.writeStruct(request, .little);
    for (tail) |part| try writer.writeAll(part);
    try writer.flush();
}

fn readResponseHeader(reader: *std.Io.Reader, request_id: u32) !protocol.Header {
    const header = try reader.takeStruct(protocol.Header, .little);
    if (header.request_id != request_id) return error.UnexpectedRequestId;
    return header;
}

fn nameRequest(name: []const u8) !protocol.TypeMembersRequest {
    if (name.len > std.math.maxInt(u32)) return error.NameTooLong;
    return .{ .name_length = @intCast(name.len) };
}

fn BodyResult(comptime Reader: type) type {
    const return_type = switch (@typeInfo(Reader)) {
        .@"fn" => |function| function.return_type.?,
        else => @typeInfo(@TypeOf(Reader.read)).@"fn".return_type.?,
    };
    return @typeInfo(return_type).error_union.payload;
}

fn readBody(read_body: anytype, reader: *std.Io.Reader, header: protocol.Header) !BodyResult(@TypeOf(read_body)) {
    return switch (@typeInfo(@TypeOf(read_body))) {
        .@"fn" => read_body(reader, header),
        else => read_body.read(reader, header),
    };
}

const HelloResult = struct {
    status: protocol.HandshakeStatus,
    zig_version_matches: bool,
};

const HelloReader = struct {
    fn read(_: HelloReader, reader: *std.Io.Reader, header: protocol.Header) !HelloResult {
        if (header.body_length < @sizeOf(protocol.HelloResponse)) return error.MalformedResponse;
        const response = try reader.takeStruct(protocol.HelloResponse, .little);
        const expected_length: u32 = @sizeOf(protocol.HelloResponse) + response.zig_version_length;
        if (header.body_length != expected_length) return error.MalformedResponse;
        // Bound before take: the length comes off the wire and take asserts it
        // fits the reader buffer.
        if (response.zig_version_length > max_zig_version_length) return error.MalformedResponse;
        const zig_version = try reader.take(response.zig_version_length);
        return .{
            .status = response.status,
            .zig_version_matches = std.mem.eql(u8, zig_version, build_options.zig_version),
        };
    }
};

fn readSummary(reader: *std.Io.Reader, header: protocol.Header) !protocol.WorkspaceSummary {
    if (header.body_length != @sizeOf(protocol.WorkspaceSummary)) return error.MalformedResponse;
    return try reader.takeStruct(protocol.WorkspaceSummary, .little);
}

fn readDocumentFacts(reader: *std.Io.Reader, header: protocol.Header) !protocol.DocumentFacts {
    if (header.body_length != @sizeOf(protocol.DocumentFacts)) return error.MalformedResponse;
    return try reader.takeStruct(protocol.DocumentFacts, .little);
}

fn readRemoveAck(reader: *std.Io.Reader, header: protocol.Header) !void {
    if (header.body_length != @sizeOf(protocol.RemoveOverlayRequest)) return error.MalformedResponse;
    _ = try reader.takeStruct(protocol.RemoveOverlayRequest, .little);
}

const NameListReader = struct {
    allocator: std.mem.Allocator,

    fn read(self: NameListReader, reader: *std.Io.Reader, header: protocol.Header) ![]const []const u8 {
        if (header.body_length < @sizeOf(protocol.DeclarationList)) return error.MalformedResponse;
        const list = try reader.takeStruct(protocol.DeclarationList, .little);
        if (list.declaration_count > (header.body_length - @sizeOf(protocol.DeclarationList)) / @sizeOf(u32)) {
            return error.MalformedResponse;
        }
        const names = try self.allocator.alloc([]const u8, list.declaration_count);
        var names_read: usize = 0;
        errdefer {
            for (names[0..names_read]) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        var consumed: u64 = @sizeOf(protocol.DeclarationList);
        var names_length: u64 = 0;
        for (names) |*name| {
            const name_length = try reader.takeInt(u32, .little);
            consumed += @sizeOf(u32) + name_length;
            names_length += name_length;
            if (consumed > header.body_length) return error.MalformedResponse;
            name.* = try reader.readAllocAll(self.allocator, name_length);
            names_read += 1;
        }
        if (consumed != header.body_length or names_length != list.names_length) return error.MalformedResponse;
        return names;
    }
};

const ErrorBundleReader = struct {
    allocator: std.mem.Allocator,

    fn read(self: ErrorBundleReader, reader: *std.Io.Reader, header: protocol.Header) !std.zig.ErrorBundle {
        if (header.body_length < @sizeOf(protocol.DiagnosticBundle)) return error.MalformedResponse;
        const bundle_header = try reader.takeStruct(protocol.DiagnosticBundle, .little);
        const expected_length = @sizeOf(protocol.DiagnosticBundle) +
            @as(u64, bundle_header.extra_length) * @sizeOf(u32) + bundle_header.string_bytes_length;
        if (header.body_length != expected_length) return error.MalformedResponse;

        const extra = try self.allocator.alloc(u32, bundle_header.extra_length);
        errdefer self.allocator.free(extra);
        const string_bytes = try self.allocator.alloc(u8, bundle_header.string_bytes_length);
        errdefer self.allocator.free(string_bytes);
        try reader.readSliceEndian(u32, extra, .little);
        try reader.readSliceAll(string_bytes);
        return .{ .extra = extra, .string_bytes = string_bytes };
    }
};

const TypeShapeReader = struct {
    allocator: std.mem.Allocator,

    fn read(self: TypeShapeReader, reader: *std.Io.Reader, header: protocol.Header) !TypeShape {
        if (header.body_length < @sizeOf(protocol.TypeShape)) return error.MalformedResponse;
        const shape_header = try reader.takeStruct(protocol.TypeShape, .little);
        const expected_length = @sizeOf(protocol.TypeShape) +
            @as(u64, shape_header.field_count) * @sizeOf(u32) + shape_header.names_length;
        if (header.body_length != expected_length) return error.MalformedResponse;
        const fields = try self.allocator.alloc([]const u8, shape_header.field_count);
        var fields_read: usize = 0;
        errdefer {
            for (fields[0..fields_read]) |field| self.allocator.free(field);
            self.allocator.free(fields);
        }
        var names_length: u64 = 0;
        for (fields) |*field| {
            const field_length = try reader.takeInt(u32, .little);
            names_length += field_length;
            if (names_length > shape_header.names_length) return error.MalformedResponse;
            field.* = try reader.readAllocAll(self.allocator, field_length);
            fields_read += 1;
        }
        if (names_length != shape_header.names_length) return error.MalformedResponse;
        return .{ .kind = shape_header.kind, .fields = fields };
    }
};

const SymbolsReader = struct {
    allocator: std.mem.Allocator,
    count: usize,

    fn read(self: SymbolsReader, reader: *std.Io.Reader, header: protocol.Header) ![]Symbol {
        if (header.body_length < @sizeOf(protocol.SymbolsResponse)) return error.MalformedResponse;
        const response = try reader.takeStruct(protocol.SymbolsResponse, .little);
        if (response.result_count != self.count) return error.MalformedResponse;
        const symbols = try self.allocator.alloc(Symbol, self.count);
        var read_count: usize = 0;
        errdefer {
            for (symbols[0..read_count]) |symbol| self.allocator.free(symbol.file);
            self.allocator.free(symbols);
        }
        var consumed: u64 = @sizeOf(protocol.SymbolsResponse);
        for (symbols) |*symbol| {
            consumed += @sizeOf(protocol.SymbolResult);
            if (consumed > header.body_length) return error.MalformedResponse;
            const result = try reader.takeStruct(protocol.SymbolResult, .little);
            consumed += result.file_length;
            if (consumed > header.body_length) return error.MalformedResponse;
            symbol.* = .{
                .status = result.status,
                .kind = result.kind,
                .file = try reader.readAllocAll(self.allocator, result.file_length),
                .start = result.start,
                .end = result.end,
            };
            read_count += 1;
        }
        if (consumed != header.body_length) return error.MalformedResponse;
        return symbols;
    }
};

const ResolvedValueReader = struct {
    allocator: std.mem.Allocator,

    fn read(self: ResolvedValueReader, reader: *std.Io.Reader, header: protocol.Header) !ResolvedValue {
        if (header.body_length < @sizeOf(protocol.ResolvedValue)) return error.MalformedResponse;
        const value_header = try reader.takeStruct(protocol.ResolvedValue, .little);
        const expected_length: u64 = @sizeOf(protocol.ResolvedValue) +
            @as(u64, value_header.type_length) + value_header.value_length;
        if (header.body_length != expected_length) return error.MalformedResponse;
        const type_name = try reader.readAllocAll(self.allocator, value_header.type_length);
        errdefer self.allocator.free(type_name);
        const value = try reader.readAllocAll(self.allocator, value_header.value_length);
        return .{ .type_name = type_name, .value = value };
    }
};

test "queries encode their steps in order" {
    const query: symbol_query.Query = .{
        .declaration_site = true,
        .steps = &.{ .{ .kind = .scope, .name = "Outer" }, .{ .kind = .call }, .{ .kind = .target, .name = "name" } },
    };
    const encoded = try encodeQueries(std.testing.allocator, &.{query});
    defer std.testing.allocator.free(encoded);
    const header_size = @sizeOf(protocol.QueryHeader);
    const step_size = @sizeOf(protocol.Step);
    try std.testing.expectEqual(header_size + 3 * step_size + "Outer".len + "name".len, encoded.len);
    try std.testing.expectEqual(protocol.query_declaration_site, std.mem.readInt(u16, encoded[0..2], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, encoded[2..4], .little));
    try std.testing.expectEqual(@as(u8, @backingInt(protocol.StepKind.scope)), encoded[header_size]);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, encoded[header_size + 2 ..][0..2], .little));
    try std.testing.expectEqualStrings("Outer", encoded[header_size + step_size ..][0..5]);
}

test "hello request carries the version and authentication token" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    const hello: protocol.Hello = .{
        .protocol_version = protocol.version,
        .zig_version_length = 6,
        .authentication_token_length = 6,
    };
    try writeRequest(&allocating.writer, 17, 0, .hello, hello, &.{ "0.17.0", "secret" });

    var reader: std.Io.Reader = .fixed(allocating.written());
    const header = try reader.takeStruct(protocol.Header, .little);
    const decoded = try reader.takeStruct(protocol.Hello, .little);
    try std.testing.expectEqual(@as(u32, 17), header.request_id);
    try std.testing.expectEqual(protocol.Tag.hello, header.tag);
    try std.testing.expectEqual(@as(u32, @sizeOf(protocol.Hello) + 12), header.body_length);
    try std.testing.expectEqual(protocol.version, decoded.protocol_version);
    try std.testing.expectEqualStrings("0.17.0", try reader.take(decoded.zig_version_length));
    try std.testing.expectEqualStrings("secret", try reader.take(decoded.authentication_token_length));
}

test "hello response rejects a version string that exceeds the reader buffer" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    const oversized_length = max_zig_version_length + 1;
    try bytes.writer.writeStruct(protocol.Header{
        .body_length = @sizeOf(protocol.HelloResponse) + oversized_length,
        .request_id = 8,
        .generation = 2,
        .tag = .hello_response,
    }, .little);
    try bytes.writer.writeStruct(protocol.HelloResponse{
        .protocol_version = protocol.version,
        .status = .accepted,
        .zig_version_length = oversized_length,
    }, .little);
    try bytes.writer.splatByteAll('x', oversized_length);

    var reader: std.Io.Reader = .fixed(bytes.written());
    const header = try readResponseHeader(&reader, 8);
    try std.testing.expectError(error.MalformedResponse, readBody(HelloReader{}, &reader, header));
}

test "a request against an unresponsive backend fails once the response deadline expires" {
    // The watchdog warn is expected here; silence it so the accumulated
    // stderr is not attributed to whichever test fails later in this binary.
    std.testing.log_level = .err;
    const io = std.testing.io;
    // A listener that never accepts nor replies stands in for a hung backend:
    // the TCP handshake still completes, so the client's read blocks forever
    // without the watchdog.
    const address: std.Io.net.IpAddress = .{ .ip6 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var client = try Client.connect(io, std.testing.allocator, server.socket.address.getPort());
    defer client.deinit();
    client.response_deadline_ms = 50;

    try std.testing.expectError(error.EndOfStream, client.workspaceSummary());
}

test "response header rejects an unexpected request id" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeStruct(protocol.Header{
        .body_length = 0,
        .request_id = 9,
        .generation = 2,
        .tag = .hello_response,
    }, .little);

    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.UnexpectedRequestId, readResponseHeader(&reader, 8));
}

test "name list rejects a body whose lengths disagree with its header" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeStruct(protocol.DeclarationList{ .declaration_count = 1, .names_length = 99 }, .little);
    try bytes.writer.writeInt(u32, 3, .little);
    try bytes.writer.writeAll("abc");
    const header: protocol.Header = .{
        .body_length = @intCast(bytes.written().len),
        .request_id = 1,
        .generation = 1,
        .tag = .type_members,
    };
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(
        error.MalformedResponse,
        readBody(NameListReader{ .allocator = std.testing.allocator }, &reader, header),
    );
}
