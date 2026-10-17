//! Owned fields and element sequences whose cleanup is proven incomplete: a
//! field or element a type allocates must be released by its cleanup method,
//! replaced only after release, and moved only with its owner.
const std = @import("std");
const syntax_scope = @import("../../syntax/scope.zig");
const summaries = @import("../summaries.zig");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const types = @import("../types.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const findTag = tokens_util.findTag;
const firstCall = tokens_util.firstCall;
const fieldTypeEnd = tokens_util.fieldTypeEnd;
const project = @import("../project.zig");
const reach = @import("../lifecycle/reach.zig");

pub const rules = [_]types.Rule{.incomplete_owned_field_cleanup};

/// A project file with its scope index, which the scans below use to match
/// delimiters and find statement ends, and the lookups they repeat per item.
const File = struct {
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    scopes: *const syntax_scope.Index,
    facts: *Facts,
};

/// Token positions grouped by a name, in token order.
const NamePositions = std.StringHashMapUnmanaged(std.ArrayList(u32));

/// Lookups over one file that the proofs below would otherwise repeat for
/// every container, field or call: built in one pass over the tokens, or
/// memoized per name, so no proof rescans the whole file per item.
const Facts = struct {
    allocator: std.mem.Allocator,
    /// `Name {` (the name), by name.
    braced_names: NamePositions = .empty,
    /// `fn name(` (the `fn`), by name.
    functions: NamePositions = .empty,
    /// `fn` tokens, counted by the spelling of the token after them.
    function_counts: std.StringHashMapUnmanaged(usize) = .empty,
    /// `receiver.append(` and `receiver.appendAssumeCapacity(` (the method),
    /// by the spelling of the receiver.
    appends: NamePositions = .empty,
    /// The first `const Name = struct {` that closes, by name.
    containers: std.StringHashMapUnmanaged(TypeContainer) = .empty,
    /// The `fn name(...)` whose body each opening brace starts.
    function_bodies: std.AutoHashMapUnmanaged(usize, ContainingFunction) = .empty,
    /// The first direct `name:` member of a container, by container range
    /// and name; built for a container when first asked.
    container_fields: std.AutoHashMapUnmanaged([2]usize, std.StringHashMapUnmanaged(usize)) = .empty,
    /// Whether the file appends an owned allocation to a sequence field, by
    /// field name; memoized.
    owned_allocations: std.StringHashMapUnmanaged(bool) = .empty,
    /// The element type of every field the file declares as an `ArrayList`,
    /// by field name; null when the file declares the name with two
    /// different element types. Built when first asked, as are the next two.
    element_types: ?std.StringHashMapUnmanaged(?[]const u8) = null,
    /// Whether the `ArrayList` fields of each name hold only pointers.
    stores_pointers: ?std.StringHashMapUnmanaged(bool) = null,
    /// The element field the first cleanup loop over each sequence frees.
    cleanup_owned_fields: ?std.StringHashMapUnmanaged([]const u8) = null,
    /// `sequence.orderedRemove`, `sequence.swapRemove` and `sequence.pop`
    /// (the method), in order; built when first asked.
    removals: ?[]const u32 = null,

    fn init(allocator: std.mem.Allocator, source: []const u8, tokens: []const std.zig.Token, scopes: *const syntax_scope.Index) !Facts {
        var facts: Facts = .{ .allocator = allocator };
        errdefer facts.deinit();
        for (tokens, 0..) |token, index| switch (token.tag) {
            .identifier => {
                if (index + 1 >= tokens.len or tokens[index + 1].tag != .l_paren) {
                    if (index + 1 < tokens.len and tokens[index + 1].tag == .l_brace) {
                        try facts.add(&facts.braced_names, tokenText(source, token), index);
                    }
                    continue;
                }
                if (index < 2 or tokens[index - 1].tag != .period or
                    (!tokenIs(source, token, "append") and !tokenIs(source, token, "appendAssumeCapacity"))) continue;
                try facts.add(&facts.appends, tokenText(source, tokens[index - 2]), index);
            },
            .keyword_fn => {
                if (index + 1 >= tokens.len) continue;
                const count = try facts.function_counts.getOrPut(allocator, tokenText(source, tokens[index + 1]));
                count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
                if (index + 2 >= tokens.len or tokens[index + 2].tag != .l_paren) continue;
                try facts.add(&facts.functions, tokenText(source, tokens[index + 1]), index);
                const parameters_end = scopes.matchingToken(index + 2) orelse continue;
                const body_start = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse continue;
                if (scopes.matchingToken(body_start) == null) continue;
                try facts.function_bodies.put(allocator, body_start, .{
                    .parameters_start = index + 3,
                    .parameters_end = parameters_end,
                    .body_start = body_start,
                });
            },
            .keyword_const => {
                if (index + 4 >= tokens.len or tokens[index + 2].tag != .equal or
                    tokens[index + 3].tag != .keyword_struct or tokens[index + 4].tag != .l_brace) continue;
                const container_end = scopes.matchingToken(index + 4) orelse continue;
                const entry = try facts.containers.getOrPut(allocator, tokenText(source, tokens[index + 1]));
                if (!entry.found_existing) entry.value_ptr.* = .{ .start = index + 5, .end = container_end };
            },
            else => {},
        };
        return facts;
    }

    fn deinit(facts: *Facts) void {
        for ([_]*NamePositions{ &facts.braced_names, &facts.functions, &facts.appends }) |positions| {
            var lists = positions.valueIterator();
            while (lists.next()) |list| list.deinit(facts.allocator);
            positions.deinit(facts.allocator);
        }
        var fields = facts.container_fields.valueIterator();
        while (fields.next()) |members| members.deinit(facts.allocator);
        facts.container_fields.deinit(facts.allocator);
        facts.function_counts.deinit(facts.allocator);
        facts.containers.deinit(facts.allocator);
        facts.function_bodies.deinit(facts.allocator);
        facts.owned_allocations.deinit(facts.allocator);
        if (facts.element_types) |*types_by_field| types_by_field.deinit(facts.allocator);
        if (facts.stores_pointers) |*pointers| pointers.deinit(facts.allocator);
        if (facts.cleanup_owned_fields) |*cleanups| cleanups.deinit(facts.allocator);
        if (facts.removals) |removals| facts.allocator.free(removals);
    }

    fn removalMethods(facts: *Facts, file: File) ![]const u32 {
        if (facts.removals) |removals| return removals;
        var removals: std.ArrayList(u32) = .empty;
        errdefer removals.deinit(facts.allocator);
        for (file.tokens, 0..) |token, method_index| {
            if (token.tag != .identifier or method_index < 2 or file.tokens[method_index - 1].tag != .period or
                file.tokens[method_index - 2].tag != .identifier or
                (!tokenIs(file.source, token, "orderedRemove") and !tokenIs(file.source, token, "swapRemove") and
                    !tokenIs(file.source, token, "pop"))) continue;
            try removals.append(facts.allocator, @intCast(method_index));
        }
        const owned = try removals.toOwnedSlice(facts.allocator);
        facts.removals = owned;
        return owned;
    }

    fn elementType(facts: *Facts, file: File, field_name: []const u8) !?[]const u8 {
        if (facts.element_types == null) {
            facts.element_types = .empty;
            try collectSequenceElementTypes(facts.allocator, file, &facts.element_types.?);
        }
        return facts.element_types.?.get(field_name) orelse null;
    }

    fn add(facts: *Facts, positions: *NamePositions, name: []const u8, index: usize) !void {
        const entry = try positions.getOrPut(facts.allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(facts.allocator, @intCast(index));
    }

    fn named(positions: *const NamePositions, name: []const u8) []const u32 {
        return if (positions.get(name)) |list| list.items else &.{};
    }

    /// The positions of `name` in `[start, end)`.
    fn namedIn(positions: *const NamePositions, name: []const u8, start: usize, end: usize) []const u32 {
        return positionsIn(named(positions, name), start, end);
    }

    fn orderPosition(target: usize, position: u32) std.math.Order {
        return std.math.order(target, position);
    }

    /// The `name` member declared directly in the container `[start, end)`.
    fn containerField(facts: *Facts, file: File, start: usize, end: usize, name: []const u8) !?usize {
        const entry = try facts.container_fields.getOrPut(facts.allocator, .{ start, end });
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
            var field_index = start;
            while (field_index < end) : (field_index = nextOwnToken(file, field_index)) {
                const token = file.tokens[field_index];
                if (token.tag != .identifier or field_index + 2 >= end or
                    file.tokens[field_index + 1].tag != .colon) continue;
                const member = try entry.value_ptr.getOrPut(facts.allocator, tokenText(file.source, token));
                if (!member.found_existing) member.value_ptr.* = field_index;
            }
        }
        return entry.value_ptr.get(name);
    }
};

const OwnedFieldEvidence = struct {
    file_index: usize,
    type_name: []const u8,
    field_name: []const u8,
    span: std.zig.Token.Loc,
};

const OwnedSequenceEvidence = struct {
    file_index: usize,
    type_name: []const u8,
    field_name: []const u8,
    span: std.zig.Token.Loc,
};

/// The positions of the ordered `all` in `[start, end)`.
fn positionsIn(all: []const u32, start: usize, end: usize) []const u32 {
    const first = std.sort.lowerBound(u32, all, start, Facts.orderPosition);
    const last = std.sort.lowerBound(u32, all, end, Facts.orderPosition);
    return all[first..last];
}

/// The owned fields proven in one file, in the order they were proven, with
/// each type's fields indexed so lookups do not scan every proven field.
const FieldEvidence = struct {
    items: std.ArrayList(OwnedFieldEvidence) = .empty,
    /// Positions in `items` of each type's fields, in order.
    by_type: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,

    fn deinit(evidence: *FieldEvidence, allocator: std.mem.Allocator) void {
        var positions = evidence.by_type.valueIterator();
        while (positions.next()) |list| list.deinit(allocator);
        evidence.by_type.deinit(allocator);
        evidence.items.deinit(allocator);
    }

    fn append(evidence: *FieldEvidence, allocator: std.mem.Allocator, field: OwnedFieldEvidence) !void {
        const entry = try evidence.by_type.getOrPut(allocator, field.type_name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, @intCast(evidence.items.items.len));
        try evidence.items.append(allocator, field);
    }

    /// Positions in `items` of the fields proven for `type_name`, in order.
    fn ofType(evidence: *const FieldEvidence, type_name: []const u8) []const u32 {
        return if (evidence.by_type.get(type_name)) |positions| positions.items else &.{};
    }

    fn proven(evidence: *const FieldEvidence, type_name: []const u8, field_name: []const u8) bool {
        for (evidence.ofType(type_name)) |position| {
            if (std.mem.eql(u8, evidence.items.items[position].field_name, field_name)) return true;
        }
        return false;
    }
};

pub fn findIncompleteOwnedFieldCleanup(
    run: ProjectRun,
    summary_index: summaries.Index,
) !void {
    if (run.configuration.level(.incomplete_owned_field_cleanup) == .off and
        run.configuration.level(.unreleased_allocation) == .off and
        run.configuration.level(.overwritten_owning_value) == .off and
        run.configuration.level(.partial_ownership_transfer) == .off and
        run.configuration.level(.missing_errdefer) == .off) return;
    // A file's proofs read only its own evidence, so files are checked on
    // several threads, each into a list of its own joined in file order.
    const per_file = try run.allocator.alloc(std.ArrayList(run_module.Finding), run.files.len);
    @memset(per_file, .empty);
    defer for (per_file) |*found| found.deinit(run.results);
    try run_module.forEachIndex(run, run.files.len, FileChecks{
        .run = run,
        .summary_index = summary_index,
        .per_file = per_file,
    }, FileChecks.check);
    for (per_file) |found| try run.findings.appendSlice(run.results, found.items);
}

const FileChecks = struct {
    run: ProjectRun,
    summary_index: summaries.Index,
    per_file: []std.ArrayList(run_module.Finding),

    fn check(checks: FileChecks, file_index: usize) !void {
        var file_arena: std.heap.ArenaAllocator = .init(checks.run.backing);
        defer file_arena.deinit();
        var file_run = checks.run;
        file_run.allocator = file_arena.allocator();
        file_run.findings = &checks.per_file[file_index];
        try checkFile(file_run, checks.summary_index, file_index);
    }
};

fn checkFile(run: ProjectRun, summary_index: summaries.Index, file_index: usize) !void {
    const level = run.configuration.level(.incomplete_owned_field_cleanup);
    const project_file = run.files[file_index];
    const scopes = try run.scopes(file_index);
    var facts: Facts = try .init(run.allocator, project_file.source, project_file.tokens, scopes);
    defer facts.deinit();
    const file: File = .{ .source = project_file.source, .tokens = project_file.tokens, .scopes = scopes, .facts = &facts };
    var evidence: FieldEvidence = .{};
    defer evidence.deinit(run.allocator);
    var sequence_evidence: std.ArrayList(OwnedSequenceEvidence) = .empty;
    defer sequence_evidence.deinit(run.allocator);
    try collectOwnedFieldEvidence(run.allocator, file, file_index, summary_index, &evidence);
    try collectOwnedSequenceEvidence(run.allocator, file, file_index, summary_index, &sequence_evidence);
    for (sequence_evidence.items) |sequence| {
        if (evidence.proven(sequence.type_name, sequence.field_name)) continue;
        try evidence.append(run.allocator, .{
            .file_index = sequence.file_index,
            .type_name = sequence.type_name,
            .field_name = sequence.field_name,
            .span = sequence.span,
        });
    }
    try findIncompleteOwnedElementCleanup(run, file, file_index, &evidence);
    try findDroppedOwnedElements(run, file, file_index, &evidence);
    try findOwnedElementOverwrites(run, file, file_index, summary_index, &evidence);
    try findAliasedOwnedElementOverwrites(run, file, file_index, summary_index, &evidence);
    try findCapturedOwnedElementOverwrites(run, file, file_index, summary_index, &evidence);
    try findDirectOwnedFieldOverwrites(run, file, file_index, summary_index, &evidence);
    try findRemovedOwnedValueTransfers(run, file, file_index, &evidence);
    try findOwnedSequenceIssues(
        run,
        file,
        summary_index,
        sequence_evidence.items,
    );
    try findFailureUnsafeOwnedSliceShrinks(run, file, file_index, &evidence);
    if (level == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const type_name = tokenText(file.source, file.tokens[declaration_index + 1]);
        if (evidence.ofType(type_name).len < 2) continue;
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        // Fields allocated from an arena the aggregate owns go with it.
        if (containerOwnsArena(file, declaration_index + 5, container_end)) continue;
        const cleanup = cleanupMethod(file, declaration_index + 5, container_end) orelse continue;
        var owned_count: usize = 0;
        var released_count: usize = 0;
        for (evidence.ofType(type_name)) |position| {
            const field = evidence.items.items[position];
            // Another type of the same name proves its own fields.
            if (try file.facts.containerField(file, declaration_index + 5, container_end, field.field_name) == null) continue;
            owned_count += 1;
            if (try fieldReleased(
                file,
                cleanup,
                declaration_index + 5,
                container_end,
                &evidence,
                field.field_name,
            )) released_count += 1;
        }
        if (owned_count < 2 or released_count == 0 or released_count == owned_count) continue;
        for (evidence.ofType(type_name)) |position| {
            const field = evidence.items.items[position];
            if (try file.facts.containerField(file, declaration_index + 5, container_end, field.field_name) == null) continue;
            if (try fieldReleased(
                file,
                cleanup,
                declaration_index + 5,
                container_end,
                &evidence,
                field.field_name,
            )) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .incomplete_owned_field_cleanup,
                .span = field.span,
                .message = try run.allocator.print(
                    "cleanup for '{s}' releases {d} of {d} proven owned fields but omits '{s}'",
                    .{ type_name, released_count, owned_count, field.field_name },
                ),
            });
        }
    }
}

fn findDirectOwnedFieldOverwrites(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const type_name = tokenText(file.source, file.tokens[declaration_index + 1]);
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        const cleanup = cleanupMethod(file, declaration_index + 5, container_end);
        var function_index = declaration_index + 5;
        while (function_index < container_end) : (function_index = nextOwnToken(file, function_index)) {
            const candidate = file.tokens[function_index];
            // A nested type's methods assign that type's fields.
            if (candidate.tag != .keyword_fn or function_index + 2 >= container_end or
                file.tokens[function_index + 2].tag != .l_paren or
                file.scopes.enclosingOpeningBrace(function_index) != declaration_index + 4) continue;
            // An `init` fills fields that hold no allocation yet.
            if (std.mem.startsWith(u8, tokenText(file.source, file.tokens[function_index + 1]), "init")) continue;
            const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
            const receiver = firstParameterName(file, function_index + 3, parameters_end) orelse continue;
            const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
            const body_end = file.scopes.matchingToken(body_start) orelse continue;
            if (body_end > container_end) continue;
            var equal_index = body_start + 1;
            while (equal_index + 1 < body_end) : (equal_index += 1) {
                if (file.tokens[equal_index].tag != .equal or equal_index < 3 or
                    file.tokens[equal_index - 1].tag != .identifier or file.tokens[equal_index - 2].tag != .period or
                    !tokenIs(file.source, file.tokens[equal_index - 3], receiver)) continue;
                const field_name = tokenText(file.source, file.tokens[equal_index - 1]);
                if (!evidence.proven(type_name, field_name) or
                    containerFieldIsOptional(file, declaration_index + 5, container_end, field_name)) continue;
                const assignment_end = file.scopes.statementEnd(equal_index) orelse continue;
                if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, assignment_end, body_start + 1)) continue;
                // Without a cleanup that frees the field, its owner (often an
                // arena) releases what it holds.
                const type_cleanup = cleanup orelse continue;
                if (!try fieldReleased(file, type_cleanup, declaration_index + 5, container_end, evidence, field_name)) continue;
                if (previousValueUnowned(file, receiver, field_name, body_start, equal_index) or
                    previousValueMoved(file, receiver, field_name, body_start, equal_index)) continue;
                const released = rangeReleasesElementField(file, receiver, field_name, body_start + 1, equal_index) or
                    try aggregateFieldReleasedByHelper(
                        file,
                        evidence,
                        receiver,
                        field_name,
                        body_start + 1,
                        equal_index,
                        declaration_index + 5,
                        container_end,
                    );
                if (released and !rangeContainsTry(file.tokens, equal_index + 1, assignment_end)) continue;
                // `if (first) { self.field = try dupe(..); return; } ... free(self.field)`:
                // the function tracks when the field holds an allocation.
                if (!released and !reach.runsWithin(file.tokens, file.scopes, equal_index - 3, body_start) and
                    rangeReleasesElementField(file, receiver, field_name, assignment_end, body_end)) continue;
                try run.report(.{
                    .file_index = file_index,
                    .rule = .overwritten_owning_value,
                    .span = file.tokens[equal_index - 1].loc,
                    .message = if (released)
                        try run.allocator.print(
                            "fallible replacement of proven owned field '{s}.{s}' occurs after its previous allocation is released",
                            .{ type_name, field_name },
                        )
                    else
                        try run.allocator.print(
                            "assignment replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                            .{ type_name, field_name },
                        ),
                });
            }
        }
    }
}

/// Whether every path to the assignment of `receiver.field` at `before` first
/// stores a value that owns nothing: `""`, `undefined`, `null`, `&.{}`, `.{}`
/// or `.empty`.
fn previousValueUnowned(file: File, receiver: []const u8, field_name: []const u8, body_start: usize, before: usize) bool {
    const tokens = file.tokens;
    for (tokens[body_start + 1 .. before], body_start + 1..) |token, index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, receiver) or index + 4 >= before or
            tokens[index + 1].tag != .period or !tokenIs(file.source, tokens[index + 2], field_name) or
            tokens[index + 3].tag != .equal or (index > 0 and tokens[index - 1].tag == .period)) continue;
        const value_end = file.scopes.statementEnd(index) orelse continue;
        if (!unownedValue(file, index + 4, value_end)) continue;
        const block = reach.commonBlock(file.scopes, index, before) orelse continue;
        if (reach.runsWithin(tokens, file.scopes, index, block)) return true;
    }
    return false;
}

/// Whether the function hands the field's previous value elsewhere before the
/// assignment at `before`: `old.tree = handle.tree;`.
fn previousValueMoved(file: File, receiver: []const u8, field_name: []const u8, body_start: usize, before: usize) bool {
    const tokens = file.tokens;
    for (tokens[body_start + 1 .. before], body_start + 1..) |token, index| {
        if (token.tag != .equal or index + 4 >= before or !tokenIs(file.source, tokens[index + 1], receiver) or
            tokens[index + 2].tag != .period or !tokenIs(file.source, tokens[index + 3], field_name)) continue;
        switch (tokens[index + 4].tag) {
            .semicolon, .comma, .r_brace => return true,
            else => {},
        }
    }
    return false;
}

fn unownedValue(file: File, start: usize, end: usize) bool {
    const tokens = file.tokens;
    switch (end - start) {
        1 => return tokens[start].tag == .string_literal or tokenIs(file.source, tokens[start], "undefined") or
            tokenIs(file.source, tokens[start], "null"),
        2 => return tokens[start].tag == .period and tokenIs(file.source, tokens[start + 1], "empty"),
        3 => return tokens[start].tag == .period and tokens[start + 1].tag == .l_brace and tokens[start + 2].tag == .r_brace,
        4 => return tokens[start].tag == .ampersand and tokens[start + 1].tag == .period and
            tokens[start + 2].tag == .l_brace and tokens[start + 3].tag == .r_brace,
        else => return false,
    }
}

fn containerFieldIsOptional(
    file: File,
    start: usize,
    end: usize,
    field_name: []const u8,
) bool {
    var field_index = start;
    while (field_index < end) : (field_index = nextOwnToken(file, field_index)) {
        const token = file.tokens[field_index];
        if (token.tag != .identifier or !tokenIs(file.source, token, field_name) or
            field_index + 2 >= end or file.tokens[field_index + 1].tag != .colon) continue;
        return file.tokens[field_index + 2].tag == .question_mark;
    }
    return false;
}

fn collectOwnedFieldEvidence(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *FieldEvidence,
) !void {
    try collectCleanupOwnedFieldEvidence(allocator, file, file_index, summary_index, evidence);
    for (file.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= file.tokens.len or file.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = file.scopes.matchingToken(fn_index + 2) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        // Each owned binding, with every `.field = binding` (the period) of the
        // body that initializes a field with it, in order.
        var binding_fields: NamePositions = .empty;
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, declaration_index| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or declaration_index + 3 >= body_end or
                file.tokens[declaration_index + 1].tag != .identifier) continue;
            const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
            const equal_index = findTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
            if (equal_index + 2 < declaration_end and file.tokens[equal_index + 1].tag == .identifier and
                file.tokens[equal_index + 2].tag == .l_brace)
            {
                try collectDirectAggregateOwnedFields(
                    allocator,
                    file,
                    file_index,
                    tokenText(file.source, file.tokens[equal_index + 1]),
                    equal_index + 1,
                    declaration_end,
                    summary_index,
                    evidence,
                );
            }
            const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
            const name = tokenText(file.source, file.tokens[call.name_index]);
            const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
            if (!summary_index.callReturnsOwned(file.source, receiver, name)) continue;
            const entry = try binding_fields.getOrPut(allocator, tokenText(file.source, file.tokens[declaration_index + 1]));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
        }
        if (binding_fields.count() != 0) {
            for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, field_index| {
                if (candidate.tag != .period or field_index + 3 >= body_end or
                    file.tokens[field_index + 1].tag != .identifier or file.tokens[field_index + 2].tag != .equal or
                    file.tokens[field_index + 3].tag != .identifier) continue;
                const fields = binding_fields.getPtr(tokenText(file.source, file.tokens[field_index + 3])) orelse continue;
                try fields.append(allocator, @intCast(field_index));
            }
        }
        try collectPointerFieldAssignments(
            allocator,
            file,
            file_index,
            body_start + 1,
            body_end,
            summary_index,
            evidence,
        );
        if (functionReturnType(file, parameters_end + 1, body_start)) |type_name| {
            var statements: ReturnStatements = .{};
            for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, return_index| {
                if (candidate.tag != .keyword_return) continue;
                const statement = try statements.of(allocator, file, return_index) orelse continue;
                const return_end = statement.end;
                try collectAggregateOwnedFields(
                    allocator,
                    file,
                    file_index,
                    type_name,
                    return_index + 1,
                    return_end,
                    &binding_fields,
                    evidence,
                );
                if (!statement.reads_direct_fields) continue;
                try collectDirectAggregateOwnedFields(
                    allocator,
                    file,
                    file_index,
                    type_name,
                    return_index + 1,
                    return_end,
                    summary_index,
                    evidence,
                );
            }
        }
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "append") and !tokenIs(file.source, candidate, "appendAssumeCapacity")) or
                method_index < 2 or file.tokens[method_index - 1].tag != .period or
                file.tokens[method_index - 2].tag != .identifier or method_index + 1 >= body_end or
                file.tokens[method_index + 1].tag != .l_paren) continue;
            const element_type = try file.facts.elementType(file, tokenText(file.source, file.tokens[method_index - 2])) orelse continue;
            const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
            try collectAggregateOwnedFields(
                allocator,
                file,
                file_index,
                element_type,
                method_index + 2,
                call_end,
                &binding_fields,
                evidence,
            );
            try collectDirectAggregateOwnedFields(
                allocator,
                file,
                file_index,
                element_type,
                method_index + 2,
                call_end,
                summary_index,
                evidence,
            );
        }
    }
}

fn collectPointerFieldAssignments(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    start: usize,
    end: usize,
    summary_index: summaries.Index,
    evidence: *FieldEvidence,
) !void {
    for (file.tokens[start..end], start..) |token, equal_index| {
        if (token.tag != .equal or equal_index < start + 3 or
            file.tokens[equal_index - 1].tag != .identifier or file.tokens[equal_index - 2].tag != .period or
            file.tokens[equal_index - 3].tag != .identifier) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        const call = firstCall(file.tokens, equal_index + 1, statement_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (!summary_index.callReturnsOwned(file.source, receiver, name)) continue;
        const binding = tokenText(file.source, file.tokens[equal_index - 3]);
        const type_name = localBindingReturnType(file, binding, start, equal_index) orelse continue;
        const field_name = tokenText(file.source, file.tokens[equal_index - 1]);
        if (evidence.proven(type_name, field_name)) continue;
        try evidence.append(allocator, .{
            .file_index = file_index,
            .type_name = type_name,
            .field_name = field_name,
            .span = file.tokens[equal_index - 1].loc,
        });
    }
}

fn localBindingReturnType(
    file: File,
    binding: []const u8,
    start: usize,
    before: usize,
) ?[]const u8 {
    for (file.tokens[start..before], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= before or
            !tokenIs(file.source, file.tokens[declaration_index + 1], binding)) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= before) continue;
        const call = firstCall(file.tokens, declaration_index + 2, declaration_end) orelse continue;
        return uniqueFunctionReturnType(file, tokenText(file.source, file.tokens[call.name_index]));
    }
    return null;
}

fn uniqueFunctionReturnType(file: File, function_name: []const u8) ?[]const u8 {
    const functions = Facts.named(&file.facts.functions, function_name);
    if (functions.len != 1) return null;
    const parameters_end = file.scopes.matchingToken(functions[0] + 2) orelse return null;
    const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse return null;
    return functionReturnType(file, parameters_end + 1, body_start);
}

fn collectDirectAggregateOwnedFields(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    type_name: []const u8,
    start: usize,
    end: usize,
    summary_index: summaries.Index,
    evidence: *FieldEvidence,
) !void {
    var values: FieldValues = .{ .file = file, .start = start, .end = end };
    var field_index = start;
    while (field_index + 3 < end) : (field_index += 1) {
        if (file.tokens[field_index].tag != .period or file.tokens[field_index + 1].tag != .identifier or
            file.tokens[field_index + 2].tag != .equal or nestedAggregateField(file, field_index, start)) continue;
        const value_end = try values.valueEnd(allocator, field_index + 3);
        const call = values.firstCall(field_index + 3, value_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (!summary_index.callReturnsOwned(file.source, receiver, name)) continue;
        const field_name = tokenText(file.source, file.tokens[field_index + 1]);
        if (evidence.proven(type_name, field_name)) continue;
        try evidence.append(allocator, .{
            .file_index = file_index,
            .type_name = type_name,
            .field_name = field_name,
            .span = file.tokens[field_index + 1].loc,
        });
    }
}

fn collectCleanupOwnedFieldEvidence(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *FieldEvidence,
) !void {
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        const cleanup = cleanupMethod(file, declaration_index + 5, container_end) orelse continue;
        const type_name = tokenText(file.source, file.tokens[declaration_index + 1]);
        var member_index = declaration_index + 5;
        while (member_index < container_end) : (member_index = nextOwnToken(file, member_index)) {
            const field = file.tokens[member_index];
            if (field.tag != .identifier or member_index + 1 >= container_end or
                file.tokens[member_index + 1].tag != .colon or
                file.scopes.enclosingOpeningBrace(member_index) != declaration_index + 4 or !try fieldReleased(
                file,
                cleanup,
                declaration_index + 5,
                container_end,
                evidence,
                tokenText(file.source, field),
            )) continue;
            const field_name = tokenText(file.source, field);
            if (evidence.proven(type_name, field_name)) continue;
            try evidence.append(allocator, .{
                .file_index = file_index,
                .type_name = type_name,
                .field_name = field_name,
                .span = field.loc,
            });
        }
        for (Facts.named(&file.facts.braced_names, type_name)) |aggregate_position| {
            const type_index: usize = aggregate_position;
            // `fn make() !Type {` opens a body, not an aggregate.
            if (file.facts.function_bodies.contains(type_index + 1)) continue;
            const aggregate_end = file.scopes.matchingToken(type_index + 1) orelse continue;
            var field_index = type_index + 2;
            while (field_index + 3 < aggregate_end) : (field_index += 1) {
                if (file.tokens[field_index].tag != .period or file.tokens[field_index + 1].tag != .identifier or
                    file.tokens[field_index + 2].tag != .equal or
                    file.scopes.enclosingOpeningBrace(field_index) != type_index + 1) continue;
                const value_end = aggregateFieldValueEnd(file.tokens, field_index + 3, aggregate_end);
                const call = firstCall(file.tokens, field_index + 3, value_end) orelse continue;
                const name = tokenText(file.source, file.tokens[call.name_index]);
                const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
                if (!summary_index.callReturnsOwned(file.source, receiver, name)) continue;
                const field_name = tokenText(file.source, file.tokens[field_index + 1]);
                if (evidence.proven(type_name, field_name)) continue;
                try evidence.append(allocator, .{
                    .file_index = file_index,
                    .type_name = type_name,
                    .field_name = field_name,
                    .span = file.tokens[field_index + 1].loc,
                });
            }
        }
    }
}

/// The token after `index` in a scan of a container body's own tokens: a
/// nested `{ ... }` is stepped over whole, as counting brace depth skips it.
fn nextOwnToken(file: File, index: usize) usize {
    if (file.tokens[index].tag != .l_brace) return index + 1;
    return (file.scopes.matchingToken(index) orelse return file.tokens.len) + 1;
}

/// Whether the `.field =` at `field_index` initializes a literal nested in
/// the aggregate that starts at `start`, whose fields belong to another type.
fn nestedAggregateField(file: File, field_index: usize, start: usize) bool {
    const opening = file.scopes.enclosingOpeningBrace(field_index) orelse return false;
    const parent = file.scopes.enclosingOpeningBrace(opening) orelse return false;
    return parent >= start;
}

fn aggregateFieldValueEnd(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    var depth: ValueDepth = .{};
    for (tokens[start..end], start..) |token, index| if (depth.step(token.tag)) return index;
    return end;
}

/// The delimiters a field value has opened, counted from its start: a closing
/// delimiter with none open is ignored.
const ValueDepth = struct {
    parentheses: usize = 0,
    brackets: usize = 0,
    braces: usize = 0,

    fn zero(depth: ValueDepth) bool {
        return depth.parentheses == 0 and depth.brackets == 0 and depth.braces == 0;
    }

    /// Steps over a token; whether it is a comma that ends the value.
    fn step(depth: *ValueDepth, tag: std.zig.Token.Tag) bool {
        switch (tag) {
            .l_paren => depth.parentheses += 1,
            .r_paren => depth.parentheses -|= 1,
            .l_bracket => depth.brackets += 1,
            .r_bracket => depth.brackets -|= 1,
            .l_brace => depth.braces += 1,
            .r_brace => depth.braces -|= 1,
            .comma => return depth.zero(),
            else => {},
        }
        return false;
    }
};

/// `aggregateFieldValueEnd` and `firstCall` for the fields of one range, with
/// the scans shared: where a statement chains aggregates
/// (`if (a) return .{ .x = 1 } else return .{ .x = 2 };`), the value of every
/// last field runs on to the end of the statement.
const FieldValues = struct {
    file: File,
    start: usize,
    end: usize,
    /// Per position, where a value scanned from there with no delimiter open
    /// ends, or `unknown`. Allocated by the first scan, as is `calls`.
    value_ends: []u32 = &.{},
    /// Per position, the first `name(` at or after it, or `end`.
    calls: []u32 = &.{},

    const unknown = std.math.maxInt(u32);

    /// `aggregateFieldValueEnd(tokens, value_start, end)`.
    fn valueEnd(values: *FieldValues, allocator: std.mem.Allocator, value_start: usize) !usize {
        try values.prepare(allocator);
        const tokens = values.file.tokens;
        var depth: ValueDepth = .{};
        var value_end = values.end;
        var stop = value_start;
        while (stop < values.end) : (stop += 1) {
            if (depth.zero()) {
                const known = values.value_ends[stop - values.start];
                if (known != unknown) {
                    value_end = known;
                    break;
                }
            }
            if (depth.step(tokens[stop].tag)) {
                value_end = stop;
                break;
            }
        }
        // A value scanned from a position this scan passed with nothing open
        // ends where this one does.
        depth = .{};
        for (tokens[value_start..@min(stop + 1, values.end)], value_start..) |token, index| {
            if (depth.zero()) values.value_ends[index - values.start] = @intCast(value_end);
            _ = depth.step(token.tag);
        }
        return value_end;
    }

    /// `firstCall(tokens, call_start, call_end)`, after a `valueEnd`.
    fn firstCall(values: *const FieldValues, call_start: usize, call_end: usize) ?tokens_util.Call {
        const tokens = values.file.tokens;
        var opening: usize = values.calls[call_start - values.start];
        while (opening < call_end) : (opening = values.calls[opening + 1 - values.start]) {
            const closing = values.file.scopes.matchingToken(opening) orelse continue;
            if (closing > call_end) continue;
            return .{
                .opening = opening,
                .closing = closing,
                .name_index = opening - 1,
                .receiver_index = if (opening >= 3 and tokens[opening - 2].tag == .period and
                    tokens[opening - 3].tag == .identifier) opening - 3 else null,
            };
        }
        return null;
    }

    fn prepare(values: *FieldValues, allocator: std.mem.Allocator) !void {
        if (values.calls.len != 0) return;
        const tokens = values.file.tokens;
        const length = values.end - values.start;
        values.value_ends = try allocator.alloc(u32, length);
        @memset(values.value_ends, unknown);
        values.calls = try allocator.alloc(u32, length + 1);
        var next: u32 = @intCast(values.end);
        values.calls[length] = next;
        var index = values.end;
        while (index > values.start) {
            index -= 1;
            if (tokens[index].tag == .l_paren and index != 0 and tokens[index - 1].tag == .identifier) next = @intCast(index);
            values.calls[index - values.start] = next;
        }
    }
};

/// The ends of the statements that the returns of one body are in, found as
/// the returns are visited in order, so a statement that chains several
/// returns (`if (a) return .{ ... } else return .{ ... };`) is walked once.
/// A later return of a statement, in the same block as an earlier one, sees a
/// suffix of the earlier one's fields with the same nesting, so only the
/// earlier one reads the fields proven by their values.
const ReturnStatements = struct {
    /// The statement end of each return that a walk passed in its own block,
    /// or `none`.
    ends: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// `(statement end, block)` of each return whose fields were read.
    read: std.AutoHashMapUnmanaged([2]u32, void) = .empty,
    passed: std.ArrayList(u32) = .empty,

    const none = std.math.maxInt(u32);

    const Statement = struct { end: usize, reads_direct_fields: bool };

    fn of(statements: *ReturnStatements, allocator: std.mem.Allocator, file: File, return_index: usize) !?Statement {
        const block: u32 = if (file.scopes.enclosingOpeningBrace(return_index)) |opening| @intCast(opening) else none;
        const end = statements.ends.get(@intCast(return_index)) orelse try statements.walk(allocator, file, return_index, block);
        if (end == none) return null;
        const read = try statements.read.getOrPut(allocator, .{ end, block });
        return .{ .end = end, .reads_direct_fields = !read.found_existing };
    }

    /// `syntax_scope.Index.statementEnd(return_index)`, recorded for each
    /// return the walk passes in the same block: its statement ends there too.
    fn walk(statements: *ReturnStatements, allocator: std.mem.Allocator, file: File, return_index: usize, block: u32) !u32 {
        const scopes = file.scopes;
        const limit = scopes.enclosingScopeEnd(return_index) orelse file.tokens.len;
        statements.passed.clearRetainingCapacity();
        var end: u32 = none;
        var cursor = return_index;
        while (cursor < limit) : (cursor += 1) {
            switch (file.tokens[cursor].tag) {
                .l_paren, .l_bracket, .l_brace => cursor = scopes.matchingToken(cursor) orelse break,
                .r_brace => break,
                .semicolon => {
                    end = @intCast(cursor);
                    break;
                },
                .keyword_return => if (cursor != return_index and scopes.enclosingOpeningBrace(cursor) == block) {
                    try statements.passed.append(allocator, @intCast(cursor));
                },
                else => {},
            }
        }
        for (statements.passed.items) |passed| try statements.ends.put(allocator, passed, end);
        return end;
    }
};

/// Fields of the aggregates in `[start, end)` that an owned binding
/// initializes, when it initializes no other field there.
fn collectAggregateOwnedFields(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    type_name: []const u8,
    start: usize,
    end: usize,
    binding_fields: *const NamePositions,
    evidence: *FieldEvidence,
) !void {
    if (binding_fields.count() == 0 or end < start + 4) return;
    var fields: std.ArrayList(u32) = .empty;
    defer fields.deinit(allocator);
    var bindings = binding_fields.valueIterator();
    while (bindings.next()) |positions| {
        const in_range = positionsIn(positions.items, start, end - 3);
        if (in_range.len != 1 or nestedAggregateField(file, in_range[0], start)) continue;
        try fields.append(allocator, in_range[0]);
    }
    std.mem.sortUnstable(u32, fields.items, {}, std.sort.asc(u32));
    for (fields.items) |field_index| {
        const field_name = tokenText(file.source, file.tokens[field_index + 1]);
        if (!evidence.proven(type_name, field_name)) try evidence.append(allocator, .{
            .file_index = file_index,
            .type_name = type_name,
            .field_name = field_name,
            .span = file.tokens[field_index + 1].loc,
        });
    }
}

fn collectOwnedSequenceEvidence(
    allocator: std.mem.Allocator,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *std.ArrayList(OwnedSequenceEvidence),
) !void {
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const container_start = declaration_index + 5;
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        const type_name = tokenText(file.source, file.tokens[declaration_index + 1]);
        const arena_lifetime = containerOwnsArena(file, container_start, container_end);
        var field_index = container_start;
        while (field_index < container_end) : (field_index = nextOwnToken(file, field_index)) {
            const field = file.tokens[field_index];
            if (field.tag != .identifier or field_index + 1 >= container_end or
                file.tokens[field_index + 1].tag != .colon or !fieldStoresSlices(file, field_index, container_end)) continue;
            const field_name = tokenText(file.source, field);
            if ((arena_lifetime or !try sequenceStoresOwnedAllocation(file, field_name, summary_index)) and
                !sequenceCleanupReleasesElements(file, field_name, container_start, container_end)) continue;
            try evidence.append(allocator, .{
                .file_index = file_index,
                .type_name = type_name,
                .field_name = field_name,
                .span = field.loc,
            });
        }
    }
}

fn containerOwnsArena(file: File, start: usize, end: usize) bool {
    var arena_field: ?[]const u8 = null;
    var field_index = start;
    while (field_index < end) : (field_index = nextOwnToken(file, field_index)) {
        const token = file.tokens[field_index];
        if (token.tag != .identifier or field_index + 2 >= end or
            file.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(file.tokens, field_index + 2, end);
        for (file.tokens[field_index + 2 .. field_end]) |type_token| {
            if (type_token.tag == .identifier and tokenIs(file.source, type_token, "ArenaAllocator")) {
                arena_field = tokenText(file.source, token);
                break;
            }
        }
    }
    const field_name = arena_field orelse return false;
    var arena_alias: ?[]const u8 = null;
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and tokenIs(file.source, token, field_name)) {
            const capture_end = @min(index + 7, end);
            for (file.tokens[index + 1 .. capture_end], index + 1..) |candidate, capture_index| {
                if (candidate.tag == .pipe and capture_index + 1 < capture_end and
                    file.tokens[capture_index + 1].tag == .identifier)
                {
                    arena_alias = tokenText(file.source, file.tokens[capture_index + 1]);
                    break;
                }
            }
        }
        if (token.tag != .identifier or !tokenIs(file.source, token, "deinit") or index < start + 2 or
            file.tokens[index - 1].tag != .period or file.tokens[index - 2].tag != .identifier) continue;
        const receiver = tokenText(file.source, file.tokens[index - 2]);
        if (std.mem.eql(u8, receiver, field_name) or
            (arena_alias != null and std.mem.eql(u8, receiver, arena_alias.?))) return true;
    }
    return false;
}

fn fieldStoresSlices(file: File, field_index: usize, container_end: usize) bool {
    const field_end = fieldTypeEnd(file.tokens, field_index + 2, container_end);
    for (file.tokens[field_index + 2 .. field_end], field_index + 2..) |token, type_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "ArrayList") and !tokenIs(file.source, token, "ArrayListUnmanaged")) or
            type_index + 3 >= field_end or file.tokens[type_index + 1].tag != .l_paren or
            file.tokens[type_index + 2].tag != .l_bracket) continue;
        const bracket_end = file.scopes.matchingToken(type_index + 2) orelse continue;
        if (bracket_end >= field_end) continue;
        return bracket_end == type_index + 3 or file.tokens[type_index + 3].tag == .colon;
    }
    return false;
}

/// Whether the file appends an owned allocation to a sequence field spelled
/// `field_name`; memoized per name.
fn sequenceStoresOwnedAllocation(file: File, field_name: []const u8, summary_index: summaries.Index) !bool {
    const entry = try file.facts.owned_allocations.getOrPut(file.facts.allocator, field_name);
    if (!entry.found_existing) entry.value_ptr.* = for (Facts.named(&file.facts.appends, field_name)) |method_position| {
        const method_index: usize = method_position;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        const call = firstCall(file.tokens, method_index + 2, call_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (summary_index.callReturnsOwned(file.source, receiver, name)) break true;
    } else false;
    return entry.value_ptr.*;
}

fn sequenceCleanupReleasesElements(
    file: File,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= end or file.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
        const receiver = firstParameterName(file, function_index + 3, parameters_end) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        const element = sequenceElementCapture(file, receiver, field_name, body_start + 1, body_end) orelse continue;
        if (rawElementReleased(file, element, body_start + 1, body_end)) return true;
    }
    return false;
}

fn findOwnedSequenceIssues(
    run: ProjectRun,
    file: File,
    summary_index: summaries.Index,
    evidence: []const OwnedSequenceEvidence,
) !void {
    for (evidence) |sequence| {
        const container = file.facts.containers.get(sequence.type_name) orelse continue;
        try findOwnedSequenceCleanupOmissions(run, file, sequence, container);
        try findOwnedSequenceDiscardedRemovals(run, file, sequence, container);
        try findOwnedSequenceOverwrites(
            run,
            file,
            summary_index,
            sequence,
            container,
        );
        try findInlineOwnedSequenceInsertions(
            run,
            file,
            summary_index,
            sequence,
            container,
        );
    }
}

const TypeContainer = struct { start: usize, end: usize };

fn findOwnedSequenceCleanupOmissions(
    run: ProjectRun,
    file: File,
    sequence: OwnedSequenceEvidence,
    container: TypeContainer,
) !void {
    if (run.configuration.level(.incomplete_owned_field_cleanup) == .off) return;
    for (file.tokens[container.start..container.end], container.start..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= container.end or
            file.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
        const receiver = firstParameterName(file, function_index + 3, parameters_end) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        const drop = sequenceDropCall(file, receiver, sequence.field_name, body_start + 1, body_end) orelse continue;
        if (cleanupDelegatesToAnotherMethod(file, receiver, sequence.field_name, body_start + 1, body_end)) continue;
        if (sequenceElementCapture(file, receiver, sequence.field_name, body_start + 1, body_end)) |element| {
            if (rawElementReleased(file, element, body_start + 1, body_end)) continue;
        }
        try run.report(.{
            .file_index = sequence.file_index,
            .rule = .incomplete_owned_field_cleanup,
            .span = file.tokens[drop].loc,
            .message = try run.allocator.print(
                "{s} drops owned slice elements stored in '{s}.{s}' without freeing them",
                .{ tokenText(file.source, file.tokens[drop]), sequence.type_name, sequence.field_name },
            ),
        });
    }
}

fn rawElementReleased(file: File, element: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        for (file.tokens[method_index + 2 .. @min(call_end, end)]) |argument| {
            if (argument.tag == .identifier and tokenIs(file.source, argument, element)) return true;
        }
    }
    return false;
}

fn findOwnedSequenceDiscardedRemovals(
    run: ProjectRun,
    file: File,
    sequence: OwnedSequenceEvidence,
    container: TypeContainer,
) !void {
    if (run.configuration.level(.unreleased_allocation) == .off) return;
    for (file.tokens[container.start..container.end], container.start..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !tokenIs(file.source, file.tokens[equal_index - 1], "_")) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        for (file.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "swapRemove") and !tokenIs(file.source, candidate, "orderedRemove")) or
                method_index < 2 or file.tokens[method_index - 1].tag != .period or
                !tokenIs(file.source, file.tokens[method_index - 2], sequence.field_name) or
                rawSequenceElementReleasedBefore(file, sequence.field_name, method_index)) continue;
            try run.report(.{
                .file_index = sequence.file_index,
                .rule = .unreleased_allocation,
                .span = candidate.loc,
                .message = try run.allocator.print(
                    "discarding an element removed from '{s}.{s}' leaks its owned slice",
                    .{ sequence.type_name, sequence.field_name },
                ),
            });
        }
    }
}

fn rawSequenceElementReleasedBefore(file: File, field_name: []const u8, before: usize) bool {
    const scope_start = file.scopes.enclosingOpeningBrace(before) orelse return false;
    return rangeReleasesRawSequenceElement(file, field_name, scope_start + 1, before);
}

fn rangeReleasesRawSequenceElement(
    file: File,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        var saw_field = false;
        var saw_items = false;
        for (file.tokens[method_index + 2 .. @min(call_end, end)]) |argument| {
            if (argument.tag != .identifier) continue;
            if (tokenIs(file.source, argument, field_name)) saw_field = true;
            if (tokenIs(file.source, argument, "items")) saw_items = true;
            if (rawAliasTargetsSequenceElement(
                file,
                tokenText(file.source, argument),
                field_name,
                start,
                method_index,
            )) return true;
        }
        if (saw_field and saw_items) return true;
    }
    return false;
}

fn rawAliasTargetsSequenceElement(
    file: File,
    alias: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= end or
            !tokenIs(file.source, file.tokens[declaration_index + 1], alias)) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= end) continue;
        var saw_field = false;
        var saw_items = false;
        for (file.tokens[declaration_index + 2 .. declaration_end]) |part| {
            if (part.tag != .identifier) continue;
            if (tokenIs(file.source, part, field_name)) saw_field = true;
            if (tokenIs(file.source, part, "items")) saw_items = true;
        }
        if (saw_field and saw_items) return true;
    }
    return false;
}

fn findOwnedSequenceOverwrites(
    run: ProjectRun,
    file: File,
    summary_index: summaries.Index,
    sequence: OwnedSequenceEvidence,
    container: TypeContainer,
) !void {
    if (run.configuration.level(.overwritten_owning_value) == .off) return;
    for (file.tokens[container.start..container.end], container.start..) |token, equal_index| {
        if (token.tag != .equal) continue;
        const items_index = findItemsBefore(file, equal_index, equal_index -| 16) orelse continue;
        if (items_index < 2 or file.tokens[items_index - 1].tag != .period or
            !tokenIs(file.source, file.tokens[items_index - 2], sequence.field_name)) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        const scope_start = file.scopes.enclosingOpeningBrace(equal_index) orelse continue;
        if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, scope_start + 1)) continue;
        const released = rangeReleasesRawSequenceElement(file, sequence.field_name, scope_start + 1, equal_index);
        if (released and !rangeContainsTry(file.tokens, equal_index + 1, statement_end)) continue;
        try run.report(.{
            .file_index = sequence.file_index,
            .rule = .overwritten_owning_value,
            .span = file.tokens[items_index].loc,
            .message = if (released)
                try run.allocator.print(
                    "fallible replacement in '{s}.{s}' occurs after its previous owned slice is freed",
                    .{ sequence.type_name, sequence.field_name },
                )
            else
                try run.allocator.print(
                    "assignment in '{s}.{s}' replaces an owned slice without freeing it",
                    .{ sequence.type_name, sequence.field_name },
                ),
        });
    }
}

fn findInlineOwnedSequenceInsertions(
    run: ProjectRun,
    file: File,
    summary_index: summaries.Index,
    sequence: OwnedSequenceEvidence,
    _: TypeContainer,
) !void {
    if (run.configuration.level(.missing_errdefer) == .off) return;
    for (Facts.named(&file.facts.appends, sequence.field_name)) |method_position| {
        const method_index: usize = method_position;
        if (!tokenIs(file.source, file.tokens[method_index], "append")) continue;
        if (inlineSequenceOwnerHasErrdefer(file, method_index)) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        const allocation_call = firstCall(file.tokens, method_index + 2, call_end) orelse continue;
        const name = tokenText(file.source, file.tokens[allocation_call.name_index]);
        const receiver = if (allocation_call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (!summary_index.callReturnsOwned(file.source, receiver, name)) continue;
        try run.report(.{
            .file_index = sequence.file_index,
            .rule = .missing_errdefer,
            .span = file.tokens[allocation_call.name_index].loc,
            .message = try run.allocator.print(
                "owned slice inserted inline into '{s}.{s}' leaks if append fails; bind it and add errdefer cleanup",
                .{ sequence.type_name, sequence.field_name },
            ),
        });
    }
}

fn inlineSequenceOwnerHasErrdefer(file: File, append_index: usize) bool {
    if (append_index < 4 or file.tokens[append_index - 3].tag != .period or
        file.tokens[append_index - 4].tag != .identifier) return false;
    const owner = tokenText(file.source, file.tokens[append_index - 4]);
    const scope_start = file.scopes.enclosingOpeningBrace(append_index) orelse return false;
    for (file.tokens[scope_start + 1 .. append_index], scope_start + 1..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = file.scopes.statementEnd(defer_index) orelse continue;
        if (defer_end >= append_index) continue;
        var saw_owner = false;
        var saw_cleanup = false;
        for (file.tokens[defer_index + 1 .. defer_end]) |candidate| {
            if (candidate.tag != .identifier) continue;
            if (tokenIs(file.source, candidate, owner)) saw_owner = true;
            if (tokenIs(file.source, candidate, "deinit") or tokenIs(file.source, candidate, "free") or
                tokenIs(file.source, candidate, "destroy")) saw_cleanup = true;
        }
        if (saw_owner and saw_cleanup) return true;
    }
    return false;
}

fn findFailureUnsafeOwnedSliceShrinks(
    run: ProjectRun,
    file: File,
    file_index: usize,
    evidence: *const FieldEvidence,
) !void {
    if (run.configuration.level(.partial_ownership_transfer) == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const container_start = declaration_index + 5;
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        var field_index = container_start;
        while (field_index < container_end) : (field_index = nextOwnToken(file, field_index)) {
            const field = file.tokens[field_index];
            if (field.tag != .identifier or field_index + 1 >= container_end or
                file.tokens[field_index + 1].tag != .colon) continue;
            const element_type = directSliceElementType(file, field_index, container_end) orelse continue;
            if (evidence.ofType(element_type).len == 0) continue;
            try findFieldFailureUnsafeShrinks(
                run,
                file,
                file_index,
                tokenText(file.source, field),
                element_type,
                container_start,
                container_end,
            );
        }
    }
}

fn directSliceElementType(file: File, field_index: usize, container_end: usize) ?[]const u8 {
    const field_end = fieldTypeEnd(file.tokens, field_index + 2, container_end);
    if (field_index + 4 >= field_end or file.tokens[field_index + 2].tag != .l_bracket) return null;
    const bracket_end = file.scopes.matchingToken(field_index + 2) orelse return null;
    if (bracket_end >= field_end or
        (bracket_end != field_index + 3 and file.tokens[field_index + 3].tag != .colon)) return null;
    return functionReturnType(file, bracket_end + 1, field_end);
}

fn findFieldFailureUnsafeShrinks(
    run: ProjectRun,
    file: File,
    file_index: usize,
    field_name: []const u8,
    element_type: []const u8,
    container_start: usize,
    container_end: usize,
) !void {
    for (file.tokens[container_start..container_end], container_start..) |token, function_index| {
        if (token.tag != .keyword_fn or function_index + 2 >= container_end or
            file.tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
        const receiver = firstParameterName(file, function_index + 3, parameters_end) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, equal_index| {
            if (candidate.tag != .equal or equal_index < 3 or
                !tokenIs(file.source, file.tokens[equal_index - 1], field_name) or
                file.tokens[equal_index - 2].tag != .period or
                !tokenIs(file.source, file.tokens[equal_index - 3], receiver)) continue;
            const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
            const realloc_index = reallocOfField(
                file,
                receiver,
                field_name,
                equal_index + 1,
                statement_end,
            ) orelse continue;
            const mutation = ownedElementCopyBefore(
                file,
                receiver,
                field_name,
                body_start + 1,
                equal_index,
            ) orelse continue;
            if (rangeHasErrdeferForField(file, field_name, mutation, equal_index)) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .partial_ownership_transfer,
                .span = file.tokens[realloc_index].loc,
                .message = try run.allocator.print(
                    "fallible shrink of '{s}' follows a move of owned '{s}' elements; realloc failure leaves duplicate ownership",
                    .{ field_name, element_type },
                ),
            });
        }
    }
}

fn reallocOfField(
    file: File,
    receiver: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) ?usize {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, "realloc") or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        if (fieldPathArgumentIndex(file, receiver, field_name, method_index + 2, @min(call_end, end)) != null) {
            return method_index;
        }
    }
    return null;
}

fn ownedElementCopyBefore(
    file: File,
    receiver: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) ?usize {
    for (file.tokens[start..end], start..) |token, equal_index| {
        if (token.tag != .equal) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        const mutation_start = statementBoundaryStart(file.tokens, equal_index, start);
        const left = indexedFieldPath(file, receiver, field_name, mutation_start, equal_index) orelse continue;
        const right = indexedFieldPath(file, receiver, field_name, equal_index + 1, @min(statement_end, end)) orelse continue;
        const left_text = file.source[file.tokens[left.start].loc.start..file.tokens[left.end].loc.end];
        const right_text = file.source[file.tokens[right.start].loc.start..file.tokens[right.end].loc.end];
        if (!std.mem.eql(u8, left_text, right_text)) return equal_index;
    }
    return null;
}

fn statementBoundaryStart(tokens: []const std.zig.Token, index: usize, minimum: usize) usize {
    var cursor = index;
    while (cursor > minimum) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .semicolon, .l_brace, .r_brace => return cursor + 1,
            else => {},
        }
    }
    return minimum;
}

const IndexedFieldPath = struct { start: usize, end: usize };

fn indexedFieldPath(
    file: File,
    receiver: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) ?IndexedFieldPath {
    var selected: ?IndexedFieldPath = null;
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], field_name) or file.tokens[index + 3].tag != .l_bracket) continue;
        const bracket_end = file.scopes.matchingToken(index + 3) orelse continue;
        if (bracket_end >= end) continue;
        selected = .{ .start = index, .end = bracket_end };
    }
    return selected;
}

fn rangeHasErrdeferForField(
    file: File,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = file.scopes.statementEnd(defer_index) orelse continue;
        if (defer_end > end) continue;
        for (file.tokens[defer_index + 1 .. defer_end]) |part| {
            if (part.tag == .identifier and tokenIs(file.source, part, field_name)) return true;
        }
    }
    return false;
}

fn collectSequenceElementTypes(
    allocator: std.mem.Allocator,
    file: File,
    entries: *std.StringHashMapUnmanaged(?[]const u8),
) !void {
    for (file.tokens, 0..) |token, field_index| {
        if (token.tag != .identifier or field_index + 4 >= file.tokens.len or file.tokens[field_index + 1].tag != .colon) continue;
        const field_end = fieldTypeEnd(file.tokens, field_index + 2, file.tokens.len);
        var declares_list = false;
        for (file.tokens[field_index + 2 .. field_end], field_index + 2..) |candidate, type_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "ArrayList") and !tokenIs(file.source, candidate, "ArrayListUnmanaged")) or
                type_index + 2 >= field_end or file.tokens[type_index + 1].tag != .l_paren) continue;
            var element_index = type_index + 2;
            while (element_index < field_end and (file.tokens[element_index].tag == .asterisk or
                file.tokens[element_index].tag == .question_mark or file.tokens[element_index].tag == .keyword_const)) : (element_index += 1)
            {}
            if (element_index >= field_end or file.tokens[element_index].tag != .identifier) continue;
            var element_end = element_index;
            while (element_end + 2 < field_end and file.tokens[element_end + 1].tag == .period and
                file.tokens[element_end + 2].tag == .identifier) element_end += 2;
            const element_type = tokenText(file.source, file.tokens[element_end]);
            const entry = try entries.getOrPut(allocator, tokenText(file.source, token));
            if (!entry.found_existing) {
                entry.value_ptr.* = element_type;
            } else if (entry.value_ptr.*) |known| {
                if (!std.mem.eql(u8, known, element_type)) entry.value_ptr.* = null;
            }
            declares_list = true;
        }
        // A field of the same name that holds no list leaves the name ambiguous.
        if (!declares_list and file.scopes.isContainerFieldDeclaration(field_index)) {
            try entries.put(allocator, tokenText(file.source, token), null);
        }
    }
}

/// Returns the closing brace when `index` opens a nested struct declaration, so
/// member scans attribute direct members to each container exactly once. It
/// matches only the `const Name = struct {` shape that the struct scans process
/// independently; anything else keeps the legacy overlapping scan.
fn nestedStructClose(file: File, index: usize, end: usize) ?usize {
    if (index + 4 >= end) return null;
    const tokens = file.tokens;
    if (tokens[index].tag != .keyword_const or tokens[index + 1].tag != .identifier or
        tokens[index + 2].tag != .equal or tokens[index + 3].tag != .keyword_struct or
        tokens[index + 4].tag != .l_brace) return null;
    const close = file.scopes.matchingToken(index + 4) orelse return null;
    if (close >= end) return null;
    return close;
}

fn findIncompleteOwnedElementCleanup(
    run: ProjectRun,
    file: File,
    file_index: usize,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.incomplete_owned_field_cleanup);
    if (level == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .keyword_struct or file.tokens[declaration_index + 4].tag != .l_brace) continue;
        const container_end = file.scopes.matchingToken(declaration_index + 4) orelse continue;
        var field_index = declaration_index + 5;
        while (field_index < container_end) : (field_index += 1) {
            if (nestedStructClose(file, field_index, container_end)) |close| {
                field_index = close;
                continue;
            }
            const field_token = file.tokens[field_index];
            if (field_token.tag != .identifier or field_index + 1 >= container_end or
                file.tokens[field_index + 1].tag != .colon) continue;
            const sequence_field = tokenText(file.source, field_token);
            const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
            if (evidence.ofType(element_type).len == 0) continue;
            try findSequenceCleanupOmissions(
                run,
                file,
                file_index,
                declaration_index + 5,
                container_end,
                sequence_field,
                element_type,
                evidence,
            );
        }
    }
}

fn findSequenceCleanupOmissions(
    run: ProjectRun,
    file: File,
    file_index: usize,
    container_start: usize,
    container_end: usize,
    sequence_field: []const u8,
    element_type: []const u8,
    evidence: *const FieldEvidence,
) !void {
    var fn_index = container_start;
    while (fn_index < container_end) : (fn_index += 1) {
        if (nestedStructClose(file, fn_index, container_end)) |close| {
            fn_index = close;
            continue;
        }
        const token = file.tokens[fn_index];
        if (token.tag != .keyword_fn or fn_index + 2 >= container_end or file.tokens[fn_index + 1].tag != .identifier or
            file.tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = file.scopes.matchingToken(fn_index + 2) orelse continue;
        const receiver = firstParameterName(file, fn_index + 3, parameters_end) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        if (body_end > container_end) continue;
        const drop = sequenceDropCall(file, receiver, sequence_field, body_start + 1, body_end) orelse continue;
        if (cleanupDelegatesToAnotherMethod(file, receiver, sequence_field, body_start + 1, body_end)) continue;
        const capture = sequenceElementCapture(file, receiver, sequence_field, body_start + 1, body_end);
        if (capture) |element| {
            if (elementCleanupIsOpaque(file, element, body_start + 1, body_end)) continue;
        }
        for (evidence.ofType(element_type)) |position| {
            const owned_field = evidence.items.items[position];
            if (sequenceFieldReleasedByHelper(
                file,
                receiver,
                sequence_field,
                owned_field.field_name,
                body_start + 1,
                body_end,
            )) continue;
            if (capture) |element| {
                if (elementFieldReleased(file, element, owned_field.field_name, body_start + 1, body_end)) continue;
                if (optionalElementFieldReleased(file, element, owned_field.field_name, body_start + 1, body_end)) continue;
            }
            try run.report(.{
                .file_index = file_index,
                .rule = .incomplete_owned_field_cleanup,
                .span = file.tokens[drop].loc,
                .message = try run.allocator.print(
                    "{s} drops '{s}' elements without releasing proven owned field '{s}'",
                    .{ tokenText(file.source, file.tokens[drop]), element_type, owned_field.field_name },
                ),
            });
        }
    }
}

fn firstParameterName(file: File, start: usize, end: usize) ?[]const u8 {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and file.tokens[index + 1].tag == .colon) {
            return tokenText(file.source, token);
        }
    }
    return null;
}

fn sequenceDropCall(
    file: File,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?usize {
    const methods = [_][]const u8{ "deinit", "clearRetainingCapacity", "clearAndFree" };
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], sequence_field) or file.tokens[index + 3].tag != .period or
            file.tokens[index + 4].tag != .identifier or file.tokens[index + 5].tag != .l_paren) continue;
        for (methods) |method| if (tokenIs(file.source, file.tokens[index + 4], method)) return index + 4;
    }
    return null;
}

fn cleanupDelegatesToAnotherMethod(
    file: File,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) bool {
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver) or file.tokens[index + 1].tag != .period or
            file.tokens[index + 2].tag != .identifier or file.tokens[index + 3].tag != .l_paren) continue;
        if (!tokenIs(file.source, file.tokens[index + 2], sequence_field)) return true;
    }
    return false;
}

fn sequenceElementCapture(
    file: File,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?[]const u8 {
    var index = start;
    while (index + 7 < end) : (index += 1) {
        if (file.tokens[index].tag != .keyword_for or file.tokens[index + 1].tag != .l_paren) continue;
        const condition_end = file.scopes.matchingToken(index + 1) orelse continue;
        var names_sequence = false;
        var condition = index + 2;
        while (condition + 4 < condition_end) : (condition += 1) {
            if (tokenIs(file.source, file.tokens[condition], receiver) and file.tokens[condition + 1].tag == .period and
                tokenIs(file.source, file.tokens[condition + 2], sequence_field) and file.tokens[condition + 3].tag == .period and
                tokenIs(file.source, file.tokens[condition + 4], "items")) names_sequence = true;
        }
        if (!names_sequence or condition_end + 3 >= end or file.tokens[condition_end + 1].tag != .pipe) continue;
        const capture_index = if (file.tokens[condition_end + 2].tag == .asterisk) condition_end + 3 else condition_end + 2;
        if (capture_index + 1 >= end or file.tokens[capture_index].tag != .identifier or
            file.tokens[capture_index + 1].tag != .pipe) continue;
        return tokenText(file.source, file.tokens[capture_index]);
    }
    return null;
}

fn elementCleanupIsOpaque(file: File, element: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (!tokenIs(file.source, token, element)) continue;
        if (index + 3 < end and file.tokens[index + 1].tag == .period and
            tokenIs(file.source, file.tokens[index + 2], "deinit") and file.tokens[index + 3].tag == .l_paren) return true;
        if (index > start and file.tokens[index - 1].tag == .l_paren and
            (index + 1 >= end or file.tokens[index + 1].tag != .period) and
            (index < 2 or file.tokens[index - 2].tag != .identifier or
                (!tokenIs(file.source, file.tokens[index - 2], "free") and !tokenIs(file.source, file.tokens[index - 2], "destroy")))) return true;
    }
    return false;
}

fn sequenceFieldReleasedByHelper(
    file: File,
    receiver: []const u8,
    sequence_field: []const u8,
    owned_field: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, call_index| {
        if (token.tag != .identifier or call_index + 1 >= end or file.tokens[call_index + 1].tag != .l_paren or
            (call_index > 0 and (file.tokens[call_index - 1].tag == .period or file.tokens[call_index - 1].tag == .keyword_fn))) continue;
        const call_end = file.scopes.matchingToken(call_index + 1) orelse continue;
        const argument_index = sequencePathArgumentIndex(file, receiver, sequence_field, call_index + 2, call_end) orelse continue;
        const functions = Facts.named(&file.facts.functions, tokenText(file.source, token));
        if (functions.len != 1) continue;
        const function_index: usize = functions[0];
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
        const parameter = parameterNameAt(file, function_index + 3, parameters_end, argument_index) orelse continue;
        const helper_body = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const helper_end = file.scopes.matchingToken(helper_body) orelse continue;
        const element = sequenceParameterCapture(file, parameter, helper_body + 1, helper_end) orelse continue;
        if (elementFieldReleased(file, element, owned_field, helper_body + 1, helper_end)) return true;
    }
    return false;
}

fn sequencePathArgumentIndex(
    file: File,
    receiver: []const u8,
    sequence_field: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (file.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (file.tokens[index].tag != .comma or depth != 0)) continue;
        var path_index = segment_start;
        while (path_index + 4 < index) : (path_index += 1) {
            if (tokenIs(file.source, file.tokens[path_index], receiver) and file.tokens[path_index + 1].tag == .period and
                tokenIs(file.source, file.tokens[path_index + 2], sequence_field) and file.tokens[path_index + 3].tag == .period and
                tokenIs(file.source, file.tokens[path_index + 4], "items")) return argument_index;
        }
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn parameterNameAt(file: File, start: usize, end: usize, wanted: usize) ?[]const u8 {
    var parameter_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (file.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (file.tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter_index == wanted) {
            for (file.tokens[segment_start..index], segment_start..) |candidate, name_index| {
                if (candidate.tag == .identifier and name_index + 1 < index and
                    file.tokens[name_index + 1].tag == .colon) return tokenText(file.source, candidate);
            }
            return null;
        }
        parameter_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn sequenceParameterCapture(file: File, parameter: []const u8, start: usize, end: usize) ?[]const u8 {
    for (file.tokens[start..end], start..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 1 >= end or file.tokens[for_index + 1].tag != .l_paren) continue;
        const condition_end = file.scopes.matchingToken(for_index + 1) orelse continue;
        var names_parameter = false;
        for (file.tokens[for_index + 2 .. condition_end]) |condition| {
            if (condition.tag == .identifier and tokenIs(file.source, condition, parameter)) names_parameter = true;
        }
        if (!names_parameter or condition_end + 3 >= end or file.tokens[condition_end + 1].tag != .pipe) continue;
        const capture_index = if (file.tokens[condition_end + 2].tag == .asterisk) condition_end + 3 else condition_end + 2;
        if (capture_index + 1 >= end or file.tokens[capture_index].tag != .identifier or
            file.tokens[capture_index + 1].tag != .pipe) continue;
        return tokenText(file.source, file.tokens[capture_index]);
    }
    return null;
}

fn elementFieldReleased(
    file: File,
    element: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        var index = method_index + 2;
        while (index + 2 < call_end) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], element) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], field)) return true;
        }
    }
    return false;
}

fn optionalElementFieldReleased(
    file: File,
    element: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) bool {
    var capture: ?[]const u8 = null;
    var index = start;
    while (index + 6 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], element) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], field) or file.tokens[index + 3].tag != .r_paren or
            file.tokens[index + 4].tag != .pipe or file.tokens[index + 5].tag != .identifier or
            file.tokens[index + 6].tag != .pipe) continue;
        capture = tokenText(file.source, file.tokens[index + 5]);
        break;
    }
    const binding = capture orelse return false;
    for (file.tokens[start..end], start..) |token, release_index| {
        if (tokenIs(file.source, token, binding) and release_index + 3 < end and
            file.tokens[release_index + 1].tag == .period and tokenIs(file.source, file.tokens[release_index + 2], "deinit") and
            file.tokens[release_index + 3].tag == .l_paren) return true;
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            release_index + 1 >= end or file.tokens[release_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(release_index + 1) orelse continue;
        for (file.tokens[release_index + 2 .. @min(call_end, end)], release_index + 2..) |argument, argument_index| {
            if (argument.tag == .identifier and tokenIs(file.source, file.tokens[argument_index], binding)) return true;
        }
    }
    return false;
}

fn findRemovedOwnedValueTransfers(
    run: ProjectRun,
    file: File,
    file_index: usize,
    evidence: *const FieldEvidence,
) !void {
    if (run.configuration.level(.partial_ownership_transfer) == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or
            declaration_index + 3 >= file.tokens.len or file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        const sequence_field = try removedValueSequence(file, declaration_index + 2, declaration_end) orelse continue;
        const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
        if (evidence.ofType(element_type).len == 0) continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);
        const scope_end = file.scopes.enclosingScopeEnd(declaration_index) orelse continue;
        const insertion = fallibleInsertionOfBinding(file, binding, declaration_end + 1, scope_end) orelse continue;
        if (rangeHasErrdeferForBinding(file, binding, declaration_end + 1, insertion)) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = .partial_ownership_transfer,
            .span = file.tokens[insertion].loc,
            .message = try run.allocator.print(
                "fallible insertion can lose removed owned '{s}' value '{s}' when it fails",
                .{ element_type, binding },
            ),
        });
    }
}

fn removedValueSequence(file: File, start: usize, end: usize) !?[]const u8 {
    const removals = positionsIn(try file.facts.removalMethods(file), start, end);
    if (removals.len == 0) return null;
    return tokenText(file.source, file.tokens[removals[0] - 2]);
}

fn fallibleInsertionOfBinding(
    file: File,
    binding: []const u8,
    start: usize,
    end: usize,
) ?usize {
    for (file.tokens[start..end], start..) |token, try_index| {
        if (token.tag != .keyword_try) continue;
        const statement_end = file.scopes.statementEnd(try_index) orelse continue;
        if (statement_end > end) continue;
        for (file.tokens[try_index + 1 .. statement_end], try_index + 1..) |candidate, call_index| {
            if (candidate.tag != .identifier or call_index + 1 >= statement_end or
                file.tokens[call_index + 1].tag != .l_paren) continue;
            const call_end = file.scopes.matchingToken(call_index + 1) orelse continue;
            if (call_end > statement_end) continue;
            const argument_index = bareArgumentPosition(file, binding, call_index + 2, call_end) orelse continue;
            const function_name = tokenText(file.source, candidate);
            const receiver_parameter = @intFromBool(call_index > 0 and file.tokens[call_index - 1].tag == .period);
            if (standardFallibleInsertion(function_name) and localFunctionCount(file, function_name) == 0) return call_index;
            if (localFunctionForwardsToFallibleInsertion(file, function_name, argument_index + receiver_parameter)) return call_index;
        }
    }
    return null;
}

fn standardFallibleInsertion(function_name: []const u8) bool {
    return std.mem.eql(u8, function_name, "append") or std.mem.eql(u8, function_name, "insert") or
        std.mem.eql(u8, function_name, "put");
}

fn localFunctionCount(file: File, function_name: []const u8) usize {
    return file.facts.function_counts.get(function_name) orelse 0;
}

fn localFunctionForwardsToFallibleInsertion(
    file: File,
    function_name: []const u8,
    parameter_index: usize,
) bool {
    if (localFunctionCount(file, function_name) != 1) return false;
    for (Facts.named(&file.facts.functions, function_name)) |function_position| {
        const function_index: usize = function_position;
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse return false;
        const parameter = parameterNameAt(file, function_index + 3, parameters_end, parameter_index) orelse return false;
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse return false;
        const body_end = file.scopes.matchingToken(body_start) orelse return false;
        for (file.tokens[body_start + 1 .. body_end], body_start + 1..) |candidate, try_index| {
            if (candidate.tag != .keyword_try) continue;
            const statement_end = file.scopes.statementEnd(try_index) orelse continue;
            if (statement_end > body_end) continue;
            for (file.tokens[try_index + 1 .. statement_end], try_index + 1..) |call, call_index| {
                if (call.tag != .identifier or !standardFallibleInsertion(tokenText(file.source, call)) or
                    localFunctionCount(file, tokenText(file.source, call)) != 0 or
                    call_index + 1 >= statement_end or file.tokens[call_index + 1].tag != .l_paren) continue;
                const call_end = file.scopes.matchingToken(call_index + 1) orelse continue;
                if (call_end > statement_end or
                    bareArgumentPosition(file, parameter, call_index + 2, call_end) == null) continue;
                return !rangeHasErrdeferForBinding(file, parameter, body_start + 1, call_index);
            }
        }
    }
    return false;
}

fn bareArgumentPosition(file: File, binding: []const u8, start: usize, end: usize) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (file.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (file.tokens[index].tag != .comma or depth != 0)) continue;
        if (segment_start + 1 == index and tokenIs(file.source, file.tokens[segment_start], binding)) return argument_index;
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn rangeHasErrdeferForBinding(
    file: File,
    binding: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = file.scopes.statementEnd(defer_index) orelse continue;
        if (defer_end > end) continue;
        for (file.tokens[defer_index + 1 .. defer_end]) |candidate| {
            if (candidate.tag == .identifier and tokenIs(file.source, candidate, binding)) return true;
        }
    }
    return false;
}

fn findDroppedOwnedElements(
    run: ProjectRun,
    file: File,
    file_index: usize,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.unreleased_allocation);
    if (level == .off) return;
    for (file.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or !tokenIs(file.source, file.tokens[equal_index - 1], "_")) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        for (file.tokens[equal_index + 1 .. statement_end], equal_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or
                (!tokenIs(file.source, candidate, "swapRemove") and !tokenIs(file.source, candidate, "orderedRemove")) or
                method_index < 2 or file.tokens[method_index - 1].tag != .period or file.tokens[method_index - 2].tag != .identifier) continue;
            const sequence_field = tokenText(file.source, file.tokens[method_index - 2]);
            const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
            if (removedElementTransferredBefore(file, sequence_field, method_index)) continue;
            if (sequenceElementDeinitializedBeforeRemoval(file, sequence_field, method_index)) continue;
            if (try sequenceStoresPointers(file, sequence_field) and
                removedPointerMatchesParameter(file, sequence_field, method_index)) continue;
            var reported = false;
            for (evidence.ofType(element_type)) |position| {
                const owned_field = evidence.items.items[position];
                if (elementFieldReleasedBeforeRemoval(file, owned_field.field_name, method_index)) continue;
                try run.report(.{
                    .file_index = file_index,
                    .rule = .unreleased_allocation,
                    .span = candidate.loc,
                    .message = try run.allocator.print(
                        "discarding removed '{s}' drops proven owned field '{s}'",
                        .{ element_type, owned_field.field_name },
                    ),
                });
                reported = true;
            }
            if (reported) continue;
            const cleanup_field = try sequenceCleanupOwnedField(file, sequence_field) orelse continue;
            if (elementFieldReleasedBeforeRemoval(file, cleanup_field, method_index)) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .unreleased_allocation,
                .span = candidate.loc,
                .message = try run.allocator.print(
                    "discarding removed '{s}' drops proven owned field '{s}'",
                    .{ element_type, cleanup_field },
                ),
            });
        }
    }
}

/// The element field the first cleanup loop over `sequence_field.items`
/// frees.
fn sequenceCleanupOwnedField(file: File, sequence_field: []const u8) !?[]const u8 {
    if (file.facts.cleanup_owned_fields == null) {
        // A loop's freed field does not depend on the sequence it is looked up
        // for, so one pass records it for every name its iterable mentions.
        var cleanups: std.StringHashMapUnmanaged([]const u8) = .empty;
        errdefer cleanups.deinit(file.facts.allocator);
        for (file.tokens, 0..) |token, for_index| {
            if (token.tag != .keyword_for or for_index + 1 >= file.tokens.len or
                file.tokens[for_index + 1].tag != .l_paren) continue;
            const iterable_end = file.scopes.matchingToken(for_index + 1) orelse continue;
            var names_items = false;
            for (file.tokens[for_index + 2 .. iterable_end]) |part| {
                if (part.tag == .identifier and tokenIs(file.source, part, "items")) names_items = true;
            }
            if (!names_items) continue;
            const freed = loopFreedElementField(file, for_index, iterable_end) orelse continue;
            for (file.tokens[for_index + 2 .. iterable_end]) |part| {
                if (part.tag != .identifier) continue;
                const entry = try cleanups.getOrPut(file.facts.allocator, tokenText(file.source, part));
                if (!entry.found_existing) entry.value_ptr.* = freed;
            }
        }
        file.facts.cleanup_owned_fields = cleanups;
    }
    return file.facts.cleanup_owned_fields.?.get(sequence_field);
}

/// The field of the capture that the loop `for (...) |element|` at
/// `for_index` frees first, as in `free(element.name)`.
fn loopFreedElementField(file: File, for_index: usize, iterable_end: usize) ?[]const u8 {
    if (iterable_end + 2 >= file.tokens.len or
        file.tokens[iterable_end + 1].tag != .pipe or file.tokens[iterable_end + 2].tag != .identifier) return null;
    const element = tokenText(file.source, file.tokens[iterable_end + 2]);
    const cleanup_end = file.scopes.statementEnd(for_index) orelse return null;
    var index = iterable_end + 3;
    while (index + 4 < cleanup_end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], "free") or file.tokens[index + 1].tag != .l_paren) continue;
        const free_end = file.scopes.matchingToken(index + 1) orelse continue;
        if (free_end > cleanup_end) continue;
        var argument_index = index + 2;
        while (argument_index + 2 < free_end) : (argument_index += 1) {
            if (!tokenIs(file.source, file.tokens[argument_index], element) or
                file.tokens[argument_index + 1].tag != .period or
                file.tokens[argument_index + 2].tag != .identifier) continue;
            return tokenText(file.source, file.tokens[argument_index + 2]);
        }
    }
    return null;
}

fn removedElementTransferredBefore(
    file: File,
    sequence_field: []const u8,
    removal_index: usize,
) bool {
    if (removal_index + 1 >= file.tokens.len or file.tokens[removal_index + 1].tag != .l_paren) return false;
    const removal_end = file.scopes.matchingToken(removal_index + 1) orelse return false;
    var removed_index: ?[]const u8 = null;
    for (file.tokens[removal_index + 2 .. removal_end]) |argument| {
        if (argument.tag != .identifier) continue;
        if (removed_index != null) return false;
        removed_index = tokenText(file.source, argument);
    }
    const index_name = removed_index orelse return false;
    const scope_start = file.scopes.enclosingOpeningBrace(removal_index) orelse return false;
    for (file.tokens[scope_start + 1 .. removal_index], scope_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= removal_index or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= removal_index) continue;
        var saw_sequence = false;
        var saw_items = false;
        var saw_index = false;
        for (file.tokens[declaration_index + 2 .. declaration_end]) |part| {
            if (part.tag != .identifier) continue;
            if (tokenIs(file.source, part, sequence_field)) saw_sequence = true;
            if (tokenIs(file.source, part, "items")) saw_items = true;
            if (tokenIs(file.source, part, index_name)) saw_index = true;
        }
        if (!saw_sequence or !saw_items or !saw_index) continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);
        for (file.tokens[declaration_end + 1 .. removal_index], declaration_end + 1..) |candidate, append_index| {
            if (candidate.tag != .identifier or !tokenIs(file.source, candidate, "append") or
                append_index + 1 >= removal_index or file.tokens[append_index + 1].tag != .l_paren) continue;
            const append_end = file.scopes.matchingToken(append_index + 1) orelse continue;
            if (append_end >= removal_index or bareArgumentPosition(file, binding, append_index + 2, append_end) == null) continue;
            const append_statement_start = statementBoundaryStart(file.tokens, append_index, declaration_end + 1);
            const append_statement_end = file.scopes.statementEnd(append_index) orelse continue;
            if (rangeContainsTry(file.tokens, append_statement_start, append_statement_end)) return true;
        }
    }
    return false;
}

fn sequenceElementDeinitializedBeforeRemoval(
    file: File,
    sequence_field: []const u8,
    removal_index: usize,
) bool {
    if (removal_index + 1 >= file.tokens.len or file.tokens[removal_index + 1].tag != .l_paren) return false;
    const removal_end = file.scopes.matchingToken(removal_index + 1) orelse return false;
    const scope_start = file.scopes.enclosingOpeningBrace(removal_index) orelse return false;
    var path_index = scope_start + 1;
    while (path_index + 7 < removal_index) : (path_index += 1) {
        if (!tokenIs(file.source, file.tokens[path_index], sequence_field) or
            file.tokens[path_index + 1].tag != .period or !tokenIs(file.source, file.tokens[path_index + 2], "items") or
            file.tokens[path_index + 3].tag != .l_bracket) continue;
        const bracket_end = file.scopes.matchingToken(path_index + 3) orelse continue;
        if (bracket_end + 3 >= removal_index or file.tokens[bracket_end + 1].tag != .period or
            !tokenIs(file.source, file.tokens[bracket_end + 2], "deinit") or
            file.tokens[bracket_end + 3].tag != .l_paren) continue;
        if (tokenRangesHaveSameSpelling(
            file,
            path_index + 4,
            bracket_end,
            removal_index + 2,
            removal_end,
        )) return true;
    }
    return capturedElementDeinitializedBeforeRemoval(file, sequence_field, removal_index, removal_end);
}

/// `for (list.items, 0..) |*entry, index| { entry.deinit(..); _ = list.swapRemove(index); }`.
fn capturedElementDeinitializedBeforeRemoval(
    file: File,
    sequence_field: []const u8,
    removal_index: usize,
    removal_end: usize,
) bool {
    const tokens = file.tokens;
    if (removal_end != removal_index + 3 or tokens[removal_index + 2].tag != .identifier) return false;
    const removed = tokenText(file.source, tokens[removal_index + 2]);
    var brace = file.scopes.enclosingOpeningBrace(removal_index);
    while (brace) |opening| : (brace = file.scopes.enclosingOpeningBrace(opening)) {
        // `) |*entry, index| {`
        if (opening < 7 or tokens[opening - 1].tag != .pipe or !tokenIs(file.source, tokens[opening - 2], removed) or
            tokens[opening - 3].tag != .comma or tokens[opening - 4].tag != .identifier) continue;
        const capture_open = if (tokens[opening - 5].tag == .asterisk) opening - 6 else opening - 5;
        if (tokens[capture_open].tag != .pipe or tokens[capture_open - 1].tag != .r_paren) return false;
        const loop_open = file.scopes.matchingToken(capture_open - 1) orelse return false;
        if (loop_open == 0 or tokens[loop_open - 1].tag != .keyword_for or
            !rangeEndsWithItemsOf(file, sequence_field, loop_open + 1, capture_open - 1)) return false;
        const element = tokenText(file.source, tokens[opening - 4]);
        for (tokens[opening + 1 .. removal_index], opening + 1..) |token, index| {
            if (tokenIs(file.source, token, element) and tokens[index + 1].tag == .period and
                tokenIs(file.source, tokens[index + 2], "deinit") and tokens[index + 3].tag == .l_paren) return true;
        }
        return false;
    }
    return false;
}

/// Whether the first loop operand in `[start, end)` is `<path>.sequence_field.items`.
fn rangeEndsWithItemsOf(file: File, sequence_field: []const u8, start: usize, end: usize) bool {
    const operand_end = aggregateFieldValueEnd(file.tokens, start, end);
    return operand_end >= start + 3 and tokenIs(file.source, file.tokens[operand_end - 1], "items") and
        file.tokens[operand_end - 2].tag == .period and tokenIs(file.source, file.tokens[operand_end - 3], sequence_field);
}

/// Whether the `ArrayList` fields spelled `field_name` all hold pointers.
fn sequenceStoresPointers(file: File, field_name: []const u8) !bool {
    if (file.facts.stores_pointers == null) {
        // One pass records, per name, whether every such field holds pointers.
        var pointers: std.StringHashMapUnmanaged(bool) = .empty;
        errdefer pointers.deinit(file.facts.allocator);
        for (file.tokens, 0..) |token, field_index| {
            if (token.tag != .identifier or field_index + 4 >= file.tokens.len or file.tokens[field_index + 1].tag != .colon) continue;
            const field_end = fieldTypeEnd(file.tokens, field_index + 2, file.tokens.len);
            for (file.tokens[field_index + 2 .. field_end], field_index + 2..) |candidate, type_index| {
                if (candidate.tag != .identifier or
                    (!tokenIs(file.source, candidate, "ArrayList") and !tokenIs(file.source, candidate, "ArrayListUnmanaged")) or
                    type_index + 2 >= field_end or file.tokens[type_index + 1].tag != .l_paren) continue;
                const entry = try pointers.getOrPut(file.facts.allocator, tokenText(file.source, token));
                if (file.tokens[type_index + 2].tag != .asterisk) {
                    entry.value_ptr.* = false;
                } else if (!entry.found_existing) {
                    entry.value_ptr.* = true;
                }
            }
        }
        file.facts.stores_pointers = pointers;
    }
    return file.facts.stores_pointers.?.get(field_name) orelse false;
}

const ContainingFunction = struct {
    parameters_start: usize,
    parameters_end: usize,
    body_start: usize,
};

/// The innermost `fn name(...)` body around `target`: function bodies nest,
/// so it is the first one met walking out through the enclosing blocks.
fn functionContaining(file: File, target: usize) ?ContainingFunction {
    var brace = file.scopes.enclosingOpeningBrace(target);
    while (brace) |opening| : (brace = file.scopes.enclosingOpeningBrace(opening)) {
        const function = file.facts.function_bodies.get(opening) orelse continue;
        const body_end = file.scopes.matchingToken(opening) orelse continue;
        if (target <= opening or target >= body_end) continue;
        return function;
    }
    return null;
}

fn removedPointerMatchesParameter(
    file: File,
    sequence_field: []const u8,
    removal_index: usize,
) bool {
    if (removal_index + 1 >= file.tokens.len or file.tokens[removal_index + 1].tag != .l_paren) return false;
    const removal_end = file.scopes.matchingToken(removal_index + 1) orelse return false;
    if (removal_index + 3 != removal_end or file.tokens[removal_index + 2].tag != .identifier) return false;
    const removal_position = tokenText(file.source, file.tokens[removal_index + 2]);
    const function = functionContaining(file, removal_index) orelse return false;

    var for_index = function.body_start + 1;
    while (for_index < removal_index) : (for_index += 1) {
        if (file.tokens[for_index].tag != .keyword_for or for_index + 1 >= removal_index or
            file.tokens[for_index + 1].tag != .l_paren) continue;
        const iterable_end = file.scopes.matchingToken(for_index + 1) orelse continue;
        if (iterable_end + 5 >= removal_index or file.tokens[iterable_end + 1].tag != .pipe) continue;
        var saw_sequence = false;
        var saw_items = false;
        for (file.tokens[for_index + 2 .. iterable_end]) |part| {
            if (part.tag != .identifier) continue;
            if (tokenIs(file.source, part, sequence_field)) saw_sequence = true;
            if (tokenIs(file.source, part, "items")) saw_items = true;
        }
        if (!saw_sequence or !saw_items) continue;
        const element_capture = file.tokens[iterable_end + 2];
        if (element_capture.tag != .identifier or file.tokens[iterable_end + 3].tag != .comma or
            file.tokens[iterable_end + 4].tag != .identifier or file.tokens[iterable_end + 5].tag != .pipe or
            !tokenIs(file.source, file.tokens[iterable_end + 4], removal_position)) continue;
        const element_name = tokenText(file.source, element_capture);
        for (file.tokens[function.parameters_start..function.parameters_end], function.parameters_start..) |parameter, parameter_index| {
            if (parameter.tag != .identifier or parameter_index + 1 >= function.parameters_end or
                file.tokens[parameter_index + 1].tag != .colon) continue;
            const parameter_name = tokenText(file.source, parameter);
            if (namesComparedBefore(file, element_name, parameter_name, iterable_end + 6, removal_index)) return true;
        }
    }
    return false;
}

fn namesComparedBefore(
    file: File,
    left_name: []const u8,
    right_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, comparison_index| {
        if (token.tag != .equal_equal or comparison_index == start or comparison_index + 1 >= end) continue;
        const left = file.tokens[comparison_index - 1];
        const right = file.tokens[comparison_index + 1];
        if (left.tag != .identifier or right.tag != .identifier) continue;
        if ((tokenIs(file.source, left, left_name) and tokenIs(file.source, right, right_name)) or
            (tokenIs(file.source, left, right_name) and tokenIs(file.source, right, left_name))) return true;
    }
    return false;
}

fn tokenRangesHaveSameSpelling(
    file: File,
    left_start: usize,
    left_end: usize,
    right_start: usize,
    right_end: usize,
) bool {
    if (left_end - left_start != right_end - right_start) return false;
    for (file.tokens[left_start..left_end], 0..) |left, offset| {
        if (!std.mem.eql(u8, tokenText(file.source, left), tokenText(file.source, file.tokens[right_start + offset]))) {
            return false;
        }
    }
    return true;
}

fn elementFieldReleasedBeforeRemoval(file: File, field_name: []const u8, removal_index: usize) bool {
    const scope_start = file.scopes.enclosingOpeningBrace(removal_index) orelse return false;
    for (file.tokens[scope_start + 1 .. removal_index], scope_start + 1..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= removal_index or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        if (call_end >= removal_index) continue;
        var index = method_index + 2;
        while (index + 1 < call_end) : (index += 1) {
            if (file.tokens[index].tag == .period and tokenIs(file.source, file.tokens[index + 1], field_name)) return true;
        }
    }
    return false;
}

fn findOwnedElementOverwrites(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (file.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 6) continue;
        const field_index = equal_index - 1;
        if (file.tokens[field_index].tag != .identifier or file.tokens[field_index - 1].tag != .period) continue;
        const items_index = findItemsBefore(file, field_index, equal_index -| 16) orelse continue;
        if (items_index < 2 or file.tokens[items_index - 1].tag != .period or file.tokens[items_index - 2].tag != .identifier) continue;
        const sequence_field = tokenText(file.source, file.tokens[items_index - 2]);
        const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
        const field_name = tokenText(file.source, file.tokens[field_index]);
        if (!evidence.proven(element_type, field_name)) continue;
        const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
        const scope_start = file.scopes.enclosingOpeningBrace(equal_index) orelse continue;
        if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, scope_start + 1)) continue;
        const released = rangeReleasesElementField(file, sequence_field, field_name, scope_start + 1, equal_index);
        if (released and !rangeContainsTry(file.tokens, equal_index + 1, statement_end)) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = .overwritten_owning_value,
            .span = file.tokens[field_index].loc,
            .message = if (released)
                try run.allocator.print(
                    "fallible replacement of proven owned field '{s}.{s}' occurs after its previous allocation is released",
                    .{ element_type, field_name },
                )
            else
                try run.allocator.print(
                    "assignment replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                    .{ element_type, field_name },
                ),
        });
    }
}

fn findAliasedOwnedElementOverwrites(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier or file.tokens[declaration_index + 2].tag != .equal or
            file.tokens[declaration_index + 3].tag != .ampersand) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        const items_index = findItemsBefore(file, declaration_end, declaration_index + 3) orelse continue;
        if (items_index < 2 or file.tokens[items_index - 1].tag != .period or
            file.tokens[items_index - 2].tag != .identifier) continue;
        const sequence_field = tokenText(file.source, file.tokens[items_index - 2]);
        const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
        const alias = tokenText(file.source, file.tokens[declaration_index + 1]);
        const scope_end = file.scopes.enclosingScopeEnd(declaration_index) orelse continue;
        var equal_index = declaration_end + 1;
        while (equal_index + 2 < scope_end) : (equal_index += 1) {
            if (file.tokens[equal_index].tag != .equal or file.tokens[equal_index - 1].tag != .identifier or
                file.tokens[equal_index - 2].tag != .period or !tokenIs(file.source, file.tokens[equal_index - 3], alias)) continue;
            const field_index = equal_index - 1;
            const field_name = tokenText(file.source, file.tokens[field_index]);
            if (!evidence.proven(element_type, field_name)) continue;
            const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
            if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, declaration_end + 1)) continue;
            const released = rangeReleasesAliasedField(file, alias, field_name, declaration_end + 1, equal_index);
            if (released and !rangeContainsTry(file.tokens, equal_index + 1, statement_end)) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .overwritten_owning_value,
                .span = file.tokens[field_index].loc,
                .message = if (released)
                    try run.allocator.print(
                        "fallible replacement through alias '{s}' occurs after proven owned field '{s}.{s}' is released",
                        .{ alias, element_type, field_name },
                    )
                else
                    try run.allocator.print(
                        "assignment through alias '{s}' replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                        .{ alias, element_type, field_name },
                    ),
            });
        }
    }
}

fn findCapturedOwnedElementOverwrites(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
    evidence: *const FieldEvidence,
) !void {
    const level = run.configuration.level(.overwritten_owning_value);
    if (level == .off) return;
    for (file.tokens, 0..) |token, for_index| {
        if (token.tag != .keyword_for or for_index + 1 >= file.tokens.len or
            file.tokens[for_index + 1].tag != .l_paren) continue;
        const sequence_end = file.scopes.matchingToken(for_index + 1) orelse continue;
        const items_index = findItemsBefore(file, sequence_end, for_index + 2) orelse continue;
        if (items_index < 2 or file.tokens[items_index - 1].tag != .period or
            file.tokens[items_index - 2].tag != .identifier) continue;
        const sequence_field = tokenText(file.source, file.tokens[items_index - 2]);
        const element_type = try file.facts.elementType(file, sequence_field) orelse continue;
        if (sequence_end + 4 >= file.tokens.len or file.tokens[sequence_end + 1].tag != .pipe or
            file.tokens[sequence_end + 2].tag != .asterisk or file.tokens[sequence_end + 3].tag != .identifier or
            file.tokens[sequence_end + 4].tag != .pipe) continue;
        const alias = tokenText(file.source, file.tokens[sequence_end + 3]);
        const body_open = sequence_end + 5;
        if (body_open >= file.tokens.len) continue;
        const body_start = if (file.tokens[body_open].tag == .l_brace) body_open + 1 else body_open;
        const body_end = if (file.tokens[body_open].tag == .l_brace)
            file.scopes.matchingToken(body_open) orelse continue
        else
            file.scopes.statementEnd(for_index) orelse firstNestedBodyEnd(file, body_open) orelse continue;
        var equal_index = body_start;
        while (equal_index + 2 < body_end) : (equal_index += 1) {
            if (file.tokens[equal_index].tag != .equal or file.tokens[equal_index - 1].tag != .identifier or
                file.tokens[equal_index - 2].tag != .period or !tokenIs(file.source, file.tokens[equal_index - 3], alias)) continue;
            const field_index = equal_index - 1;
            const field_name = tokenText(file.source, file.tokens[field_index]);
            if (!evidence.proven(element_type, field_name)) continue;
            const statement_end = file.scopes.statementEnd(equal_index) orelse continue;
            if (!assignmentAcquiresOwned(file, summary_index, equal_index + 1, statement_end, body_start)) continue;
            const released = rangeReleasesAliasedField(file, alias, field_name, body_start, equal_index);
            if (released and !rangeContainsTry(file.tokens, equal_index + 1, statement_end)) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .overwritten_owning_value,
                .span = file.tokens[field_index].loc,
                .message = if (released)
                    try run.allocator.print(
                        "fallible replacement through pointer capture '{s}' occurs after proven owned field '{s}.{s}' is released",
                        .{ alias, element_type, field_name },
                    )
                else
                    try run.allocator.print(
                        "assignment through pointer capture '{s}' replaces proven owned field '{s}.{s}' without releasing its previous allocation",
                        .{ alias, element_type, field_name },
                    ),
            });
        }
    }
}

fn firstNestedBodyEnd(file: File, start: usize) ?usize {
    const scope_end = file.scopes.enclosingScopeEnd(start) orelse return null;
    for (file.tokens[start..scope_end], start..) |token, opening| {
        if (token.tag == .l_brace) return file.scopes.matchingToken(opening);
    }
    return null;
}

fn rangeContainsTry(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| if (token.tag == .keyword_try) return true;
    return false;
}

fn assignmentAcquiresOwned(
    file: File,
    summary_index: summaries.Index,
    start: usize,
    end: usize,
    declaration_start: usize,
) bool {
    if (firstCall(file.tokens, start, end)) |call| {
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (summary_index.callReturnsOwned(file.source, receiver, name)) return true;
    }
    if (start + 1 != end or file.tokens[start].tag != .identifier) return false;
    const binding = tokenText(file.source, file.tokens[start]);
    const assignment_scope = file.scopes.enclosingOpeningBrace(start) orelse return false;
    for (file.tokens[declaration_start..start], declaration_start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 1 >= start or
            !tokenIs(file.source, file.tokens[declaration_index + 1], binding)) continue;
        const declaration_scope = file.scopes.enclosingOpeningBrace(declaration_index) orelse continue;
        if (declaration_scope != assignment_scope) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= start) continue;
        const call = firstCall(file.tokens, declaration_index + 2, declaration_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        if (summary_index.callReturnsOwned(file.source, receiver, name)) return true;
    }
    return false;
}

fn rangeReleasesAliasedField(
    file: File,
    alias: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy")) or
            method_index + 1 >= end or file.tokens[method_index + 1].tag != .l_paren) continue;
        const call_end = file.scopes.matchingToken(method_index + 1) orelse continue;
        var index = method_index + 2;
        while (index + 2 < @min(call_end, end)) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], alias) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], field_name)) return true;
        }
    }
    return false;
}

fn findItemsBefore(file: File, end: usize, start: usize) ?usize {
    var index = end;
    while (index > start) {
        index -= 1;
        if (tokenIs(file.source, file.tokens[index], "items")) return index;
        if (file.tokens[index].tag == .semicolon or file.tokens[index].tag == .l_brace) return null;
    }
    return null;
}

fn rangeReleasesElementField(
    file: File,
    sequence_field: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIs(file.source, token, "free") and !tokenIs(file.source, token, "destroy"))) continue;
        const statement_end = file.scopes.statementEnd(method_index) orelse continue;
        var saw_sequence = false;
        var saw_field = false;
        for (file.tokens[method_index + 1 .. @min(statement_end, end)], method_index + 1..) |argument, index| {
            if (argument.tag != .identifier) continue;
            if (tokenIs(file.source, argument, sequence_field)) saw_sequence = true;
            if (tokenIs(file.source, file.tokens[index], field_name)) saw_field = true;
            const alias = tokenText(file.source, argument);
            if (fieldAliasTargetsElement(file, alias, sequence_field, field_name, start, method_index)) return true;
        }
        if (saw_sequence and saw_field) return true;
    }
    return false;
}

fn fieldAliasTargetsElement(
    file: File,
    alias: []const u8,
    sequence_field: []const u8,
    field_name: []const u8,
    start: usize,
    end: usize,
) bool {
    for (file.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 2 >= end or
            !tokenIs(file.source, file.tokens[declaration_index + 1], alias)) continue;
        const declaration_end = file.scopes.statementEnd(declaration_index) orelse continue;
        if (declaration_end >= end) continue;
        var saw_sequence = false;
        var saw_field = false;
        for (file.tokens[declaration_index + 2 .. declaration_end]) |part| {
            if (part.tag != .identifier) continue;
            if (tokenIs(file.source, part, sequence_field)) saw_sequence = true;
            if (tokenIs(file.source, part, field_name)) saw_field = true;
        }
        if (saw_sequence and saw_field) return true;
    }
    return false;
}

fn functionReturnType(file: File, start: usize, end: usize) ?[]const u8 {
    var selected: ?[]const u8 = null;
    for (file.tokens[start..end]) |token| {
        if (token.tag == .identifier) selected = tokenText(file.source, token);
    }
    return selected;
}

const CleanupMethod = struct {
    receiver: []const u8,
    body_start: usize,
    body_end: usize,
};

/// The `deinit` the container `[start, end)` declares itself; a nested
/// type's `deinit` cleans up that type.
fn cleanupMethod(file: File, start: usize, end: usize) ?CleanupMethod {
    for (Facts.namedIn(&file.facts.functions, "deinit", start, end)) |function_position| {
        const fn_index: usize = function_position;
        if (fn_index + 3 >= end or file.tokens[fn_index + 1].tag != .identifier or
            file.scopes.enclosingOpeningBrace(fn_index) != start - 1) continue;
        const parameters_end = file.scopes.matchingToken(fn_index + 2) orelse continue;
        var receiver: ?[]const u8 = null;
        for (file.tokens[fn_index + 3 .. parameters_end], fn_index + 3..) |parameter, index| {
            if (parameter.tag == .identifier and index + 1 < parameters_end and file.tokens[index + 1].tag == .colon) {
                receiver = tokenText(file.source, parameter);
                break;
            }
        }
        const body_start = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const body_end = file.scopes.matchingToken(body_start) orelse continue;
        return .{ .receiver = receiver orelse continue, .body_start = body_start, .body_end = body_end };
    }
    return null;
}

fn fieldReleased(
    file: File,
    cleanup: CleanupMethod,
    container_start: usize,
    container_end: usize,
    evidence: *const FieldEvidence,
    field: []const u8,
) !bool {
    var index = cleanup.body_start + 1;
    while (index + 2 < cleanup.body_end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], cleanup.receiver) or file.tokens[index + 1].tag != .period or
            !tokenIs(file.source, file.tokens[index + 2], field)) continue;
        if (optionalFieldCaptureReleased(file, cleanup, index) or switchCaptureReleased(file, cleanup, index)) return true;
        if (index + 4 < cleanup.body_end and file.tokens[index + 3].tag == .period and
            releaseMethod(file, index + 4)) return true;
        var cursor = index;
        while (cursor > cleanup.body_start and index - cursor < 6) {
            cursor -= 1;
            if (file.tokens[cursor].tag == .identifier and
                (tokenIs(file.source, file.tokens[cursor], "free") or tokenIs(file.source, file.tokens[cursor], "destroy"))) return true;
            if (file.tokens[cursor].tag == .semicolon or file.tokens[cursor].tag == .l_brace) break;
        }
    }
    return try aggregateFieldReleasedByHelper(
        file,
        evidence,
        cleanup.receiver,
        field,
        cleanup.body_start + 1,
        cleanup.body_end,
        container_start,
        container_end,
    );
}

fn aggregateFieldReleasedByHelper(
    file: File,
    evidence: *const FieldEvidence,
    receiver: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
    container_start: usize,
    container_end: usize,
) !bool {
    const field_type = try declaredFieldTypeName(file, container_start, container_end, field) orelse return false;
    var call_index = start;
    while (call_index + 1 < end) : (call_index += 1) {
        if (file.tokens[call_index].tag != .identifier or file.tokens[call_index + 1].tag != .l_paren or
            call_index < 2 or file.tokens[call_index - 1].tag != .period or
            !tokenIs(file.source, file.tokens[call_index - 2], receiver)) continue;
        const call_end = file.scopes.matchingToken(call_index + 1) orelse continue;
        if (call_end >= end) continue;
        const argument_index = fieldPathArgumentIndex(
            file,
            receiver,
            field,
            call_index + 2,
            call_end,
        ) orelse continue;
        const function_name = tokenText(file.source, file.tokens[call_index]);
        var selected_function: ?usize = null;
        for (Facts.namedIn(&file.facts.functions, function_name, container_start, container_end)) |function_position| {
            const function_index: usize = function_position;
            if (function_index + 2 >= container_end or
                file.scopes.enclosingOpeningBrace(function_index) != container_start - 1) continue;
            if (selected_function != null) {
                selected_function = null;
                break;
            }
            selected_function = function_index;
        }
        const function_index = selected_function orelse continue;
        const parameters_end = file.scopes.matchingToken(function_index + 2) orelse continue;
        const parameter = parameterNameAt(file, function_index + 3, parameters_end, argument_index + 1) orelse continue;
        const parameter_type = parameterTypeNameAt(file, function_index + 3, parameters_end, argument_index + 1) orelse continue;
        if (!std.mem.eql(u8, field_type, parameter_type)) continue;
        const helper_body = syntax_scope.functionBodyAfterParameters(file.tokens, parameters_end) orelse continue;
        const helper_end = file.scopes.matchingToken(helper_body) orelse continue;
        var owned_field_count: usize = 0;
        var released_field_count: usize = 0;
        for (evidence.ofType(field_type)) |position| {
            const owned_field = evidence.items.items[position];
            owned_field_count += 1;
            if (elementFieldReleased(
                file,
                parameter,
                owned_field.field_name,
                helper_body + 1,
                helper_end,
            )) released_field_count += 1;
        }
        if (owned_field_count != 0 and released_field_count == owned_field_count) return true;
    }
    return false;
}

fn declaredFieldTypeName(
    file: File,
    start: usize,
    end: usize,
    field: []const u8,
) !?[]const u8 {
    const field_index = try file.facts.containerField(file, start, end, field) orelse return null;
    return functionReturnType(file, field_index + 2, fieldTypeEnd(file.tokens, field_index + 2, end));
}

fn fieldPathArgumentIndex(
    file: File,
    receiver: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (file.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (file.tokens[index].tag != .comma or depth != 0)) continue;
        var path_index = segment_start;
        while (path_index + 2 < index) : (path_index += 1) {
            if (tokenIs(file.source, file.tokens[path_index], receiver) and
                file.tokens[path_index + 1].tag == .period and
                tokenIs(file.source, file.tokens[path_index + 2], field)) return argument_index;
        }
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn parameterTypeNameAt(file: File, start: usize, end: usize, wanted: usize) ?[]const u8 {
    var parameter_index: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (file.tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (file.tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter_index == wanted) {
            var colon: ?usize = null;
            for (file.tokens[segment_start..index], segment_start..) |candidate, candidate_index| {
                if (candidate.tag == .colon) colon = candidate_index;
            }
            const type_start = (colon orelse return null) + 1;
            return functionReturnType(file, type_start, index);
        }
        parameter_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn optionalFieldCaptureReleased(file: File, cleanup: CleanupMethod, field_index: usize) bool {
    var capture_open = field_index + 3;
    while (capture_open < cleanup.body_end and capture_open - field_index < 8 and
        file.tokens[capture_open].tag != .pipe) : (capture_open += 1)
    {}
    if (capture_open + 2 >= cleanup.body_end or file.tokens[capture_open].tag != .pipe) return false;
    const capture_index = if (file.tokens[capture_open + 1].tag == .asterisk) capture_open + 2 else capture_open + 1;
    if (capture_index + 1 >= cleanup.body_end or file.tokens[capture_index].tag != .identifier or
        file.tokens[capture_index + 1].tag != .pipe) return false;
    const capture = tokenText(file.source, file.tokens[capture_index]);
    const branch_start = capture_index + 2;
    const branch_end = if (branch_start < cleanup.body_end and file.tokens[branch_start].tag == .l_brace)
        file.scopes.matchingToken(branch_start) orelse cleanup.body_end
    else
        @min(file.scopes.statementEnd(branch_start) orelse cleanup.body_end, cleanup.body_end);
    return captureReleased(file, capture, branch_start, branch_end);
}

/// `switch (self.field) { .tag => |value| allocator.free(value), ... }`: a
/// prong that releases its capture releases the field's owned payload.
fn switchCaptureReleased(file: File, cleanup: CleanupMethod, field_index: usize) bool {
    const tokens = file.tokens;
    if (field_index < 2 or tokens[field_index - 1].tag != .l_paren or tokens[field_index - 2].tag != .keyword_switch or
        field_index + 4 >= cleanup.body_end or tokens[field_index + 3].tag != .r_paren or
        tokens[field_index + 4].tag != .l_brace) return false;
    const opening = field_index + 4;
    const closing = file.scopes.matchingToken(opening) orelse return false;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, arrow| {
        if (token.tag != .equal_angle_bracket_right or tokens[arrow + 1].tag != .pipe or
            file.scopes.enclosingOpeningBrace(arrow) != opening) continue;
        const capture_index = if (tokens[arrow + 2].tag == .asterisk) arrow + 3 else arrow + 2;
        if (capture_index + 2 >= closing or tokens[capture_index].tag != .identifier or
            tokens[capture_index + 1].tag != .pipe) continue;
        const prong_start = capture_index + 2;
        const prong_end = if (tokens[prong_start].tag == .l_brace)
            file.scopes.matchingToken(prong_start) orelse closing
        else
            aggregateFieldValueEnd(tokens, prong_start, closing);
        if (captureReleased(file, tokenText(file.source, tokens[capture_index]), prong_start, prong_end)) return true;
    }
    return false;
}

/// `deinit`, `close`, or a reference-counted handle's `release`.
fn releaseMethod(file: File, index: usize) bool {
    return tokenIs(file.source, file.tokens[index], "deinit") or tokenIs(file.source, file.tokens[index], "close") or
        tokenIs(file.source, file.tokens[index], "release");
}

/// Whether `[start, end)` releases `capture`: `capture.deinit()`,
/// `capture.close()`, `capture.release()`, or a `free` or `destroy` call taking it.
fn captureReleased(file: File, capture: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (!tokenIs(file.source, token, capture)) continue;
        if (index + 2 < end and file.tokens[index + 1].tag == .period and file.tokens[index + 2].tag == .identifier and
            releaseMethod(file, index + 2)) return true;
        var cursor = index;
        while (cursor > start and index - cursor < 6) {
            cursor -= 1;
            if (file.tokens[cursor].tag == .identifier and
                (tokenIs(file.source, file.tokens[cursor], "free") or tokenIs(file.source, file.tokens[cursor], "destroy"))) return true;
            if (file.tokens[cursor].tag == .semicolon or file.tokens[cursor].tag == .l_brace) break;
        }
    }
    return false;
}

test "cleanup methods release every proven owned field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Record = struct { title: []u8, payload: []u8, allocator: std.mem.Allocator, " ++
            "fn deinit(self: Record) void { self.allocator.free(self.title); } };" ++
            "fn make(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
            "fn makeRecord(allocator: std.mem.Allocator) !Record {" ++
            "const title = try make(allocator, \"title\"); const payload = try make(allocator, \"payload\");" ++
            "return .{ .title = title, .payload = payload, .allocator = allocator }; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "returns chained in one statement prove the fields each one alone initializes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The first return's statement holds both aggregates, so each binding
    // initializes two fields there; the second return's holds one.
    const source: [:0]const u8 = "const Record = struct { title: []u8, payload: []u8, allocator: std.mem.Allocator, " ++
        "fn deinit(self: Record) void { self.allocator.free(self.title); } };" ++
        "fn make(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
        "fn makeRecord(allocator: std.mem.Allocator, short: bool) !Record {" ++
        "const title = try make(allocator, \"title\"); const payload = try make(allocator, \"payload\");" ++
        "if (short) return .{ .title = title, .payload = payload, .allocator = allocator }" ++
        " else return .{ .title = title, .payload = payload, .allocator = allocator }; }";
    const files = [_]project.SourceFile{.{ .path = "src/main.zig", .source = source }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanups: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanups += 1;
        try std.testing.expectEqual(std.mem.findLast(u8, source, ".payload").? + 1, finding.finding.span.start);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanups);
}

test "an aggregate that owns its arena releases every field with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/config.zig",
        .source = "const Derived = struct { arena: std.heap.ArenaAllocator, title: []u8, words: []u8, keys: []u8," ++
            "fn init(gpa: std.mem.Allocator) !Derived { var arena = std.heap.ArenaAllocator.init(gpa); errdefer arena.deinit();" ++
            "const alloc = arena.allocator(); const title = try alloc.dupe(u8, \"t\"); const words = try alloc.dupe(u8, \"w\");" ++
            "const keys = try alloc.dupe(u8, \"k\"); return .{ .title = title, .words = words, .keys = keys, .arena = arena }; }" ++
            "fn deinit(self: *Derived) void { self.arena.deinit(); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "nested struct cleanup drops report once per owned field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/store.zig",
        .source = "const Entry = struct { payload: []u8 };" ++
            "const Outer = struct { const Store = struct { items: std.ArrayList(Entry)," ++
            "fn add(self: *Store, allocator: std.mem.Allocator, text: []const u8) !void {" ++
            "try self.items.append(allocator, .{ .payload = try allocator.dupe(u8, text) }); }" ++
            "fn deinit(self: *Store, allocator: std.mem.Allocator) void { self.items.deinit(allocator); } } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "aggregate cleanup helpers release owned fields before replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/machine.zig",
        .source = "const State = struct { name: []u8, payload: []u8 };" ++
            "const Machine = struct { allocator: std.mem.Allocator, current: State, checkpoints: List," ++
            "fn freeState(self: *Machine, state: State) void { self.allocator.free(state.name); self.allocator.free(state.payload); }" ++
            "fn deinit(self: *Machine) void { self.freeState(self.current); self.checkpoints.deinit(self.allocator); }" ++
            "fn replace(self: *Machine, name: []const u8, payload: []const u8) !void { const next = State{" ++
            ".name = try self.allocator.dupe(u8, name), .payload = try self.allocator.dupe(u8, payload) };" ++
            "self.freeState(self.current); self.current = next; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
        try std.testing.expect(finding.finding.rule != .overwritten_owning_value);
    }
}

test "cleanup helpers release every proven owned element field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/store.zig",
        .source = "const Record = struct { key: []u8, value: []u8 };" ++
            "const Store = struct { allocator: std.mem.Allocator, records: std.ArrayList(Record)," ++
            "fn add(self: *Store, key: []const u8, value: []const u8) !void { try self.records.append(self.allocator, .{" ++
            ".key = try self.allocator.dupe(u8, key), .value = try self.allocator.dupe(u8, value) }); }" ++
            "fn deinit(self: *Store) void { freeRecords(self.allocator, self.records.items); self.records.deinit(self.allocator); } };" ++
            "fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {" ++
            "for (records) |record| { allocator.free(record.key); allocator.free(record.value); } }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "owned field evidence remains separate for same-named types in different files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "const Record = struct { first: []u8, second: []u8, allocator: std.mem.Allocator, " ++
        "fn deinit(self: Record) void { self.allocator.free(self.first); } };" ++
        "fn copy(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
        "fn make(allocator: std.mem.Allocator) !Record { const first = try copy(allocator, \"a\");" ++
        "const second = try copy(allocator, \"b\"); return .{ .first = first, .second = second, .allocator = allocator }; }";
    const files = [_]project.SourceFile{
        .{ .path = "src/first.zig", .source = source },
        .{ .path = "src/second.zig", .source = source },
    };
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "container cleanup preserves every proven owned element field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn deinit(self: *Cache) void { for (self.entries.items) |entry| self.allocator.free(entry.key);" ++
            "self.entries.deinit(self.allocator); }" ++
            "fn clear(self: *Cache) void { for (self.entries.items) |entry| self.allocator.free(entry.key);" ++
            "self.entries.clearRetainingCapacity(); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "value") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "owned slice sequences require cleanup and failure safe insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/pool.zig",
        .source = "const Pool = struct { allocator: std.mem.Allocator, strings: std.ArrayList([]u8) = .empty," ++
            "fn deinit(self: *Pool) void { self.strings.deinit(self.allocator); }" ++
            "fn insert(self: *Pool, value: []const u8) !void {" ++
            "try self.strings.append(self.allocator, try self.allocator.dupe(u8, value)); }" ++
            "fn replace(self: *Pool, index: usize, value: []const u8) !void {" ++
            "self.strings.items[index] = try self.allocator.dupe(u8, value); }" ++
            "fn remove(self: *Pool, index: usize) void { _ = self.strings.orderedRemove(index); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    var insertion_count: usize = 0;
    var overwrite_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .incomplete_owned_field_cleanup => cleanup_count += 1,
        .missing_errdefer => if (std.mem.find(u8, finding.finding.message, "inserted inline") != null) {
            insertion_count += 1;
        },
        .overwritten_owning_value => overwrite_count += 1,
        .unreleased_allocation => if (std.mem.find(u8, finding.finding.message, "removed from 'Pool.strings'") != null) {
            removal_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
    try std.testing.expectEqual(@as(usize, 1), insertion_count);
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);
    try std.testing.expectEqual(@as(usize, 1), removal_count);
}

test "owned slice fields mutated through a parent container retain their obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/directory.zig",
        .source = "const Contact = struct { tags: std.ArrayList([]u8) = .empty," ++
            "aliases: std.ArrayList([]u8) = .empty };" ++
            "const Directory = struct { allocator: std.mem.Allocator, contacts: std.ArrayList(Contact) = .empty," ++
            "fn tag(self: *Directory, index: usize, value: []const u8) !void {" ++
            "try self.contacts.items[index].tags.append(self.allocator, try self.allocator.dupe(u8, value)); }" ++
            "fn alias(self: *Directory, index: usize, value: []const u8) !void {" ++
            "try self.contacts.items[index].aliases.append(self.allocator, try self.allocator.dupe(u8, value)); }" ++
            "fn deinit(self: *Directory) void { self.contacts.deinit(self.allocator); }" ++
            "fn remove(self: *Directory, index: usize) void { _ = self.contacts.orderedRemove(index); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var insertion_count: usize = 0;
    var cleanup_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .missing_errdefer => if (std.mem.find(u8, finding.finding.message, "inserted inline") != null) {
            insertion_count += 1;
        },
        .incomplete_owned_field_cleanup => cleanup_count += 1,
        .unreleased_allocation => if (std.mem.find(u8, finding.finding.message, "removed 'Contact'") != null) {
            removal_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), insertion_count);
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
}

test "aggregate errdefer covers nested inline slice insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/profile.zig",
        .source = "const Profile = struct { allocator: std.mem.Allocator, tags: std.ArrayList([]u8) = .empty," ++
            "fn deinit(self: *Profile) void { for (self.tags.items) |tag| self.allocator.free(tag);" ++
            "self.tags.deinit(self.allocator); }" ++
            "fn clone(self: *const Profile, allocator: std.mem.Allocator) !Profile {" ++
            "var copy = Profile{ .allocator = allocator }; errdefer copy.deinit();" ++
            "for (self.tags.items) |tag| try copy.tags.append(allocator, try allocator.dupe(u8, tag));" ++
            "return copy; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "inserted inline") == null);
    }
}

test "arena owned aggregate does not require per element rollback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/options.zig",
        .source = "const Options = struct { _arena: ?std.heap.ArenaAllocator = null," ++
            "arguments: std.ArrayList([]const u8) = .empty," ++
            "fn parse(self: *Options, allocator: std.mem.Allocator, value: []const u8) !void {" ++
            "try self.arguments.append(allocator, try allocator.dupe(u8, value)); }" ++
            "fn deinit(self: *Options) void { if (self._arena) |owned_arena| owned_arena.deinit(); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "inserted inline") == null);
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "Options.arguments") == null);
    }
}

test "owned slice sequences with explicit transfers stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/pool.zig",
        .source = "const Pool = struct { allocator: std.mem.Allocator, strings: std.ArrayList([]u8) = .empty," ++
            "fn deinit(self: *Pool) void { for (self.strings.items) |value| self.allocator.free(value);" ++
            "self.strings.deinit(self.allocator); }" ++
            "fn insert(self: *Pool, value: []const u8) !void { const owned = try self.allocator.dupe(u8, value);" ++
            "errdefer self.allocator.free(owned); try self.strings.append(self.allocator, owned); }" ++
            "fn replace(self: *Pool, index: usize, value: []const u8) !void {" ++
            "const previous = self.strings.items[index]; const replacement = try self.allocator.dupe(u8, value);" ++
            "self.allocator.free(previous);" ++
            "self.strings.items[index] = replacement; }" ++
            "fn remove(self: *Pool, index: usize) void { const removed = self.strings.orderedRemove(index);" ++
            "self.allocator.free(removed); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
        try std.testing.expect(finding.finding.rule != .overwritten_owning_value);
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "inserted inline") == null);
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "removed from 'Pool.strings'") == null);
    }
}

test "fallible slice shrink after moving owned elements reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: []Entry," ++
            "fn add(self: *Cache, key: []const u8) !void { const entry = Entry{ .key = try self.allocator.dupe(u8, key) };" ++
            "_ = entry; }" ++
            "fn remove(self: *Cache, index: usize) !void { const result = self.entries[index];" ++
            "for (index..self.entries.len - 1) |position| self.entries[position] = self.entries[position + 1];" ++
            "self.entries = try self.allocator.realloc(self.entries, self.entries.len - 1);" ++
            "self.allocator.free(result.key); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var shrink_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .partial_ownership_transfer and
        std.mem.find(u8, finding.finding.message, "realloc failure leaves duplicate ownership") != null)
    {
        shrink_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), shrink_count);
}

test "explicit aggregate allocations establish cleanup obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/jobs.zig",
        .source = "const Job = struct { name: []u8, payload: []u8, scratch: List," ++
            "fn deinit(self: *Job, allocator: std.mem.Allocator) void { self.scratch.deinit(allocator); } };" ++
            "const Queue = struct { allocator: std.mem.Allocator, jobs: std.ArrayListUnmanaged(Job) = .empty," ++
            "fn add(self: *Queue, name: []const u8, payload: []const u8) !void { const job = Job{" ++
            ".name = try self.allocator.dupe(u8, name), .payload = try self.allocator.dupe(u8, payload), .scratch = .empty };" ++
            "try self.jobs.append(self.allocator, job); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule == .incomplete_owned_field_cleanup) cleanup_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "inline aggregate allocations establish element cleanup obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayList(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8) !*Entry { try self.entries.append(self.allocator," ++
            ".{ .key = try self.allocator.dupe(u8, key), .value = &.{} }); return &self.entries.items[0]; }" ++
            "fn put(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const entry = try self.add(key); entry.value = try self.allocator.dupe(u8, value); }" ++
            "fn remove(self: *Cache) void { _ = self.entries.orderedRemove(0); }" ++
            "fn deinit(self: *Cache) void { self.entries.deinit(self.allocator); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .incomplete_owned_field_cleanup => cleanup_count += 1,
        .unreleased_allocation => removal_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
}

test "function return types are not mistaken for aggregate constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/journal.zig",
        .source = "const Command = struct { name: []u8, payload: []u8 };" ++
            "const Journal = struct { allocator: std.mem.Allocator, commands: std.ArrayList(Command) = .empty," ++
            "fn deinit(self: *Journal) void { self.commands.deinit(self.allocator); }" ++
            "fn clone(self: *Journal) !Journal { var copy = Journal{ .allocator = self.allocator };" ++
            "try copy.commands.append(self.allocator, .{ .name = try self.allocator.dupe(u8, \"name\")," ++
            ".payload = try self.allocator.dupe(u8, \"payload\") }); return copy; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule != .incomplete_owned_field_cleanup) continue;
        cleanup_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "cleanup for 'Journal'") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "fallible insertion after removing an owned element reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/transfers.zig",
        .source = "const Command = struct { name: []u8," ++
            "fn deinit(self: *Command, allocator: std.mem.Allocator) void { allocator.free(self.name); } };" ++
            "const Queue = struct { allocator: std.mem.Allocator, undo: std.ArrayList(Command) = .empty," ++
            "redo: std.ArrayList(Command) = .empty," ++
            "fn move(self: *Queue) !void { const command = self.undo.pop().?;" ++
            "try self.redo.append(self.allocator, command); }" ++
            "fn moveSafe(self: *Queue) !void { var command = self.undo.pop().?;" ++
            "errdefer command.deinit(self.allocator); try self.redo.append(self.allocator, command); } };" ++
            "const Node = struct { allocator: std.mem.Allocator, name: []u8, children: std.ArrayList(*Node) = .empty," ++
            "fn deinit(self: *Node) void { self.allocator.free(self.name); }" ++
            "fn addChild(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {" ++
            "try self.children.append(allocator, child); }" ++
            "fn moveChild(self: *Node, destination: *Node) !void {" ++
            "const child = self.children.orderedRemove(0); try destination.addChild(self.allocator, child); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var transfer_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .partial_ownership_transfer) {
        transfer_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), transfer_count);
}

test "discarding a local sequence element preserves project owned field evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Item = struct { name: []u8 };" ++
            "fn makeList(a: std.mem.Allocator) !std.ArrayList(Item) { var list: std.ArrayList(Item) = .empty;" ++
            "const name = try a.dupe(u8, \"one\"); errdefer a.free(name); try list.append(a, .{ .name = name }); return list; }" ++
            "fn removeAt(list: *std.ArrayList(Item), index: usize) void { _ = list.orderedRemove(index); }" ++
            "fn run(a: std.mem.Allocator) !void { var list = try makeList(a);" ++
            "defer { for (list.items) |item| a.free(item.name); list.deinit(a); } removeAt(&list, 0); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var removal_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .unreleased_allocation and
        std.mem.find(u8, finding.finding.message, "discarding removed 'Item'") != null)
    {
        removal_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), removal_count);
}

test "inserting an owned element before removing its source transfers ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/tree.zig",
        .source = "const Node = struct { name: []u8, children: std.ArrayList(*Node) = .empty," ++
            "fn deinit(self: *Node, allocator: std.mem.Allocator) void { allocator.free(self.name); } };" ++
            "fn move(source: *Node, destination: *Node, allocator: std.mem.Allocator, index: usize) !void {" ++
            "const child = source.children.items[index]; try destination.children.append(allocator, child);" ++
            "_ = source.children.orderedRemove(index); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "discarding removed 'Node'") == null);
    }
}

test "deinitializing an owned element before removal releases its fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/store.zig",
        .source = "const Record = struct { key: []u8, value: []u8," ++
            "fn deinit(self: *Record, allocator: std.mem.Allocator) void {" ++
            "allocator.free(self.key); allocator.free(self.value); } };" ++
            "const Store = struct { allocator: std.mem.Allocator, records: std.ArrayList(Record)," ++
            "fn add(self: *Store, key: []const u8, value: []const u8) !void {" ++
            "try self.records.append(self.allocator, .{ .key = try self.allocator.dupe(u8, key)," ++
            ".value = try self.allocator.dupe(u8, value) }); }" ++
            "fn remove(self: *Store, index: usize) void { self.records.items[index].deinit(self.allocator);" ++
            "_ = self.records.orderedRemove(index); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "discarding removed 'Record'") == null);
    }
}

test "removing a pointer selected by an existing parameter preserves its owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/tree.zig",
        .source = "const Node = struct { name: []u8, children: std.ArrayList(*Node) = .empty," ++
            "fn create(allocator: std.mem.Allocator, name: []const u8) !*Node {" ++
            "const node = try allocator.create(Node); node.* = .{ .name = try allocator.dupe(u8, name) }; return node; }" ++
            "fn detach(self: *Node, child: *Node) bool {" ++
            "for (self.children.items, 0..) |candidate, index| if (candidate == child) {" ++
            "_ = self.children.orderedRemove(index); return true; }; return false; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| {
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "discarding removed 'Node'") == null);
    }
}

test "owned fields returned directly from constructors establish element cleanup obligations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/logs.zig",
        .source = "const Record = struct { level: []u8, message: []u8 };" ++
            "fn parse(allocator: std.mem.Allocator) !Record { return .{ .level = try allocator.dupe(u8, \"INFO\")," ++
            ".message = try allocator.dupe(u8, \"ready\") }; }" ++
            "const Log = struct { allocator: std.mem.Allocator, records: std.ArrayListUnmanaged(Record) = .empty," ++
            "fn add(self: *Log) !void { const record = try parse(self.allocator); try self.records.append(self.allocator, record);" ++
            "_ = self.records.orderedRemove(0); } fn deinit(self: *Log) void { self.records.deinit(self.allocator); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .incomplete_owned_field_cleanup => cleanup_count += 1,
        .unreleased_allocation => if (std.mem.find(u8, finding.finding.message, "removed 'Record'") != null) {
            removal_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
}

test "complete element cleanup and delegated cleanup remain opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn clear(self: *Cache) void { for (self.entries.items) |*entry| { self.allocator.free(entry.key);" ++
            "self.allocator.free(entry.value); } self.entries.clearRetainingCapacity(); }" ++
            "fn deinit(self: *Cache) void { self.clear(); self.entries.deinit(self.allocator); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "owning elements cleared outside a cleanup-named method report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/connection.zig",
        .source = "const Packet = struct { bytes: []u8 };" ++
            "const Connection = struct { allocator: std.mem.Allocator, pending: std.ArrayListUnmanaged(Packet) = .empty," ++
            "fn enqueue(self: *Connection, payload: []const u8) !void { const copy = try self.allocator.dupe(u8, payload);" ++
            "try self.pending.append(self.allocator, .{ .bytes = copy }); }" ++
            "fn flush(self: *Connection) void { for (self.pending.items) |packet| consume(packet.bytes);" ++
            "self.pending.clearRetainingCapacity(); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var cleanup_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .incomplete_owned_field_cleanup) {
        cleanup_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.finding.message, "bytes") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "optional owning element fields released through captures stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/pool.zig",
        .source = "const Object = struct {}; const Slot = struct { object: ?*Object = null };" ++
            "const Pool = struct { allocator: std.mem.Allocator, slots: std.ArrayListUnmanaged(Slot) = .empty," ++
            "fn add(self: *Pool) !void { const object = try self.allocator.create(Object);" ++
            "try self.slots.append(self.allocator, .{ .object = object }); }" ++
            "fn deinit(self: *Pool) void { for (self.slots.items) |slot| { if (slot.object) |object| {" ++
            "self.allocator.destroy(object); } } self.slots.deinit(self.allocator); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "optional owned field captures count as cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/record.zig",
        .source = "const Record = struct { first: ?[]u8, second: ?[]u8, allocator: std.mem.Allocator," ++
            "fn deinit(self: Record) void { if (self.first) |first| self.allocator.free(first);" ++
            "if (self.second) |second| self.allocator.free(second); } };" ++
            "fn make(allocator: std.mem.Allocator) !Record { const first = try allocator.dupe(u8, \"a\");" ++
            "const second = try allocator.dupe(u8, \"b\"); return .{ .first = first, .second = second, .allocator = allocator }; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "several fields aliasing one allocation do not invent several owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/aliases.zig",
        .source = "const Aliases = struct { view: []const u8, owned: ?[]u8," ++
            "fn deinit(self: Aliases, allocator: std.mem.Allocator) void {" ++
            "if (self.owned) |owned| allocator.free(owned); } };" ++
            "fn make(allocator: std.mem.Allocator) !Aliases { const bytes = try allocator.dupe(u8, \"a\");" ++
            "return .{ .view = bytes, .owned = bytes }; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .incomplete_owned_field_cleanup);
}

test "overwriting and discarding proven owned element fields report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/cache.zig",
        .source = "const Entry = struct { key: []u8, value: []u8 };" ++
            "const Cache = struct { allocator: std.mem.Allocator, entries: std.ArrayListUnmanaged(Entry) = .empty," ++
            "fn add(self: *Cache, key: []const u8, value: []const u8) !void {" ++
            "const owned_key = try self.allocator.dupe(u8, key); const owned_value = try self.allocator.dupe(u8, value);" ++
            "try self.entries.append(self.allocator, .{ .key = owned_key, .value = owned_value }); }" ++
            "fn replace(self: *Cache, index: usize, value: []const u8) !void {" ++
            "self.entries.items[index].value = try self.allocator.dupe(u8, value); }" ++
            "fn safeReplace(self: *Cache, index: usize, value: []const u8) !void {" ++
            "self.allocator.free(self.entries.items[index].value);" ++
            "self.entries.items[index].value = try self.allocator.dupe(u8, value); }" ++
            "fn remove(self: *Cache, index: usize) void { _ = self.entries.swapRemove(index); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    var removal_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .overwritten_owning_value => overwrite_count += 1,
        .unreleased_allocation => if (std.mem.find(u8, finding.finding.message, "removed 'Entry'") != null) {
            removal_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), overwrite_count);
    try std.testing.expectEqual(@as(usize, 2), removal_count);
}

test "preallocated element replacement released through an alias stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/sync.zig",
        .source = "const Entry = struct { path: []u8 };" ++
            "const Snapshot = struct { allocator: std.mem.Allocator, entries: std.ArrayList(Entry)," ++
            "fn add(self: *Snapshot, path: []const u8) !void { try self.entries.append(self.allocator, .{ .path = try self.allocator.dupe(u8, path) }); }" ++
            "fn rename(self: *Snapshot, index: usize, path: []const u8) !void {" ++
            "const old_path = self.entries.items[index].path; const new_path = try self.allocator.dupe(u8, path);" ++
            "self.allocator.free(old_path); self.entries.items[index].path = new_path; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .overwritten_owning_value);
}

test "replacing a directly owned struct field without release reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/ring.zig",
        .source = "const Ring = struct { allocator: std.mem.Allocator, slots: []u8," ++
            "fn init(allocator: std.mem.Allocator) !Ring { return .{ .allocator = allocator, .slots = try allocator.alloc(u8, 4) }; }" ++
            "fn deinit(self: *Ring) void { self.allocator.free(self.slots); }" ++
            "fn resize(self: *Ring) !void { const new_slots = try self.allocator.alloc(u8, 8); self.slots = new_slots; }" ++
            "fn safeResize(self: *Ring) !void { const new_slots = try self.allocator.alloc(u8, 8);" ++
            "self.allocator.free(self.slots); self.slots = new_slots; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .overwritten_owning_value) {
        overwrite_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);
}

test "overwriting a proven owned element field through an alias reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/scheduler.zig",
        .source = "const Task = struct { label: []u8 };" ++
            "const Scheduler = struct { allocator: std.mem.Allocator, tasks: std.ArrayListUnmanaged(Task) = .empty," ++
            "fn add(self: *Scheduler, label: []const u8) !void { const owned = try self.allocator.dupe(u8, label);" ++
            "try self.tasks.append(self.allocator, .{ .label = owned }); }" ++
            "fn replace(self: *Scheduler, index: usize, label: []const u8) !void {" ++
            "const task = &self.tasks.items[index]; const replacement = try self.allocator.dupe(u8, label);" ++
            "task.label = replacement; }" ++
            "fn safeReplace(self: *Scheduler, index: usize, label: []const u8) !void {" ++
            "const task = &self.tasks.items[index]; const replacement = try self.allocator.dupe(u8, label);" ++
            "self.allocator.free(task.label); task.label = replacement; } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule == .overwritten_owning_value) overwrite_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);
}

test "overwriting a proven owned element field through a pointer capture reports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/contacts.zig",
        .source = "const Contact = struct { email: []u8, fn deinit(self: Contact, allocator: std.mem.Allocator) void { allocator.free(self.email); } };" ++
            "const Book = struct { allocator: std.mem.Allocator, contacts: std.ArrayListUnmanaged(Contact) = .empty," ++
            "fn add(self: *Book, email: []const u8) !void {" ++
            "try self.contacts.append(self.allocator, .{ .email = try self.allocator.dupe(u8, email) }); }" ++
            "fn replace(self: *Book, email: []const u8) !void { for (self.contacts.items) |*contact| {" ++
            "contact.email = try self.allocator.dupe(u8, email); } }" ++
            "fn safeReplace(self: *Book, email: []const u8) !void { for (self.contacts.items) |*contact| {" ++
            "self.allocator.free(contact.email); contact.email = try self.allocator.dupe(u8, email); } }" ++
            "fn replaceMatching(self: *Book, email: []const u8) !void { for (self.contacts.items) |*contact|" ++
            "if (contact.email.len != 0) { contact.email = try self.allocator.dupe(u8, email); } } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var overwrite_count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule == .overwritten_owning_value) overwrite_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), overwrite_count);
}

fn countRule(found: []const project.Finding, rule: types.Rule) usize {
    var count: usize = 0;
    for (found) |finding| {
        if (finding.finding.rule == rule) count += 1;
    }
    return count;
}

test "a container's own deinit is its cleanup, not a nested type's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/window.zig",
        .source = "const Window = struct { alloc: std.mem.Allocator, needle: []u8, overlap: []u8, cells: List," ++
            "const Meta = struct { map: List, fn deinit(self: *Meta, alloc: std.mem.Allocator) void { self.map.deinit(alloc); } };" ++
            "fn init(alloc: std.mem.Allocator) !Window { const needle = try alloc.alloc(u8, 4); errdefer alloc.free(needle);" ++
            "const overlap = try alloc.alloc(u8, 8); return .{ .alloc = alloc, .needle = needle, .overlap = overlap, .cells = .empty }; }" ++
            "fn deinit(self: *Window) void { self.alloc.free(self.overlap); self.alloc.free(self.needle); self.cells.deinit(self.alloc); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), countRule(found, .incomplete_owned_field_cleanup));
}

test "union payloads released through switch captures and nested literals stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/link.zig",
        .source = "const Link = struct { id: Id, uri: []const u8, const Id = union(enum) { explicit: []const u8, implicit: u32 };" ++
            "fn deinit(self: *const Link, alloc: std.mem.Allocator) void { alloc.free(self.uri);" ++
            "switch (self.id) { .implicit => {}, .explicit => |v| alloc.free(v), } }" ++
            "fn dupe(self: *const Link, alloc: std.mem.Allocator) !Link { const uri = try alloc.dupe(u8, self.uri); errdefer alloc.free(uri);" ++
            "const id: Link.Id = switch (self.id) { .implicit => self.id, .explicit => |v| .{ .explicit = try alloc.dupe(u8, v) } };" ++
            "return .{ .id = id, .uri = uri }; } };" ++
            "const Dual = struct { first: Half, second: Half, const Half = struct { bytes: []u8, busy: bool };" ++
            "fn init(alloc: std.mem.Allocator) !Dual { const one = try alloc.alloc(u8, 4); errdefer alloc.free(one);" ++
            "const two = try alloc.alloc(u8, 4); return .{ .first = .{ .bytes = one, .busy = false }, .second = .{ .bytes = two, .busy = false } }; }" ++
            "fn deinit(self: *Dual, alloc: std.mem.Allocator) void { alloc.free(self.second.bytes); alloc.free(self.first.bytes); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), countRule(found, .incomplete_owned_field_cleanup));
}

test "same-named types in one file prove their own fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/discovery.zig",
        .source = "const Mac = struct { const Iterator = struct { alloc: std.mem.Allocator, list: []u8," ++
            "fn deinit(self: *Iterator) void { self.alloc.free(self.list); } };" ++
            "fn discover(alloc: std.mem.Allocator) !Iterator { const list = try alloc.alloc(u8, 4); return .{ .alloc = alloc, .list = list }; } };" ++
            "const Win = struct { const Iterator = struct { alloc: std.mem.Allocator, system: ?[]u8, user: ?[]u8," ++
            "fn deinit(self: *Iterator) void { if (self.system) |p| self.alloc.free(p); if (self.user) |p| self.alloc.free(p); } }; };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 0), countRule(found, .incomplete_owned_field_cleanup));
}

test "replacing a field whose previous value holds no allocation stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/log.zig",
        .source = "const Log = struct { alloc: std.mem.Allocator, info: []const u8 = \"\", root: []const u8 = \"\", entries: usize = 0, tree: []u8," ++
            "fn deinit(self: *Log) void { self.alloc.free(self.info); self.alloc.free(self.root); self.alloc.free(self.tree); }" ++
            "fn make(self: *Log) !Log { return .{ .alloc = self.alloc, .info = try self.alloc.dupe(u8, \"i\"), .tree = try self.alloc.alloc(u8, 2) }; }" ++
            "fn reset(self: *Log, text: []const u8) !void { self.info = \"\"; if (text.len > 0) self.info = try self.alloc.dupe(u8, text); }" ++
            "fn initFrom(self: *Log, text: []const u8) !void { self.info = try self.alloc.dupe(u8, text); }" ++
            "fn first(self: *Log, path: []const u8) !void { self.entries += 1; if (self.entries == 1) { self.root = try self.alloc.dupe(u8, path); return; }" ++
            "if (self.root.len == 0) return; self.alloc.free(self.root); self.root = \"\"; }" ++
            "fn swap(self: *Log, old: *Log, next: []u8) void { old.tree = self.tree; self.tree = next; }" ++
            "fn leak(self: *Log, text: []const u8) !void { self.info = try self.alloc.dupe(u8, text); } };" ++
            "const Theme = struct { light: []const u8," ++
            "fn clone(self: Theme, alloc: std.mem.Allocator) !Theme { return .{ .light = try alloc.dupe(u8, self.light) }; }" ++
            "fn finalize(self: *Theme, alloc: std.mem.Allocator) !void { self.light = try alloc.dupe(u8, \"x\"); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    // Only `leak` replaces an allocation it never released.
    try std.testing.expectEqual(@as(usize, 1), countRule(found, .overwritten_owning_value));
}

test "an element deinitialized through its loop capture before removal stays clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/modules.zig",
        .source = "const Module = struct { name: ?[]const u8, fn deinit(module: *Module, gpa: std.mem.Allocator) void {" ++
            "if (module.name) |n| gpa.free(n); } };" ++
            "const Info = struct { modules: std.ArrayList(Module), gpa: std.mem.Allocator," ++
            "fn add(self: *Info, name: []const u8) !void { try self.modules.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) }); }" ++
            "fn unload(self: *Info, base: usize) void { for (self.modules.items, 0..) |*mod, mod_index| {" ++
            "if (mod_index != base) continue; mod.deinit(self.gpa); _ = self.modules.swapRemove(mod_index); break; } }" ++
            "fn drop(self: *Info, index: usize) void { _ = self.modules.swapRemove(index); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    // Only `drop` discards an element that still owns its name.
    try std.testing.expectEqual(@as(usize, 1), countRule(found, .unreleased_allocation));
}
