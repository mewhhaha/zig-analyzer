//! `file://` URIs and filesystem paths, converted in both directions with
//! RFC 3986 percent-encoding. Every result is allocated by the caller's
//! allocator and freed by the caller as a whole.
const std = @import("std");

const scheme = "file://";

/// The URI for an absolute filesystem path. Windows drive paths
/// (`C:\dir\file.zig`) become `file:///C:/dir/file.zig`.
pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    var uri: std.ArrayList(u8) = .empty;
    errdefer uri.deinit(allocator);
    try uri.appendSlice(allocator, scheme);
    var rest = path;
    if (hasDrivePrefix(path)) {
        try uri.append(allocator, '/');
        try uri.appendSlice(allocator, path[0..2]);
        rest = path[2..];
    }
    for (rest) |byte| {
        const separator = byte == '/' or byte == '\\';
        if (separator) {
            try uri.append(allocator, '/');
        } else if (isUnreserved(byte)) {
            try uri.append(allocator, byte);
        } else {
            try uri.appendSlice(allocator, &.{ '%', hex_digits[byte >> 4], hex_digits[byte & 0xf] });
        }
    }
    return uri.toOwnedSlice(allocator);
}

/// The filesystem path of a `file://` URI, or null when `uri` is not a local
/// file URI (another scheme, a remote host, or malformed percent-encoding).
pub fn toPath(allocator: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (!std.mem.startsWith(u8, uri, scheme)) return null;
    var encoded = uri[scheme.len..];
    // Authority: empty (`file:///path`) or `localhost`.
    const authority_end = std.mem.findScalar(u8, encoded, '/') orelse return null;
    const authority = encoded[0..authority_end];
    if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) return null;
    encoded = encoded[authority_end..];

    const path = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(path);
    var length: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (length += 1) {
        if (encoded[index] != '%') {
            path[length] = encoded[index];
            index += 1;
            continue;
        }
        const high = if (index + 2 < encoded.len) hexValue(encoded[index + 1]) else null;
        const low = if (index + 2 < encoded.len) hexValue(encoded[index + 2]) else null;
        if (high == null or low == null) {
            allocator.free(path);
            return null;
        }
        path[length] = high.? << 4 | low.?;
        index += 3;
    }
    // `/C:/dir` names a Windows drive; the leading slash is URI syntax only.
    var start: usize = 0;
    if (length >= 3 and path[0] == '/' and hasDrivePrefix(path[1..length])) start = 1;
    @memmove(path[0 .. length - start], path[start..length]);
    return try allocator.realloc(path, length - start);
}

fn hexValue(digit: u8) ?u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => null,
    };
}

fn hasDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path.len == 2 or path[2] == '/' or path[2] == '\\');
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

const hex_digits = "0123456789ABCDEF";

test "paths round trip through URIs" {
    const allocator = std.testing.allocator;
    const paths = [_][]const u8{
        "/home/user/project/src/main.zig",
        "/home/user/my project/a b.zig",
        "/tmp/100%/done#1?.zig",
        "/tmp/café/日本語.zig",
        "/tmp/semi;colon,comma=eq+plus&amp/x.zig",
        "/",
    };
    for (paths) |path| {
        const uri = try fromPath(allocator, path);
        defer allocator.free(uri);
        try std.testing.expect(std.mem.startsWith(u8, uri, "file:///"));
        for (uri) |byte| try std.testing.expect(byte > ' ' and byte < 0x7f);
        const decoded = (try toPath(allocator, uri)).?;
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings(path, decoded);
    }
}

test "path characters are percent-encoded" {
    const uri = try fromPath(std.testing.allocator, "/a b/%/é.zig");
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings("file:///a%20b/%25/%C3%A9.zig", uri);
}

test "percent escapes decode into a freshly owned path" {
    const allocator = std.testing.allocator;
    const path = (try toPath(allocator, "file:///work/my%20project/%C3%A9%2f%e3%81%82.zig")).?;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/work/my project/é/あ.zig", path);
}

test "non-file and malformed URIs have no path" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try toPath(allocator, "untitled:Untitled-1") == null);
    try std.testing.expect(try toPath(allocator, "https://example.com/a.zig") == null);
    try std.testing.expect(try toPath(allocator, "file://remote-host/share/a.zig") == null);
    try std.testing.expect(try toPath(allocator, "file:///a%2") == null);
    try std.testing.expect(try toPath(allocator, "file:///a%zz.zig") == null);
    try std.testing.expect(try toPath(allocator, "file:///a%") == null);
    try std.testing.expect(try toPath(allocator, "file://") == null);
    const local = (try toPath(allocator, "file://localhost/a.zig")).?;
    defer allocator.free(local);
    try std.testing.expectEqualStrings("/a.zig", local);
}

test "Windows drive paths use a slash-prefixed drive in URIs" {
    const allocator = std.testing.allocator;
    const uri = try fromPath(allocator, "C:\\Users\\me\\my project\\main.zig");
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("file:///C:/Users/me/my%20project/main.zig", uri);

    const plain = (try toPath(allocator, uri)).?;
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("C:/Users/me/my project/main.zig", plain);

    const encoded_colon = (try toPath(allocator, "file:///c%3A/Users/me/a.zig")).?;
    defer allocator.free(encoded_colon);
    try std.testing.expectEqualStrings("c:/Users/me/a.zig", encoded_colon);

    const posix_look_alike = (try toPath(allocator, "file:///c/Users/a.zig")).?;
    defer allocator.free(posix_look_alike);
    try std.testing.expectEqualStrings("/c/Users/a.zig", posix_look_alike);
}
