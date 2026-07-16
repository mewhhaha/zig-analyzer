const std = @import("std");

pub const Reference = struct {
    url: []const u8,
    label: []const u8,
};

pub const Content = struct {
    declaration: []const u8,
    type_summary: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    reference: ?Reference = null,
};

pub const MarkdownRenderer = struct {
    code_fence_language: []const u8 = "zig",

    pub fn render(
        renderer: MarkdownRenderer,
        allocator: std.mem.Allocator,
        content: Content,
    ) ![]const u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();

        try writer.writer.print("```{s}\n{s}\n```", .{
            renderer.code_fence_language,
            content.declaration,
        });
        if (content.type_summary) |type_summary| {
            try writer.writer.print("\n```{s}\n({s})\n```", .{
                renderer.code_fence_language,
                type_summary,
            });
        }
        if (content.documentation) |documentation| {
            try writer.writer.print("\n\n{s}", .{documentation});
        }
        if (content.reference) |reference| {
            try writer.writer.print("\n\n[{s}]({s})", .{ reference.label, reference.url });
        }
        return try writer.toOwnedSlice();
    }
};

pub const default_markdown_renderer: MarkdownRenderer = .{};

test "default Markdown renderer preserves hover sections" {
    const rendered = try default_markdown_renderer.render(std.testing.allocator, .{
        .declaration = "const count: u8 = 1",
        .type_summary = "u8 = 1",
        .documentation = "Number of attempts.",
        .reference = .{
            .label = "Zig language reference",
            .url = "https://ziglang.org/documentation/master/#Primitive-Types",
        },
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "```zig\nconst count: u8 = 1\n```\n```zig\n(u8 = 1)\n```\n\n" ++
            "Number of attempts.\n\n" ++
            "[Zig language reference](https://ziglang.org/documentation/master/#Primitive-Types)",
        rendered,
    );
}

test "Markdown renderer accepts a different code fence language" {
    const renderer: MarkdownRenderer = .{ .code_fence_language = "zig-custom" };
    const rendered = try renderer.render(std.testing.allocator, .{ .declaration = "const count = 1" });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig-custom\nconst count = 1\n```", rendered);
}
