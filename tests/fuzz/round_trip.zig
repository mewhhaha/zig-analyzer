//! The fix round-trip property: applying a rule's fixes to a program that
//! parses must leave a program that still parses and lowers through AstGen
//! without new errors, applying the fix-all edits twice must change nothing the
//! second time, and a fix applied to formatted source must stay formatted.
//! Semantic errors only surface in a real compilation: every program and fix
//! result checked here can be recorded in a `compile_batch.Corpus`.

const std = @import("std");
const zig_analyzer = @import("zig_analyzer");

const analysis = zig_analyzer.analysis;
const text_edits = zig_analyzer.syntax.text_edits;
const compile_batch = @import("compile_batch.zig");

pub const Verdict = struct {
    /// Rule violations found; each is reported as it is found.
    failures: usize = 0,
    /// Fix-all edit sets applied.
    fix_all_applied: usize = 0,
    /// Individual fixes (quick fixes and fix-alls) applied separately.
    fixes_applied: usize = 0,
    /// Fixes whose output differed from the formatter's rendering of the same
    /// text while their input was already formatted.
    unformatted: usize = 0,
    /// Programs checked whose own text was already formatted.
    formatted_inputs: usize = 0,
    /// The rules whose fixes were applied.
    fixed_rules: std.EnumSet(analysis.Rule) = .empty,
    /// Where checked programs and their fix results are recorded for the
    /// compile check; null skips recording.
    corpus: ?*compile_batch.Corpus = null,
};

/// The messages of the errors AstGen reports for `source`, sorted; empty when
/// it lowers cleanly. `source` must parse without errors.
pub fn astgenMessages(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var tree = try std.zig.Ast.parse(arena, source, .{ .mode = .zig });
    defer tree.deinit(arena);
    var zir = try std.zig.AstGen.generate(arena, tree);
    defer zir.deinit(arena);
    if (!zir.hasCompileErrors()) return &.{};
    const Zir = std.zig.Zir;
    const header = zir.extraData(Zir.Inst.CompileErrors, zir.extra[@backingInt(Zir.ExtraIndex.compile_errors)]);
    var messages: std.ArrayList([]const u8) = .empty;
    var extra_index = header.end;
    for (0..header.data.items_len) |_| {
        const item = zir.extraData(Zir.Inst.CompileErrors.Item, extra_index);
        extra_index = item.end;
        try messages.append(arena, try arena.dupe(u8, zir.nullTerminatedString(item.data.msg)));
    }
    std.mem.sort([]const u8, messages.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return messages.items;
}

/// The first of the sorted `after` messages that `before` does not account for.
pub fn firstIntroduced(before: []const []const u8, after: []const []const u8) ?[]const u8 {
    var cursor: usize = 0;
    for (after) |message| {
        while (cursor < before.len and std.mem.lessThan(u8, before[cursor], message)) cursor += 1;
        if (cursor < before.len and std.mem.eql(u8, before[cursor], message)) {
            cursor += 1;
        } else return message;
    }
    return null;
}

fn parseErrorCount(allocator: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    return tree.errors.len;
}

/// Whether `source` is what the formatter prints for it, ignoring the final newline.
pub fn isFormatted(allocator: std.mem.Allocator, source: [:0]const u8) !bool {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return false;
    const rendered = try tree.renderAlloc(allocator);
    defer allocator.free(rendered);
    return std.mem.eql(u8, std.mem.trimEnd(u8, rendered, "\n"), std.mem.trimEnd(u8, source, "\n"));
}

fn report(label: []const u8, what: []const u8, rule: analysis.Rule, title: []const u8, before: []const u8, after: []const u8) void {
    std.debug.print("--- {s}: {s} [{s}] \"{s}\"\n--- before\n{s}\n--- after\n{s}\n", .{ label, what, rule.code(), title, before, after });
}

/// Checks every fix `rule` offers on `source`, with only `rule` enabled.
/// `arena` must outlive the call; nothing is freed.
pub fn checkRule(
    arena: std.mem.Allocator,
    verdict: *Verdict,
    label: []const u8,
    source: [:0]const u8,
    rule: analysis.Rule,
    configuration: analysis.Configuration,
) !void {
    const original_errors = try parseErrorCount(arena, source);
    if (original_errors != 0) return;
    const was_formatted = try isFormatted(arena, source);
    verdict.formatted_inputs += @intFromBool(was_formatted);
    const original_astgen = try astgenMessages(arena, source);
    const program: ?compile_batch.Corpus.Program = if (verdict.corpus) |corpus|
        try corpus.program(label, source, original_astgen.len == 0)
    else
        null;
    const found = try analysis.findings(arena, source, configuration);

    var offered_fix_all = false;
    for (found) |finding| {
        if (finding.rule != rule) continue;
        for (finding.fixes) |fix| {
            const edits = try text_edits.nonOverlapping(arena, fix.edits);
            const fixed = try text_edits.apply(arena, source, edits);
            verdict.fixes_applied += 1;
            verdict.fixed_rules.insert(rule);
            if (try parseErrorCount(arena, fixed) != 0) {
                verdict.failures += 1;
                report(label, "fix leaves a syntax error", rule, fix.title, source, fixed);
            } else {
                if (firstIntroduced(original_astgen, try astgenMessages(arena, fixed))) |message| {
                    verdict.failures += 1;
                    report(label, message, rule, fix.title, source, fixed);
                } else if (program) |recorded| {
                    try recorded.addVariant(rule.code(), fix.title, fixed);
                }
                if (was_formatted and !try isFormatted(arena, fixed)) {
                    verdict.unformatted += 1;
                    report(label, "fix output is not formatted", rule, fix.title, source, fixed);
                }
            }
            if (fix.fix_all) offered_fix_all = true;
        }
    }
    if (!offered_fix_all) return;

    const edits = try text_edits.safeFixAll(arena, found);
    if (edits.len == 0) return;
    const fixed = try text_edits.apply(arena, source, edits);
    verdict.fix_all_applied += 1;
    if (try parseErrorCount(arena, fixed) != 0) {
        verdict.failures += 1;
        report(label, "fix-all leaves a syntax error", rule, "fix-all", source, fixed);
        return;
    }
    if (firstIntroduced(original_astgen, try astgenMessages(arena, fixed))) |message| {
        verdict.failures += 1;
        report(label, message, rule, "fix-all", source, fixed);
    } else if (program) |recorded| {
        try recorded.addVariant(rule.code(), "fix-all", fixed);
    }
    const again = try analysis.findings(arena, fixed, configuration);
    const more = try text_edits.safeFixAll(arena, again);
    if (more.len != 0) {
        verdict.failures += 1;
        report(label, "fix-all is not idempotent", rule, "fix-all", source, fixed);
    }
}

/// `checkRule` for every rule that reports on `source`, each in isolation, so
/// a failure names the rule.
pub fn checkEveryReportingRule(
    arena: std.mem.Allocator,
    verdict: *Verdict,
    label: []const u8,
    source: [:0]const u8,
    everything: analysis.Configuration,
) !void {
    const found = try analysis.findings(arena, source, everything);
    var seen: std.EnumSet(analysis.Rule) = .empty;
    for (found) |finding| {
        if (seen.contains(finding.rule)) continue;
        seen.insert(finding.rule);
        var only = analysis.Configuration.defaults();
        @memset(&only.levels, .off);
        only.levels[@backingInt(finding.rule)] = .warning;
        try checkRule(arena, verdict, label, source, finding.rule, only);
    }
}

/// The combined property with every rule on at once: all fix-all edits applied
/// together keep the program parseable.
pub fn checkCombined(
    arena: std.mem.Allocator,
    verdict: *Verdict,
    label: []const u8,
    source: [:0]const u8,
    everything: analysis.Configuration,
) !void {
    if (try parseErrorCount(arena, source) != 0) return;
    const found = try analysis.findings(arena, source, everything);
    const edits = try text_edits.safeFixAll(arena, found);
    if (edits.len == 0) return;
    const fixed = try text_edits.apply(arena, source, edits);
    verdict.fix_all_applied += 1;
    if (try parseErrorCount(arena, fixed) != 0) {
        verdict.failures += 1;
        report(label, "combined fix-all leaves a syntax error", .unreleased_allocation, "fix-all", source, fixed);
        return;
    }
    const original_astgen = try astgenMessages(arena, source);
    if (firstIntroduced(original_astgen, try astgenMessages(arena, fixed))) |message| {
        verdict.failures += 1;
        report(label, message, .unreleased_allocation, "combined fix-all", source, fixed);
    } else if (verdict.corpus) |corpus| {
        const program = try corpus.program(label, source, original_astgen.len == 0);
        try program.addVariant("combined", "fix-all", fixed);
    }
}
