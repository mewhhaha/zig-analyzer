//! The lexical scans of a binding's uses that the leak proof, the path walk
//! and the reports share: whether the tokens a scan visits release the
//! binding (directly, by a conventional cleanup method, or through a helper
//! whose summary releases it), let it escape or transfer it, and the
//! call-argument and scope helpers they read calls with.
const std = @import("std");

const syntax_scope = @import("../../../syntax/scope.zig");
const resources = @import("../../resources.zig");
const summaries = @import("../../summaries.zig");
const tokenRefersToBinding = @import("../../context.zig").tokenRefersToBinding;
const TokenRange = @import("../../../syntax/tokens.zig").Range;

pub const Cleanup = enum { released, errdefer_only, missing };

pub fn ownershipLeavesScope(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    spans: []const TokenRange,
    release_method: []const u8,
    summary_index: summaries.Index,
) Cleanup {
    var found_errdefer = false;
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, index| {
        if ((token.tag == .keyword_return or token.tag == .keyword_break) and
            controlFlowValueContainsBinding(source, tokens, scope_index, binding_name, binding_index, index + 1, end)) return .released;
        if (token.tag != .identifier) continue;
        const method = source[token.loc.start..token.loc.end];
        const expected_cleanup = std.mem.eql(u8, method, release_method);
        if (!expected_cleanup and !conventionalCleanupMethod(method)) continue;
        if (index == 0 or index + 2 >= end or tokens[index - 1].tag != .period or tokens[index + 1].tag != .l_paren) {
            continue;
        }
        const closing_parenthesis = scope_index.matchingToken(index + 1) orelse continue;
        if (closing_parenthesis >= end) continue;
        const receiver_is_binding = index >= 2 and tokenIsIdentifier(source, tokens[index - 2], binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index - 2);
        const argument_start = lastCallArgumentStart(tokens, index + 1, closing_parenthesis);
        const argument_contains_binding = releaseArgumentContainsBinding(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            argument_start,
            closing_parenthesis,
        ) or releaseArgumentContainsOptionalCapture(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            start,
            argument_start,
            closing_parenthesis,
            index,
        );
        const receiver_cleanup = receiver_is_binding and conventionalCleanupMethod(method);
        if (!receiver_cleanup and (!expected_cleanup or !argument_contains_binding)) continue;
        if (!statementStartsWithErrdefer(tokens, index)) return .released;
        found_errdefer = true;
    };
    if (localHelperReleasesBinding(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        end,
        spans,
        summary_index,
    )) return .released;
    if (bindingEscapes(source, tokens, scope_index, binding_name, binding_index, start, end, spans, release_method, summary_index)) return .released;
    return if (found_errdefer) .errdefer_only else .missing;
}

fn releaseArgumentContainsOptionalCapture(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    search_start: usize,
    argument_start: usize,
    argument_end: usize,
    release_index: usize,
) bool {
    for (tokens[argument_start..argument_end], argument_start..) |argument, argument_index| {
        if (argument.tag != .identifier) continue;
        const capture_name = source[argument.loc.start..argument.loc.end];
        var captures = scope_index.identifiersNamed(capture_name, search_start + 1, release_index -| 2);
        while (captures.next()) |capture_name_index| {
            const capture_index = capture_name_index - 1;
            if (tokens[capture_index].tag != .pipe or tokens[capture_index + 2].tag != .pipe) continue;
            const body_end = if (tokens[capture_index + 3].tag == .l_brace)
                scope_index.matchingToken(capture_index + 3) orelse continue
            else
                scope_index.statementEnd(capture_index + 3) orelse continue;
            if (body_end < release_index) continue;
            // Only the `if` whose condition closes right before the capture owns it.
            if (capture_index == 0 or tokens[capture_index - 1].tag != .r_paren) continue;
            const condition_start = scope_index.matchingToken(capture_index - 1) orelse continue;
            if (condition_start <= search_start or tokens[condition_start - 1].tag != .keyword_if) continue;
            const if_index = condition_start - 1;
            if (!identifierRefersToBinding(scope_index, capture_index + 1, argument_index) or !containsBinding(
                scope_index,
                binding_name,
                binding_index,
                if_index + 2,
                capture_index - 1,
            )) continue;
            return true;
        }
    }
    return false;
}

fn conventionalCleanupMethod(method: []const u8) bool {
    const methods = [_][]const u8{ "close", "deinit", "delete", "destroy", "free", "release", "shutdown" };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

fn controlFlowValueContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    scope_end: usize,
) bool {
    const end = @min(scope_index.statementEnd(start) orelse scope_end, scope_end);
    return valueTransfersBinding(source, tokens, scope_index, binding_name, binding_index, start, end);
}

/// One past the last token a scan of `[start, end)` for a release, escape or
/// transfer of `binding_name` has to visit: the end of the statement holding
/// the binding's last mention in the range. Every such site names the binding
/// inside its own statement, in the call (`free(name)`), two tokens before it
/// (`name.deinit()`), or in the condition of the `if` whose capture it
/// releases, so no later token can be one. The checks made at each site still
/// look as far as `end`.
fn usesEnd(scope_index: *const syntax_scope.Index, binding_name: []const u8, start: usize, end: usize) usize {
    var last_use: ?usize = null;
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |use| last_use = use;
    const use = last_use orelse return start;
    // A block opened inside the range ends with the statement that opens it.
    var outermost = use;
    var brace = scope_index.enclosingOpeningBrace(use);
    while (brace) |opening| : (brace = scope_index.enclosingOpeningBrace(opening)) {
        if (opening < start) break;
        outermost = opening;
    }
    const statement_end = scope_index.statementEnd(outermost) orelse return end;
    return @min(end, statement_end + 1);
}

/// `[start, usesEnd)` as the one span a scan of `[start, end)` visits.
pub fn usesSpan(scope_index: *const syntax_scope.Index, binding_name: []const u8, start: usize, end: usize) [1]TokenRange {
    return .{.{ .start = start, .end = usesEnd(scope_index, binding_name, start, end) }};
}

pub fn containsBinding(
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (identifierRefersToBinding(scope_index, binding_index, index)) return true;
    }
    return false;
}

pub fn bindingEscapes(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
    spans: []const TokenRange,
    release_method: []const u8,
    summary_index: summaries.Index,
) bool {
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, index| {
        if (tokenIsIdentifier(source, token, binding_name) and
            identifierRefersToBinding(scope_index, binding_index, index) and
            index + 3 < end and tokens[index + 1].tag == .period and
            tokens[index + 2].tag == .identifier and tokens[index + 3].tag == .l_paren)
        {
            return true;
        }
        if (token.tag == .l_paren and index > 0 and
            (tokens[index - 1].tag == .identifier or tokens[index - 1].tag == .builtin))
        {
            const closing = scope_index.matchingToken(index) orelse continue;
            if (closing >= end or !containsBinding(scope_index, binding_name, binding_index, index + 1, closing)) continue;
            if (callOnlyUsesScalarProjections(
                source,
                tokens,
                scope_index,
                binding_name,
                binding_index,
                index + 1,
                closing,
            )) continue;
            const method = source[tokens[index - 1].loc.start..tokens[index - 1].loc.end];
            if (std.mem.eql(u8, method, release_method)) {
                const method_call = index >= 2 and tokens[index - 2].tag == .period;
                if (method_call) continue;
                return true;
            }
            if (tokens[index - 1].tag == .identifier) {
                switch (localCallOwnership(
                    source,
                    tokens,
                    scope_index,
                    binding_name,
                    binding_index,
                    index,
                    summary_index,
                )) {
                    .borrowed, .released => continue,
                    .unknown => {},
                }
            }
            if (tokens[index - 1].tag == .builtin and builtinBorrowsMemory(method)) continue;
            return true;
        }
        if (token.tag != .equal) continue;
        const statement_end = scope_index.statementEnd(index) orelse continue;
        if (statement_end >= end or
            !containsBinding(scope_index, binding_name, binding_index, index + 1, statement_end) or
            assignmentDiscards(source, tokens, start, index)) continue;
        if (index >= 2 and (tokens[index - 2].tag == .keyword_const or tokens[index - 2].tag == .keyword_var) and
            localDeclarationCreatesBorrowingView(
                source,
                tokens,
                scope_index,
                binding_name,
                binding_index,
                index + 1,
                statement_end,
            )) continue;
        return true;
    };
    return false;
}

fn callOnlyUsesScalarProjections(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    var found = false;
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (!identifierRefersToBinding(scope_index, binding_index, index)) continue;
        found = true;
        if (index + 2 < end and tokens[index + 1].tag == .period and
            tokenIsIdentifier(source, tokens[index + 2], "len")) continue;
        if (index + 1 < end and tokens[index + 1].tag == .l_bracket) {
            const bracket_end = scope_index.matchingToken(index + 1) orelse return false;
            if (bracket_end >= end) return false;
            var is_slice = false;
            for (tokens[index + 2 .. bracket_end]) |part| {
                if (part.tag == .ellipsis2 or part.tag == .ellipsis3) {
                    is_slice = true;
                    break;
                }
            }
            if (!is_slice) continue;
        }
        return false;
    }
    return found;
}

fn localDeclarationCreatesBorrowingView(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    for (tokens[start..end], start..) |token, call_open| {
        if (token.tag != .l_paren or call_open == 0 or tokens[call_open - 1].tag != .identifier) continue;
        const call_close = scope_index.matchingToken(call_open) orelse continue;
        if (call_close >= end) continue;
        const argument_index = bareBindingArgumentIndex(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            call_open + 1,
            call_close,
        ) orelse continue;
        var callable_start = call_open - 1;
        while (callable_start >= 2 and tokens[callable_start - 1].tag == .period and
            tokens[callable_start - 2].tag == .identifier) callable_start -= 2;
        const callable = source[tokens[callable_start].loc.start..tokens[call_open - 1].loc.end];
        if (conventionalBorrowingCall(callable, argument_index, callArgumentCount(tokens, call_open + 1, call_close))) return true;
    }
    return false;
}

fn builtinBorrowsMemory(name: []const u8) bool {
    return !std.mem.eql(u8, name, "@call");
}

const CallOwnership = enum { borrowed, released, unknown };

fn localHelperReleasesBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    end: usize,
    spans: []const TokenRange,
    summary_index: summaries.Index,
) bool {
    for (spans) |span| for (tokens[span.start..span.end], span.start..) |token, call_open| {
        if (token.tag != .l_paren or call_open == 0 or tokens[call_open - 1].tag != .identifier) continue;
        const closing = scope_index.matchingToken(call_open) orelse continue;
        if (closing >= end or !containsBinding(
            scope_index,
            binding_name,
            binding_index,
            call_open + 1,
            closing,
        )) continue;
        if (localCallOwnership(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            call_open,
            summary_index,
        ) == .released) return true;
    };
    return false;
}

pub fn localCallOwnership(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    call_open: usize,
    summary_index: summaries.Index,
) CallOwnership {
    if (call_open == 0 or tokens[call_open - 1].tag != .identifier) return .unknown;
    const call_close = scope_index.matchingToken(call_open) orelse return .unknown;
    const containing_argument = bindingArgumentIndex(
        tokens,
        scope_index,
        binding_name,
        binding_index,
        call_open + 1,
        call_close,
    ) orelse return .unknown;
    var callable_start = call_open - 1;
    while (callable_start >= 2 and tokens[callable_start - 1].tag == .period and
        tokens[callable_start - 2].tag == .identifier) callable_start -= 2;
    const callable = source[tokens[callable_start].loc.start..tokens[call_open - 1].loc.end];
    const argument_count = callArgumentCount(tokens, call_open + 1, call_close);
    const method = if (std.mem.findScalarLast(u8, callable, '.')) |separator| callable[separator + 1 ..] else callable;
    if (containing_argument == 2 and argument_count >= 6 and
        std.mem.eql(u8, method, "write") and
        asyncWriteCallbackReleasesBuffer(source, tokens, scope_index, call_open, call_close)) return .released;
    if (conventionalBorrowingCall(callable, containing_argument, argument_count)) return .borrowed;
    const argument_index = bareBindingArgumentIndex(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        call_open + 1,
        call_close,
    ) orelse return .unknown;
    return switch (summary_index.parameterEffectForCall(source, callable, argument_index)) {
        .borrowed => .borrowed,
        .released => .released,
        .escaped, .unknown => .unknown,
    };
}

fn asyncWriteCallbackReleasesBuffer(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    call_open: usize,
    call_close: usize,
) bool {
    const callback_start = lastCallArgumentStart(tokens, call_open, call_close);
    if (callback_start + 1 != call_close or tokens[callback_start].tag != .identifier) return false;
    const callback_binding = scope_index.findBinding(callback_start) orelse return false;
    if (callback_binding.token_index == 0 or tokens[callback_binding.token_index - 1].tag != .keyword_fn) return false;
    const function_index = callback_binding.token_index - 1;
    if (function_index + 2 >= tokens.len or tokens[function_index + 2].tag != .l_paren) return false;
    const parameters_end = scope_index.matchingToken(function_index + 2) orelse return false;
    var parameter_index: usize = 0;
    var segment_start = function_index + 3;
    var depth: usize = 0;
    var buffer_parameter: ?[]const u8 = null;
    var index = segment_start;
    while (index <= parameters_end) : (index += 1) {
        const at_end = index == parameters_end;
        if (!at_end) switch (tokens[index].tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            else => {},
        };
        if (!at_end and (tokens[index].tag != .comma or depth != 0)) continue;
        if (parameter_index == 4) {
            for (tokens[segment_start..index], segment_start..) |parameter, name_index| {
                if (parameter.tag == .identifier and name_index + 1 < index and tokens[name_index + 1].tag == .colon) {
                    buffer_parameter = source[parameter.loc.start..parameter.loc.end];
                    break;
                }
            }
            break;
        }
        parameter_index += 1;
        segment_start = index + 1;
    }
    const buffer_name = buffer_parameter orelse return false;
    const body_start = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse return false;
    const body_end = scope_index.matchingToken(body_start) orelse return false;
    for (tokens[body_start + 1 .. body_end], body_start + 1..) |token, method_index| {
        if (token.tag != .identifier or method_index + 1 >= body_end or tokens[method_index + 1].tag != .l_paren) continue;
        const method = source[token.loc.start..token.loc.end];
        if (!std.mem.eql(u8, method, "destroy") and !std.mem.eql(u8, method, "free") and
            !std.mem.eql(u8, method, "deinit") and !std.mem.eql(u8, method, "release")) continue;
        const cleanup_end = scope_index.matchingToken(method_index + 1) orelse continue;
        for (tokens[method_index + 2 .. @min(cleanup_end, body_end)]) |argument| {
            if (tokenIsIdentifier(source, argument, buffer_name)) return true;
        }
    }
    return false;
}

fn bindingArgumentIndex(
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
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
        if (containsBinding(scope_index, binding_name, binding_index, segment_start, index)) return argument_index;
        argument_index += 1;
        segment_start = index + 1;
    }
    return null;
}

fn conventionalBorrowingCall(callable: []const u8, argument_index: usize, argument_count: usize) bool {
    const separator = std.mem.findScalarLast(u8, callable, '.');
    const method = if (separator) |index| callable[index + 1 ..] else callable;
    const methods = [_][]const u8{ "appendSlice", "writeAll", "writeStreamingAll", "print" };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return argument_index + 1 == argument_count;
    if (std.mem.eql(u8, method, "write")) {
        if (argument_count >= 6) return argument_index == 2;
        return argument_index + 1 == argument_count;
    }
    const slice_iterators = [_][]const u8{
        "splitAny",
        "splitBackwardsAny",
        "splitBackwardsScalar",
        "splitBackwardsSequence",
        "splitScalar",
        "splitSequence",
        "tokenizeAny",
        "tokenizeScalar",
        "tokenizeSequence",
        "window",
    };
    for (slice_iterators) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return argument_index == 1;
    }
    return false;
}

fn callArgumentCount(tokens: []const std.zig.Token, start: usize, end: usize) usize {
    if (start >= end) return 0;
    var count: usize = 1;
    var depth: usize = 0;
    for (tokens[start..end]) |token| switch (token.tag) {
        .l_paren, .l_bracket, .l_brace => depth += 1,
        .r_paren, .r_bracket, .r_brace => depth -|= 1,
        .comma => if (depth == 0) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn bareBindingArgumentIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) ?usize {
    var argument_index: usize = 0;
    var segment_start = start;
    var parenthesis_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    for (tokens[start..end], start..) |token, index| {
        const segment_end = token.tag == .comma and parenthesis_depth == 0 and
            bracket_depth == 0 and brace_depth == 0;
        if (segment_end) {
            if (index == segment_start + 1 and tokenRefersToBinding(source, tokens, segment_start, binding_name) and
                identifierRefersToBinding(scope_index, binding_index, segment_start)) return argument_index;
            argument_index += 1;
            segment_start = index + 1;
            continue;
        }
        switch (token.tag) {
            .l_paren => parenthesis_depth += 1,
            .r_paren => parenthesis_depth -|= 1,
            .l_bracket => bracket_depth += 1,
            .r_bracket => bracket_depth -|= 1,
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            else => {},
        }
    }
    if (end == segment_start + 1 and tokenRefersToBinding(source, tokens, segment_start, binding_name) and
        identifierRefersToBinding(scope_index, binding_index, segment_start)) return argument_index;
    return null;
}

fn assignmentDiscards(
    source: []const u8,
    tokens: []const std.zig.Token,
    range_start: usize,
    equal_index: usize,
) bool {
    var start = equal_index;
    while (start > range_start) {
        const previous = tokens[start - 1].tag;
        if (previous == .semicolon or previous == .l_brace or previous == .r_brace) break;
        start -= 1;
    }
    return equal_index == start + 1 and tokenIsIdentifier(source, tokens[start], "_");
}

pub fn identifierRefersToBinding(
    scope_index: *const syntax_scope.Index,
    binding_index: usize,
    use_index: usize,
) bool {
    const binding = scope_index.findBinding(use_index) orelse return false;
    return binding.token_index == binding_index;
}

pub fn statementStartsWithErrdefer(tokens: []const std.zig.Token, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .keyword_errdefer => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

/// Whether a returned or break value in `[start, end)` hands the binding on:
/// it names the binding other than through its length or an element read, as
/// in `return copy.len;`. An element's address, `&bytes[0]`, still points into it.
pub fn valueTransfersBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    if (!callOnlyUsesScalarProjections(source, tokens, scope_index, binding_name, binding_index, start, end)) {
        return containsBinding(scope_index, binding_name, binding_index, start, end);
    }
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (index > start and tokens[index - 1].tag == .ampersand and
            identifierRefersToBinding(scope_index, binding_index, index)) return true;
    }
    return false;
}

pub fn releaseCallContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    method_index: usize,
    end: usize,
) bool {
    if (method_index == 0 or method_index + 1 >= end or tokens[method_index - 1].tag != .period or
        tokens[method_index + 1].tag != .l_paren) return false;
    const closing = scope_index.matchingToken(method_index + 1) orelse return false;
    if (closing >= end) return false;
    const receiver_is_binding = method_index >= 2 and
        tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
        identifierRefersToBinding(scope_index, binding_index, method_index - 2);
    return receiver_is_binding or releaseArgumentContainsBinding(
        source,
        tokens,
        scope_index,
        binding_name,
        binding_index,
        lastCallArgumentStart(tokens, method_index + 1, closing),
        closing,
    );
}

fn lastCallArgumentStart(tokens: []const std.zig.Token, opening: usize, closing: usize) usize {
    var parentheses: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    var start = opening + 1;
    for (tokens[opening + 1 .. closing], opening + 1..) |token, index| switch (token.tag) {
        .l_paren => parentheses += 1,
        .r_paren => parentheses -|= 1,
        .l_bracket => brackets += 1,
        .r_bracket => brackets -|= 1,
        .l_brace => braces += 1,
        .r_brace => braces -|= 1,
        .comma => if (parentheses == 0 and brackets == 0 and braces == 0) {
            start = index + 1;
        },
        else => {},
    };
    return start;
}

fn releaseArgumentContainsBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    start: usize,
    end: usize,
) bool {
    var uses = scope_index.identifiersNamed(binding_name, start, end);
    while (uses.next()) |index| {
        if (!tokenRefersToBinding(source, tokens, index, binding_name) or
            !identifierRefersToBinding(scope_index, binding_index, index)) continue;
        if (index > start and tokens[index - 1].tag == .period) continue;
        if (index + 1 < end and tokens[index + 1].tag == .period) continue;
        if (index + 1 < end and tokens[index + 1].tag == .l_bracket and
            !sliceCoversAllocation(source, tokens, scope_index, binding_name, binding_index, index + 1)) continue;
        return true;
    }
    return false;
}

/// Whether the slice opening at `opening`, applied to the binding, covers its
/// whole allocation: `[0..]`, `[0..name.len]`, or `[0..n]` over `alloc(T, n)`.
/// A sentinel allocation keeps its length only through `[0..]`.
fn sliceCoversAllocation(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    opening: usize,
) bool {
    const closing = scope_index.matchingToken(opening) orelse return false;
    if (opening + 3 > closing or tokens[opening + 1].tag != .number_literal or
        !std.mem.eql(u8, source[tokens[opening + 1].loc.start..tokens[opening + 1].loc.end], "0") or
        tokens[opening + 2].tag != .ellipsis2) return false;
    const length_start = opening + 3;
    if (length_start == closing) return true;
    const declaration_end = scope_index.statementEnd(binding_index) orelse return false;
    var sentinel = false;
    var allocated_length: ?TokenRange = null;
    for (tokens[binding_index + 1 .. declaration_end], binding_index + 1..) |token, method_index| {
        if (token.tag != .identifier or tokens[method_index - 1].tag != .period or
            method_index + 1 >= declaration_end or tokens[method_index + 1].tag != .l_paren) continue;
        const method = source[token.loc.start..token.loc.end];
        if (resources.allocationRelease(method) == null) continue;
        sentinel = std.mem.find(u8, method, "Sentinel") != null or method[method.len - 1] == 'Z';
        const call_end = scope_index.matchingToken(method_index + 1) orelse return false;
        for (resources.sized_allocations) |sized| {
            if (sized.length_from_end != 1 or !std.mem.eql(u8, sized.method, method)) continue;
            allocated_length = .{ .start = lastCallArgumentStart(tokens, method_index + 1, call_end), .end = call_end };
        }
        break;
    }
    if (sentinel) return false;
    if (length_start + 3 == closing and tokenIsIdentifier(source, tokens[length_start], binding_name) and
        tokens[length_start + 1].tag == .period and tokenIsIdentifier(source, tokens[length_start + 2], "len")) return true;
    const length = allocated_length orelse return false;
    if (length.end - length.start != closing - length_start) return false;
    for (tokens[length.start..length.end], tokens[length_start..closing]) |expected, actual| {
        if (expected.tag != actual.tag or
            !std.mem.eql(u8, source[expected.loc.start..expected.loc.end], source[actual.loc.start..actual.loc.end])) return false;
    }
    return true;
}

pub fn releaseUsesAllocationReceiver(
    source: []const u8,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    binding_name: []const u8,
    binding_index: usize,
    method_index: usize,
    allocation_receiver: ?[]const u8,
) bool {
    if (method_index < 2 or tokens[method_index - 2].tag != .identifier) return allocation_receiver == null;
    if (tokenIsIdentifier(source, tokens[method_index - 2], binding_name) and
        identifierRefersToBinding(scope_index, binding_index, method_index - 2)) return true;
    const expected_receiver = allocation_receiver orelse return true;
    return tokenIsIdentifier(source, tokens[method_index - 2], expected_receiver);
}

pub fn tokenIsIdentifier(source: []const u8, token: std.zig.Token, name: []const u8) bool {
    return token.tag == .identifier and std.mem.eql(u8, source[token.loc.start..token.loc.end], name);
}

const Scope = struct {
    opening: usize,
    closing: usize,
};

pub fn enclosingScope(scope_index: *const syntax_scope.Index, index: usize) ?Scope {
    const opening = scope_index.enclosingOpeningBrace(index) orelse return null;
    return .{ .opening = opening, .closing = scope_index.matchingToken(opening) orelse return null };
}
