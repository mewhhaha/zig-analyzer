//! Semantic errors surface only when Sema runs, so the fix gates compile real
//! code: every checked program and every fix result is written to a scratch
//! directory and all of them are analyzed in one `zig test -fno-emit-bin`
//! compilation. A fix result may not report an error that its program did
//! not already report (compared by message, not position, since fixes move
//! code).
//!
//! Only programs that lower through AstGen cleanly are compiled: AstGen errors
//! suppress Sema for the whole compilation, and `round_trip.zig` already
//! compares those errors in-process.

const std = @import("std");
const round_trip = @import("round_trip.zig");

/// Programs and their fix results, collected by the round-trip checks.
pub const Corpus = struct {
    arena_state: std.heap.ArenaAllocator,
    programs: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        label: []const u8,
        source: [:0]const u8,
        /// Lowers through AstGen without errors, so Sema can run on it.
        clean: bool,
        variants: std.ArrayList(Variant) = .empty,
    };

    const Variant = struct {
        rule: []const u8,
        title: []const u8,
        source: [:0]const u8,
    };

    pub const Program = struct {
        corpus: *Corpus,
        index: usize,

        /// Records a fix result of this program; ignored when the program
        /// cannot be compiled anyway.
        pub fn addVariant(recorded: Program, rule: []const u8, title: []const u8, fixed: []const u8) !void {
            const arena = recorded.corpus.arena_state.allocator();
            const entry = &recorded.corpus.programs.items[recorded.index];
            if (!entry.clean) return;
            try entry.variants.append(arena, .{
                .rule = try arena.dupe(u8, rule),
                .title = try arena.dupe(u8, title),
                .source = try arena.dupeSentinel(u8, fixed, 0),
            });
        }
    };

    pub fn init(gpa: std.mem.Allocator) Corpus {
        return .{ .arena_state = .init(gpa) };
    }

    pub fn deinit(corpus: *Corpus) void {
        corpus.arena_state.deinit();
    }

    /// The program `source`, recorded once however many rules are checked on it.
    pub fn program(corpus: *Corpus, label: []const u8, source: []const u8, clean: bool) !Program {
        if (corpus.programs.items.len != 0) {
            const last = corpus.programs.items.len - 1;
            const entry = corpus.programs.items[last];
            if (std.mem.eql(u8, entry.source, source)) return .{ .corpus = corpus, .index = last };
        }
        const arena = corpus.arena_state.allocator();
        try corpus.programs.append(arena, .{
            .label = try arena.dupe(u8, label),
            .source = try arena.dupeSentinel(u8, source, 0),
            .clean = clean,
        });
        return .{ .corpus = corpus, .index = corpus.programs.items.len - 1 };
    }
};

pub const Outcome = struct {
    /// Programs compiled.
    programs: usize = 0,
    /// Fix results compiled.
    variants: usize = 0,
    /// Compiled programs that already report errors, which weakens the
    /// comparison for them.
    erroneous: usize = 0,
    /// Programs left out: AstGen errors or imports of files that do not exist.
    skipped: usize = 0,
    /// Fix results that report an error their program does not.
    failures: usize = 0,
};

/// Compiles the corpus and reports every fix result that introduces an error.
pub fn check(gpa: std.mem.Allocator, io: std.Io, corpus: *Corpus) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var outcome: Outcome = .{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root: std.ArrayList(u8) = .empty;
    try root.appendSlice(arena,
        \\const std = @import("std");
        \\
        \\fn force(comptime T: type) void {
        \\    inline for (comptime std.meta.declarations(T)) |name| _ = &@field(T, name);
        \\}
        \\
        \\test {
        \\
    );
    for (corpus.programs.items, 0..) |entry, index| {
        if (!compiles(entry)) continue;
        outcome.programs += 1;
        try writeUnit(arena, io, tmp.dir, &root, try arena.print("o{d}.zig", .{index}), entry.source);
        for (entry.variants.items, 0..) |variant, variant_index| {
            outcome.variants += 1;
            const name = try arena.print("v{d}_{d}.zig", .{ index, variant_index });
            try writeUnit(arena, io, tmp.dir, &root, name, variant.source);
        }
    }
    try root.appendSlice(arena, "}\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig", .data = root.items });

    const directory = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "zig", "test", "-fno-emit-bin", "root.zig" },
        .cwd = .{ .path = directory },
    });
    const messages = try parseMessages(arena, result.stderr);

    for (corpus.programs.items, 0..) |entry, index| {
        if (!compiles(entry)) {
            outcome.skipped += 1;
            continue;
        }
        const before = messagesFor(messages, try arena.print("o{d}.zig", .{index}));
        outcome.erroneous += @intFromBool(before.len != 0);
        for (entry.variants.items, 0..) |variant, variant_index| {
            const name = try arena.print("v{d}_{d}.zig", .{ index, variant_index });
            const introduced = round_trip.firstIntroduced(before, messagesFor(messages, name)) orelse continue;
            outcome.failures += 1;
            std.debug.print(
                "--- {s}: fix introduces a compile error [{s}] \"{s}\"\n--- {s}\n--- before\n{s}\n--- after\n{s}\n",
                .{ entry.label, variant.rule, variant.title, introduced, entry.source, variant.source },
            );
        }
    }
    const crashed = switch (result.term) {
        .exited => |code| code > 1,
        else => true,
    };
    if (crashed) {
        outcome.failures += 1;
        std.debug.print("zig test -fno-emit-bin did not finish:\n{s}\n", .{result.stderr});
    }
    return outcome;
}

/// Whether the program is compiled: it lowers cleanly and imports nothing
/// the scratch directory lacks (a missing file fails the whole compilation).
fn compiles(entry: Corpus.Entry) bool {
    if (!entry.clean) return false;
    var tokenizer = std.zig.Tokenizer.init(entry.source);
    var previous: std.zig.Token.Tag = .invalid;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return true,
            .string_literal => if (previous == .l_paren) {
                const text = entry.source[token.loc.start + 1 .. token.loc.end - 1];
                const is_import = std.mem.endsWith(u8, std.mem.trimEnd(u8, entry.source[0..token.loc.start], "( \t\n"), "@import");
                if (is_import and !std.mem.eql(u8, text, "std") and !std.mem.eql(u8, text, "builtin") and !std.mem.eql(u8, text, "root")) return false;
            },
            else => {},
        }
        previous = token.tag;
    }
}

const FileMessages = struct {
    file: []const u8,
    /// Sorted.
    messages: []const []const u8,
};

fn messagesFor(all: []const FileMessages, file: []const u8) []const []const u8 {
    for (all) |entry| {
        if (std.mem.eql(u8, entry.file, file)) return entry.messages;
    }
    return &.{};
}

/// Error messages by file from `zig test` output lines `file.zig:line:column: error: message`;
/// only the scratch files (relative paths) are kept.
fn parseMessages(arena: std.mem.Allocator, stderr: []const u8) ![]const FileMessages {
    var grouped: std.ArrayList(struct { file: []const u8, messages: std.ArrayList([]const u8) }) = .empty;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const marker = std.mem.find(u8, line, ": error: ") orelse continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (colon > marker or line[0] == '/' or !std.mem.endsWith(u8, line[0..colon], ".zig")) continue;
        const file = line[0..colon];
        const message = line[marker + ": error: ".len ..];
        const slot = for (grouped.items) |*group| {
            if (std.mem.eql(u8, group.file, file)) break group;
        } else blk: {
            try grouped.append(arena, .{ .file = file, .messages = .empty });
            break :blk &grouped.items[grouped.items.len - 1];
        };
        try slot.messages.append(arena, message);
    }
    const all = try arena.alloc(FileMessages, grouped.items.len);
    for (grouped.items, all) |group, *entry| {
        std.mem.sort([]const u8, group.messages.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        entry.* = .{ .file = group.file, .messages = group.messages.items };
    }
    return all;
}

/// Writes `source` as `name` with every container member public, and adds the
/// calls to `root` that make the compiler analyze it: Sema skips declarations
/// nothing references.
fn writeUnit(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, root: *std.ArrayList(u8), name: []const u8, source: [:0]const u8) !void {
    var tree = try std.zig.Ast.parse(arena, source, .{ .mode = .zig });
    var inserts: std.ArrayList(usize) = .empty;
    var types: std.ArrayList([]const u8) = .empty;
    try collectMembers(arena, &tree, tree.rootDecls(), "", &inserts, &types);

    var text: std.ArrayList(u8) = .empty;
    var consumed: usize = 0;
    for (inserts.items) |at| {
        try text.appendSlice(arena, source[consumed..at]);
        try text.appendSlice(arena, "pub ");
        consumed = at;
    }
    try text.appendSlice(arena, source[consumed..]);
    try dir.writeFile(io, .{ .sub_path = name, .data = text.items });

    try root.print(arena, "    _ = @import(\"{s}\");\n    force(@import(\"{s}\"));\n", .{ name, name });
    for (types.items) |path| try root.print(arena, "    force(@import(\"{s}\"){s});\n", .{ name, path });
}

/// Insertion offsets for `pub` (ascending) and the paths of the named
/// containers declared along the way.
fn collectMembers(
    arena: std.mem.Allocator,
    tree: *const std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    path: []const u8,
    inserts: *std.ArrayList(usize),
    types: *std.ArrayList([]const u8),
) !void {
    for (members) |member| {
        const first = tree.firstToken(member);
        var is_public = false;
        var cursor = first;
        while (cursor <= tree.nodeMainToken(member)) : (cursor += 1) {
            if (tree.tokenTag(cursor) == .keyword_pub) is_public = true;
        }
        switch (tree.nodeTag(member)) {
            .fn_decl, .fn_proto, .fn_proto_simple, .fn_proto_multi, .fn_proto_one => {
                if (!is_public) try inserts.append(arena, tree.tokenStart(first));
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                if (!is_public) try inserts.append(arena, tree.tokenStart(first));
                const declaration = tree.fullVarDecl(member).?;
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                const container = if (declaration.ast.init_node.unwrap()) |init_node|
                    tree.fullContainerDecl(&buffer, init_node)
                else
                    null;
                if (container) |nested| {
                    const child = try arena.print("{s}.{s}", .{ path, tree.tokenSlice(declaration.ast.mut_token + 1) });
                    try types.append(arena, child);
                    try collectMembers(arena, tree, nested.ast.members, child, inserts, types);
                }
            },
            else => {},
        }
    }
}
