//! The findings the engine derives from an allocation besides a leak: a
//! release through the wrong method or allocator, a second release, a use
//! after release, cleanup registered after a fallible operation, an owner
//! overwritten before its release, and an aggregate `errdefer` freeing a
//! field an earlier `errdefer` already frees; and the pool `defer deinit`
//! that excuses a leak.
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const resources = @import("../../resources.zig");
const summaries = @import("../../summaries.zig");
const types = @import("../../types.zig");
const tokenRefersToBinding = @import("../../context.zig").tokenRefersToBinding;
const tokens_util = @import("../../../syntax/tokens.zig");
const TokenRange = @import("../../../syntax/tokens.zig").Range;
const Allocation = @import("allocation.zig").Allocation;
const identifierHasAllocatorType = @import("allocation.zig").identifierHasAllocatorType;
const scans = @import("scans.zig");
const containsBinding = scans.containsBinding;
const enclosingScope = scans.enclosingScope;
const identifierRefersToBinding = scans.identifierRefersToBinding;
const localCallOwnership = scans.localCallOwnership;
const releaseCallContainsBinding = scans.releaseCallContainsBinding;
const releaseUsesAllocationReceiver = scans.releaseUsesAllocationReceiver;
const statementStartsWithErrdefer = scans.statementStartsWithErrdefer;
const tokenIsIdentifier = scans.tokenIsIdentifier;

pub fn findOverlappingAggregateErrdefers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: types.Configuration,
    found: *std.ArrayList(types.Finding),
) !void {
    for (tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index < 2 or tokens[equal_index - 1].tag != .period_asterisk or
            tokens[equal_index - 2].tag != .identifier) continue;
        const owner_name = source[tokens[equal_index - 2].loc.start..tokens[equal_index - 2].loc.end];
        const owner_binding = scope_index.findBinding(equal_index - 2) orelse continue;
        const owner_type = createdPointerType(source, tokens, scope_index, owner_binding.token_index) orelse continue;
        const assignment_end = scope_index.statementEnd(equal_index) orelse continue;
        const scope = enclosingScope(scope_index, equal_index) orelse continue;
        var field_index = equal_index + 1;
        while (field_index + 3 < assignment_end) : (field_index += 1) {
            if (tokens[field_index].tag != .period or tokens[field_index + 1].tag != .identifier or
                tokens[field_index + 2].tag != .equal or tokens[field_index + 3].tag != .identifier) continue;
            const field_name = source[tokens[field_index + 1].loc.start..tokens[field_index + 1].loc.end];
            const binding_name = source[tokens[field_index + 3].loc.start..tokens[field_index + 3].loc.end];
            const field_binding = scope_index.findBinding(field_index + 3) orelse continue;
            if (!typeDeinitReleasesField(source, tokens, scope_index, owner_type, field_name)) continue;
            if (errdeferReleasingBinding(
                source,
                tokens,
                scope_index,
                binding_name,
                field_binding.token_index,
                scope.opening + 1,
                assignment_end,
            ) == null) continue;
            const aggregate_cleanup = errdeferDeinitializingOwner(
                source,
                tokens,
                scope_index,
                owner_name,
                owner_binding.token_index,
                assignment_end + 1,
                scope.closing,
            ) orelse continue;
            try found.append(allocator, .{
                .rule = .double_release,
                .level = configuration.level(.double_release),
                .span = tokens[aggregate_cleanup].loc,
                .message = try allocator.print(
                    "errdefer cleanup for '{s}' releases owned field '{s}' after an earlier errdefer already releases '{s}'",
                    .{ owner_name, field_name, binding_name },
                ),
            });
        }
    }
}

fn createdPointerType(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    owner_binding: usize,
) ?usize {
    if (owner_binding == 0 or
        (tokens[owner_binding - 1].tag != .keyword_const and tokens[owner_binding - 1].tag != .keyword_var) or
        owner_binding + 2 >= tokens.len or tokens[owner_binding + 1].tag != .equal) return null;
    const declaration_end = scope_index.statementEnd(owner_binding - 1) orelse return null;
    for (tokens[owner_binding + 2 .. declaration_end], owner_binding + 2..) |candidate, create_index| {
        if (!tokenIsIdentifier(source, candidate, "create") or create_index + 3 >= declaration_end or
            tokens[create_index + 1].tag != .l_paren or tokens[create_index + 2].tag != .identifier or
            tokens[create_index + 3].tag != .r_paren) continue;
        return create_index + 2;
    }
    return null;
}

fn typeDeinitReleasesField(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    type_use: usize,
    field_name: []const u8,
) bool {
    const type_binding = scope_index.findBinding(type_use) orelse return false;
    const type_name = type_binding.token_index;
    if (type_name == 0 or tokens[type_name - 1].tag != .keyword_const or type_name + 3 >= tokens.len or
        tokens[type_name + 1].tag != .equal or tokens[type_name + 2].tag != .keyword_struct or
        tokens[type_name + 3].tag != .l_brace) return false;
    const type_end = scope_index.matchingToken(type_name + 3) orelse return false;
    for (tokens[type_name + 4 .. type_end], type_name + 4..) |candidate, function_index| {
        if (candidate.tag != .keyword_fn or function_index + 3 >= type_end or
            !tokenIsIdentifier(source, tokens[function_index + 1], "deinit") or
            tokens[function_index + 2].tag != .l_paren) continue;
        const parameters_end = scope_index.matchingToken(function_index + 2) orelse continue;
        var receiver: ?[]const u8 = null;
        for (tokens[function_index + 3 .. parameters_end], function_index + 3..) |parameter, parameter_index| {
            if (parameter.tag == .identifier and parameter_index + 1 < parameters_end and
                tokens[parameter_index + 1].tag == .colon)
            {
                receiver = source[parameter.loc.start..parameter.loc.end];
                break;
            }
        }
        const receiver_name = receiver orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < type_end and tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start == type_end) continue;
        const body_end = scope_index.matchingToken(body_start) orelse continue;
        for (tokens[body_start + 1 .. body_end], body_start + 1..) |body_token, method_index| {
            if ((!tokenIsIdentifier(source, body_token, "free") and
                !tokenIsIdentifier(source, body_token, "destroy")) or method_index + 1 >= body_end or
                tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = scope_index.matchingToken(method_index + 1) orelse continue;
            var index = method_index + 2;
            while (index + 2 < call_end) : (index += 1) {
                if (tokenIsIdentifier(source, tokens[index], receiver_name) and tokens[index + 1].tag == .period and
                    tokenIsIdentifier(source, tokens[index + 2], field_name)) return true;
            }
        }
    }
    return false;
}

fn errdeferReleasingBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    for (tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = scope_index.statementEnd(defer_index) orelse continue;
        if (defer_end >= end) continue;
        var saw_binding = false;
        var saw_release = false;
        var conditional = false;
        for (tokens[defer_index + 1 .. defer_end], defer_index + 1..) |candidate, candidate_index| {
            if (candidate.tag == .keyword_if or candidate.tag == .keyword_switch) conditional = true;
            if (tokenIsIdentifier(source, candidate, binding_name) and
                identifierRefersToBinding(scope_index, binding_index, candidate_index)) saw_binding = true;
            if (tokenIsIdentifier(source, candidate, "free") or tokenIsIdentifier(source, candidate, "destroy")) {
                saw_release = true;
            }
        }
        if (!conditional and saw_binding and saw_release) return defer_index;
    }
    return null;
}

fn errdeferDeinitializingOwner(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    owner_name: []const u8,
    owner_binding: usize,
    start: usize,
    end: usize,
) ?usize {
    for (tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_errdefer) continue;
        const defer_end = scope_index.statementEnd(defer_index) orelse continue;
        if (defer_end >= end) continue;
        var index = defer_index + 1;
        while (index + 2 < defer_end) : (index += 1) {
            if (tokenIsIdentifier(source, tokens[index], owner_name) and tokens[index + 1].tag == .period and
                identifierRefersToBinding(scope_index, owner_binding, index) and
                tokenIsIdentifier(source, tokens[index + 2], "deinit")) return index + 2;
        }
    }
    return null;
}

pub fn findMismatchedRelease(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    end: usize,
    spans: []const TokenRange,
    allocation: Allocation,
    configuration: types.Configuration,
    found: *std.ArrayList(types.Finding),
) !bool {
    var mismatched = false;
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, method_index| {
        if (token.tag != .identifier or
            (!tokenIsIdentifier(source, token, "free") and !tokenIsIdentifier(source, token, "destroy"))) continue;
        if (!releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, end)) continue;
        const actual_release = source[token.loc.start..token.loc.end];
        const receiver_is_binding = method_index >= 2 and
            tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
            identifierRefersToBinding(scope_index, binding_index, method_index - 2);
        // `set.free(address)` is a method of the owned value itself, not a release of it.
        if (receiver_is_binding) continue;
        const receiver_name = releaseReceiverPath(source, tokens, method_index);
        const wrong_method = !std.mem.eql(u8, actual_release, allocation.release);
        const expected_allocator = allocation.receiver orelse allocation.allocator_source;
        // A receiver that is not an allocator, such as `self.free(value)` on a
        // wrapper type, releases through whatever allocator it holds.
        const wrong_allocator = expected_allocator != null and receiver_name != null and
            !allocatorPathMatches(expected_allocator.?, allocation.allocator_member, receiver_name.?) and
            releaseReceiverIsAllocator(source, tokens, scope_index, method_index);
        if (!wrong_method and !wrong_allocator) continue;
        mismatched = true;
        const message = if (wrong_method)
            try allocator.print(
                "allocation '{s}' from {s} must use {s}, not {s}",
                .{ binding_name, allocation.method, allocation.release, actual_release },
            )
        else if (allocation.allocator_member) |member|
            try allocator.print(
                "allocation '{s}' created by allocator '{s}.{s}' is released through different allocator '{s}'",
                .{ binding_name, expected_allocator.?, member, receiver_name.? },
            )
        else
            try allocator.print(
                "allocation '{s}' created by allocator '{s}' is released through different allocator '{s}'",
                .{ binding_name, expected_allocator.?, receiver_name.? },
            );
        try found.append(allocator, .{
            .rule = .mismatched_allocation_release,
            .level = configuration.level(.mismatched_allocation_release),
            .span = token.loc,
            .message = message,
        });
    };
    return mismatched;
}

/// Whether a `release` call in `spans`, which end by `end`, releases the binding.
pub fn bindingReleasedWith(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    end: usize,
    spans: []const TokenRange,
    release: []const u8,
) bool {
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, method_index| {
        if (tokenIsIdentifier(source, token, release) and
            releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, end)) return true;
    };
    return false;
}

fn allocatorPathMatches(base: []const u8, member: ?[]const u8, actual: []const u8) bool {
    const field = member orelse return std.mem.eql(u8, base, actual);
    return actual.len == base.len + 1 + field.len and
        std.mem.startsWith(u8, actual, base) and actual[base.len] == '.' and
        std.mem.endsWith(u8, actual, field);
}

fn releaseReceiverPath(source: []const u8, tokens: []const std.zig.Token, method_index: usize) ?[]const u8 {
    if (method_index < 2 or tokens[method_index - 1].tag != .period or
        tokens[method_index - 2].tag != .identifier) return null;
    var start = method_index - 2;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return source[tokens[start].loc.start..tokens[method_index - 2].loc.end];
}

pub fn findReleaseOrderingIssues(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    declaration_index: usize,
    declaration_end: usize,
    scope_end: usize,
    spans: []const TokenRange,
    allocation: Allocation,
    summary_index: summaries.Index,
    configuration: types.Configuration,
    report_leaks: bool,
    found: *std.ArrayList(types.Finding),
) !bool {
    const declaration_scope = enclosingScope(scope_index, declaration_index) orelse return false;
    var cleanup_registered_after_fallible_operation = false;
    var releases: std.ArrayList(usize) = .empty;
    defer releases.deinit(allocator);
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= scope_end or tokens[method_index + 1].tag != .l_paren) continue;
        const release_scope = enclosingScope(scope_index, method_index) orelse continue;
        if (release_scope.opening != declaration_scope.opening) continue;
        if (statementStartsWithErrdefer(tokens, method_index)) continue;
        const direct_release = tokenIsIdentifier(source, token, allocation.release) and
            releaseCallContainsBinding(source, tokens, scope_index, binding_name, binding_index, method_index, scope_end) and
            releaseUsesAllocationReceiver(source, tokens, scope_index, binding_name, binding_index, method_index, allocation.receiver);
        const summarized_release = localCallOwnership(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            method_index + 1,
            summary_index,
        ) == .released;
        if (!direct_release and !summarized_release) continue;
        try releases.append(allocator, method_index);
    };

    if (releases.items.len != 0) {
        const first_release = releases.items[0];
        if (statementStartsWith(tokens, first_release, .keyword_defer) and
            scope_index.fallibleOperationBetween(declaration_end + 1, first_release, declaration_scope.opening))
        {
            cleanup_registered_after_fallible_operation = true;
            if (report_leaks) try found.append(allocator, .{
                .rule = .cleanup_after_fallible_operation,
                .level = configuration.level(.cleanup_after_fallible_operation),
                .span = tokens[binding_index].loc,
                .message = try allocator.print(
                    "cleanup for allocation '{s}' is registered after a fallible operation; an earlier error can leak it",
                    .{binding_name},
                ),
            });
        }
        for (releases.items[1..], 1..) |release_index, position| {
            // Re-acquiring the value between two releases starts a new lifetime,
            // and `destroy` on a pool or other non-allocator recycles items.
            if (reassignedBetween(tokens, scope_index, binding_name, releases.items[position - 1], release_index)) continue;
            if (std.mem.eql(u8, allocation.release, "destroy") and !releaseReceiverIsAllocator(source, tokens, scope_index, release_index)) continue;
            const fixes = try releaseDeletionFix(allocator, source, tokens, scope_index, release_index);
            errdefer {
                for (fixes) |fix| allocator.free(fix.edits);
                allocator.free(fixes);
            }
            const message = try allocator.print(
                "allocation '{s}' has more than one visible {s} in the same control-flow scope",
                .{ binding_name, allocation.release },
            );
            errdefer allocator.free(message);
            try found.append(allocator, .{
                .rule = .double_release,
                .level = configuration.level(.double_release),
                .span = tokens[release_index].loc,
                .message = message,
                .fixes = fixes,
            });
        }
        if (!statementStartsWith(tokens, first_release, .keyword_defer) and
            !statementStartsWith(tokens, first_release, .keyword_errdefer))
        {
            const release_end = scope_index.statementEnd(first_release) orelse first_release;
            if (firstUseAfterRelease(source, tokens, scope_index, binding_name, binding_index, release_end + 1, scope_end, releases.items)) |use_index| {
                try found.append(allocator, .{
                    .rule = .use_after_release,
                    .level = configuration.level(.use_after_release),
                    .span = tokens[use_index].loc,
                    .message = try allocator.print(
                        "allocation '{s}' is used after its visible {s}",
                        .{ binding_name, allocation.release },
                    ),
                });
            }
            if (bufferViewUseAfterRelease(
                source,
                tokens,
                scope_index,
                binding_name,
                binding_index,
                declaration_end + 1,
                first_release,
                release_end + 1,
                scope_end,
            )) |view_use| {
                try found.append(allocator, .{
                    .rule = .use_after_release,
                    .level = configuration.level(.use_after_release),
                    .span = tokens[view_use.use_index].loc,
                    .message = try allocator.print(
                        "'{s}' buffers its I/O in allocation '{s}' and is used after its visible {s}",
                        .{ view_use.name, binding_name, allocation.release },
                    ),
                });
            }
        }
    }

    const before_release = if (releases.items.len == 0) scope_end else releases.items[0];
    if (owningAssignment(source, tokens, scope_index, binding_name, binding_index, declaration_end + 1, before_release)) |assignment_index| {
        try found.append(allocator, .{
            .rule = .overwritten_owning_value,
            .level = configuration.level(.overwritten_owning_value),
            .span = tokens[assignment_index].loc,
            .message = try allocator.print(
                "assignment replaces owning value '{s}' before its original allocation is released",
                .{binding_name},
            ),
        });
    }
    return cleanup_registered_after_fallible_operation;
}

fn reassignedBetween(
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    start: usize,
    end: usize,
) bool {
    var uses = scope_index.identifiersNamed(binding_name, start + 1, end);
    while (uses.next()) |index| {
        if (tokens[index + 1].tag == .equal and tokens[index - 1].tag != .period) return true;
    }
    return false;
}

/// Whether the receiver of the release call at `method_index` names an
/// allocator. Unknown receivers count as allocators.
fn releaseReceiverIsAllocator(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    method_index: usize,
) bool {
    const path = releaseReceiverPath(source, tokens, method_index) orelse return true;
    const last = if (std.mem.findScalarLast(u8, path, '.')) |dot| path[dot + 1 ..] else path;
    return std.ascii.findIgnoreCase(last, "alloc") != null or std.ascii.findIgnoreCase(last, "arena") != null or
        std.mem.eql(u8, last, "gpa") or identifierHasAllocatorType(source, tokens, scope_index, last);
}

fn releaseDeletionFix(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    release_index: usize,
) ![]const types.Fix {
    var statement_start = release_index;
    while (statement_start > 0) {
        switch (tokens[statement_start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => statement_start -= 1,
        }
    }
    const statement_end = scope_index.statementEnd(release_index) orelse release_index;
    const edits = try allocator.alloc(types.Edit, 1);
    errdefer allocator.free(edits);
    const statement_span: std.zig.Token.Loc = .{ .start = tokens[statement_start].loc.start, .end = tokens[statement_end].loc.end };
    // A release alone on its lines goes with its lines, so no blank one is left behind.
    const alone = std.mem.trim(u8, source[tokens_util.lineStart(source, statement_span.start)..statement_span.start], " \t").len == 0 and
        std.mem.trim(u8, source[statement_span.end..tokens_util.lineEnd(source, statement_span.end)], " \t\r\n").len == 0;
    edits[0] = .{
        .span = if (alone) tokens_util.removedLinesSpan(source, statement_span.start, statement_span.end) else statement_span,
        .replacement = "",
    };
    const fixes = try allocator.alloc(types.Fix, 1);
    fixes[0] = .{ .title = "Delete the duplicate release", .kind = .quickfix, .edits = edits };
    return fixes;
}

fn statementStartsWith(tokens: []const std.zig.Token, index: usize, expected: std.zig.Token.Tag) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .semicolon, .l_brace, .r_brace => return false,
            else => if (tokens[cursor].tag == expected) return true,
        }
    }
    return false;
}

fn firstUseAfterRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    release_indices: []const usize,
) ?usize {
    const declaration_scope = enclosingScope(scope_index, binding_index) orelse return null;
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (!tokenRefersToBinding(source, tokens, index, binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index)) continue;
        const use_scope = enclosingScope(scope_index, index) orelse continue;
        if (use_scope.opening != declaration_scope.opening and !isFormatArgument(source, tokens, index)) continue;
        var belongs_to_release = false;
        for (release_indices) |release_index| {
            const closing = if (release_index + 1 < tokens.len and tokens[release_index + 1].tag == .l_paren)
                scope_index.matchingToken(release_index + 1)
            else
                null;
            if (closing) |closing_index| if (index >= release_index -| 2 and index <= closing_index) {
                belongs_to_release = true;
                break;
            };
        }
        if (belongs_to_release) continue;
        if (index + 1 < tokens.len and tokens[index + 1].tag == .equal) return null;
        if (!useDefinitelyReadsReleasedAllocation(source, tokens, index, end)) continue;
        return index;
    }
    return null;
}

/// Calls that build a reader or writer over the buffer passed last, such as
/// `file.writer(io, buffer)`, `stream.reader(io, buffer)` or `Writer.fixed(buffer)`.
const buffer_view_methods = [_][]const u8{ "writer", "writerStreaming", "reader", "readerStreaming", "fixed" };

const BufferViewUse = struct { name: []const u8, use_index: usize };

/// A reader or writer that `var out = file.writer(io, buffer);` builds over
/// the binding in `[start, release)` and that a call uses after the release:
/// `out.interface.print(...)` then reads and writes the freed buffer. Both the
/// view and the use sit directly in the binding's block, like the uses
/// `firstUseAfterRelease` reports, and assigning the view ends the search.
fn bufferViewUseAfterRelease(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    release: usize,
    after_release: usize,
    scope_end: usize,
) ?BufferViewUse {
    const block = scope_index.enclosingOpeningBrace(binding_index) orelse return null;
    var arguments = scope_index.identifiersNamed(binding_name, start, release);
    candidates: while (arguments.next()) |argument| {
        // The bare last argument of the call that ends the declaration's value.
        if (argument + 2 >= tokens.len or tokens[argument + 1].tag != .r_paren or tokens[argument + 2].tag != .semicolon or
            (tokens[argument - 1].tag != .comma and tokens[argument - 1].tag != .l_paren) or
            !identifierRefersToBinding(scope_index, binding_index, argument)) continue;
        const call_open = scope_index.matchingToken(argument + 1) orelse continue;
        if (call_open < 2 or tokens[call_open - 1].tag != .identifier or tokens[call_open - 2].tag != .period) continue;
        const method = source[tokens[call_open - 1].loc.start..tokens[call_open - 1].loc.end];
        for (buffer_view_methods) |candidate| {
            if (std.mem.eql(u8, method, candidate)) break;
        } else continue;
        const declaration = scope_index.statementStart(argument);
        if ((tokens[declaration].tag != .keyword_var and tokens[declaration].tag != .keyword_const) or
            tokens[declaration + 1].tag != .identifier or scope_index.enclosingOpeningBrace(declaration) != block) continue;
        const view_index = declaration + 1;
        const view_name = source[tokens[view_index].loc.start..tokens[view_index].loc.end];
        var uses = scope_index.identifiersNamed(view_name, after_release, scope_end);
        while (uses.next()) |use| {
            if (use + 5 >= tokens.len or tokens[use - 1].tag == .period or
                !identifierRefersToBinding(scope_index, view_index, use) or scope_index.enclosingOpeningBrace(use) != block) continue;
            // `out = ...` or `out.interface.buffer = ...` points it elsewhere.
            if (tokens[use + 1].tag == .equal) continue :candidates;
            if (tokens[use + 1].tag != .period or tokens[use + 2].tag != .identifier) continue;
            if (tokens[use + 3].tag == .equal) continue :candidates;
            const method_index = if (tokens[use + 3].tag == .period and tokens[use + 4].tag == .identifier) method: {
                if (tokens[use + 5].tag == .equal) continue :candidates;
                break :method use + 4;
            } else use + 2;
            if (tokens[method_index + 1].tag == .l_paren) return .{ .name = view_name, .use_index = use };
        }
    }
    return null;
}

fn useDefinitelyReadsReleasedAllocation(source: []const u8, tokens: []const std.zig.Token, use_index: usize, end: usize) bool {
    if (use_index + 1 >= end) return false;
    if (isFormatArgument(source, tokens, use_index)) return true;
    if (tokens[use_index + 1].tag == .l_bracket or tokens[use_index + 1].tag == .period_asterisk) return true;
    if (use_index + 2 >= end or tokens[use_index + 1].tag != .period or tokens[use_index + 2].tag != .identifier) return false;
    const member = source[tokens[use_index + 2].loc.start..tokens[use_index + 2].loc.end];
    if (std.mem.eql(u8, member, "len")) return false;
    if (!std.mem.eql(u8, member, "ptr")) return true;
    return use_index + 3 < end and
        (tokens[use_index + 3].tag == .period_asterisk or tokens[use_index + 3].tag == .l_bracket);
}

/// A bare binding inside the argument tuple of a formatting call, such as
/// `std.debug.print("{s}", .{name})`, which reads through it.
fn isFormatArgument(source: []const u8, tokens: []const std.zig.Token, use_index: usize) bool {
    if (use_index == 0 or use_index + 1 >= tokens.len) return false;
    const before = tokens[use_index - 1].tag;
    const after = tokens[use_index + 1].tag;
    if ((before != .l_brace and before != .comma) or (after != .r_brace and after != .comma)) return false;
    var depth: usize = 0;
    var cursor = use_index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace, .r_paren, .r_bracket => depth += 1,
            .l_paren, .l_bracket => if (depth == 0) return false else {
                depth -= 1;
            },
            .l_brace => if (depth != 0) {
                depth -= 1;
            } else {
                // `.{` after a comma that follows the format string, inside a call.
                if (cursor < 3 or tokens[cursor - 1].tag != .period or tokens[cursor - 2].tag != .comma) return false;
                var call = cursor - 2;
                var call_depth: usize = 0;
                while (call > 0) {
                    call -= 1;
                    switch (tokens[call].tag) {
                        .r_paren => call_depth += 1,
                        .l_paren => if (call_depth == 0) {
                            if (call == 0 or tokens[call - 1].tag != .identifier) return false;
                            const callee = source[tokens[call - 1].loc.start..tokens[call - 1].loc.end];
                            for ([_][]const u8{ "print", "err", "warn", "info", "debug", "bufPrint", "allocPrint", "format" }) |name| {
                                if (std.mem.eql(u8, callee, name)) return true;
                            }
                            return false;
                        } else {
                            call_depth -= 1;
                        },
                        .semicolon => return false,
                        else => {},
                    }
                }
                return false;
            },
            .semicolon => return false,
            else => {},
        }
    }
    return false;
}

fn owningAssignment(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    const declaration_scope = enclosingScope(scope_index, binding_index) orelse return null;
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (index + 2 >= end) break;
        if (!identifierRefersToBinding(scope_index, binding_index, index) or
            tokens[index + 1].tag != .equal) continue;
        const assignment_scope = enclosingScope(scope_index, index) orelse continue;
        if (assignment_scope.opening != declaration_scope.opening) continue;
        const statement_end = scope_index.statementEnd(index) orelse continue;
        const value_end = @min(statement_end, end);
        var replaces_with_allocation = false;
        var realloc_consumes_original = false;
        for (tokens[index + 2 .. value_end], index + 2..) |rhs_token, rhs_index| {
            if (rhs_token.tag != .identifier) continue;
            const method = source[rhs_token.loc.start..rhs_token.loc.end];
            if (resources.allocationRelease(method) == null) continue;
            replaces_with_allocation = true;
            if (!std.mem.eql(u8, method, "realloc") or rhs_index + 1 >= tokens.len or
                tokens[rhs_index + 1].tag != .l_paren) continue;
            const closing = scope_index.matchingToken(rhs_index + 1) orelse continue;
            if (containsBinding(scope_index, binding_name, binding_index, rhs_index + 2, @min(closing, value_end))) {
                realloc_consumes_original = true;
            }
        }
        if (replaces_with_allocation and !realloc_consumes_original) return index;
    }
    return null;
}

/// Whether a `defer` in a scope deinitializes a receiver, by the scope's
/// opening brace and the receiver's name: every leaked allocation from the
/// receiver asks, and the answer is the same for each.
pub const ReceiverCleanups = struct {
    answers: std.HashMapUnmanaged(Key, bool, Key.Context, std.hash_map.default_max_load_percentage) = .empty,

    const Key = struct {
        opening: usize,
        receiver: []const u8,

        const Context = struct {
            pub fn hash(_: Context, key: Key) u64 {
                return std.hash.Wyhash.hash(key.opening, key.receiver);
            }

            pub fn eql(_: Context, left: Key, right: Key) bool {
                return left.opening == right.opening and std.mem.eql(u8, left.receiver, right.receiver);
            }
        };
    };
};

pub fn deferDeinitializesReceiver(
    allocator: std.mem.Allocator,
    cleanups: *ReceiverCleanups,
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    receiver_name: []const u8,
    declaration_index: usize,
    scope_end: usize,
) !bool {
    const scope = enclosingScope(scope_index, declaration_index) orelse return false;
    const answer = try cleanups.answers.getOrPut(allocator, .{ .opening = scope.opening, .receiver = receiver_name });
    if (!answer.found_existing) answer.value_ptr.* = scopeDefersReceiverDeinit(source, tokens, scope_index, receiver_name, scope.opening, scope_end);
    return answer.value_ptr.*;
}

fn scopeDefersReceiverDeinit(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    receiver_name: []const u8,
    scope_opening: usize,
    scope_end: usize,
) bool {
    var index = scope_opening + 1;
    while (index + 3 < scope_end) : (index += 1) {
        // Only 'defer' releases on the success path; 'errdefer' alone still
        // leaks when the function succeeds.
        if (tokens[index].tag != .keyword_defer) continue;
        const body_end = if (tokens[index + 1].tag == .l_brace)
            scope_index.matchingToken(index + 1) orelse scope_end
        else
            scope_index.statementEnd(index + 1) orelse scope_end;
        var body_index = index + 1;
        while (body_index + 2 < @min(body_end, scope_end)) : (body_index += 1) {
            if (tokens[body_index].tag == .identifier and
                tokenIsIdentifier(source, tokens[body_index], receiver_name) and
                tokens[body_index + 1].tag == .period and
                tokenIsIdentifier(source, tokens[body_index + 2], "deinit")) return true;
        }
        index = @min(body_end, scope_end - 1);
    }
    return false;
}

pub fn freeFinding(allocator: std.mem.Allocator, finding: types.Finding) void {
    allocator.free(finding.message);
    for (finding.fixes) |fix| {
        for (fix.edits) |edit| allocator.free(edit.replacement);
        allocator.free(fix.edits);
    }
    allocator.free(finding.fixes);
}
