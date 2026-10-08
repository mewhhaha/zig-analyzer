//! Rules that need a callee's summary from another file: borrowed or owned
//! returns, partial IO contracts, container invalidation through helpers, and
//! local storage escaping through calls.
const std = @import("std");
const allocation_lifecycle = @import("../lifecycle/allocation_lifecycle.zig");
const missing_errdefer = @import("../lifecycle/missing_errdefer.zig");
const summaries = @import("../summaries.zig");
const run_module = @import("run.zig");
const ProjectRun = run_module.ProjectRun;
const File = run_module.File;
const types = @import("../types.zig");
const tokens_util = @import("../../syntax/tokens.zig");
const tokenText = tokens_util.tokenText;
const tokenIs = tokens_util.tokenIs;
const statementEnd = tokens_util.statementEnd;
const enclosingOpeningBrace = tokens_util.enclosingOpeningBrace;
const matchingToken = tokens_util.matchingToken;
const enclosingScopeEnd = tokens_util.enclosingScopeEnd;
const findTag = tokens_util.findTag;
const PathRange = tokens_util.Range;
const Call = tokens_util.Call;
const firstCall = tokens_util.firstCall;
const project = @import("../project.zig");

/// Runs every summary-driven check over one file.
pub fn checkFile(run: ProjectRun, file_index: usize, summary_index: summaries.Index) !void {
    const file = run.files[file_index];
    if (run.level(.missing_errdefer) != .off) {
        var summary_findings: std.ArrayList(types.Finding) = .empty;
        try missing_errdefer.runWithSummaries(try run.ruleRun(file_index, &summary_findings), summary_index);
        for (summary_findings.items) |finding| try run.emit(file_index, finding);
    }
    try findDiscardedSummaryIo(run, file, file_index, summary_index);
    try findBorrowedReturnInvalidations(run, file, file_index, summary_index);
    try findSummaryContainerInvalidations(run, file, file_index, summary_index);
    try findEscapingLocalStorage(run, file, file_index, summary_index);
    try reportLifecycleDifferences(run, file, file_index, summary_index);
}

/// Allocation-lifecycle findings only the cross-file summaries prove. The
/// file-local engine already reports its own findings, so the summary-backed
/// pass is diffed against a local one, which only runs when the summaries
/// found something.
fn reportLifecycleDifferences(run: ProjectRun, file: File, file_index: usize, summary_index: summaries.Index) !void {
    if (!run.configuration.anyEnabled(&allocation_lifecycle.rules)) return;
    if (!summary_index.hasImportedLifecycleFacts(file.source)) return;
    const shared = try run.syntax(file_index);
    const project_warnings = try allocation_lifecycle.findingsWithSummaries(
        run.allocator,
        file.source,
        &shared.tree,
        file.tokens,
        &shared.scopes,
        summary_index,
        run.configuration,
    );
    if (project_warnings.len == 0) return;
    const local_warnings = try allocation_lifecycle.findingsWithSyntax(
        run.allocator,
        file.source,
        &shared.tree,
        file.tokens,
        &shared.scopes,
        run.configuration,
    );
    for (project_warnings) |warning| {
        if (containsLifecycleFinding(local_warnings, warning)) continue;
        try run.emit(file_index, warning);
    }
}

fn findSummaryContainerInvalidations(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
) !void {
    const pointer_level = run.configuration.level(.invalidated_element_pointer);
    const iterator_level = run.configuration.level(.iterator_invalidated_during_loop);
    if (pointer_level == .off and iterator_level == .off) return;

    for (file.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);

        if (pointer_level != .off) {
            if (borrowedElementPath(file, declaration_index + 2, declaration_end)) |path| {
                if (firstSummarizedMutation(file, summary_index, path, declaration_end + 1, scope_end)) |mutation| {
                    if (bindingUsedAfter(file, binding, mutation.method_index + 1, scope_end)) {
                        try run.report(.{
                            .file_index = file_index,
                            .rule = .invalidated_element_pointer,
                            .span = file.tokens[declaration_index + 1].loc,
                            .message = try run.allocator.print(
                                "pointer '{s}' is used after helper '{s}' mutates its backing container",
                                .{ binding, mutation.method },
                            ),
                        });
                    }
                }
            }
        }

        if (iterator_level == .off) continue;
        const iterated_path = iteratorReceiverPath(file, declaration_index + 2, declaration_end) orelse continue;
        const mutation = firstSummarizedMutation(file, summary_index, iterated_path, declaration_end + 1, scope_end) orelse continue;
        if (!iteratorActiveAt(file, binding, mutation.method_index, declaration_end + 1, scope_end)) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = .iterator_invalidated_during_loop,
            .span = file.tokens[mutation.method_index].loc,
            .message = try run.allocator.print(
                "helper '{s}' mutates the map while iterator '{s}' is active",
                .{ mutation.method, binding },
            ),
        });
    }
}

fn borrowedElementPath(file: File, start: usize, end: usize) ?PathRange {
    for (file.tokens[start..end], start..) |token, address_index| {
        if (token.tag != .ampersand or address_index + 3 >= end) continue;
        var items_index = address_index + 1;
        while (items_index + 1 < end) : (items_index += 1) {
            if (tokenIs(file.source, file.tokens[items_index], "items") and
                file.tokens[items_index - 1].tag == .period and file.tokens[items_index + 1].tag == .l_bracket)
            {
                return .{ .start = address_index + 1, .end = items_index - 2 };
            }
        }
    }
    return null;
}

fn iteratorReceiverPath(file: File, start: usize, end: usize) ?PathRange {
    for (file.tokens[start..end], start..) |token, method_index| {
        if (!tokenIs(file.source, token, "iterator") or method_index < start + 2 or
            file.tokens[method_index - 1].tag != .period or method_index + 1 >= end or
            file.tokens[method_index + 1].tag != .l_paren) continue;
        var path_start = method_index - 2;
        while (path_start >= start + 2 and file.tokens[path_start - 1].tag == .period and
            file.tokens[path_start - 2].tag == .identifier) path_start -= 2;
        return .{ .start = path_start, .end = method_index - 2 };
    }
    return null;
}

const SummaryMutation = struct { method_index: usize, method: []const u8 };

fn firstSummarizedMutation(
    file: File,
    summary_index: summaries.Index,
    expected_path: PathRange,
    start: usize,
    end: usize,
) ?SummaryMutation {
    for (file.tokens[start..end], start..) |token, opening| {
        if (token.tag != .l_paren or opening == 0 or file.tokens[opening - 1].tag != .identifier or
            (opening >= 2 and file.tokens[opening - 2].tag == .period)) continue;
        const closing = matchingToken(file.tokens, opening, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        const method = tokenText(file.source, file.tokens[opening - 1]);
        const mutation = summary_index.containerMutationCall(file.source, null, method) orelse continue;
        const argument = callArgumentRange(file.tokens, opening + 1, closing, mutation.parameter) orelse continue;
        if (!mutationArgumentMatchesPath(file, argument, mutation.field, expected_path)) continue;
        return .{ .method_index = opening - 1, .method = method };
    }
    return null;
}

fn callArgumentRange(tokens: []const std.zig.Token, start: usize, end: usize, wanted: usize) ?PathRange {
    var parameter: usize = 0;
    var argument_start = start;
    var depth: usize = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const at_end = index == end;
        if (!at_end) switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter == wanted) return .{ .start = argument_start, .end = index - 1 };
        parameter += 1;
        argument_start = index + 1;
    }
    return null;
}

fn mutationArgumentMatchesPath(
    file: File,
    argument: PathRange,
    field: []const u8,
    expected: PathRange,
) bool {
    var argument_start = argument.start;
    if (argument_start <= argument.end and file.tokens[argument_start].tag == .ampersand) argument_start += 1;
    const argument_count = if (argument_start <= argument.end) argument.end - argument_start + 1 else 0;
    const expected_count = expected.end - expected.start + 1;
    const field_tokens: usize = if (field.len == 0) 0 else 2;
    if (argument_count + field_tokens != expected_count) return false;
    for (0..argument_count) |offset| {
        if (!std.mem.eql(
            u8,
            tokenText(file.source, file.tokens[argument_start + offset]),
            tokenText(file.source, file.tokens[expected.start + offset]),
        )) return false;
    }
    if (field.len == 0) return true;
    return file.tokens[expected.start + argument_count].tag == .period and
        tokenIs(file.source, file.tokens[expected.start + argument_count + 1], field);
}

fn iteratorActiveAt(file: File, iterator: []const u8, mutation: usize, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, while_index| {
        if (token.tag != .keyword_while or while_index >= mutation) continue;
        var body_start = while_index + 1;
        while (body_start < mutation and file.tokens[body_start].tag != .l_brace) : (body_start += 1) {}
        if (body_start >= mutation) continue;
        const body_end = matchingToken(file.tokens, body_start, .l_brace, .r_brace) orelse continue;
        if (mutation >= body_end) continue;
        var index = while_index + 1;
        while (index + 3 < body_start) : (index += 1) {
            if (tokenIs(file.source, file.tokens[index], iterator) and file.tokens[index + 1].tag == .period and
                tokenIs(file.source, file.tokens[index + 2], "next") and file.tokens[index + 3].tag == .l_paren) return true;
        }
    }
    return false;
}

fn findDiscardedSummaryIo(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
) !void {
    if (run.configuration.level(.discarded_read_count) == .off and run.configuration.level(.discarded_write_count) == .off) return;
    for (file.tokens, 0..) |token, equal_index| {
        if (token.tag != .equal or equal_index == 0 or file.tokens[equal_index - 1].tag != .identifier or
            !tokenIs(file.source, file.tokens[equal_index - 1], "_")) continue;
        const statement_end = statementEnd(file.tokens, equal_index) orelse continue;
        const call = outerCall(file.tokens, equal_index + 1, statement_end) orelse continue;
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
        const partial_io = summary_index.partialIoReturnCall(file.source, receiver, name);
        if (partial_io == .none or directPartialIoMethod(name)) continue;
        const rule: types.Rule = if (partial_io == .read) .discarded_read_count else .discarded_write_count;
        const level = run.configuration.level(rule);
        if (level == .off) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = rule,
            .span = file.tokens[call.name_index].loc,
            .message = try run.allocator.print(
                "discarding {s}'s summarized partial-{s} count loses how much data was transferred",
                .{ name, if (partial_io == .read) "read" else "write" },
            ),
        });
    }
}

fn directPartialIoMethod(name: []const u8) bool {
    const methods = [_][]const u8{ "read", "readVec", "readSliceShort", "pread", "readv", "preadv", "write" };
    for (methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

fn findBorrowedReturnInvalidations(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
) !void {
    if (run.configuration.level(.invalidated_element_pointer) == .off and
        run.configuration.level(.invalidated_container_view) == .off) return;
    for (file.tokens, 0..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= file.tokens.len or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const equal_index = findTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
        const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
        const receiver_index = call.receiver_index orelse continue;
        const receiver = tokenText(file.source, file.tokens[receiver_index]);
        const name = tokenText(file.source, file.tokens[call.name_index]);
        const borrowed = summary_index.borrowedReturnCall(file.source, receiver, name) orelse continue;
        if (call.closing + 1 != declaration_end) continue;
        if (borrowed.parameter != 0) continue;
        const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
        const invalidation = firstBorrowInvalidation(
            file,
            summary_index,
            receiver,
            borrowed.field,
            declaration_end + 1,
            scope_end,
        ) orelse continue;
        const binding = tokenText(file.source, file.tokens[declaration_index + 1]);
        if (!bindingUsedAfter(file, binding, invalidation.method_index + 1, scope_end)) continue;
        const rule: types.Rule = if (borrowed.kind == .pointer) .invalidated_element_pointer else .invalidated_container_view;
        const level = run.configuration.level(rule);
        if (level == .off) continue;
        try run.report(.{
            .file_index = file_index,
            .rule = rule,
            .span = file.tokens[declaration_index + 1].loc,
            .message = try run.allocator.print(
                "{s} '{s}' returned by {s} borrows from '{s}{s}{s}' and is used after {s}",
                .{
                    if (borrowed.kind == .pointer) "pointer" else "view",
                    binding,
                    name,
                    receiver,
                    if (borrowed.field.len == 0) "" else ".",
                    borrowed.field,
                    invalidation.method,
                },
            ),
        });
    }
}

const BorrowInvalidation = struct { method_index: usize, method: []const u8 };

fn firstBorrowInvalidation(
    file: File,
    summary_index: summaries.Index,
    receiver: []const u8,
    field: []const u8,
    start: usize,
    end: usize,
) ?BorrowInvalidation {
    const methods = [_][]const u8{
        "append",
        "appendSlice",
        "insert",
        "resize",
        "ensureTotalCapacity",
        "ensureUnusedCapacity",
        "addOne",
        "addManyAsArray",
        "orderedRemove",
        "swapRemove",
        "clearAndFree",
        "clearRetainingCapacity",
    };
    var index = start;
    while (index + 3 < end) : (index += 1) {
        if (!tokenIs(file.source, file.tokens[index], receiver)) continue;
        var method_index = index + 2;
        if (file.tokens[index + 1].tag != .period) continue;
        const direct_field_mutation = field.len != 0 and index + 5 < end and
            tokenIs(file.source, file.tokens[index + 2], field) and file.tokens[index + 3].tag == .period;
        if (direct_field_mutation) {
            method_index = index + 4;
        }
        if (file.tokens[method_index].tag != .identifier or method_index + 1 >= end or
            file.tokens[method_index + 1].tag != .l_paren) continue;
        const method = tokenText(file.source, file.tokens[method_index]);
        if (field.len == 0 or direct_field_mutation) {
            for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) {
                return .{ .method_index = method_index, .method = method };
            };
        }
        if (method_index != index + 2) continue;
        const mutation = summary_index.containerMutationCall(file.source, receiver, method) orelse continue;
        if (mutation.parameter == 0 and std.mem.eql(u8, mutation.field, field)) {
            return .{ .method_index = method_index, .method = method };
        }
    }
    return null;
}

fn bindingUsedAfter(file: File, binding: []const u8, start: usize, end: usize) bool {
    const path_scope = enclosingOpeningBrace(file.tokens, start);
    const path_end = if (path_scope) |opening|
        @min(matchingToken(file.tokens, opening, .l_brace, .r_brace) orelse end, end)
    else
        end;
    for (file.tokens[start..path_end], start..) |token, index| {
        if (token.tag != .identifier or !tokenIs(file.source, token, binding) or
            (index > 0 and file.tokens[index - 1].tag == .period))
        {
            const direct_terminator = index == 0 or switch (file.tokens[index - 1].tag) {
                .semicolon, .l_brace, .r_brace => true,
                else => false,
            };
            if (direct_terminator and path_scope != null and enclosingOpeningBrace(file.tokens, index) == path_scope) switch (token.tag) {
                .keyword_return, .keyword_continue, .keyword_break, .keyword_unreachable => {
                    const statement_end = statementEnd(file.tokens, index) orelse return false;
                    for (file.tokens[index + 1 .. @min(statement_end, path_end)], index + 1..) |value_token, value_index| {
                        if (value_token.tag == .identifier and tokenIs(file.source, value_token, binding) and
                            (value_index == 0 or file.tokens[value_index - 1].tag != .period)) return true;
                    }
                    return false;
                },
                else => {},
            };
            continue;
        }
        if (index + 1 < end and file.tokens[index + 1].tag == .equal) return false;
        return true;
    }
    if (path_end == end) return false;
    for (file.tokens[path_end + 1 .. end], path_end + 1..) |token, index| {
        if (token.tag == .identifier and tokenIs(file.source, token, binding) and
            (index == 0 or file.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn findEscapingLocalStorage(
    run: ProjectRun,
    file: File,
    file_index: usize,
    summary_index: summaries.Index,
) !void {
    const level = run.configuration.level(.local_storage_escape);
    if (level == .off) return;
    for (file.tokens, 0..) |token, array_declaration| {
        if (token.tag != .keyword_var or array_declaration + 5 >= file.tokens.len or
            file.tokens[array_declaration + 1].tag != .identifier or file.tokens[array_declaration + 2].tag != .colon or
            file.tokens[array_declaration + 3].tag != .l_bracket or file.tokens[array_declaration + 4].tag != .number_literal or
            file.tokens[array_declaration + 5].tag != .r_bracket) continue;
        const array_end = statementEnd(file.tokens, array_declaration) orelse continue;
        const scope_end = enclosingScopeEnd(file.tokens, array_declaration) orelse continue;
        const array_name = tokenText(file.source, file.tokens[array_declaration + 1]);
        for (file.tokens[array_end + 1 .. scope_end], array_end + 1..) |candidate, alias_declaration| {
            if ((candidate.tag != .keyword_const and candidate.tag != .keyword_var) or
                alias_declaration + 3 >= scope_end or file.tokens[alias_declaration + 1].tag != .identifier) continue;
            const alias_end = statementEnd(file.tokens, alias_declaration) orelse continue;
            if (!rangeBorrowsArray(file, array_name, alias_declaration + 2, alias_end)) continue;
            const alias = tokenText(file.source, file.tokens[alias_declaration + 1]);
            const escaped = escapingCallResult(file, summary_index, alias, alias_end + 1, scope_end) orelse continue;
            if (!bindingRetained(file, escaped.binding, escaped.declaration_end + 1, scope_end)) continue;
            try run.report(.{
                .file_index = file_index,
                .rule = .local_storage_escape,
                .span = file.tokens[escaped.argument_index].loc,
                .message = try run.allocator.print(
                    "'{s}' aliases local array '{s}' and is retained by {s} beyond that storage's safe lifetime",
                    .{ alias, array_name, escaped.callable },
                ),
            });
        }
    }
}

fn rangeBorrowsArray(file: File, name: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .ampersand and index + 1 < end and tokenIs(file.source, file.tokens[index + 1], name)) return true;
        if (token.tag != .identifier or !tokenIs(file.source, token, name) or index + 1 >= end or
            file.tokens[index + 1].tag != .l_bracket) continue;
        const closing = matchingToken(file.tokens, index + 1, .l_bracket, .r_bracket) orelse continue;
        if (closing > end) continue;
        for (file.tokens[index + 2 .. closing]) |slice_token| if (slice_token.tag == .ellipsis2) return true;
    }
    return false;
}

const EscapingCall = struct {
    binding: []const u8,
    declaration_end: usize,
    argument_index: usize,
    callable: []const u8,
};

fn escapingCallResult(
    file: File,
    summary_index: summaries.Index,
    alias: []const u8,
    start: usize,
    end: usize,
) ?EscapingCall {
    for (file.tokens[start..end], start..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= end or
            file.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
        const equal_index = findTag(file.tokens, declaration_index + 2, declaration_end, .equal) orelse continue;
        const call = firstCall(file.tokens, equal_index + 1, declaration_end) orelse continue;
        const argument = exactArgument(file, call, alias) orelse continue;
        const callable_start = call.receiver_index orelse call.name_index;
        const callable = file.source[file.tokens[callable_start].loc.start..file.tokens[call.name_index].loc.end];
        if (!summary_index.parameterEscapesForCall(file.source, callable, argument.parameter)) continue;
        return .{
            .binding = tokenText(file.source, file.tokens[declaration_index + 1]),
            .declaration_end = declaration_end,
            .argument_index = argument.token_index,
            .callable = callable,
        };
    }
    return null;
}

const Argument = struct { parameter: usize, token_index: usize };

fn exactArgument(file: File, call: Call, name: []const u8) ?Argument {
    var parameter: usize = 0;
    var argument_start = call.opening + 1;
    var depth: usize = 0;
    var index = argument_start;
    while (index <= call.closing) : (index += 1) {
        const at_end = index == call.closing;
        const tag = file.tokens[index].tag;
        if (!at_end) switch (tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tag != .comma or depth != 0)) continue;
        if (argument_start + 1 == index and file.tokens[argument_start].tag == .identifier and
            tokenIs(file.source, file.tokens[argument_start], name)) return .{ .parameter = parameter, .token_index = argument_start };
        parameter += 1;
        argument_start = index + 1;
    }
    return null;
}

fn bindingRetained(file: File, binding: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .keyword_return) {
            const return_end = statementEnd(file.tokens, index) orelse continue;
            if (rangeRefersToBinding(file, binding, index + 1, @min(return_end, end))) return true;
        }
        if (token.tag != .l_paren or index == 0 or file.tokens[index - 1].tag != .identifier) continue;
        const method = tokenText(file.source, file.tokens[index - 1]);
        if (!std.mem.eql(u8, method, "append") and !std.mem.eql(u8, method, "put") and
            !std.mem.eql(u8, method, "insert")) continue;
        const closing = matchingToken(file.tokens, index, .l_paren, .r_paren) orelse continue;
        if (closing >= end) continue;
        if (rangeRefersToBinding(file, binding, index + 1, closing)) return true;
    }
    return false;
}

fn rangeRefersToBinding(file: File, name: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and tokenIs(file.source, token, name) and
            (index == 0 or file.tokens[index - 1].tag != .period)) return true;
    }
    return false;
}

fn outerCall(tokens: []const std.zig.Token, start: usize, end: usize) ?Call {
    const call = firstCall(tokens, start, end) orelse return null;
    return if (call.closing + 1 == end) call else null;
}

fn containsLifecycleFinding(
    warnings: []const types.Finding,
    candidate: types.Finding,
) bool {
    for (warnings) |warning| {
        if (warning.rule == candidate.rule and warning.span.start == candidate.span.start and
            warning.span.end == candidate.span.end) return true;
    }
    return false;
}

pub fn findDeferredOwnedEscapes(
    run: ProjectRun,
    summary_index: summaries.Index,
) !void {
    if (run.configuration.level(.returning_released_value) == .off) return;
    for (run.files, 0..) |file, file_index| {
        for (file.tokens, 0..) |token, declaration_index| {
            if ((token.tag != .keyword_const and token.tag != .keyword_var) or
                declaration_index + 3 >= file.tokens.len or file.tokens[declaration_index + 1].tag != .identifier) continue;
            const declaration_end = statementEnd(file.tokens, declaration_index) orelse continue;
            const call = firstCall(file.tokens, declaration_index + 2, declaration_end) orelse continue;
            const function_name = tokenText(file.source, file.tokens[call.name_index]);
            const receiver = if (call.receiver_index) |index| tokenText(file.source, file.tokens[index]) else null;
            const binding = tokenText(file.source, file.tokens[declaration_index + 1]);
            const returns_owned = summary_index.callReturnsOwned(file.source, receiver, function_name);
            if (!returns_owned) continue;
            const scope_start = enclosingOpeningBrace(file.tokens, declaration_index) orelse continue;
            const scope_end = enclosingScopeEnd(file.tokens, declaration_index) orelse continue;
            const release_end = deferredOwnedRelease(file, binding, declaration_end + 1, scope_end, scope_start) orelse continue;
            for (file.tokens[release_end + 1 .. scope_end], release_end + 1..) |candidate, equal_index| {
                if (candidate.tag != .equal or equal_index + 2 >= scope_end or
                    !tokenIs(file.source, file.tokens[equal_index + 1], binding) or
                    file.tokens[equal_index + 2].tag != .semicolon or
                    !assignmentStoresWholeValue(file.tokens, equal_index) or
                    bindingReassignedAfter(file, binding, equal_index + 3, scope_end)) continue;
                try run.report(.{
                    .file_index = file_index,
                    .rule = .returning_released_value,
                    .span = file.tokens[equal_index + 1].loc,
                    .message = try run.allocator.print(
                        "stored owning value '{s}' is released by its deferred cleanup as the scope exits",
                        .{binding},
                    ),
                });
                break;
            }
        }
    }
}

fn deferredOwnedRelease(
    file: File,
    binding: []const u8,
    start: usize,
    end: usize,
    scope_start: usize,
) ?usize {
    for (file.tokens[start..end], start..) |token, defer_index| {
        if (token.tag != .keyword_defer or enclosingOpeningBrace(file.tokens, defer_index) != scope_start) continue;
        const statement_end = statementEnd(file.tokens, defer_index) orelse continue;
        if (statement_end >= end) continue;
        var method_index = defer_index + 1;
        while (method_index < statement_end) : (method_index += 1) {
            if (file.tokens[method_index].tag == .keyword_if) break;
            if (file.tokens[method_index].tag != .identifier or
                (!tokenIs(file.source, file.tokens[method_index], "deinit") and
                    !tokenIs(file.source, file.tokens[method_index], "free") and
                    !tokenIs(file.source, file.tokens[method_index], "destroy") and
                    !tokenIs(file.source, file.tokens[method_index], "close") and
                    !tokenIs(file.source, file.tokens[method_index], "release"))) continue;
            if (method_index >= 2 and file.tokens[method_index - 1].tag == .period and
                tokenIs(file.source, file.tokens[method_index - 2], binding)) return statement_end;
            if (method_index + 1 >= statement_end or file.tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = matchingToken(file.tokens, method_index + 1, .l_paren, .r_paren) orelse continue;
            for (file.tokens[method_index + 2 .. @min(call_end, statement_end)]) |argument| {
                if (argument.tag == .identifier and tokenIs(file.source, argument, binding)) return statement_end;
            }
        }
    }
    return null;
}

fn assignmentStoresWholeValue(tokens: []const std.zig.Token, equal_index: usize) bool {
    if (equal_index < 2) return false;
    return tokens[equal_index - 1].tag == .period_asterisk or
        (tokens[equal_index - 1].tag == .asterisk and tokens[equal_index - 2].tag == .period) or
        (tokens[equal_index - 1].tag == .identifier and tokens[equal_index - 2].tag == .period);
}

fn bindingReassignedAfter(file: File, binding: []const u8, start: usize, end: usize) bool {
    for (file.tokens[start..end], start..) |token, binding_index| {
        if (token.tag == .identifier and tokenIs(file.source, token, binding) and
            binding_index + 1 < end and file.tokens[binding_index + 1].tag == .equal) return true;
    }
    return false;
}

test "project summaries expose leaks hidden by cross-file borrowing calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{
        .{ .path = "src/inspect.zig", .source = "pub fn inspect(bytes: []u8) void { _ = bytes.len; }" },
        .{ .path = "src/main.zig", .source = "const inspection = @import(\"inspect.zig\"); fn run(allocator: std.mem.Allocator) !void { const bytes = try allocator.alloc(u8, 4); inspection.inspect(bytes); }" },
    };
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].finding.rule);
    try std.testing.expectEqual(@as(usize, 1), found[0].file_index);
}

test "cross-file owned returns retain allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{
        .{ .path = "src/config.zig", .source = "pub fn optionValueAlloc(allocator: std.mem.Allocator) ![]u8 { return allocator.dupe(u8, \"value\"); }" },
        .{ .path = "src/main.zig", .source = "const config = @import(\"config.zig\"); const App = struct { allocator: std.mem.Allocator, fn run(self: *App) !void { const value = try config.optionValueAlloc(self.allocator); defer self.allocator.free(value); } };" },
    };
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .mismatched_allocation_release);
}

test "stored ownership is not released by the source defer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/database.zig",
        .source = "const Database = struct { allocator: std.mem.Allocator, bytes: []u8," ++
            "fn init(allocator: std.mem.Allocator) Database { return .{ .allocator = allocator, .bytes = &.{} }; }" ++
            "fn deinit(self: *Database) void { self.allocator.free(self.bytes); }" ++
            "fn clone(self: *Database) !Database { var copy = Database.init(self.allocator);" ++
            "copy.bytes = try self.allocator.alloc(u8, 8); errdefer copy.deinit(); return copy; } };" ++
            "fn rollback(database: *Database) !void { var backup = try database.clone();" ++
            "defer backup.deinit(); database.* = backup; }" ++
            "fn transfer(database: *Database) !void { var backup = try database.clone(); var retained = true;" ++
            "defer if (retained) backup.deinit(); database.* = backup; retained = false; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var released_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .returning_released_value) {
        released_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), released_count);
}

test "owned helper returns require errdefer before later failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "fn makeMessage(allocator: std.mem.Allocator, text: []const u8) ![]u8 { return allocator.dupe(u8, text); }" ++
            "fn assemble(allocator: std.mem.Allocator) ![]u8 {" ++
            "const prefix = try makeMessage(allocator, \"prefix\");" ++
            "const suffix = try makeMessage(allocator, \"suffix\");" ++
            "errdefer allocator.free(prefix);" ++
            "const result = try allocator.alloc(u8, prefix.len + suffix.len);" ++
            "allocator.free(prefix); allocator.free(suffix); return result; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var missing_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .missing_errdefer) {
        missing_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), missing_count);
}

test "project summaries preserve partial IO contracts through wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Socket = struct { stream: Stream, fn send(self: *Socket, bytes: []const u8) !usize { return self.stream.write(bytes); } };" ++
            "fn run(socket: *Socket, bytes: []const u8) !void { _ = try socket.send(bytes); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var discarded_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .discarded_write_count) {
        discarded_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), discarded_count);
}

test "borrowed helper returns are invalidated with their receiver field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Catalog = struct { records: List, " ++
            "fn find(self: *Catalog, index: usize) *Record { return &self.records.items[index]; } " ++
            "fn view(self: *Catalog) []Record { return self.records.items[0..]; } " ++
            "fn remove(self: *Catalog) void { _ = self.records.orderedRemove(0); } };" ++
            "fn run(catalog: *Catalog) !void {" ++
            "const record = catalog.find(0); try catalog.records.append(a, .{}); use(record);" ++
            "const view = catalog.view(); _ = catalog.records.orderedRemove(0); consume(view);" ++
            "const second = catalog.view(); catalog.remove(); return consume(second); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var pointer_count: usize = 0;
    var view_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .invalidated_element_pointer => pointer_count += 1,
        .invalidated_container_view => view_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
    try std.testing.expectEqual(@as(usize, 2), view_count);
}

test "owned helper returns remain valid after their source container resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Builder = struct { buffer: List, " ++
            "fn finish(self: *Builder, allocator: std.mem.Allocator) ![]u8 { return self.buffer.toOwnedSlice(allocator); } " ++
            "fn reset(self: *Builder) void { self.buffer.clearRetainingCapacity(); } };" ++
            "fn run(builder: *Builder, allocator: std.mem.Allocator) !void {" ++
            "const first = try builder.finish(allocator); defer allocator.free(first); builder.reset(); use(first); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .invalidated_container_view);
}

test "fields copied from borrowed returns and terminated mutation branches stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Tree = struct { nodes: List, " ++
            "fn nodeAt(self: *Tree, index: usize) *Node { return &self.nodes.items[index]; } " ++
            "fn run(self: *Tree, index: usize, grow: bool) !void {" ++
            "const parent = self.nodeAt(index).parent; try self.nodes.append(a, .{}); use(parent);" ++
            "const current = self.nodeAt(index); if (grow) { try self.nodes.append(a, .{}); continueWork(); return; } use(current); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .invalidated_element_pointer);
}

test "conditional branch termination does not hide a later borrowed pointer use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Tree = struct { nodes: List, " ++
            "fn nodeAt(self: *Tree, index: usize) *Node { return &self.nodes.items[index]; } " ++
            "fn run(self: *Tree, index: usize, stop: bool) !void { const current = self.nodeAt(index);" ++
            "try self.nodes.append(a, .{}); if (stop) return; use(current); } };",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var invalidation_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .invalidated_element_pointer) {
        invalidation_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), invalidation_count);
}

test "container mutation summaries invalidate direct pointers and active iterators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "fn grow(values: *List) !void { try values.ensureTotalCapacity(a, 64); }" ++
            "fn add(map: *Map) !void { try map.put(2, 2); }" ++
            "fn run(values: *List, map: *Map) !void { const borrowed = &values.items[0];" ++
            "try grow(&values); use(borrowed); var iterator = map.iterator();" ++
            "while (iterator.next()) |_| { try add(&map); } }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var pointer_count: usize = 0;
    var iterator_count: usize = 0;
    for (found) |finding| switch (finding.finding.rule) {
        .invalidated_element_pointer => pointer_count += 1,
        .iterator_invalidated_during_loop => iterator_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), pointer_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_count);
}

test "escaped local views retained in aggregates report" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Entry = struct { text: []const u8 };" ++
            "fn parse(raw: []const u8) Entry { return .{ .text = raw }; }" ++
            "fn load(allocator: anytype, source: []const u8) ![]Entry {" ++
            "var entries = List.empty; var buffer: [64]u8 = undefined; @memcpy(buffer[0..source.len], source);" ++
            "const input = buffer[0..source.len]; const entry = parse(input); try entries.append(allocator, entry); return entries.items; }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    var escape_count: usize = 0;
    for (found) |finding| if (finding.finding.rule == .local_storage_escape) {
        escape_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), escape_count);
}

test "borrowed local views and unretained aggregate results stay clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]project.SourceFile{.{
        .path = "src/main.zig",
        .source = "const Entry = struct { text: []const u8 };" ++
            "fn length(raw: []const u8) usize { return raw.len; }" ++
            "fn parse(raw: []const u8) Entry { return .{ .text = raw }; }" ++
            "fn load() void { var buffer: [64]u8 = undefined; const input = buffer[0..];" ++
            "const scalar = std.math.cast(u8, buffer[0]) orelse return;" ++
            "const size = length(input); const entry = parse(input); use(scalar, size, entry); }",
    }};
    const found = try project.findings(arena.allocator(), &files, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.finding.rule != .local_storage_escape);
}
