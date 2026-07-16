const std = @import("std");
const build_options = @import("build_options");
const protocol = @import("compiler_protocol.zig");

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    read_buffer: []u8,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    next_request_id: u32 = 1,
    generation: u32 = 0,

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
            protocol.current_version,
            authentication_token,
        );
    }

    pub fn probeHandshake(
        client: *Client,
        zig_version: []const u8,
        protocol_version: u16,
        authentication_token: []const u8,
    ) !void {
        const request_id = client.takeRequestId();
        try writeHello(
            &client.writer.interface,
            request_id,
            zig_version,
            protocol_version,
            authentication_token,
        );
        const response = try readHelloResponse(&client.reader.interface, request_id);
        client.generation = response.generation;
        switch (response.status) {
            .accepted => {},
            .incompatible_protocol => return error.IncompatibleProtocol,
            .incompatible_zig => return error.IncompatibleZig,
            .authentication_failed => return error.AuthenticationFailed,
            _ => return error.UnknownHandshakeStatus,
        }
        if (!std.mem.eql(u8, response.zig_version, build_options.zig_version)) {
            return error.IncompatibleZig;
        }
    }

    pub fn workspaceSummary(client: *Client) !protocol.WorkspaceSummary {
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = 0,
            .request_id = request_id,
            .generation = client.generation,
            .tag = .workspace_declarations,
        }, .little);
        try client.writer.interface.flush();

        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        if (header.tag != .workspace_declarations) return error.UnexpectedResponse;
        if (header.body_length != @sizeOf(protocol.WorkspaceSummary)) return error.MalformedResponse;
        const summary = try client.reader.interface.takeStruct(protocol.WorkspaceSummary, .little);
        client.generation = header.generation;
        return summary;
    }

    pub fn replaceOverlay(
        client: *Client,
        uri: []const u8,
        document_version: i32,
        source: []const u8,
    ) !protocol.DocumentFacts {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        if (source.len > std.math.maxInt(u32)) return error.SourceTooLong;
        const request_id = client.takeRequestId();
        const request: protocol.ReplaceOverlayRequest = .{
            .uri_length = @intCast(uri.len),
            .source_length = @intCast(source.len),
            .document_version = document_version,
        };
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = @intCast(@sizeOf(protocol.ReplaceOverlayRequest) + uri.len + source.len),
            .request_id = request_id,
            .generation = client.generation,
            .tag = .replace_overlay,
        }, .little);
        try client.writer.interface.writeStruct(request, .little);
        try client.writer.interface.writeAll(uri);
        try client.writer.interface.writeAll(source);
        try client.writer.interface.flush();
        return try client.readDocumentFacts(request_id);
    }

    pub fn analyzeOverlay(client: *Client, uri: []const u8, document_version: i32) !protocol.DocumentFacts {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = @intCast(@sizeOf(protocol.AnalyzeRequest) + uri.len),
            .request_id = request_id,
            .generation = client.generation,
            .tag = .analyze,
        }, .little);
        try client.writer.interface.writeStruct(protocol.AnalyzeRequest{
            .uri_length = @intCast(uri.len),
            .expected_document_version = document_version,
        }, .little);
        try client.writer.interface.writeAll(uri);
        try client.writer.interface.flush();
        return try client.readDocumentFacts(request_id);
    }

    pub fn removeOverlay(client: *Client, uri: []const u8) !void {
        if (uri.len > std.math.maxInt(u32)) return error.UriTooLong;
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = @intCast(@sizeOf(protocol.RemoveOverlayRequest) + uri.len),
            .request_id = request_id,
            .generation = client.generation,
            .tag = .remove_overlay,
        }, .little);
        try client.writer.interface.writeStruct(protocol.RemoveOverlayRequest{ .uri_length = @intCast(uri.len) }, .little);
        try client.writer.interface.writeAll(uri);
        try client.writer.interface.flush();

        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != .remove_overlay or header.body_length != @sizeOf(protocol.RemoveOverlayRequest)) {
            return error.MalformedResponse;
        }
        _ = try client.reader.interface.takeStruct(protocol.RemoveOverlayRequest, .little);
    }

    pub fn workspaceDeclarations(
        client: *Client,
        allocator: std.mem.Allocator,
    ) ![]const []const u8 {
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = 0,
            .request_id = request_id,
            .generation = client.generation,
            .tag = .workspace_declaration_names,
        }, .little);
        try client.writer.interface.flush();

        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != .workspace_declaration_names or header.body_length < @sizeOf(protocol.DeclarationList)) {
            return error.MalformedResponse;
        }
        const list = try client.reader.interface.takeStruct(protocol.DeclarationList, .little);
        if (list.declaration_count > (header.body_length - @sizeOf(protocol.DeclarationList)) / @sizeOf(u32)) {
            return error.MalformedResponse;
        }
        const names = try allocator.alloc([]const u8, list.declaration_count);
        var names_read: usize = 0;
        errdefer {
            for (names[0..names_read]) |name| allocator.free(name);
            allocator.free(names);
        }
        var consumed: u64 = @sizeOf(protocol.DeclarationList);
        var names_length: u64 = 0;
        for (names) |*name| {
            const name_length = try client.reader.interface.takeInt(u32, .little);
            consumed += @sizeOf(u32) + name_length;
            names_length += name_length;
            if (consumed > header.body_length) return error.MalformedResponse;
            name.* = try client.reader.interface.readAlloc(allocator, name_length);
            names_read += 1;
        }
        if (consumed != header.body_length or names_length != list.names_length) return error.MalformedResponse;
        return names;
    }

    pub fn diagnostics(client: *Client, allocator: std.mem.Allocator) !std.zig.ErrorBundle {
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = 0,
            .request_id = request_id,
            .generation = client.generation,
            .tag = .diagnostics,
        }, .little);
        try client.writer.interface.flush();

        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != .diagnostics or header.body_length < @sizeOf(protocol.DiagnosticBundle)) {
            return error.MalformedResponse;
        }
        const bundle_header = try client.reader.interface.takeStruct(protocol.DiagnosticBundle, .little);
        const expected_length = @sizeOf(protocol.DiagnosticBundle) +
            @as(u64, bundle_header.extra_length) * @sizeOf(u32) + bundle_header.string_bytes_length;
        if (header.body_length != expected_length) return error.MalformedResponse;

        const extra = try allocator.alloc(u32, bundle_header.extra_length);
        errdefer allocator.free(extra);
        const string_bytes = try allocator.alloc(u8, bundle_header.string_bytes_length);
        errdefer allocator.free(string_bytes);
        try client.reader.interface.readSliceEndian(u32, extra, .little);
        try client.reader.interface.readSliceAll(string_bytes);
        return .{ .extra = extra, .string_bytes = string_bytes };
    }

    pub fn typeMembers(
        client: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]const []const u8 {
        if (name.len > std.math.maxInt(u32)) return error.NameTooLong;
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = @intCast(@sizeOf(protocol.TypeMembersRequest) + name.len),
            .request_id = request_id,
            .generation = client.generation,
            .tag = .type_members,
        }, .little);
        try client.writer.interface.writeStruct(protocol.TypeMembersRequest{
            .name_length = @intCast(name.len),
        }, .little);
        try client.writer.interface.writeAll(name);
        try client.writer.interface.flush();
        return try client.readDeclarationList(allocator, request_id, .type_members);
    }

    pub fn typeShape(
        client: *Client,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !TypeShape {
        if (name.len > std.math.maxInt(u32)) return error.NameTooLong;
        const request_id = client.takeRequestId();
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = @intCast(@sizeOf(protocol.TypeMembersRequest) + name.len),
            .request_id = request_id,
            .generation = client.generation,
            .tag = .type_shape,
        }, .little);
        try client.writer.interface.writeStruct(protocol.TypeMembersRequest{
            .name_length = @intCast(name.len),
        }, .little);
        try client.writer.interface.writeAll(name);
        try client.writer.interface.flush();

        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != .type_shape or header.body_length < @sizeOf(protocol.TypeShape)) return error.MalformedResponse;
        const shape_header = try client.reader.interface.takeStruct(protocol.TypeShape, .little);
        const expected_length = @sizeOf(protocol.TypeShape) +
            @as(u64, shape_header.field_count) * @sizeOf(u32) + shape_header.names_length;
        if (header.body_length != expected_length) return error.MalformedResponse;
        const fields = try allocator.alloc([]const u8, shape_header.field_count);
        var fields_read: usize = 0;
        errdefer {
            for (fields[0..fields_read]) |field| allocator.free(field);
            allocator.free(fields);
        }
        var names_length: u64 = 0;
        for (fields) |*field| {
            const field_length = try client.reader.interface.takeInt(u32, .little);
            names_length += field_length;
            if (names_length > shape_header.names_length) return error.MalformedResponse;
            field.* = try client.reader.interface.readAlloc(allocator, field_length);
            fields_read += 1;
        }
        if (names_length != shape_header.names_length) return error.MalformedResponse;
        return .{ .kind = shape_header.kind, .fields = fields };
    }

    pub fn shutdown(client: *Client) !void {
        try client.writer.interface.writeStruct(protocol.Header{
            .body_length = 0,
            .request_id = client.takeRequestId(),
            .generation = client.generation,
            .tag = .shutdown,
        }, .little);
        try client.writer.interface.flush();
    }

    fn takeRequestId(client: *Client) u32 {
        const request_id = client.next_request_id;
        client.next_request_id +%= 1;
        if (client.next_request_id == 0) client.next_request_id = 1;
        return request_id;
    }

    fn readDocumentFacts(client: *Client, request_id: u32) !protocol.DocumentFacts {
        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != .document_facts or header.body_length != @sizeOf(protocol.DocumentFacts)) {
            return error.MalformedResponse;
        }
        return try client.reader.interface.takeStruct(protocol.DocumentFacts, .little);
    }

    fn readDeclarationList(
        client: *Client,
        allocator: std.mem.Allocator,
        request_id: u32,
        expected_tag: protocol.Tag,
    ) ![]const []const u8 {
        const header = try client.reader.interface.takeStruct(protocol.Header, .little);
        if (header.request_id != request_id) return error.UnexpectedRequestId;
        client.generation = header.generation;
        if (header.tag == .response_error) return try client.readProtocolError(header);
        if (header.tag != expected_tag or header.body_length < @sizeOf(protocol.DeclarationList)) {
            return error.MalformedResponse;
        }
        const list = try client.reader.interface.takeStruct(protocol.DeclarationList, .little);
        if (list.declaration_count > (header.body_length - @sizeOf(protocol.DeclarationList)) / @sizeOf(u32)) {
            return error.MalformedResponse;
        }
        const names = try allocator.alloc([]const u8, list.declaration_count);
        var names_read: usize = 0;
        errdefer {
            for (names[0..names_read]) |member_name| allocator.free(member_name);
            allocator.free(names);
        }
        var consumed: u64 = @sizeOf(protocol.DeclarationList);
        var names_length: u64 = 0;
        for (names) |*member_name| {
            const name_length = try client.reader.interface.takeInt(u32, .little);
            consumed += @sizeOf(u32) + name_length;
            names_length += name_length;
            if (consumed > header.body_length) return error.MalformedResponse;
            member_name.* = try client.reader.interface.readAlloc(allocator, name_length);
            names_read += 1;
        }
        if (consumed != header.body_length or names_length != list.names_length) return error.MalformedResponse;
        return names;
    }

    fn readProtocolError(client: *Client, header: protocol.Header) !noreturn {
        if (header.body_length < @sizeOf(protocol.ErrorResponse)) return error.MalformedResponse;
        const response = try client.reader.interface.takeStruct(protocol.ErrorResponse, .little);
        const expected_length: u32 = @sizeOf(protocol.ErrorResponse) + response.message_length;
        if (header.body_length != expected_length) return error.MalformedResponse;
        _ = try client.reader.interface.take(response.message_length);
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

const HelloResult = struct {
    generation: u32,
    status: protocol.HandshakeStatus,
    zig_version: []const u8,
};

fn writeHello(
    writer: *std.Io.Writer,
    request_id: u32,
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
    try writer.writeStruct(protocol.Header{
        .body_length = @intCast(@sizeOf(protocol.Hello) + zig_version.len + authentication_token.len),
        .request_id = request_id,
        .generation = 0,
        .tag = .hello,
    }, .little);
    try writer.writeStruct(hello, .little);
    try writer.writeAll(zig_version);
    try writer.writeAll(authentication_token);
    try writer.flush();
}

fn readHelloResponse(reader: *std.Io.Reader, request_id: u32) !HelloResult {
    const header = try reader.takeStruct(protocol.Header, .little);
    if (header.request_id != request_id) return error.UnexpectedRequestId;
    if (header.tag != .hello_response) return error.UnexpectedResponse;
    if (header.body_length < @sizeOf(protocol.HelloResponse)) return error.MalformedResponse;

    const response = try reader.takeStruct(protocol.HelloResponse, .little);
    const expected_length: u32 = @sizeOf(protocol.HelloResponse) + response.zig_version_length;
    if (header.body_length != expected_length) return error.MalformedResponse;
    return .{
        .generation = header.generation,
        .status = response.status,
        .zig_version = try reader.take(response.zig_version_length),
    };
}

test "hello request carries the version and authentication token" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try writeHello(&allocating.writer, 17, "0.16.0", protocol.current_version, "secret");

    var reader: std.Io.Reader = .fixed(allocating.written());
    const header = try reader.takeStruct(protocol.Header, .little);
    const hello = try reader.takeStruct(protocol.Hello, .little);
    try std.testing.expectEqual(@as(u32, 17), header.request_id);
    try std.testing.expectEqual(protocol.Tag.hello, header.tag);
    try std.testing.expectEqual(protocol.current_version, hello.protocol_version);
    try std.testing.expectEqualStrings("0.16.0", try reader.take(hello.zig_version_length));
    try std.testing.expectEqualStrings("secret", try reader.take(hello.authentication_token_length));
}

test "hello response rejects an unexpected request id" {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try bytes.writer.writeStruct(protocol.Header{
        .body_length = @sizeOf(protocol.HelloResponse) + 6,
        .request_id = 9,
        .generation = 2,
        .tag = .hello_response,
    }, .little);
    try bytes.writer.writeStruct(protocol.HelloResponse{
        .protocol_version = protocol.current_version,
        .status = .accepted,
        .zig_version_length = 6,
    }, .little);
    try bytes.writer.writeAll("0.16.0");

    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.UnexpectedRequestId, readHelloResponse(&reader, 8));
}
