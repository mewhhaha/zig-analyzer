const std = @import("std");
const RuleRun = @import("context.zig").RuleRun;
const types = @import("types.zig");
const syntax_scope = @import("../syntax_scope.zig");

pub fn run(context: RuleRun) !void {
    if (context.level(.modernize_managed_container) == .off and
        context.level(.modernize_deprecated_io) == .off and
        context.level(.modernize_deprecated_stdlib) == .off and
        context.level(.modernize_deprecated_builtin) == .off and
        context.level(.modernize_removed_syntax) == .off and
        context.level(.modernize_build_api) == .off and
        context.level(.modernize_bitcast) == .off) return;
    var scopes = try syntax_scope.Index.init(context.allocator, context.source, context.tokens);
    defer scopes.deinit();
    try findManagedContainers(context, &scopes);
    try findDeprecatedIo(context, &scopes);
    try findDeprecatedStdlib(context, &scopes);
    try findDeprecatedBuiltins(context, &scopes);
    try findRemovedSyntax(context, &scopes);
    try findBuildApi(context, &scopes);
    try findBitcastChanges(context, &scopes);
}

const StdlibReplacement = struct {
    path: []const u8,
    advice: []const u8,
    removed: bool = false,
    /// The advice minus its `std.` root is a signature-identical replacement
    /// for the matched path, so the finding carries a fix.
    drop_in: bool = false,
};

// Verified against the Zig 0.17.0 standard library: entries marked removed are
// absent from that release; the rest carry `Deprecated` doc comments there.
const stdlib_replacements = [_]StdlibReplacement{
    .{ .path = "mem.indexOf", .advice = "std.mem.find", .drop_in = true },
    .{ .path = "mem.indexOfPos", .advice = "std.mem.findPos", .drop_in = true },
    .{ .path = "mem.lastIndexOf", .advice = "std.mem.findLast", .drop_in = true },
    .{ .path = "mem.indexOfScalar", .advice = "std.mem.findScalar", .drop_in = true },
    .{ .path = "mem.indexOfScalarPos", .advice = "std.mem.findScalarPos", .drop_in = true },
    .{ .path = "mem.lastIndexOfScalar", .advice = "std.mem.findScalarLast", .drop_in = true },
    .{ .path = "mem.indexOfAny", .advice = "std.mem.findAny", .drop_in = true },
    .{ .path = "mem.indexOfAnyPos", .advice = "std.mem.findAnyPos", .drop_in = true },
    .{ .path = "mem.lastIndexOfAny", .advice = "std.mem.findLastAny", .drop_in = true },
    .{ .path = "mem.indexOfNone", .advice = "std.mem.findNone", .drop_in = true },
    .{ .path = "mem.lastIndexOfNone", .advice = "std.mem.findLastNone", .drop_in = true },
    .{ .path = "mem.indexOfDiff", .advice = "std.mem.findDiff", .drop_in = true },
    .{ .path = "mem.indexOfSentinel", .advice = "std.mem.findSentinel", .drop_in = true },
    .{ .path = "mem.indexOfMin", .advice = "std.mem.findMin", .drop_in = true },
    .{ .path = "mem.indexOfMinMax", .advice = "std.mem.findMinMax", .drop_in = true },
    .{ .path = "mem.lastIndexOfLinear", .advice = "std.mem.findLastLinear", .drop_in = true },
    .{ .path = "ascii.indexOfIgnoreCase", .advice = "std.ascii.findIgnoreCase", .removed = true, .drop_in = true },
    .{ .path = "ascii.indexOfIgnoreCasePos", .advice = "std.ascii.findIgnoreCasePos", .removed = true, .drop_in = true },
    .{ .path = "ascii.indexOfIgnoreCasePosLinear", .advice = "std.ascii.findIgnoreCasePosLinear", .removed = true, .drop_in = true },
    .{ .path = "mem.copyForwards", .advice = "@memmove" },
    .{ .path = "mem.copyBackwards", .advice = "@memmove" },
    .{ .path = "Build.Step.TranslateC", .advice = "the official translate-c package's Translator API" },
    .{ .path = "Build.Module.addWin32ResourceFile", .advice = "the external Windows resource package before Zig 0.18" },
    .{ .path = "Build.LazyPath.basename", .advice = "path resolution during a make step", .removed = true },
    .{ .path = "fmt.bufPrintZ", .advice = "std.mem.printSentinel with a 0 sentinel", .removed = true },
    .{ .path = "fmt.bufPrint", .advice = "std.mem.print", .drop_in = true },
    .{ .path = "fmt.bufPrintSentinel", .advice = "std.mem.printSentinel", .drop_in = true },
    .{ .path = "fmt.BufPrintError", .advice = "std.mem.PrintError", .drop_in = true },
    .{ .path = "fmt.allocPrint", .advice = "the allocator's print method" },
    .{ .path = "fmt.allocPrintSentinel", .advice = "the allocator's printSentinel method" },
    .{ .path = "meta.Int", .advice = "the @Int builtin", .removed = true },
    .{ .path = "meta.Tuple", .advice = "the @Tuple builtin", .removed = true },
    .{ .path = "meta.fieldInfo", .advice = "@typeInfo and its field_names, field_types, and related arrays" },
    .{ .path = "meta.fieldNames", .advice = "@typeInfo and its field_names array" },
    .{ .path = "meta.fieldTypes", .advice = "@typeInfo and its field_types array" },
    .{ .path = "ArrayListUnmanaged", .advice = "std.ArrayList", .drop_in = true },
    .{ .path = "ArrayListAligned", .advice = "std.array_list.Aligned", .drop_in = true },
    .{ .path = "ArrayListAlignedUnmanaged", .advice = "std.array_list.Aligned", .drop_in = true },
    .{ .path = "ArrayHashMapUnmanaged", .advice = "std.array_hash_map.Custom", .drop_in = true },
    .{ .path = "AutoArrayHashMapUnmanaged", .advice = "std.array_hash_map.Auto", .drop_in = true },
    .{ .path = "StringArrayHashMapUnmanaged", .advice = "std.array_hash_map.String", .drop_in = true },
    .{ .path = "heap.MemoryPoolAligned", .advice = "std.heap.memory_pool.Aligned", .removed = true, .drop_in = true },
    .{ .path = "heap.MemoryPoolExtra", .advice = "std.heap.memory_pool.Extra", .removed = true, .drop_in = true },
    .{ .path = "heap.MemoryPoolOptions", .advice = "std.heap.memory_pool.Options", .removed = true, .drop_in = true },
    .{ .path = "heap.memory_pool.AlignedManaged", .advice = "std.heap.memory_pool.Aligned and pass the allocator to allocating calls", .removed = true },
    .{ .path = "heap.memory_pool.ExtraManaged", .advice = "std.heap.memory_pool.Extra and pass the allocator to allocating calls", .removed = true },
    .{ .path = "heap.DebugAllocator", .advice = "std.heap.SafeAllocator with its explicit init and deinit API" },
    .{ .path = "heap.DebugAllocatorConfig", .advice = "std.heap.SafeAllocator.Options" },
    .{ .path = "heap.Check", .advice = "std.heap.SafeAllocator and its deinit API" },
    .{ .path = "heap.stackFallback", .advice = "std.heap.StackFallbackAllocator.init with a caller-owned buffer", .removed = true },
    .{ .path = "fs.path.resolve", .advice = "std.Io.Dir.path.resolveAlloc", .drop_in = true },
    .{ .path = "fs.path.resolveWindows", .advice = "std.Io.Dir.path.resolveAllocWindows", .drop_in = true },
    .{ .path = "fs.path.resolvePosix", .advice = "std.Io.Dir.path.resolveAllocPosix", .drop_in = true },
    .{ .path = "fs.path.relative", .advice = "std.Io.Dir.path.relativeAlloc", .drop_in = true },
    .{ .path = "fs.path.relativeWindows", .advice = "std.Io.Dir.path.relativeAllocWindows", .drop_in = true },
    .{ .path = "fs.path.relativePosix", .advice = "std.Io.Dir.path.relativeAllocPosix", .drop_in = true },
    .{ .path = "Io.Dir.path.resolve", .advice = "std.Io.Dir.path.resolveAlloc", .drop_in = true },
    .{ .path = "Io.Dir.path.resolveWindows", .advice = "std.Io.Dir.path.resolveAllocWindows", .drop_in = true },
    .{ .path = "Io.Dir.path.resolvePosix", .advice = "std.Io.Dir.path.resolveAllocPosix", .drop_in = true },
    .{ .path = "Io.Dir.path.relative", .advice = "std.Io.Dir.path.relativeAlloc", .drop_in = true },
    .{ .path = "Io.Dir.path.relativeWindows", .advice = "std.Io.Dir.path.relativeAllocWindows", .drop_in = true },
    .{ .path = "Io.Dir.path.relativePosix", .advice = "std.Io.Dir.path.relativeAllocPosix", .drop_in = true },
    .{ .path = "fs.path", .advice = "std.Io.Dir.path", .drop_in = true },
    .{ .path = "fs.max_path_bytes", .advice = "std.Io.Dir.max_path_bytes", .drop_in = true },
    .{ .path = "fs.max_name_bytes", .advice = "std.Io.Dir.max_name_bytes", .drop_in = true },
    .{ .path = "fs.base64_alphabet", .advice = "std.base64.url_safe_alphabet_chars", .drop_in = true },
    .{ .path = "fs.base64_encoder", .advice = "std.base64.url_safe.Encoder", .drop_in = true },
    .{ .path = "fs.base64_decoder", .advice = "std.base64.url_safe.Decoder", .drop_in = true },
    .{ .path = "bit_set.IntegerBitSet", .advice = "std.bit_set.Integer", .drop_in = true },
    .{ .path = "bit_set.ArrayBitSet", .advice = "std.bit_set.Array", .drop_in = true },
    .{ .path = "bit_set.StaticBitSet", .advice = "std.bit_set.Static", .drop_in = true },
    .{ .path = "StaticBitSet", .advice = "std.bit_set.Static", .drop_in = true },
    .{ .path = "bit_set.DynamicBitSetUnmanaged", .advice = "std.bit_set.Dynamic", .drop_in = true },
    .{ .path = "DynamicBitSetUnmanaged", .advice = "std.bit_set.Dynamic", .drop_in = true },
    .{ .path = "bit_set.DynamicBitSet", .advice = "std.bit_set.DynamicManaged or std.bit_set.Dynamic with explicit allocator arguments" },
    .{ .path = "DynamicBitSet", .advice = "std.bit_set.DynamicManaged or std.bit_set.Dynamic with explicit allocator arguments" },
    .{ .path = "DoublyLinkedList.pop", .advice = "std.DoublyLinkedList.popLast", .drop_in = true },
    .{ .path = "mem.containsAtLeastScalar2", .advice = "std.mem.containsAtLeastScalar", .removed = true, .drop_in = true },
    .{ .path = "mem.Allocator.dupeZ", .advice = "std.mem.Allocator.dupeSentinel with an explicit 0 sentinel", .removed = true },
    .{ .path = "mem.readPackedIntNative", .advice = "std.mem.readPackedInt with std.lang.Endian.native", .removed = true },
    .{ .path = "mem.readPackedIntForeign", .advice = "std.mem.readPackedInt with the opposite of std.lang.Endian.native", .removed = true },
    .{ .path = "mem.writePackedIntNative", .advice = "std.mem.writePackedInt with std.lang.Endian.native", .removed = true },
    .{ .path = "mem.writePackedIntForeign", .advice = "std.mem.writePackedInt with the opposite of std.lang.Endian.native", .removed = true },
    .{ .path = "gpu", .advice = "std.spirv", .removed = true, .drop_in = true },
    .{ .path = "builtin.OptimizeMode.Debug", .advice = "std.lang.Optimize.debug", .drop_in = true },
    .{ .path = "builtin.OptimizeMode.ReleaseSafe", .advice = "std.lang.Optimize.safe", .drop_in = true },
    .{ .path = "builtin.OptimizeMode.ReleaseFast", .advice = "std.lang.Optimize.fast", .drop_in = true },
    .{ .path = "builtin.OptimizeMode.ReleaseSmall", .advice = "std.lang.Optimize.small", .drop_in = true },
    .{ .path = "lang.OptimizeMode.Debug", .advice = "std.lang.Optimize.debug", .drop_in = true },
    .{ .path = "lang.OptimizeMode.ReleaseSafe", .advice = "std.lang.Optimize.safe", .drop_in = true },
    .{ .path = "lang.OptimizeMode.ReleaseFast", .advice = "std.lang.Optimize.fast", .drop_in = true },
    .{ .path = "lang.OptimizeMode.ReleaseSmall", .advice = "std.lang.Optimize.small", .drop_in = true },
    .{ .path = "lang.Optimize.Debug", .advice = "std.lang.Optimize.debug", .drop_in = true },
    .{ .path = "lang.Optimize.ReleaseSafe", .advice = "std.lang.Optimize.safe", .drop_in = true },
    .{ .path = "lang.Optimize.ReleaseFast", .advice = "std.lang.Optimize.fast", .drop_in = true },
    .{ .path = "lang.Optimize.ReleaseSmall", .advice = "std.lang.Optimize.small", .drop_in = true },
    .{ .path = "builtin.OptimizeMode", .advice = "std.lang.Optimize", .drop_in = true },
    .{ .path = "lang.OptimizeMode", .advice = "std.lang.Optimize", .drop_in = true },
    .{ .path = "builtin", .advice = "std.lang", .drop_in = true },
    .{ .path = "mem.trimLeft", .advice = "std.mem.trimStart", .removed = true, .drop_in = true },
    .{ .path = "mem.trimRight", .advice = "std.mem.trimEnd", .removed = true, .drop_in = true },
    .{ .path = "mem.tokenize", .advice = "std.mem.tokenizeAny", .removed = true, .drop_in = true },
    .{ .path = "mem.split", .advice = "std.mem.splitSequence", .removed = true, .drop_in = true },
    .{ .path = "mem.splitBackwards", .advice = "std.mem.splitBackwardsSequence", .removed = true, .drop_in = true },
    .{ .path = "ChildProcess", .advice = "std.process.Child", .removed = true, .drop_in = true },
    .{ .path = "rand", .advice = "std.Random", .removed = true, .drop_in = true },
    .{ .path = "mem.copy", .advice = "@memcpy for distinct buffers or @memmove", .removed = true },
    .{ .path = "mem.set", .advice = "@memset", .removed = true },
    .{ .path = "io.getStdOut", .advice = "std.Io.File.stdout()", .removed = true },
    .{ .path = "io.getStdIn", .advice = "std.Io.File.stdin()", .removed = true },
    .{ .path = "io.getStdErr", .advice = "std.Io.File.stderr()", .removed = true },
    .{ .path = "time.sleep", .advice = "std.Io.sleep with an Io instance and clock", .removed = true },
    .{ .path = "BoundedArray", .advice = "std.ArrayList.initBuffer over a caller-owned buffer", .removed = true },
    .{ .path = "fifo.LinearFifo", .advice = "std.Io.Reader/std.Io.Writer buffering or an explicit ring buffer", .removed = true },
    .{ .path = "math.min", .advice = "@min", .removed = true },
    .{ .path = "math.max", .advice = "@max", .removed = true },
    .{ .path = "math.absInt", .advice = "@abs", .removed = true },
    .{ .path = "math.fabs", .advice = "@abs", .removed = true },
};

fn findDeprecatedStdlib(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_deprecated_stdlib);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (!isStdRoot(context, scopes, index)) continue;
        for (&stdlib_replacements) |entry| {
            const path_end = matchedStdPathEnd(context, index, entry.path) orelse continue;
            var fixes: []const types.Fix = &.{};
            if (entry.drop_in) {
                const edits = try context.allocator.alloc(types.Edit, 1);
                edits[0] = .{
                    .span = .{ .start = context.tokens[index + 2].loc.start, .end = context.tokens[path_end].loc.end },
                    .replacement = entry.advice["std.".len..],
                };
                const drop_in_fixes = try context.allocator.alloc(types.Fix, 1);
                drop_in_fixes[0] = .{
                    .title = try context.allocator.print("Replace with {s}", .{entry.advice}),
                    .kind = .quickfix,
                    .edits = edits,
                    .preferred = true,
                    .fix_all = true,
                };
                fixes = drop_in_fixes;
            }
            try context.emit(.{
                .rule = .modernize_deprecated_stdlib,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[path_end].loc.end },
                .message = try context.allocator.print("std.{s} {s}; use {s}", .{
                    entry.path,
                    if (entry.removed) "was removed from the standard library" else "is deprecated",
                    entry.advice,
                }),
                .fixes = fixes,
            });
            break;
        }
    }
    try findLegacyReflection(context, scopes, level);
    try findLegacyAllocatorDupe(context, scopes, level);
    try findRuntimeSafety(context, scopes, level);
}

fn findRuntimeSafety(context: RuleRun, scopes: *const syntax_scope.Index, level: types.Level) !void {
    for (context.tokens, 0..) |token, index| {
        if (index > 0 and context.tokens[index - 1].tag == .period) continue;
        const end = simplePathEnd(context, scopes, index) orelse continue;
        if (end <= index or !context.tokenIs(end, "runtime_safety") or
            !provenStdPath(context, scopes, index, end, "debug.runtime_safety", 0)) continue;
        try context.emit(.{
            .rule = .modernize_deprecated_stdlib,
            .level = level,
            .span = .{ .start = token.loc.start, .end = context.tokens[end].loc.end },
            .message = "std.debug.runtime_safety is deprecated; use @import(\"builtin\").mode.runtimeSafety() to query the caller's module rather than std's module",
        });
    }
}

fn findLegacyReflection(context: RuleRun, scopes: *const syntax_scope.Index, level: types.Level) !void {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .builtin or !context.tokenIs(index, "@typeInfo") or
            index + 1 >= context.tokens.len or context.tokens[index + 1].tag != .l_paren) continue;
        const closing = scopes.matchingToken(index + 1) orelse continue;
        if (closing + 4 >= context.tokens.len or context.tokens[closing + 1].tag != .period or
            context.tokens[closing + 3].tag != .period or !context.tokenIs(closing + 4, "fields")) continue;
        const is_enum = context.tokenIs(closing + 2, "@\"enum\"");
        if (!is_enum and !context.tokenIs(closing + 2, "@\"struct\"") and
            !context.tokenIs(closing + 2, "@\"union\"")) continue;
        try context.emit(.{
            .rule = .modernize_deprecated_stdlib,
            .level = level,
            .span = .{ .start = token.loc.start, .end = context.tokens[closing + 4].loc.end },
            .message = if (is_enum)
                "@typeInfo enum fields changed in Zig 0.17; iterate field_names and field_values together instead of fields"
            else
                "@typeInfo struct and union fields changed in Zig 0.17; iterate field_names, field_types, and related arrays together instead of fields",
        });
    }
}

fn findLegacyAllocatorDupe(context: RuleRun, scopes: *const syntax_scope.Index, level: types.Level) !void {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or (index > 0 and context.tokens[index - 1].tag == .period) or
            index + 3 >= context.tokens.len or context.tokens[index + 1].tag != .period or
            !context.tokenIs(index + 2, "dupeZ") or context.tokens[index + 3].tag != .l_paren) continue;
        const binding = scopes.findBinding(index) orelse continue;
        const declaration = binding.token_index;
        if (declaration + 2 >= context.tokens.len or context.tokens[declaration + 1].tag != .colon) continue;
        const root = declaration + 2;
        const std_binding = scopes.findBinding(root) orelse continue;
        if (!isModuleImport(context, std_binding.token_index, "\"std\"") or
            matchedStdPathEnd(context, root, "mem.Allocator") == null or root + 5 >= context.tokens.len or
            switch (context.tokens[root + 5].tag) {
                .comma, .r_paren, .equal => false,
                else => true,
            }) continue;
        try context.emit(.{
            .rule = .modernize_deprecated_stdlib,
            .level = level,
            .span = .{ .start = token.loc.start, .end = context.tokens[index + 2].loc.end },
            .message = "Allocator.dupeZ was removed in Zig 0.17; use dupeSentinel with an explicit 0 sentinel",
        });
    }
}

/// Matches every dot-separated segment of the path as whole member tokens
/// after the `std` root, so 'mem.indexOf' matches neither 'mem.indexOfPos'
/// nor 'memx.indexOf'.
fn matchedStdPathEnd(context: RuleRun, std_index: usize, path: []const u8) ?usize {
    var cursor = std_index;
    var remaining = path;
    while (remaining.len != 0) {
        const segment_end = std.mem.findScalar(u8, remaining, '.') orelse remaining.len;
        if (cursor + 2 >= context.tokens.len or context.tokens[cursor + 1].tag != .period or
            context.tokens[cursor + 2].tag != .identifier or
            !context.tokenIs(cursor + 2, remaining[0..segment_end])) return null;
        cursor += 2;
        remaining = remaining[if (segment_end == remaining.len) remaining.len else segment_end + 1..];
    }
    return cursor;
}

fn findManagedContainers(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_managed_container);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (!isStdRoot(context, scopes, index)) continue;
        const paths = [_][]const u8{ "array_list.Managed", "array_list.AlignedManaged", "bit_set.DynamicManaged" };
        for (paths) |path| {
            const end = matchedStdPathEnd(context, index, path) orelse continue;
            try context.emit(.{
                .rule = .modernize_managed_container,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[end].loc.end },
                .message = try context.allocator.print("std.{s} stores its allocator and is deprecated; use the unmanaged container and pass the allocator to allocating calls", .{path}),
            });
        }
    }
}

fn findDeprecatedIo(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_deprecated_io);
    if (level == .off) return;
    const adapters = [_]struct { old: []const u8, replacement: []const u8 }{
        .{ .old = "GenericReader", .replacement = "std.Io.Reader" },
        .{ .old = "GenericWriter", .replacement = "std.Io.Writer" },
        .{ .old = "AnyReader", .replacement = "std.Io.Reader" },
        .{ .old = "AnyWriter", .replacement = "std.Io.Writer" },
        .{ .old = "BufferedWriter", .replacement = "std.Io.Writer" },
        .{ .old = "bufferedWriter", .replacement = "std.Io.Writer.Allocating or a caller-owned buffer" },
        .{ .old = "bufferedReader", .replacement = "std.Io.Reader with caller-owned buffering" },
    };
    for (context.tokens, 0..) |token, index| {
        if (!isStdRoot(context, scopes, index)) continue;
        if (index + 4 >= context.tokens.len or context.tokens[index + 1].tag != .period or
            (!context.tokenIs(index + 2, "io") and !context.tokenIs(index + 2, "Io")) or
            context.tokens[index + 3].tag != .period) continue;
        for (adapters) |adapter| {
            if (!context.tokenIs(index + 4, adapter.old)) continue;
            try context.emit(.{
                .rule = .modernize_deprecated_io,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[index + 4].loc.end },
                .message = try context.allocator.print("std I/O adapter '{s}' belongs to the pre-std.Io interface; migrate this use to {s}", .{ adapter.old, adapter.replacement }),
            });
        }
    }
}

fn isStdRoot(context: RuleRun, scopes: *const syntax_scope.Index, index: usize) bool {
    if (!context.refersToBinding(index, "std")) return false;
    // Preserve support for incomplete snippets while rejecting a declared local
    // object called `std`, including parameters that shadow the import.
    const binding = scopes.findBinding(index) orelse return true;
    return isModuleImport(context, binding.token_index, "\"std\"");
}

fn isModuleImport(context: RuleRun, declaration: usize, module_literal: []const u8) bool {
    return declaration > 0 and context.tokens[declaration - 1].tag == .keyword_const and
        declaration + 5 < context.tokens.len and context.tokens[declaration + 1].tag == .equal and
        context.tokenIs(declaration + 2, "@import") and context.tokens[declaration + 3].tag == .l_paren and
        context.tokens[declaration + 4].tag == .string_literal and context.tokenIs(declaration + 4, module_literal) and
        context.tokens[declaration + 5].tag == .r_paren and
        declaration + 6 < context.tokens.len and context.tokens[declaration + 6].tag == .semicolon;
}

fn replacementFix(context: RuleRun, span: std.zig.Token.Loc, replacement: []const u8) ![]const types.Fix {
    const edits = try context.allocator.alloc(types.Edit, 1);
    edits[0] = .{ .span = span, .replacement = replacement };
    const fixes = try context.allocator.alloc(types.Fix, 1);
    fixes[0] = .{
        .title = if (replacement.len == 0) "Use {} instead of void{}" else try context.allocator.print("Replace with {s}", .{replacement}),
        .kind = .quickfix,
        .edits = edits,
        .preferred = true,
        .fix_all = true,
    };
    return fixes;
}

fn findDeprecatedBuiltins(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_deprecated_builtin);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag == .builtin and context.tokenIs(index, "@intFromEnum")) {
            try context.emit(.{
                .rule = .modernize_deprecated_builtin,
                .level = level,
                .span = token.loc,
                .message = "@intFromEnum is deprecated in Zig 0.17; use @backingInt",
                .fixes = try replacementFix(context, token.loc, "@backingInt"),
            });
        } else if (token.tag == .builtin and context.tokenIs(index, "@enumFromInt")) {
            try context.emit(.{
                .rule = .modernize_deprecated_builtin,
                .level = level,
                .span = token.loc,
                .message = "@enumFromInt is deprecated in Zig 0.17; use @fromBackingInt and cast the argument to the exact backing integer type with @intCast when needed",
            });
        }
        const member_index: usize = if (token.tag == .builtin and context.tokenIs(index, "@import") and
            index + 5 < context.tokens.len and context.tokens[index + 1].tag == .l_paren and
            context.tokenIs(index + 2, "\"builtin\"") and context.tokens[index + 3].tag == .r_paren and
            context.tokens[index + 4].tag == .period)
            index + 5
        else if (token.tag == .identifier and (index == 0 or context.tokens[index - 1].tag != .period) and
            index + 2 < context.tokens.len and context.tokens[index + 1].tag == .period)
        member: {
            const binding = scopes.findBinding(index) orelse continue;
            if (!isModuleImport(context, binding.token_index, "\"builtin\"")) continue;
            break :member index + 2;
        } else continue;
        const replacements = [_]struct { old: []const u8, replacement: []const u8 }{
            .{ .old = "cpu", .replacement = "target.cpu" },
            .{ .old = "os", .replacement = "target.os" },
            .{ .old = "abi", .replacement = "target.abi" },
            .{ .old = "object_format", .replacement = "target.ofmt" },
        };
        for (replacements) |entry| {
            if (!context.tokenIs(member_index, entry.old)) continue;
            try context.emit(.{
                .rule = .modernize_deprecated_builtin,
                .level = level,
                .span = .{ .start = token.loc.start, .end = context.tokens[member_index].loc.end },
                .message = try context.allocator.print("@import(\"builtin\").{s} is deprecated in Zig 0.17; use {s} on the same import", .{ entry.old, entry.replacement }),
                .fixes = try replacementFix(context, context.tokens[member_index].loc, entry.replacement),
            });
        }
    }
}

fn findRemovedSyntax(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_removed_syntax);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        var end = token.loc.end;
        var fixes: []const types.Fix = &.{};
        const message: []const u8 = if (token.tag == .builtin and context.tokenIs(index, "@cImport"))
            "@cImport was removed in Zig 0.17; use the official translate-c package in build.zig and import its generated module"
        else if (token.tag == .keyword_errdefer and index + 3 < context.tokens.len and
            context.tokens[index + 1].tag == .pipe and context.tokens[index + 2].tag == .identifier and
            context.tokens[index + 3].tag == .pipe)
        capture: {
            end = context.tokens[index + 3].loc.end;
            break :capture "errdefer error captures were removed in Zig 0.17; move error-dependent handling to a catch at the caller or a wrapper function";
        } else if (context.refersToBinding(index, "void") and index + 2 < context.tokens.len and
            context.tokens[index + 1].tag == .l_brace and context.tokens[index + 2].tag == .r_brace and
            scopes.findBinding(index) == null)
        literal: {
            end = context.tokens[index + 2].loc.end;
            fixes = try replacementFix(context, token.loc, "");
            break :literal "void{} was removed in Zig 0.17; use {}";
        } else if (context.refersToBinding(index, "i0") and scopes.findBinding(index) == null and
            (index == 0 or (context.tokens[index - 1].tag != .keyword_const and
                context.tokens[index - 1].tag != .keyword_var and context.tokens[index - 1].tag != .keyword_fn)) and
            (index + 1 >= context.tokens.len or context.tokens[index + 1].tag != .colon))
            "the i0 primitive type was removed in Zig 0.17; review whether u0 is the intended zero-bit type"
        else if (token.tag == .asterisk and index > 0 and index + 1 < context.tokens.len and
            context.tokens[index + 1].tag == .asterisk and token.loc.end == context.tokens[index + 1].loc.start and
            arrayMultiplicationOperand(context, scopes, index - 1))
        repeat: {
            end = context.tokens[index + 1].loc.end;
            break :repeat "array multiplication (**) was removed in Zig 0.17; use typed @splat for single-element repetition or an explicit initializer or loop for larger patterns";
        } else continue;
        try context.emit(.{
            .rule = .modernize_removed_syntax,
            .level = level,
            .span = .{ .start = token.loc.start, .end = end },
            .message = message,
            .fixes = fixes,
        });
    }
}

fn arrayMultiplicationOperand(context: RuleRun, scopes: *const syntax_scope.Index, index: usize) bool {
    return switch (context.tokens[index].tag) {
        .r_brace, .string_literal => true,
        .identifier => expressionHasSequenceType(context, scopes, index) or stringBinding(context, scopes, index),
        .r_paren => parenthesized: {
            const opening = scopes.matchingToken(index) orelse break :parenthesized false;
            if (opening > 0 and context.tokenIs(opening - 1, "@as")) {
                break :parenthesized isSequenceType(context, scopes, opening + 1);
            }
            break :parenthesized expressionHasSequenceType(context, scopes, opening + 1) or
                context.tokens[opening + 1].tag == .string_literal;
        },
        else => false,
    };
}

fn stringBinding(context: RuleRun, scopes: *const syntax_scope.Index, index: usize) bool {
    const binding = scopes.findBinding(index) orelse return false;
    const declaration = binding.token_index;
    return declaration + 2 < context.tokens.len and context.tokens[declaration + 1].tag == .equal and
        context.tokens[declaration + 2].tag == .string_literal and
        scopes.statementEnd(declaration) == declaration + 3;
}

fn findBuildApi(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_build_api);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or (index > 0 and context.tokens[index - 1].tag == .period) or
            index + 2 >= context.tokens.len or context.tokens[index + 1].tag != .period) continue;
        const is_args = context.tokenIs(index + 2, "args");
        const is_translate = context.tokenIs(index + 2, "addTranslateC");
        const is_resource = context.tokenIs(index + 2, "addWin32ResourceFile");
        const is_basename = context.tokenIs(index + 2, "basename");
        const is_root_resource = index + 4 < context.tokens.len and
            context.tokenIs(index + 2, "root_module") and context.tokens[index + 3].tag == .period and
            context.tokenIs(index + 4, "addWin32ResourceFile");
        const is_lazy_dependency = context.tokenIs(index + 2, "lazyDependency");
        const is_find_program = context.tokenIs(index + 2, "findProgram");
        const run_argument = runArgumentReplacement(context, index + 2);
        if (!is_args and !is_translate and !is_resource and !is_basename and !is_root_resource and
            !is_lazy_dependency and !is_find_program and run_argument == null) continue;
        const receiver_kind = buildReceiverKind(context, scopes, index, 0) orelse continue;
        if ((is_args or is_translate or is_lazy_dependency or is_find_program) and receiver_kind != .build) continue;
        if (is_resource and receiver_kind != .module) continue;
        if (is_root_resource and receiver_kind != .compile_step) continue;
        if (is_basename and receiver_kind != .lazy_path) continue;
        if (run_argument != null and receiver_kind != .run_step) continue;
        const member_index = index + @as(usize, if (is_root_resource) 4 else 2);
        if (!is_args and (member_index + 1 >= context.tokens.len or context.tokens[member_index + 1].tag != .l_paren)) continue;
        if (is_find_program and callArgumentCount(context, scopes, member_index + 1) != 2) continue;
        if (run_argument) |entry| {
            try emitRunArgument(context, scopes, level, index, member_index, entry);
            continue;
        }
        try context.emit(.{
            .rule = .modernize_build_api,
            .level = level,
            .span = .{ .start = token.loc.start, .end = context.tokens[member_index].loc.end },
            .message = if (is_args)
                "std.Build.args was removed in Zig 0.17; call addPassthruArgs() on the Run step, since configure-time code can no longer observe passthru arguments"
            else if (is_translate)
                "std.Build.addTranslateC uses the deprecated TranslateC step; add the official translate-c package and use its Translator API"
            else if (is_basename)
                "std.Build.LazyPath.basename was removed; lazy path names are unavailable during configuration, so resolve them in a make step"
            else if (is_lazy_dependency)
                "std.Build.lazyDependency is deprecated; use dependencyLazy and propagate error.LazyDependencyNeeded to build(), replacing optional handling with error-union handling"
            else if (is_find_program)
                "std.Build.findProgram now takes a .{ .names = ... } options struct and returns an optional; review old search-path handling, or use findProgramLazy when configure-time lookup is unnecessary to avoid poisoning the configuration cache"
            else
                "std.Build.Module.addWin32ResourceFile is deprecated in Zig 0.17; plan migration to the external Windows resource package before Zig 0.18",
        });
    }
}

const RunArgumentReplacement = struct {
    old: []const u8,
    new: []const u8,
    plain: bool = true,
};

// The plain wrappers pass their argument and .{} straight through in Zig 0.17.
// Prefix/decorated wrappers reorder arguments; those migrations need review.
const run_argument_replacements = [_]RunArgumentReplacement{
    .{ .old = "addArtifactArg", .new = "addArtifactArg2" },
    .{ .old = "addFileArg", .new = "addFileArg2" },
    .{ .old = "addOutputFileArg", .new = "addOutputFileArg2" },
    .{ .old = "addFileContentArg", .new = "addFileContentArg2" },
    .{ .old = "addOutputDirectoryArg", .new = "addOutputDirectoryArg2" },
    .{ .old = "addDirectoryArg", .new = "addDirectoryArg2" },
    .{ .old = "addDepFileOutputArg", .new = "addDepFileOutputArg2" },
    .{ .old = "addPrefixedArtifactArg", .new = "addArtifactArg2", .plain = false },
    .{ .old = "addPrefixedFileArg", .new = "addFileArg2", .plain = false },
    .{ .old = "addPrefixedOutputFileArg", .new = "addOutputFileArg2", .plain = false },
    .{ .old = "addPrefixedFileContentArg", .new = "addFileContentArg2", .plain = false },
    .{ .old = "addPrefixedOutputDirectoryArg", .new = "addOutputDirectoryArg2", .plain = false },
    .{ .old = "addPrefixedDirectoryArg", .new = "addDirectoryArg2", .plain = false },
    .{ .old = "addPrefixedDepFileOutputArg", .new = "addDepFileOutputArg2", .plain = false },
    .{ .old = "addDecoratedDirectoryArg", .new = "addDirectoryArg2", .plain = false },
};

fn runArgumentReplacement(context: RuleRun, member: usize) ?RunArgumentReplacement {
    for (run_argument_replacements) |entry| if (context.tokenIs(member, entry.old)) return entry;
    return null;
}

fn emitRunArgument(context: RuleRun, scopes: *const syntax_scope.Index, level: types.Level, receiver: usize, member: usize, entry: RunArgumentReplacement) !void {
    var fixes: []const types.Fix = &.{};
    const opening = member + 1;
    if (entry.plain and callArgumentCount(context, scopes, opening) == 1) {
        const closing = scopes.matchingToken(opening).?;
        // Insert before an existing trailing comma, or after the argument's
        // last token. All original whitespace, comments and expressions stay.
        const insertion = if (context.tokens[closing - 1].tag == .comma)
            context.tokens[closing - 1].loc.start
        else
            context.tokens[closing - 1].loc.end;
        const edits = try context.allocator.alloc(types.Edit, 2);
        edits[0] = .{ .span = context.tokens[member].loc, .replacement = entry.new };
        edits[1] = .{ .span = .{ .start = insertion, .end = insertion }, .replacement = ", .{}" };
        const new_fixes = try context.allocator.alloc(types.Fix, 1);
        new_fixes[0] = .{
            .title = "Use Run argument options",
            .kind = .quickfix,
            .edits = edits,
            .preferred = true,
            .fix_all = true,
        };
        fixes = new_fixes;
    }
    try context.emit(.{
        .rule = .modernize_build_api,
        .level = level,
        .span = .{ .start = context.tokens[receiver].loc.start, .end = context.tokens[member].loc.end },
        .message = if (entry.plain)
            try context.allocator.print("std.Build.Step.Run.{s} is a legacy argument wrapper; use {s} with .{{}} options", .{ entry.old, entry.new })
        else
            try context.allocator.print("std.Build.Step.Run.{s} is a legacy argument wrapper; use {s} with prefix/suffix options and review argument evaluation order", .{ entry.old, entry.new }),
        .fixes = fixes,
    });
}

fn callArgumentCount(context: RuleRun, scopes: *const syntax_scope.Index, opening: usize) ?usize {
    const closing = scopes.matchingToken(opening) orelse return null;
    var count: usize = 0;
    var cursor = opening + 1;
    var argument_start = cursor;
    while (cursor < closing) : (cursor += 1) {
        switch (context.tokens[cursor].tag) {
            .l_paren, .l_brace, .l_bracket => {
                cursor = scopes.matchingToken(cursor) orelse return null;
                if (cursor >= closing) return null;
            },
            .comma => {
                if (cursor == argument_start) return null;
                count += 1;
                argument_start = cursor + 1;
            },
            else => {},
        }
    }
    return count + @as(usize, if (argument_start < closing) 1 else 0);
}

const BuildReceiverKind = enum { build, module, lazy_path, compile_step, run_step };

fn buildReceiverKind(context: RuleRun, scopes: *const syntax_scope.Index, index: usize, depth: usize) ?BuildReceiverKind {
    if (depth == 6) return null;
    const binding = scopes.findBinding(index) orelse return null;
    const declaration = binding.token_index;
    if (declaration + 2 >= context.tokens.len) return null;
    if (context.tokens[declaration + 1].tag == .colon) {
        var root_index = declaration + 2;
        if (context.tokens[root_index].tag == .asterisk) root_index += 1;
        if (root_index < context.tokens.len and context.tokens[root_index].tag == .keyword_const) root_index += 1;
        if (root_index >= context.tokens.len) return null;
        const path_end = simplePathEnd(context, scopes, root_index) orelse return null;
        if (path_end + 1 >= context.tokens.len) return null;
        switch (context.tokens[path_end + 1].tag) {
            .comma, .r_paren, .equal, .semicolon => {},
            else => return null,
        }
        const paths = [_]struct { path: []const u8, kind: BuildReceiverKind }{
            .{ .path = "Build.Step.Run", .kind = .run_step },
            .{ .path = "Build.Step.Compile", .kind = .compile_step },
            .{ .path = "Build.LazyPath", .kind = .lazy_path },
            .{ .path = "Build.Module", .kind = .module },
            .{ .path = "Build", .kind = .build },
        };
        for (paths) |entry| {
            if (provenStdPath(context, scopes, root_index, path_end, entry.path, 0)) return entry.kind;
        }
        return null;
    }
    if (declaration == 0 or context.tokens[declaration - 1].tag != .keyword_const or
        context.tokens[declaration + 1].tag != .equal) return null;
    const initializer = declaration + 2;
    const end = scopes.statementEnd(declaration) orelse return null;
    if (end == initializer + 1 and context.tokens[initializer].tag == .identifier) {
        return buildReceiverKind(context, scopes, initializer, depth + 1);
    }
    const method = simplePathEnd(context, scopes, initializer) orelse return null;
    if (method <= initializer or method + 1 >= context.tokens.len or context.tokens[method + 1].tag != .l_paren) return null;
    const closing = scopes.matchingToken(method + 1) orelse return null;
    if (closing + 1 != end) return null;
    if (context.tokenIs(method, "create") and provenStdPath(context, scopes, initializer, method - 2, "Build.Step.Run", 0)) return .run_step;
    if (method != initializer + 2 or buildReceiverKind(context, scopes, initializer, depth + 1) != .build) return null;
    if (context.tokenIs(method, "createModule") or context.tokenIs(method, "addModule")) return .module;
    const run_factories = [_][]const u8{ "addSystemCommand", "addRunArtifact", "addRunFile" };
    for (run_factories) |factory| if (context.tokenIs(method, factory)) return .run_step;
    const factories = [_][]const u8{ "addExecutable", "addLibrary", "addObject", "addTest", "addSharedLibrary", "addStaticLibrary" };
    for (factories) |factory| if (context.tokenIs(method, factory)) return .compile_step;
    return null;
}

/// A dotted identifier path, optionally rooted in a direct @import("std").
fn simplePathEnd(context: RuleRun, scopes: *const syntax_scope.Index, start: usize) ?usize {
    if (start >= context.tokens.len) return null;
    var end = start;
    if (context.tokens[start].tag == .builtin and context.tokenIs(start, "@import") and
        start + 1 < context.tokens.len and context.tokens[start + 1].tag == .l_paren)
    {
        end = scopes.matchingToken(start + 1) orelse return null;
        if (end != start + 3 or !context.tokenIs(start + 2, "\"std\"")) return null;
    } else if (context.tokens[start].tag != .identifier) return null;
    while (end + 2 < context.tokens.len and context.tokens[end + 1].tag == .period and
        context.tokens[end + 2].tag == .identifier) end += 2;
    return end;
}

/// Resolve immutable namespace aliases without accepting custom or mutable
/// namespaces that merely spell the same type/member names.
fn provenStdPath(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize, expected: []const u8, depth: usize) bool {
    if (depth == 8 or start > end) return false;
    var cursor = end;
    var remaining = expected;
    while (cursor >= start + 2 and context.tokens[cursor - 1].tag == .period) {
        const separator = std.mem.findScalarLast(u8, remaining, '.');
        const member = if (separator) |at| remaining[at + 1 ..] else remaining;
        if (!context.tokenIs(cursor, member)) return false;
        remaining = if (separator) |at| remaining[0..at] else "";
        cursor -= 2;
    }
    if (context.tokens[start].tag == .builtin) return remaining.len == 0 and cursor == start + 3 and
        context.tokenIs(start, "@import") and context.tokens[start + 1].tag == .l_paren and
        context.tokenIs(start + 2, "\"std\"") and context.tokens[cursor].tag == .r_paren;
    if (cursor != start or context.tokens[start].tag != .identifier) return false;
    const binding = scopes.findBinding(start) orelse return false;
    const declaration = binding.token_index;
    if (declaration == 0 or declaration + 2 >= context.tokens.len or
        context.tokens[declaration - 1].tag != .keyword_const or context.tokens[declaration + 1].tag != .equal) return false;
    const initializer = declaration + 2;
    const initializer_end = simplePathEnd(context, scopes, initializer) orelse return false;
    if (scopes.statementEnd(declaration) != initializer_end + 1) return false;
    return provenStdPath(context, scopes, initializer, initializer_end, remaining, depth + 1);
}

fn findBitcastChanges(context: RuleRun, scopes: *const syntax_scope.Index) !void {
    const level = context.level(.modernize_bitcast);
    if (level == .off) return;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .builtin or !context.tokenIs(index, "@bitCast") or
            index + 2 >= context.tokens.len or context.tokens[index + 1].tag != .l_paren) continue;
        const argument = index + 2;
        const closing = scopes.matchingToken(index + 1) orelse continue;
        const argument_end = if (closing > argument and context.tokens[closing - 1].tag == .comma)
            closing - 1
        else
            closing;
        const source_is_sequence = completeSequenceExpression(context, scopes, argument, argument_end);
        const destination_is_sequence = destinationHasSequenceType(context, scopes, index);
        if (!source_is_sequence and !destination_is_sequence) continue;
        try context.emit(.{
            .rule = .modernize_bitcast,
            .level = level,
            .span = token.loc,
            .message = "@bitCast involving an array or vector uses an endian-independent logical bit representation in Zig 0.17; audit code that relied on native memory order, especially on big-endian targets",
        });
    }
}

fn completeSequenceExpression(context: RuleRun, scopes: *const syntax_scope.Index, start: usize, end: usize) bool {
    if (start >= end) return false;
    if (context.tokens[start].tag == .identifier) return end == start + 1 and
        expressionHasSequenceType(context, scopes, start);
    if (context.tokenIs(start, "@as") and start + 2 < end and context.tokens[start + 1].tag == .l_paren) {
        const closing = scopes.matchingToken(start + 1) orelse return false;
        return closing + 1 == end and isSequenceType(context, scopes, start + 2);
    }
    if (context.tokens[start].tag == .l_paren) {
        const closing = scopes.matchingToken(start) orelse return false;
        return closing + 1 == end and completeSequenceExpression(context, scopes, start + 1, closing);
    }
    if (!isSequenceType(context, scopes, start)) return false;
    var cursor = start;
    while (cursor < end) : (cursor += 1) {
        switch (context.tokens[cursor].tag) {
            .l_paren, .l_bracket => cursor = scopes.matchingToken(cursor) orelse return false,
            .l_brace => return (scopes.matchingToken(cursor) orelse return false) + 1 == end,
            else => {},
        }
    }
    return false;
}

fn isSequenceType(context: RuleRun, scopes: *const syntax_scope.Index, start: usize) bool {
    if (start >= context.tokens.len) return false;
    if (context.tokenIs(start, "@Vector") and start + 1 < context.tokens.len and
        context.tokens[start + 1].tag == .l_paren) return true;
    if (context.tokens[start].tag != .l_bracket or start + 1 >= context.tokens.len) return false;
    // Slices have no logical bit representation; a nonempty array length is
    // sufficient to distinguish [N]T from []T and sentinel slices [:S]T.
    const close = scopes.matchingToken(start) orelse return false;
    return close > start + 1 and context.tokens[start + 1].tag != .colon and
        context.tokens[start + 1].tag != .asterisk;
}

fn expressionHasSequenceType(context: RuleRun, scopes: *const syntax_scope.Index, index: usize) bool {
    if (index >= context.tokens.len or (index > 0 and context.tokens[index - 1].tag == .period)) return false;
    if (context.tokenIs(index, "@as") and index + 2 < context.tokens.len and
        context.tokens[index + 1].tag == .l_paren) return isSequenceType(context, scopes, index + 2);
    if (context.tokens[index].tag != .identifier) return false;
    const binding = scopes.findBinding(index) orelse return false;
    const declaration = binding.token_index;
    if (declaration + 2 >= context.tokens.len) return false;
    if (context.tokens[declaration + 1].tag == .colon) return isSequenceType(context, scopes, declaration + 2);
    if (context.tokens[declaration + 1].tag == .equal) {
        const initializer = declaration + 2;
        const end = scopes.statementEnd(declaration) orelse return false;
        // Restrict initializer inference to explicit array literals and @as
        // calls; an indexed or member-selected result can be a scalar.
        if (!isSequenceType(context, scopes, initializer) and !context.tokenIs(initializer, "@as")) return false;
        return completeSequenceExpression(context, scopes, initializer, end);
    }
    return false;
}

fn destinationHasSequenceType(context: RuleRun, scopes: *const syntax_scope.Index, index: usize) bool {
    if (index == 0) return false;
    // Explicit @as([N]T, @bitCast(...)) destinations.
    if (context.tokens[index - 1].tag == .comma) {
        var cursor = index - 1;
        while (cursor > 0) {
            cursor -= 1;
            if (context.tokens[cursor].tag == .r_paren or context.tokens[cursor].tag == .r_bracket) {
                cursor = scopes.matchingToken(cursor) orelse return false;
                continue;
            }
            if (context.tokens[cursor].tag == .l_paren) return cursor > 0 and
                context.tokenIs(cursor - 1, "@as") and isSequenceType(context, scopes, cursor + 1);
            if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
        }
    }
    if (context.tokens[index - 1].tag != .equal) return false;
    var cursor = index - 1;
    while (cursor > 0) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_const or context.tokens[cursor].tag == .keyword_var) {
            return cursor + 3 < index and context.tokens[cursor + 2].tag == .colon and
                isSequenceType(context, scopes, cursor + 3);
        }
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
    }
    return false;
}

test "modernize profile identifies managed containers and legacy IO adapters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const List = std.array_list.Managed(u8);\n" ++
        "const Writer = std.io.GenericWriter(Context, Error, write);\n";
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(types.Rule.modernize_managed_container)] = .information;
    configuration.levels[@backingInt(types.Rule.modernize_deprecated_io)] = .information;
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(arena.allocator(), token);
    }
    var found: std.ArrayList(types.Finding) = .empty;
    try run(.{ .allocator = arena.allocator(), .source = source, .tokens = tokens.items, .configuration = configuration, .findings = &found });
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
}

test "deprecated stdlib members name their replacement and carry drop-in fixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const at = std.mem.indexOfScalar(u8, name, '.');\n" ++
        "const trimmed = std.mem.trimLeft(u8, name, \" \");\n" ++
        "std.mem.copyForwards(u8, sink, filled);\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("std.mem.indexOfScalar is deprecated; use std.mem.findScalar", findings[0].message);
    try std.testing.expectEqualStrings("mem.findScalar", findings[0].fixes[0].edits[0].replacement);
    const fixed_span = findings[0].fixes[0].edits[0].span;
    try std.testing.expectEqualStrings("mem.indexOfScalar", source[fixed_span.start..fixed_span.end]);
    try std.testing.expect(findings[0].fixes[0].fix_all);
    try std.testing.expectEqualStrings("std.mem.trimLeft was removed from the standard library; use std.mem.trimStart", findings[1].message);
    try std.testing.expectEqualStrings("mem.trimStart", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("std.mem.copyForwards is deprecated; use @memmove", findings[2].message);
    try std.testing.expectEqual(@as(usize, 0), findings[2].fixes.len);
}

test "current stdlib members and non-std roots stay unreported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const at = std.mem.findScalar(u8, name, '.');\n" ++
        "const pieces = std.mem.splitScalar(u8, name, ' ');\n" ++
        "const words = std.mem.tokenizeScalar(u8, name, ' ');\n" ++
        "const local = mystd.mem.indexOf(u8, name, item);\n" ++
        "const nested = shim.std.mem.indexOf(u8, name, item);\n";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "deprecated stdlib diagnostics honor suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "// zig-analyzer: disable-next-line modernize-deprecated-stdlib\n" ++
        "const at = std.mem.indexOf(u8, name, item);";
    const findings = try findingsFor(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "drop-in stdlib advice stays rooted in std" {
    for (stdlib_replacements) |entry| {
        if (!entry.drop_in) continue;
        try std.testing.expect(std.mem.startsWith(u8, entry.advice, "std."));
    }
}

test "modernize 0.17 standard library fixes resolve to current declarations" {
    @setEvalBranchQuota(10_000);
    inline for (stdlib_replacements) |entry| {
        if (comptime !entry.drop_in) continue;
        comptime requireStdDeclaration(std, entry.advice["std.".len..]);
    }
}

fn requireStdDeclaration(comptime namespace: anytype, comptime path: []const u8) void {
    const segment_end = comptime std.mem.findScalar(u8, path, '.') orelse path.len;
    const member = @field(namespace, path[0..segment_end]);
    if (comptime segment_end != path.len) requireStdDeclaration(member, path[segment_end + 1 ..]);
}

test "modernize 0.17 distinguishes removed aliases and shape-changing replacements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Set = std.bit_set.IntegerBitSet(16);\n" ++
        "const Static = std.StaticBitSet(12);\n" ++
        "const at = std.ascii.indexOfIgnoreCase(text, key);\n" ++
        "const names = std.meta.fieldNames(Item);\n" ++
        "const Pool = std.heap.memory_pool.AlignedManaged(Item, .@\"8\");\n" ++
        "const printed = std.fmt.allocPrint(gpa, \"{d}\", .{1});\n" ++
        "const mode = std.builtin.OptimizeMode.ReleaseSafe;\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 7), findings.len);
    try std.testing.expectEqualStrings("bit_set.Integer", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("bit_set.Static", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expect(std.mem.find(u8, findings[2].message, "was removed") != null);
    try std.testing.expectEqual(@as(usize, 0), findings[3].fixes.len);
    try std.testing.expectEqual(@as(usize, 0), findings[4].fixes.len);
    try std.testing.expectEqual(@as(usize, 0), findings[5].fixes.len);
    try std.testing.expectEqualStrings("lang.Optimize.safe", findings[6].fixes[0].edits[0].replacement);
}

test "modernize path allocator renames combine namespace migration into one fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const a = std.fs.path.resolve(gpa, paths);\n" ++
        "const b = std.Io.Dir.path.relativePosix(gpa, from, to);\n" ++
        "const c = std.fs.path.resolvePosix(gpa, paths);\n" ++
        "const current = std.Io.Dir.path.relativeAlloc(gpa, from, to);\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    try std.testing.expectEqualStrings("Io.Dir.path.resolveAlloc", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("Io.Dir.path.relativeAllocPosix", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("Io.Dir.path.resolveAllocPosix", findings[2].fixes[0].edits[0].replacement);
}

test "modernize 0.17 stdlib migration includes reflection and typed allocator dupeZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn copy(gpa: std.mem.Allocator) void { _ = gpa.dupeZ(u8, text); }\n" ++
        "const fields = @typeInfo(Item).@\"struct\".fields;\n" ++
        "const union_fields = @typeInfo(Item).@\"union\".fields;\n" ++
        "const enum_fields = @typeInfo(Item).@\"enum\".fields;\n";
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    const current: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn copy(gpa: std.mem.Allocator) void { _ = gpa.dupeSentinel(u8, text, 0); }\n" ++
        "fn custom(gpa: Custom) void { _ = gpa.dupeZ(u8, text); }\n" ++
        "fn nested(gpa: std.mem.Allocator) void { { const gpa = Custom{}; _ = gpa.dupeZ(u8, text); } }\n" ++
        "const fields = @typeInfo(Item).@\"struct\".field_names;\n" ++
        "const pointers = @typeInfo(Ptr).pointer.fields;\n" ++
        "const custom_fields = item.@\"struct\".fields;\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), current)).len);
}

test "modernize adapters ignore nested std members and unrelated namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const List = wrapper.std.array_list.Managed(u8);\n" ++
        "const Writer = wrapper.std.io.GenericWriter(Context, Error, write);\n" ++
        "const Custom = std.other.GenericWriter;\n" ++
        "fn f(std: Custom) void { _ = std.mem.indexOf(u8, text, key); _ = std.io.GenericReader; _ = std.array_list.Managed; }\n";
    inline for (.{ types.Rule.modernize_managed_container, .modernize_deprecated_io, .modernize_deprecated_stdlib }) |rule| {
        try std.testing.expectEqual(@as(usize, 0), (try findingsForRule(arena.allocator(), source, rule)).len);
    }
}

test "modernize managed containers include aligned lists and dynamic bit sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const A = std.array_list.AlignedManaged(u8, null);\n" ++
        "const B = std.bit_set.DynamicManaged;\n" ++
        "const C = std.bit_set.Dynamic;\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_managed_container);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "modernize deprecated builtins rename only signature-identical conversions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const integer = @intFromEnum(tag);\n" ++
        "const value: Tag = @enumFromInt(raw);\n" ++
        "const current = @backingInt(tag);\n" ++
        "const text = \"@intFromEnum(tag)\";\n" ++
        "// @enumFromInt(raw)\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_deprecated_builtin);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expectEqualStrings("@backingInt", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expect(findings[0].fixes[0].fix_all);
    try std.testing.expectEqual(@as(usize, 0), findings[1].fixes.len);
    try std.testing.expect(std.mem.find(u8, findings[1].message, "@intCast") != null);
}

test "modernize builtin target aliases require the builtin import and honor shadowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const platform = @import(\"builtin\");\n" ++
        "const arch = platform.cpu.arch;\n" ++
        "const os = platform.os.tag;\n" ++
        "const abi = @import(\"builtin\").abi;\n" ++
        "const format = platform.object_format;\n" ++
        "const current = platform.target.cpu;\n" ++
        "fn f(platform: Custom) void { _ = platform.os; }\n" ++
        "const other = wrapper.platform.cpu;\n" ++
        "const custom = builtin.os;\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_deprecated_builtin);
    try std.testing.expectEqual(@as(usize, 4), findings.len);
    try std.testing.expectEqualStrings("target.cpu", findings[0].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("target.os", findings[1].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("target.abi", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("target.ofmt", findings[3].fixes[0].edits[0].replacement);
}

test "modernize removed syntax reports migration even for unparseable input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const c = @cImport({ @cInclude(\"header.h\"); });\n" ++
        "const repeated = [_]u8{0} ** 8;\n" ++
        "const v = void{};\n" ++
        "fn f() !void { errdefer |err| log(err); }\n" ++
        "const Zero = i0;\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_removed_syntax);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    try std.testing.expectEqualStrings("**", source[findings[1].span.start..findings[1].span.end]);
    try std.testing.expectEqualStrings("void{}", source[findings[2].span.start..findings[2].span.end]);
    try std.testing.expectEqualStrings("", findings[2].fixes[0].edits[0].replacement);
    try std.testing.expectEqualStrings("errdefer |err|", source[findings[3].span.start..findings[3].span.end]);
    try std.testing.expectEqual(@as(usize, 0), findings[4].fixes.len);
}

test "modernize array multiplication proves operands and skips pointer types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const seed: [1]u8 = .{0};\n" ++
        "const repeated = seed ** 4;\n" ++
        "const text = \"a\" ** 4;\n" ++
        "const Pointer = **u8;\n" ++
        "const Aligned = *align(@alignOf(u8)) **u8;\n" ++
        "const pointer: []**u8 = undefined;\n" ++
        "const current: [4]u8 = @splat(0);\n" ++
        "fn f(i0: u8) void { _ = i0; _ = object.i0; errdefer cleanup(); }\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_removed_syntax);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
}

test "modernize build API requires a scoped std Build receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "pub fn build(b: *std.Build) void {\n" ++
        "    if (b.args) |args| run_cmd.addArgs(args);\n" ++
        "    _ = b.addTranslateC(.{});\n" ++
        "    { const b = Custom{}; _ = b.args; _ = b.addTranslateC(.{}); }\n" ++
        "    _ = wrapper.b.args;\n" ++
        "}\n" ++
        "fn other(b: *Custom) void { _ = b.args; _ = b.addTranslateC(.{}); }\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize build API proves module factory and compile root module receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const library = @import(\"std\");\n" ++
        "fn build(b: *library.Build, module: *library.Build.Module, exe: *library.Build.Step.Compile, path: library.Build.LazyPath) void {\n" ++
        "    module.addWin32ResourceFile(.{});\n" ++
        "    exe.root_module.addWin32ResourceFile(.{});\n" ++
        "    _ = path.basename();\n" ++
        "    const created = b.createModule(.{});\n" ++
        "    const alias = created;\n" ++
        "    alias.addWin32ResourceFile(.{});\n" ++
        "    const executable = b.addExecutable(.{});\n" ++
        "    executable.root_module.addWin32ResourceFile(.{});\n" ++
        "    { const created = Custom{}; created.addWin32ResourceFile(.{}); }\n" ++
        "}\n" ++
        "fn custom(module: *Custom, exe: *Custom, path: Custom) void {\n" ++
        "    module.addWin32ResourceFile(.{}); exe.root_module.addWin32ResourceFile(.{}); _ = path.basename();\n" ++
        "}\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize build API leaves shadowed imports and unknown factory results alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn build(b: *std.Build) void {\n" ++
        "    const unknown = b.customFactory(.{}); unknown.addWin32ResourceFile(.{});\n" ++
        "    const list = b.createModule(.{}).items; list.addWin32ResourceFile(.{});\n" ++
        "    var mutable = b.createModule(.{}); mutable.addWin32ResourceFile(.{});\n" ++
        "}\n" ++
        "fn other(std: Custom, module: *std.Build.Module) void { module.addWin32ResourceFile(.{}); }\n" ++
        "comptime { var library = @import(\"std\"); library = Custom;\n" ++
        "    const module: *library.Build.Module = undefined; module.addWin32ResourceFile(.{}); }\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "modernize Run argument wrappers offer fixes only without argument reordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const library = @import("std");
        \\fn configure(run: *library.Build.Step.Run, artifact: *library.Build.Step.Compile, path: library.Build.LazyPath) void {
        \\    run.addArtifactArg(artifact);
        \\    run.addFileArg(path);
        \\    _ = run.addOutputFileArg("out");
        \\    run.addFileContentArg(path);
        \\    _ = run.addOutputDirectoryArg("dir");
        \\    run.addDirectoryArg(path);
        \\    _ = run.addDepFileOutputArg("deps");
        \\    run.addPrefixedArtifactArg("--artifact=", artifact);
        \\    run.addPrefixedFileArg("--file=", path);
        \\    _ = run.addPrefixedOutputFileArg("--out=", "out");
        \\    run.addPrefixedFileContentArg("--content=", path);
        \\    _ = run.addPrefixedOutputDirectoryArg("--dir=", "dir");
        \\    run.addPrefixedDirectoryArg("--dir=", path);
        \\    _ = run.addPrefixedDepFileOutputArg("--deps=", "deps");
        \\    run.addDecoratedDirectoryArg("--dir=", path, "/tail");
        \\    run.addFileArg2(path, .{});
        \\    run.addArg("plain");
        \\}
    ;
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(run_argument_replacements.len, findings.len);
    for (findings, run_argument_replacements) |finding, entry| {
        try std.testing.expect(std.mem.containsAtLeast(u8, finding.message, 1, entry.new));
        try std.testing.expectEqual(@as(usize, if (entry.plain) 1 else 0), finding.fixes.len);
        if (entry.plain) {
            try std.testing.expectEqualStrings(entry.new, finding.fixes[0].edits[0].replacement);
            try std.testing.expect(finding.fixes[0].fix_all);
        } else {
            try std.testing.expect(std.mem.containsAtLeast(u8, finding.message, 1, "evaluation order"));
        }
    }
}

test "modernize Run argument fixes preserve expressions comments and trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn configure(run: *std.Build.Step.Run) void {
        \\    run.addFileArg(nextPath(.{ .a = 1, .b = 2 }) // keep argument comment
        \\    );
        \\    run.addDirectoryArg(
        \\        paths[index(1, 2)], // keep trailing comma comment
        \\    );
        \\    _ = run.addOutputFileArg("out" // keep comment before comma
        \\        ,
        \\    );
        \\}
    ;
    const expected =
        \\const std = @import("std");
        \\fn configure(run: *std.Build.Step.Run) void {
        \\    run.addFileArg2(nextPath(.{ .a = 1, .b = 2 }), .{} // keep argument comment
        \\    );
        \\    run.addDirectoryArg2(
        \\        paths[index(1, 2)], .{}, // keep trailing comma comment
        \\    );
        \\    _ = run.addOutputFileArg2("out" // keep comment before comma
        \\        , .{},
        \\    );
        \\}
    ;
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    const fixed = try arena.allocator().dupeSentinel(u8, try applyFindingFixes(arena.allocator(), source, findings), 0);
    try std.testing.expectEqualStrings(expected, fixed);
    var tree = try std.zig.Ast.parse(arena.allocator(), fixed, .{});
    defer tree.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "modernize Build receivers prove immutable namespace aliases and Run factories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const library = @import("std");
        \\const Build = library.Build;
        \\const Step = Build.Step;
        \\const Run = Step.Run;
        \\const OtherRun = @import("std").Build.Step.Run;
        \\fn configure(b: *Build, run: *const Run, direct: *@import("std").Build.Step.Run, other: *OtherRun) void {
        \\    run.addFileArg(path);
        \\    direct.addFileArg(path);
        \\    other.addFileArg(path);
        \\    const command = b.addSystemCommand(&.{"tool"});
        \\    const alias = command;
        \\    alias.addFileArg(path);
        \\    const artifact = b.addRunArtifact(exe);
        \\    artifact.addFileArg(path);
        \\    const file = b.addRunFile(path);
        \\    file.addFileArg(path);
        \\    const created = Run.create(b, "run");
        \\    created.addFileArg(path);
        \\    const directly_created = @import("std").Build.Step.Run.create(b, "run");
        \\    directly_created.addFileArg(path);
        \\}
    ;
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 8), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 1), finding.fixes.len);
}

test "modernize Run arguments reject custom mutable shadowed and incomplete proof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Run = std.Build.Step.Run;
        \\fn custom(run: *Custom, std: Custom, fake: *std.Build.Step.Run) void {
        \\    run.addFileArg(path); fake.addFileArg(path);
        \\}
        \\fn configure(b: *std.Build) void {
        \\    const unknown = b.customFactory(.{}); unknown.addFileArg(path);
        \\    const selected = b.addSystemCommand(&.{"tool"}).custom; selected.addFileArg(path);
        \\    var mutable = b.addSystemCommand(&.{"tool"}); mutable.addFileArg(path);
        \\    { const Run = Custom; const fake = Run.create(b, "run"); fake.addFileArg(path); }
        \\    { var Namespace = @import("std"); const fake: *Namespace.Build.Step.Run = undefined; fake.addFileArg(path); }
        \\    { var Namespace = Run; const fake: *Namespace = undefined; fake.addFileArg(path); }
        \\    wrapper.run.addFileArg(path);
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try findingsForRule(arena.allocator(), source, .modernize_build_api)).len);
    const malformed: [:0]const u8 =
        \\const std = @import("std");
        \\fn configure(run: *std.Build.Step.Run) void {
        \\    run.addFileArg();
        \\    run.addFileArg(path, extra);
        \\    run.addFileArg(,);
        \\}
    ;
    const findings = try findingsForRule(arena.allocator(), malformed, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize lazy dependencies and legacy program lookup explain semantic changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const Build = std.Build;
        \\fn configure(b: *Build) void {
        \\    const alias = b;
        \\    _ = alias.lazyDependency("package", .{});
        \\    _ = b.findProgram(&.{"tool", "other"}, &.{"/usr/bin"});
        \\    _ = b.dependencyLazy("package", .{});
        \\    _ = b.findProgram(.{ .names = &.{"tool"} });
        \\    _ = b.findProgramLazy(.{ .names = &.{"tool"} });
        \\    { const b = Custom{}; _ = b.lazyDependency("package", .{}); _ = b.findProgram(names, paths); }
        \\}
    ;
    const findings = try findingsForRule(arena.allocator(), source, .modernize_build_api);
    try std.testing.expectEqual(@as(usize, 2), findings.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[0].message, 1, "propagate error.LazyDependencyNeeded to build()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[1].message, 1, "returns an optional"));
    try std.testing.expect(std.mem.containsAtLeast(u8, findings[1].message, 1, "configuration cache"));
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize runtime safety requires a proven std debug namespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const library = std;
        \\const debug = library.debug;
        \\const debug_alias = debug;
        \\const safety = std.debug.runtime_safety;
        \\const aliased_safety = debug_alias.runtime_safety;
        \\const direct_safety = @import("std").debug.runtime_safety;
        \\fn configure(std: Custom) void { _ = std.debug.runtime_safety; }
        \\comptime {
        \\    var mutable = @import("std"); _ = mutable.debug.runtime_safety;
        \\    var mutable_debug = debug; _ = mutable_debug.runtime_safety;
        \\    const debug = Custom; _ = debug.runtime_safety;
        \\    _ = safety;
        \\}
    ;
    const findings = try findingsFor(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 3), findings.len);
    for (findings) |finding| {
        try std.testing.expect(std.mem.containsAtLeast(u8, finding.message, 1, "@import(\"builtin\").mode.runtimeSafety()"));
        try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
    }
    try std.testing.expectEqual(@as(usize, 0), (try findingsFor(arena.allocator(), "const value = std.debug.runtime_safety;")).len);
}

test "modernize Run wrapper replacements compile against Zig 0.17" {
    const Example = struct {
        fn migrated(run_step: *std.Build.Step.Run, artifact: *std.Build.Step.Compile, path: std.Build.LazyPath) void {
            run_step.addArtifactArg2(artifact, .{});
            run_step.addFileArg2(path, .{});
            _ = run_step.addOutputFileArg2("out", .{});
            run_step.addFileContentArg2(path, .{});
            _ = run_step.addOutputDirectoryArg2("dir", .{});
            run_step.addDirectoryArg2(path, .{});
            _ = run_step.addDepFileOutputArg2("deps", .{});
        }
    };
    // Compile the body without constructing or executing a build graph.
    std.mem.doNotOptimizeAway(&Example.migrated);
}

test "modernize additional Build and runtime safety migrations honor suppression and defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\fn configure(b: *std.Build, run_step: *std.Build.Step.Run) void {
        \\    // zig-analyzer: disable-next-line modernize-build-api
        \\    run_step.addFileArg(path);
        \\    // zig-analyzer: disable-next-line modernize-build-api
        \\    _ = b.lazyDependency("package", .{});
        \\    // zig-analyzer: disable-next-line modernize-build-api
        \\    _ = b.findProgram(names, paths);
        \\    // zig-analyzer: disable-next-line modernize-deprecated-stdlib
        \\    _ = std.debug.runtime_safety;
        \\}
    ;
    inline for (.{ types.Rule.modernize_build_api, .modernize_deprecated_stdlib }) |rule| {
        try std.testing.expectEqual(@as(usize, 0), (try findingsForRule(arena.allocator(), source, rule)).len);
    }
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = try tokenize(arena.allocator(), source),
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "modernize bitCast audits proven array and vector types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(bytes: [4]u8, vector: @Vector(4, u8), integer: u32) void {\n" ++
        "    const a: u32 = @bitCast(bytes);\n" ++
        "    const b: u32 = @bitCast(vector);\n" ++
        "    const c: [4]u8 = @bitCast(integer);\n" ++
        "    const d = @as(@Vector(4, u8), @bitCast(integer));\n" ++
        "    const e = @bitCast(@as([4]u8, bytes));\n" ++
        "}\n";
    const findings = try findingsForRule(arena.allocator(), source, .modernize_bitcast);
    try std.testing.expectEqual(@as(usize, 5), findings.len);
    for (findings) |finding| try std.testing.expectEqual(@as(usize, 0), finding.fixes.len);
}

test "modernize bitCast leaves scalars pointers unknown types and shadowed arrays alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f(integer: u32, slice: []u8, pointer: [*]u8, unknown: Alias) void {\n" ++
        "    const float: f32 = @bitCast(integer);\n" ++
        "    _ = @bitCast(slice); _ = @bitCast(pointer); _ = @bitCast(unknown);\n" ++
        "}\n" ++
        "fn g(bytes: [4]u8) void { { const bytes: u32 = 0; const f: f32 = @bitCast(bytes); } }\n" ++
        "fn scalar(bytes: [4]u8, vector: @Vector(4, u8)) void {\n" ++
        "    _ = @bitCast(bytes[0]); _ = @bitCast(bytes.len); _ = @bitCast(vector[0]);\n" ++
        "    _ = @bitCast(@as([4]u8, bytes)[0]); _ = @bitCast([4]u8{0,0,0,0}[0]);\n" ++
        "    const element = @as([4]u8, bytes)[0]; _ = @bitCast(element);\n" ++
        "    const literal_element = [4]u8{0,0,0,0}[0]; _ = @bitCast(literal_element);\n" ++
        "}\n";
    try std.testing.expectEqual(@as(usize, 0), (try findingsForRule(arena.allocator(), source, .modernize_bitcast)).len);
}

test "modernize new rules honor suppression and remain disabled by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "// zig-analyzer: disable-next-line modernize-deprecated-builtin\n" ++
        "const integer = @intFromEnum(tag);\n" ++
        "// zig-analyzer: disable-next-line modernize-removed-syntax\n" ++
        "const v = void{};\n" ++
        "fn build(b: *std.Build) void {\n" ++
        "// zig-analyzer: disable-next-line modernize-build-api\n" ++
        "    _ = b.args;\n" ++
        "}\n" ++
        "// zig-analyzer: disable-next-line modernize-bitcast\n" ++
        "const bytes: [4]u8 = @bitCast(integer);\n";
    inline for (.{ types.Rule.modernize_deprecated_builtin, .modernize_removed_syntax, .modernize_build_api, .modernize_bitcast }) |rule| {
        try std.testing.expectEqual(@as(usize, 0), (try findingsForRule(arena.allocator(), source, rule)).len);
    }
    var findings: std.ArrayList(types.Finding) = .empty;
    try run(.{
        .allocator = arena.allocator(),
        .source = source,
        .tokens = try tokenize(arena.allocator(), source),
        .configuration = types.Configuration.defaults(),
        .findings = &findings,
    });
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

fn findingsFor(allocator: std.mem.Allocator, source: [:0]const u8) ![]const types.Finding {
    return findingsForRule(allocator, source, .modernize_deprecated_stdlib);
}

fn applyFindingFixes(allocator: std.mem.Allocator, source: []const u8, findings: []const types.Finding) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var cursor: usize = 0;
    for (findings) |finding| {
        for (finding.fixes[0].edits) |edit| {
            try output.appendSlice(allocator, source[cursor..edit.span.start]);
            try output.appendSlice(allocator, edit.replacement);
            cursor = edit.span.end;
        }
    }
    try output.appendSlice(allocator, source[cursor..]);
    return try output.toOwnedSlice(allocator);
}

fn findingsForRule(allocator: std.mem.Allocator, source: [:0]const u8, rule: types.Rule) ![]const types.Finding {
    const tokens = try tokenize(allocator, source);
    var findings: std.ArrayList(types.Finding) = .empty;
    var configuration = types.Configuration.defaults();
    configuration.levels[@backingInt(rule)] = .information;
    try run(.{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .configuration = configuration,
        .findings = &findings,
    });
    return try findings.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return try tokens.toOwnedSlice(allocator);
        try tokens.append(allocator, token);
    }
}
