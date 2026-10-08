//! Public declarations judged against compiler facts: shapes that differ between compile units and declarations no compile unit reaches.
const std = @import("std");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const File = run_module.File;
const types = @import("../types.zig");
const project = @import("../project.zig");
const support = @import("../test_support.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const import_graph = @import("import_graph.zig");
const Import = import_graph.Import;
const CompilerShape = run_module.CompilerShape;

pub const rules = [_]types.Rule{
    .configuration_divergent_api,
    .unreachable_public_declaration,
};

pub fn findConfigurationDivergentApis(
    run: ProjectRun,
) !void {
    if (run.configuration.level(.configuration_divergent_api) == .off or run.compiler_facts.units.len < 2) return;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    defer reported.deinit(run.allocator);
    for (run.compiler_facts.units, 0..) |left_unit, left_index| {
        for (left_unit.shapes) |left_shape| {
            for (run.compiler_facts.units[left_index + 1 ..]) |right_unit| {
                const right_shape = shapeNamed(right_unit.shapes, left_shape.type_name) orelse continue;
                if (shapesEqual(left_shape, right_shape)) continue;
                const name = types.declarationBaseName(left_shape.type_name);
                const location = publicDeclarationNamed(run.files, name) orelse continue;
                const rep_gop = try reported.getOrPut(run.allocator, left_shape.type_name);
                if (rep_gop.found_existing) continue;
                rep_gop.value_ptr.* = {};
                try run.report(.{
                    .file_index = location.file_index,
                    .rule = .configuration_divergent_api,
                    .span = location.span,
                    .message = try run.allocator.print(
                        "public declaration '{s}' has different compiler-resolved shapes in compile units '{s}' and '{s}'",
                        .{ name, left_unit.root_path, right_unit.root_path },
                    ),
                });
            }
        }
    }
}

pub fn findUnreachablePublicDeclarations(
    run: ProjectRun,
    imports: []const Import,
) !void {
    if (run.configuration.level(.unreachable_public_declaration) == .off or
        run.compiler_facts.units.len == 0 or !run.compiler_facts.roots_complete) return;
    const reachable = try run.allocator.alloc(bool, run.files.len);
    @memset(reachable, false);
    for (run.compiler_facts.units) |unit| {
        for (run.files, 0..) |file, file_index| {
            if (std.mem.eql(u8, file.path, unit.root_path)) reachable[file_index] = true;
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (imports) |import| {
            if (!reachable[import.file_index]) continue;
            for (run.files, 0..) |file, imported_index| {
                if (reachable[imported_index] or !std.mem.eql(u8, file.path, import.resolved_path)) continue;
                reachable[imported_index] = true;
                changed = true;
            }
        }
    }
    for (imports) |import| {
        if (!reachable[import.file_index] or std.mem.endsWith(u8, import.spelling, ".zig") or
            std.mem.eql(u8, import.spelling, "std") or std.mem.eql(u8, import.spelling, "builtin") or
            std.mem.eql(u8, import.spelling, "root")) continue;
        return;
    }
    for (run.files, 0..) |file, file_index| {
        if (reachable[file_index] or std.mem.eql(u8, std.Io.Dir.path.basename(file.path), "build.zig")) continue;
        for (file.tokens, 0..) |token, pub_index| {
            if (token.tag != .keyword_pub or pub_index + 2 >= file.tokens.len) continue;
            const name_index = if (file.tokens[pub_index + 1].tag == .keyword_fn or
                file.tokens[pub_index + 1].tag == .keyword_const or
                file.tokens[pub_index + 1].tag == .keyword_var)
                pub_index + 2
            else
                continue;
            if (file.tokens[name_index].tag != .identifier) continue;
            const name = tokenText(file.source, file.tokens[name_index]);
            try run.report(.{
                .file_index = file_index,
                .rule = .unreachable_public_declaration,
                .span = file.tokens[name_index].loc,
                .message = try run.allocator.print(
                    "public declaration '{s}' is reachable from none of the {d} compiler-analyzed compile units",
                    .{ name, run.compiler_facts.units.len },
                ),
            });
        }
    }
}

const PublicDeclarationLocation = struct { file_index: usize, span: std.zig.Token.Loc };

fn publicDeclarationNamed(files: []const File, name: []const u8) ?PublicDeclarationLocation {
    var selected: ?PublicDeclarationLocation = null;
    for (files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, index| {
            if (token.tag != .keyword_pub or index + 2 >= file.tokens.len or
                (file.tokens[index + 1].tag != .keyword_const and file.tokens[index + 1].tag != .keyword_var) or
                file.tokens[index + 2].tag != .identifier or !tokenIs(file.source, file.tokens[index + 2], name)) continue;
            if (selected != null) return null;
            selected = .{ .file_index = file_index, .span = file.tokens[index + 2].loc };
        }
    }
    return selected;
}

fn shapeNamed(shapes: []const CompilerShape, name: []const u8) ?CompilerShape {
    var selected: ?CompilerShape = null;
    for (shapes) |shape| {
        if (!std.mem.eql(u8, shape.type_name, name)) continue;
        if (selected != null) return null;
        selected = shape;
    }
    return selected;
}

fn shapesEqual(left: CompilerShape, right: CompilerShape) bool {
    if (left.kind != right.kind or left.fields.len != right.fields.len) return false;
    for (left.fields, right.fields) |left_field, right_field| {
        if (!std.mem.eql(u8, left_field, right_field)) return false;
    }
    return true;
}

test "compiler facts report divergent APIs and unreachable public declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{ .configuration_divergent_api, .unreachable_public_declaration }, .warning);
    const files = [_]project.SourceFile{.{
        .path = "src/api.zig",
        .source = "pub const Api = struct {}; pub fn detached() void {}",
    }};
    const compiler_facts: project.CompilerFacts = .{ .roots_complete = true, .units = &.{
        .{
            .root_path = "src/linux.zig",
            .shapes = &.{.{ .type_name = "shared.Api", .kind = .structure, .fields = &.{"linux"} }},
        },
        .{
            .root_path = "src/windows.zig",
            .shapes = &.{.{ .type_name = "shared.Api", .kind = .structure, .fields = &.{"windows"} }},
        },
    } };
    const found = try project.findingsWithCompilerFacts(arena.allocator(), &files, configuration, compiler_facts);
    var saw_divergence = false;
    var saw_unreachable = false;
    for (found) |finding| switch (finding.finding.rule) {
        .configuration_divergent_api => saw_divergence = true,
        .unreachable_public_declaration => saw_unreachable = true,
        else => {},
    };
    try std.testing.expect(saw_divergence);
    try std.testing.expect(saw_unreachable);

    var incomplete_facts = compiler_facts;
    incomplete_facts.roots_complete = false;
    const incomplete = try project.findingsWithCompilerFacts(arena.allocator(), &files, configuration, incomplete_facts);
    for (incomplete) |finding| try std.testing.expect(finding.finding.rule != .unreachable_public_declaration);
}

test "unresolved named modules keep reachability findings opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const configuration = support.only(&.{.unreachable_public_declaration}, .warning);
    const files = [_]project.SourceFile{
        .{ .path = "src/main.zig", .source = "const custom = @import(\"custom\"); pub fn run() void { _ = custom; }" },
        .{ .path = "src/detached.zig", .source = "pub fn detached() void {}" },
    };
    const compiler_facts: project.CompilerFacts = .{
        .roots_complete = true,
        .units = &.{.{ .root_path = "src/main.zig", .shapes = &.{} }},
    };
    const found = try project.findingsWithCompilerFacts(arena.allocator(), &files, configuration, compiler_facts);
    for (found) |finding| try std.testing.expect(finding.finding.rule != .unreachable_public_declaration);
}
