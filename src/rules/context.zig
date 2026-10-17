const std = @import("std");
const syntax_scope = @import("../syntax/scope.zig");
const tokens_util = @import("../syntax/tokens.zig");
const types = @import("types.zig");

/// Token positions of a function with a body.
pub const FunctionRange = struct {
    parameters_start: usize,
    parameters_end: usize,
    body_start: usize,
    body_end: usize,
};

pub const RuleRun = struct {
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    configuration: types.Configuration,
    findings: *std.ArrayList(types.Finding),
    /// Parsed once per analysis; the tree may carry parse errors.
    tree: *const std.zig.Ast,
    /// Scope index over `tokens`, built once per analysis like `tree`.
    scopes: *const syntax_scope.Index,
    /// Shapes the compiler resolved for names the source does not declare.
    resolved_shapes: []const types.ResolvedShape = &.{},
    /// Members the file's top-level imports expose, resolved by the caller.
    module_members: []const types.ModuleMembers = &.{},
    /// What of the file the project's module roots expose, resolved by the caller.
    module_exposure: types.ModuleExposure = .whole,

    pub fn level(context: RuleRun, rule: types.Rule) types.Level {
        return context.configuration.level(rule);
    }

    /// Records the finding unless its level is off. Suppression directives are
    /// applied once over all findings by the pipeline driver.
    pub fn emit(context: RuleRun, finding: types.Finding) !void {
        if (finding.level == .off) return;
        try context.findings.append(context.allocator, finding);
    }

    /// A fix list holding one fix with one edit.
    pub fn singleFix(context: RuleRun, spec: types.Fix.Single) ![]const types.Fix {
        return types.Fix.single(context.allocator, spec);
    }

    pub fn tokenText(context: RuleRun, index: usize) []const u8 {
        return tokens_util.tokenText(context.source, context.tokens[index]);
    }

    pub fn tokenIs(context: RuleRun, index: usize, expected: []const u8) bool {
        return index < context.tokens.len and tokens_util.tokenIs(context.source, context.tokens[index], expected);
    }

    pub fn refersToBinding(context: RuleRun, index: usize, name: []const u8) bool {
        return tokenRefersToBinding(context.source, context.tokens, index, name);
    }

    pub fn matchingToken(
        context: RuleRun,
        opening_index: usize,
        opening_tag: std.zig.Token.Tag,
        closing_tag: std.zig.Token.Tag,
    ) ?usize {
        std.debug.assert(context.tokens[opening_index].tag == opening_tag);
        const closing = context.scopes.matchingToken(opening_index) orelse return null;
        std.debug.assert(context.tokens[closing].tag == closing_tag);
        return closing;
    }

    pub fn statementEnd(context: RuleRun, start: usize) ?usize {
        return context.scopes.statementEnd(start);
    }

    pub fn statementStart(context: RuleRun, index: usize) usize {
        return context.scopes.statementStart(index);
    }

    /// Whether a `//` comment explains the code from token `first_index` to
    /// token `last_index`: one on the line where `last_index` ends, or a
    /// comment-only line directly above the line where `first_index` starts.
    pub fn explainedByComment(context: RuleRun, first_index: usize, last_index: usize) bool {
        const source = context.source;
        const last = context.tokens[last_index].loc;
        const last_line = source[tokens_util.lineStart(source, last.start)..tokens_util.lineEnd(source, last.end)];
        if (tokens_util.commentStart(last_line)) |comment| {
            if (commentGivesReason(last_line[comment..])) return true;
        }
        const first_line_start = tokens_util.lineStart(source, context.tokens[first_index].loc.start);
        if (first_line_start == 0) return false;
        const previous_line = std.mem.trim(u8, source[tokens_util.lineStart(source, first_line_start - 1)..first_line_start], " \t\r\n");
        return std.mem.startsWith(u8, previous_line, "//") and commentGivesReason(previous_line);
    }

    /// Whether the expression starting at `start` is evaluated at compile
    /// time: it initializes a container-level declaration, or `comptime`
    /// marks it, its statement or a block around it.
    pub fn comptimeEvaluated(context: RuleRun, start: usize) bool {
        const tokens = context.tokens;
        if (start > 0 and tokens[start - 1].tag == .keyword_comptime) return true;
        if (tokens[context.statementStart(start)].tag == .keyword_comptime) return true;
        var brace = context.enclosingOpeningBrace(start);
        while (brace) |opening| : (brace = context.enclosingOpeningBrace(opening)) {
            if (opening > 0 and tokens[opening - 1].tag == .keyword_comptime) return true;
            switch (context.scopes.braceKind(opening)) {
                .function => return false,
                .container => return true,
                .block => {},
            }
        }
        return true;
    }

    /// Opening brace of the innermost function or test body holding `index`,
    /// or null when a container declaration holds it more closely.
    pub fn functionBodyHolding(context: RuleRun, index: usize) ?usize {
        return context.scopes.functionOrTestBodyHolding(index);
    }

    /// Whether the call from `start` to its argument list at `opening` passes
    /// only compile-time-known arguments (literals, enum literals, primitive
    /// types, container-level constants) to a free function or a function of
    /// a container-level constant, so it gives the same result on every run.
    pub fn comptimeKnownCall(context: RuleRun, start: usize, opening: usize) bool {
        const closing = context.scopes.matchingToken(opening) orelse return false;
        if (closing == opening + 1 or !context.dottedPathsEqual(start, opening, start, opening)) return false;
        if (start + 1 != opening and !context.containerConstant(start)) return false;
        var argument = opening + 1;
        while (argument < closing) {
            const end = context.topLevelComma(argument, closing) orelse closing;
            if (!context.comptimeKnownArgument(argument, end)) return false;
            argument = end + 1;
        }
        return true;
    }

    fn comptimeKnownArgument(context: RuleRun, start: usize, end: usize) bool {
        const tokens = context.tokens;
        if (end == start + 2) return tokens[start].tag == .period and tokens[start + 1].tag == .identifier or
            tokens[start].tag == .minus and tokens[start + 1].tag == .number_literal;
        if (end != start + 1) {
            for (tokens[start..end]) |token| if (token.tag != .multiline_string_literal_line) return false;
            return end > start;
        }
        return switch (tokens[start].tag) {
            .number_literal, .string_literal, .char_literal, .multiline_string_literal_line => true,
            .identifier => std.zig.isPrimitive(context.tokenText(start)) or context.containerConstant(start),
            else => false,
        };
    }

    /// The one error the call before the `catch` at `catch_index` can fail
    /// with, when its error set is known: `Overflow` for checked `std.math`
    /// arithmetic, `OutOfMemory` for allocations, `NoSpaceLeft` for
    /// `bufPrint`, `WriteFailed` for a `*std.Io.Writer` method, and the error
    /// of a function this file declares with a one-error set
    /// (`Allocator.Error`, `Writer.Error`, `error{Name}` or an alias of one).
    pub fn operandOnlyError(context: RuleRun, catch_index: usize) ?[]const u8 {
        const tokens = context.tokens;
        if (catch_index == 0 or tokens[catch_index - 1].tag != .r_paren) return null;
        const opening = context.scopes.matchingToken(catch_index - 1) orelse return null;
        const start = tokens_util.callExpressionStart(tokens, opening) orelse return null;
        const callee = context.tokenText(opening - 1);
        if (opening >= start + 3) {
            if (context.tokenIs(opening - 3, "math")) {
                const checked_arithmetic = [_][]const u8{ "add", "sub", "mul", "negate", "shlExact" };
                for (checked_arithmetic) |name| if (std.mem.eql(u8, callee, name)) return "Overflow";
                return null;
            }
            const allocating = [_][]const u8{
                "alloc",              "alignedAlloc", "allocSentinel", "allocWithOptions", "create",
                "dupe",               "dupeZ",        "dupeSentinel",  "realloc",          "allocPrint",
                "allocPrintSentinel",
            };
            for (allocating) |name| if (std.mem.eql(u8, callee, name)) return "OutOfMemory";
            if (std.mem.eql(u8, callee, "print") and std.mem.find(u8, context.tokenText(opening - 3), "allocator") != null) return "OutOfMemory";
            if (std.mem.eql(u8, callee, "bufPrint") or std.mem.eql(u8, callee, "bufPrintZ")) return "NoSpaceLeft";
            if (writerMethod(callee) and context.receiverIsWriter(start, opening - 2)) return "WriteFailed";
        }
        // A call through `self` or no receiver names a declaration of this file.
        if (opening != start + 1 and (opening != start + 3 or !context.tokenIs(start, "self"))) return null;
        const binding = context.scopes.findBindingNamed(callee, opening - 1) orelse return null;
        if (binding.token_index == 0 or tokens[binding.token_index - 1].tag != .keyword_fn) return null;
        return context.declaredSingleError(binding.token_index - 1);
    }

    /// Whether the receiver path from `start` to the `.` at `period` is a
    /// `*std.Io.Writer`: an `Allocating` writer's `writer` or a file writer's
    /// `interface` field, or a binding declared with a `Writer` type or set to
    /// the address of one of those fields.
    fn receiverIsWriter(context: RuleRun, start: usize, period: usize) bool {
        const tokens = context.tokens;
        const last = period - 1;
        if (last > start) return context.tokenIs(last, "writer") or context.tokenIs(last, "interface");
        const binding = context.scopes.findBinding(start) orelse return false;
        const name = binding.token_index;
        if (name + 3 >= tokens.len) return false;
        if (tokens[name + 1].tag == .colon) {
            var type_name: ?usize = null;
            for (tokens[name + 2 ..], name + 2..) |token, index| switch (token.tag) {
                .identifier => type_name = index,
                .period, .asterisk, .keyword_const => {},
                else => break,
            };
            return if (type_name) |index| context.tokenIs(index, "Writer") else false;
        }
        if (tokens[name + 1].tag != .equal or tokens[name + 2].tag != .ampersand or tokens[name + 3].tag != .identifier) return false;
        var field = name + 3;
        while (field + 2 < tokens.len and tokens[field + 1].tag == .period and tokens[field + 2].tag == .identifier) field += 2;
        return field > name + 3 and tokens[field + 1].tag == .semicolon and
            (context.tokenIs(field, "writer") or context.tokenIs(field, "interface"));
    }

    /// The one error a function's declared return error set holds.
    fn declaredSingleError(context: RuleRun, fn_index: usize) ?[]const u8 {
        const tokens = context.tokens;
        const parameters_end = context.matchingToken(fn_index + 2, .l_paren, .r_paren) orelse return null;
        var bang = parameters_end + 1;
        while (bang < tokens.len and bang < parameters_end + 16 and tokens[bang].tag != .bang) : (bang += 1) {
            switch (tokens[bang].tag) {
                .keyword_error => if (bang + 1 < tokens.len and tokens[bang + 1].tag == .l_brace) {
                    bang = context.matchingToken(bang + 1, .l_brace, .r_brace) orelse return null;
                },
                .l_brace, .semicolon => return null,
                else => {},
            }
        }
        if (bang >= tokens.len or tokens[bang].tag != .bang) return null;
        return context.singleErrorOf(parameters_end + 1, bang, 0);
    }

    fn singleErrorOf(context: RuleRun, start: usize, end: usize, depth: u8) ?[]const u8 {
        const tokens = context.tokens;
        if (end == start + 4 and tokens[start].tag == .keyword_error and tokens[start + 1].tag == .l_brace and
            tokens[start + 2].tag == .identifier and tokens[start + 3].tag == .r_brace) return context.tokenText(start + 2);
        if (end >= start + 3 and context.tokenIs(end - 1, "Error") and tokens[end - 2].tag == .period) {
            if (context.tokenIs(end - 3, "Allocator")) return "OutOfMemory";
            if (context.tokenIs(end - 3, "Writer")) return "WriteFailed";
        }
        if (end != start + 1 or tokens[start].tag != .identifier or depth > 2) return null;
        const binding = context.scopes.findBinding(start) orelse return null;
        const name = binding.token_index;
        if (name + 2 >= tokens.len or tokens[name - 1].tag != .keyword_const or tokens[name + 1].tag != .equal) return null;
        const value_end = context.statementEnd(name + 2) orelse return null;
        return context.singleErrorOf(name + 2, value_end, depth + 1);
    }

    /// Whether the identifier at `index` names a `const` declared outside
    /// every function body, whose value is known at compile time.
    pub fn containerConstant(context: RuleRun, index: usize) bool {
        if (index > 0 and context.tokens[index - 1].tag == .period) return false;
        const binding = context.scopes.findBinding(index) orelse return false;
        const name = binding.token_index;
        if (name == 0 or context.tokens[name - 1].tag != .keyword_const) return false;
        if (name >= 2 and context.tokens[name - 2].tag == .keyword_extern) return false;
        return context.functionBodyHolding(name) == null;
    }

    pub fn enclosingOpeningBrace(context: RuleRun, index: usize) ?usize {
        return context.scopes.enclosingOpeningBrace(index);
    }

    pub fn enclosingScopeEnd(context: RuleRun, index: usize) ?usize {
        return context.scopes.enclosingScopeEnd(index);
    }

    pub fn fallibleOperationBetween(context: RuleRun, start: usize, end: usize, scope_opening: usize) bool {
        return context.scopes.fallibleOperationBetween(start, end, scope_opening);
    }

    /// Whether the statement starting at `start` never completes: `return`,
    /// `break`, `continue`, `unreachable`, `@panic`, `@compileError`, `@trap`,
    /// or a lone call of `std.process.exit`, `std.posix.exit`/`abort`,
    /// `std.debug.panic*` or a `noreturn` function this file declares.
    pub fn statementDiverges(context: RuleRun, start: usize) bool {
        const tokens = context.tokens;
        switch (tokens[start].tag) {
            .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable => return true,
            .builtin => return context.tokenIs(start, "@panic") or context.tokenIs(start, "@compileError") or
                context.tokenIs(start, "@trap"),
            .identifier => {},
            else => return false,
        }
        var callee = start;
        while (callee + 2 < tokens.len and tokens[callee + 1].tag == .period and tokens[callee + 2].tag == .identifier) callee += 2;
        if (callee + 1 >= tokens.len or tokens[callee + 1].tag != .l_paren) return false;
        const closing = context.scopes.matchingToken(callee + 1) orelse return false;
        if (closing + 1 >= tokens.len or tokens[closing + 1].tag != .semicolon) return false;
        if (callee == start) {
            const declaration = (context.scopes.findBinding(callee) orelse return false).token_index;
            if (declaration == 0 or tokens[declaration - 1].tag != .keyword_fn or
                declaration + 1 >= tokens.len or tokens[declaration + 1].tag != .l_paren) return false;
            const parameters_end = context.scopes.matchingToken(declaration + 1) orelse return false;
            return context.tokenIs(parameters_end + 1, "noreturn");
        }
        const name = context.tokenText(callee);
        const exits = std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "abort");
        if (exits and (context.tokenIs(callee - 2, "process") or context.tokenIs(callee - 2, "posix"))) return true;
        return context.tokenIs(callee - 2, "debug") and std.mem.startsWith(u8, name, "panic");
    }

    /// First comma in `[start, end)` that is not nested in brackets; the
    /// groups before it are skipped through the scope index.
    pub fn topLevelComma(context: RuleRun, start: usize, end: usize) ?usize {
        var cursor = start;
        while (cursor < end) : (cursor += 1) {
            switch (context.tokens[cursor].tag) {
                .l_paren, .l_bracket, .l_brace => cursor = context.scopes.matchingToken(cursor) orelse return null,
                .comma => return cursor,
                else => {},
            }
        }
        return null;
    }

    pub fn threeArguments(context: RuleRun, opening: usize, closing: usize) ?[3]tokens_util.Range {
        return tokens_util.threeArguments(context.tokens, opening, closing);
    }

    /// Whether a reference to `name` in `[start, end)` assigns it, a field or
    /// element of it, or takes its address. A redeclaration of the name ends
    /// the search through its scope.
    pub fn bindingMutatedAfter(context: RuleRun, start: usize, end: usize, name: []const u8) bool {
        var index = start;
        while (index < @min(end, context.tokens.len)) : (index += 1) {
            if (!context.refersToBinding(index, name)) continue;
            if (index > 0 and (context.tokens[index - 1].tag == .keyword_const or context.tokens[index - 1].tag == .keyword_var)) {
                index = context.enclosingScopeEnd(index) orelse index;
                continue;
            }
            if (context.isLvalueMutation(index)) return true;
        }
        return false;
    }

    fn isLvalueMutation(context: RuleRun, index: usize) bool {
        if (index > 0 and context.tokens[index - 1].tag == .ampersand) return true;
        var cursor = index + 1;
        while (cursor < context.tokens.len) {
            if (context.tokens[cursor].tag == .period) {
                cursor += 1;
                if (cursor < context.tokens.len and (context.tokens[cursor].tag == .identifier or context.tokens[cursor].tag == .asterisk)) {
                    cursor += 1;
                    continue;
                }
                return false;
            } else if (context.tokens[cursor].tag == .l_bracket) {
                cursor = (context.matchingToken(cursor, .l_bracket, .r_bracket) orelse return false) + 1;
                continue;
            }
            break;
        }
        return cursor < context.tokens.len and tokens_util.isAssignment(context.tokens[cursor].tag);
    }

    /// Declared-name token of the parameter or local of the function enclosing
    /// `index` that the identifier at `index` refers to.
    pub fn localDeclaration(context: RuleRun, index: usize) ?usize {
        if (index > 0 and context.tokens[index - 1].tag == .period) return null;
        const binding = context.scopes.findBinding(index) orelse return null;
        const body = context.scopes.enclosingFunctionBody(index) orelse return null;
        const body_end = context.scopes.matchingToken(body) orelse return null;
        const declaration = binding.token_index;
        if (declaration > body) return if (declaration < body_end) declaration else null;
        // Otherwise only a parameter of this function, whose scope is its body.
        const parameter = switch (context.tokens[declaration - 1].tag) {
            .l_paren, .comma, .keyword_comptime, .keyword_noalias => true,
            else => false,
        };
        return if (parameter and binding.scope.end == context.tokens[body_end].loc.end) declaration else null;
    }

    /// Type tokens of `name: T` after the declared name at `declaration`, up
    /// to the `,` or `)` ending a parameter or the `=` or `;` of a declaration.
    pub fn annotatedType(context: RuleRun, declaration: usize) ?tokens_util.Range {
        const tokens = context.tokens;
        if (tokens[declaration + 1].tag != .colon) return null;
        const start = declaration + 2;
        var depth: usize = 0;
        for (tokens[start..], start..) |token, index| switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => {
                if (depth == 0) return if (index > start) .{ .start = start, .end = index } else null;
                depth -= 1;
            },
            .comma, .equal, .semicolon => if (depth == 0) return if (index > start) .{ .start = start, .end = index } else null,
            .eof => return null,
            else => {},
        };
        return null;
    }

    /// Whether `std` at `index` names `const std = @import("std");`, so a fix
    /// can spell `std.mem` there.
    pub fn standardLibraryVisible(context: RuleRun, index: usize) bool {
        const binding = context.scopes.findBindingNamed("std", index) orelse return false;
        const name = binding.token_index;
        return name + 6 < context.tokens.len and context.tokens[name + 1].tag == .equal and
            context.tokenIs(name + 2, "@import") and context.tokens[name + 3].tag == .l_paren and
            context.tokenIs(name + 4, "\"std\"") and context.tokens[name + 5].tag == .r_paren and
            context.tokens[name + 6].tag == .semicolon;
    }

    /// Whether an identifier spelled `name` occurs in `[start, end)`.
    pub fn rangeContainsName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, name)) return true;
        }
        return false;
    }

    /// Whether a `const` or `var` in `[start, end)` declares `name`, for
    /// example one that shadows an outer binding.
    pub fn rangeDeclaresName(context: RuleRun, name: []const u8, start: usize, end: usize) bool {
        for (context.tokens[start..end], start..) |token, index| {
            if ((token.tag == .keyword_const or token.tag == .keyword_var) and
                index + 1 < end and context.tokenIs(index + 1, name)) return true;
        }
        return false;
    }

    /// First identifier spelled `name` in `[start, end)`.
    pub fn findIdentifier(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
        for (context.tokens[start..end], start..) |token, index| {
            if (token.tag == .identifier and context.tokenIs(index, name)) return index;
        }
        return null;
    }

    /// Parameter, body, and bracket positions of the function whose `fn` token
    /// is `function_index`; null for declarations without a body.
    pub fn functionRange(context: RuleRun, function_index: usize) ?FunctionRange {
        var parameters_start = function_index + 1;
        while (parameters_start < context.tokens.len and context.tokens[parameters_start].tag != .l_paren) : (parameters_start += 1) {}
        if (parameters_start >= context.tokens.len) return null;
        const parameters_end = context.matchingToken(parameters_start, .l_paren, .r_paren) orelse return null;
        var body_start = parameters_end + 1;
        while (body_start < context.tokens.len and context.tokens[body_start].tag != .l_brace and
            context.tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start >= context.tokens.len or context.tokens[body_start].tag != .l_brace) return null;
        const body_end = context.matchingToken(body_start, .l_brace, .r_brace) orelse return null;
        return .{ .parameters_start = parameters_start, .parameters_end = parameters_end, .body_start = body_start, .body_end = body_end };
    }

    /// Whether the parameter `parameter_name` in `(start, end)` is declared
    /// with a type whose spelling contains the identifiers of `type_path` in order.
    pub fn parameterNamesTypePath(
        context: RuleRun,
        parameter_name: []const u8,
        type_path: []const []const u8,
        start: usize,
        end: usize,
    ) bool {
        for (context.tokens[start + 1 .. end], start + 1..) |token, name_index| {
            if (token.tag != .identifier or !context.tokenIs(name_index, parameter_name) or
                name_index + 1 >= end or context.tokens[name_index + 1].tag != .colon) continue;
            var segment_end = name_index + 2;
            while (segment_end < end and context.tokens[segment_end].tag != .comma) : (segment_end += 1) {}
            var matched: usize = 0;
            for (context.tokens[name_index + 2 .. segment_end], name_index + 2..) |type_token, index| {
                if (type_token.tag != .identifier or matched >= type_path.len or !context.tokenIs(index, type_path[matched])) continue;
                matched += 1;
            }
            return matched == type_path.len;
        }
        return false;
    }

    /// Whether the token is the `fn` of a named function declaration.
    pub fn isNamedFunction(context: RuleRun, fn_index: usize) bool {
        return context.tokens[fn_index].tag == .keyword_fn and fn_index + 2 < context.tokens.len and
            context.tokens[fn_index + 1].tag == .identifier and context.tokens[fn_index + 2].tag == .l_paren;
    }

    /// Start of the dotted identifier path that ends right before `end`.
    pub fn pathStartBefore(context: RuleRun, end: usize) ?usize {
        var start = end;
        var expect_identifier = true;
        while (start > 0) {
            const previous = context.tokens[start - 1];
            if (expect_identifier and previous.tag == .identifier) {
                start -= 1;
                expect_identifier = false;
            } else if (!expect_identifier and previous.tag == .period) {
                start -= 1;
                expect_identifier = true;
            } else break;
        }
        return if (expect_identifier) null else start;
    }

    /// Whether two token ranges spell the same dotted identifier path.
    pub fn dottedPathsEqual(context: RuleRun, left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
        if (left_end - left_start != right_end - right_start or left_start >= left_end) return false;
        for (context.tokens[left_start..left_end], context.tokens[right_start..right_end], 0..) |left, right, offset| {
            const expected: std.zig.Token.Tag = if (offset % 2 == 0) .identifier else .period;
            if (left.tag != expected or right.tag != expected or
                !std.mem.eql(u8, context.source[left.loc.start..left.loc.end], context.source[right.loc.start..right.loc.end])) return false;
        }
        return (left_end - left_start) % 2 == 1;
    }

    /// The `{` opening a `while` body whose condition closes at `condition_end`,
    /// after any payload capture and continue expression.
    pub fn whileBodyOpening(context: RuleRun, condition_end: usize) ?usize {
        var cursor = condition_end + 1;
        if (cursor >= context.tokens.len) return null;
        if (context.tokens[cursor].tag == .pipe) {
            cursor = tokens_util.nextTagBefore(context.tokens, cursor + 1, .pipe, .semicolon) orelse return null;
            cursor += 1;
        }
        if (cursor < context.tokens.len and context.tokens[cursor].tag == .colon) {
            cursor += 1;
            if (cursor >= context.tokens.len or context.tokens[cursor].tag != .l_paren) return null;
            cursor = (context.matchingToken(cursor, .l_paren, .r_paren) orelse return null) + 1;
        }
        return if (cursor < context.tokens.len and context.tokens[cursor].tag == .l_brace) cursor else null;
    }

    /// Whether the identifier at `index` names an `std.Io` instance, by the
    /// usual spelling (`io`, `init.io`, `test_io`) or a declared `Io` type.
    pub fn namesIo(context: RuleRun, index: usize) bool {
        if (context.tokens[index].tag != .identifier) return false;
        const name = context.tokenText(index);
        if (std.mem.eql(u8, name, "io") or std.mem.endsWith(u8, name, "_io") or std.mem.startsWith(u8, name, "io_")) return true;
        if (index > 0 and context.tokens[index - 1].tag == .period) return false;
        const binding = context.scopes.findBinding(index) orelse return false;
        var type_start = binding.token_index + 2;
        if (type_start >= context.tokens.len or context.tokens[type_start - 1].tag != .colon) return false;
        if (context.tokenIs(type_start, "std") and context.tokens[type_start + 1].tag == .period) type_start += 2;
        return context.tokenIs(type_start, "Io") and context.tokens[type_start + 1].tag != .period;
    }

    /// The `while` or `for` keyword whose body the `{` at `opening` starts,
    /// looking back over any payload capture and continue expression.
    pub fn loopKeyword(context: RuleRun, opening: usize) ?usize {
        var cursor = opening;
        while (cursor > 0) switch (context.tokens[cursor - 1].tag) {
            .pipe => {
                cursor -= 1;
                while (cursor > 0 and context.tokens[cursor - 1].tag != .pipe) cursor -= 1;
                if (cursor == 0) return null;
                cursor -= 1;
            },
            .r_paren => {
                const condition = context.scopes.matchingToken(cursor - 1) orelse return null;
                if (condition == 0) return null;
                switch (context.tokens[condition - 1].tag) {
                    .colon => cursor = condition - 1,
                    .keyword_while, .keyword_for => return condition - 1,
                    else => return null,
                }
            },
            else => return null,
        };
        return null;
    }

    pub fn argumentSource(context: RuleRun, range: tokens_util.Range) []const u8 {
        return tokens_util.rangeSource(context.source, context.tokens, range);
    }

    /// Whether the `{` at `opening` starts a `struct`, `union`, `enum` or
    /// `opaque` body, including `union(enum) {` and `packed struct(u8) {`,
    /// rather than a block or an initializer.
    pub fn opensContainer(context: RuleRun, opening: usize) bool {
        const tokens = context.tokens;
        if (opening == 0) return false;
        var before = opening - 1;
        if (tokens[before].tag == .r_paren) {
            const group = context.scopes.matchingToken(before) orelse return false;
            if (group == 0) return false;
            before = group - 1;
        }
        return switch (tokens[before].tag) {
            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => true,
            else => false,
        };
    }

    /// The kind of number the expression `node` has, when its spelling proves
    /// it: a binding declared with a primitive number type, the index capture
    /// of a `for` range, a `.len`, or a size or bit-count builtin.
    pub fn numberKind(context: RuleRun, node: std.zig.Ast.Node.Index) ?tokens_util.NumberKind {
        const tree = context.tree;
        switch (tree.nodeTag(node)) {
            .grouped_expression => return context.numberKind(tree.nodeData(node).node_and_token[0]),
            .field_access => {
                const field = tree.nodeData(node).node_and_token[1];
                return if (std.mem.eql(u8, tree.tokenSlice(field), "len")) .unsigned else null;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const unsigned_builtins = [_][]const u8{ "@sizeOf", "@alignOf", "@bitSizeOf", "@intFromPtr", "@offsetOf", "@bitOffsetOf", "@popCount", "@clz", "@ctz" };
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                for (unsigned_builtins) |builtin| if (std.mem.eql(u8, name, builtin)) return .unsigned;
                return null;
            },
            .identifier => {},
            else => return null,
        }
        const binding = context.scopes.findBinding(tree.nodeMainToken(node)) orelse return null;
        const declaration = binding.token_index;
        const tokens = context.tokens;
        if (tokens[declaration + 1].tag == .colon) {
            const type_index = declaration + 2;
            if (tokens[type_index].tag != .identifier) return null;
            switch (tokens[type_index + 1].tag) {
                .comma, .r_paren, .equal, .semicolon => {},
                else => return null,
            }
            return tokens_util.primitiveNumberKind(context.tokenText(type_index));
        }
        return if (context.isRangeIndexCapture(declaration)) .unsigned else null;
    }

    /// Whether the capture named at `capture` takes a `for` range input
    /// (`for (items, 0..) |item, index|`), which makes it a `usize`.
    fn isRangeIndexCapture(context: RuleRun, capture: usize) bool {
        const tokens = context.tokens;
        var position: usize = 0;
        var cursor = capture;
        while (cursor > 0 and tokens[cursor - 1].tag != .pipe) : (cursor -= 1) switch (tokens[cursor - 1].tag) {
            .comma => position += 1,
            .identifier, .asterisk => {},
            else => return false,
        };
        if (cursor < 2 or tokens[cursor - 2].tag != .r_paren) return false;
        const opening = context.scopes.matchingToken(cursor - 2) orelse return false;
        if (opening == 0 or tokens[opening - 1].tag != .keyword_for) return false;
        var input_start = opening + 1;
        while (position > 0) : (position -= 1) {
            input_start = (context.topLevelComma(input_start, cursor - 2) orelse return false) + 1;
        }
        const input_end = context.topLevelComma(input_start, cursor - 2) orelse cursor - 2;
        var index = input_start;
        while (index < input_end) : (index += 1) switch (tokens[index].tag) {
            .ellipsis2 => return true,
            .l_paren, .l_bracket, .l_brace => index = context.scopes.matchingToken(index) orelse return false,
            else => {},
        };
        return false;
    }
};

/// Parsed inputs of one source for building a `RuleRun`: the syntax tree and
/// scope index the pipeline driver shares between rules.
pub const Syntax = struct {
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    tree: std.zig.Ast,
    scopes: syntax_scope.Index,

    /// Borrows `tokens`, which must outlive the result.
    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8, tokens: []const std.zig.Token) !Syntax {
        var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
        errdefer tree.deinit(allocator);
        return .{
            .source = source,
            .tokens = tokens,
            .tree = tree,
            .scopes = try syntax_scope.Index.init(allocator, source, tokens),
        };
    }

    pub fn deinit(syntax: *Syntax, allocator: std.mem.Allocator) void {
        syntax.scopes.deinit();
        syntax.tree.deinit(allocator);
    }

    pub fn ruleRun(
        syntax: *const Syntax,
        allocator: std.mem.Allocator,
        configuration: types.Configuration,
        found: *std.ArrayList(types.Finding),
    ) RuleRun {
        return .{
            .allocator = allocator,
            .source = syntax.source,
            .tokens = syntax.tokens,
            .configuration = configuration,
            .findings = found,
            .tree = &syntax.tree,
            .scopes = &syntax.scopes,
        };
    }
};

/// Whether a `//` comment gives a reason rather than mark the case as
/// unhandled (`TODO`, `FIXME`, `XXX`) or direct a tool (`zig-analyzer:`,
/// `zig fmt:`, a golden-test `expect:` marker).
fn commentGivesReason(comment: []const u8) bool {
    const text = std.mem.trimStart(u8, comment, "/! \t");
    const markers = [_][]const u8{ "TODO", "FIXME", "XXX", "zig-analyzer:", "zig fmt:", "expect:" };
    for (markers) |marker| if (std.mem.startsWith(u8, text, marker)) return false;
    return std.mem.trim(u8, text, " \t\r\n").len != 0;
}

/// Whether `name` is a `std.Io.Writer` method whose only error is `WriteFailed`.
fn writerMethod(name: []const u8) bool {
    const methods = [_][]const u8{
        "write",              "writeAll",       "writeByte",    "writeBytePreserve", "writeVec",              "writeVecAll",
        "writeSplat",         "writeSplatAll",  "writeInt",     "writeStruct",       "writeSliceEndian",      "writeSliceSwap",
        "writeUleb128",       "writeSleb128",   "writeLeb128",  "print",             "printValue",            "printInt",
        "printAscii",         "printAsciiChar", "printHex",     "printFloat",        "printUnicodeCodepoint", "printStringEscaped",
        "printBase64",        "splatByte",      "splatByteAll", "splatBytes",        "splatBytesAll",         "alignBuffer",
        "alignBufferOptions", "flush",
    };
    for (methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

pub fn tokenRefersToBinding(
    source: []const u8,
    tokens: []const std.zig.Token,
    index: usize,
    name: []const u8,
) bool {
    const token = tokens[index];
    if (token.tag != .identifier or !std.mem.eql(u8, source[token.loc.start..token.loc.end], name)) return false;
    return index == 0 or tokens[index - 1].tag != .period;
}

const test_source: [:0]const u8 = "fn f(a: u8) u8 { if (a > 0) { return a; } return a; }";

const Fixture = struct {
    tokens: []const std.zig.Token,
    syntax: Syntax,
    found: std.ArrayList(types.Finding) = .empty,

    fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Fixture {
        const tokens = try tokens_util.tokenize(allocator, source);
        errdefer allocator.free(tokens);
        return .{ .tokens = tokens, .syntax = try Syntax.init(allocator, source, tokens) };
    }

    fn run(fixture: *Fixture, allocator: std.mem.Allocator) RuleRun {
        return fixture.syntax.ruleRun(allocator, types.Configuration.defaults(), &fixture.found);
    }
};

test "emit records findings and drops those whose level is off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    try context.emit(.{ .rule = .never_mutated_var, .level = .off, .span = .{ .start = 0, .end = 1 }, .message = "off" });
    try std.testing.expectEqual(@as(usize, 0), fixture.found.items.len);
    try context.emit(.{ .rule = .never_mutated_var, .level = .warning, .span = .{ .start = 0, .end = 1 }, .message = "on" });
    try std.testing.expectEqual(@as(usize, 1), fixture.found.items.len);
    try std.testing.expectEqualStrings("on", fixture.found.items[0].message);
}

test "level reads the configured level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    var context = fixture.run(arena.allocator());
    context.configuration.levels[@backingInt(types.Rule.never_mutated_var)] = .@"error";
    try std.testing.expectEqual(types.Level.@"error", context.level(.never_mutated_var));
}

test "single fixes carry one edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const fixes = try context.singleFix(.{
        .title = "Rename",
        .span = .{ .start = 3, .end = 4 },
        .replacement = "g",
        .preferred = true,
    });
    try std.testing.expectEqual(@as(usize, 1), fixes.len);
    try std.testing.expectEqual(@as(usize, 1), fixes[0].edits.len);
    try std.testing.expectEqualStrings("g", fixes[0].edits[0].replacement);
    try std.testing.expect(fixes[0].preferred and !fixes[0].fix_all);
}

test "token helpers read text and match delimiters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const tokens = context.tokens;
    try std.testing.expectEqualStrings("fn", context.tokenText(0));
    try std.testing.expect(context.tokenIs(1, "f"));
    try std.testing.expect(!context.tokenIs(1, "g"));
    try std.testing.expect(!context.tokenIs(tokens.len, "f"));
    // `(a: u8)` is tokens 2..6, the outer body brace opens at token 8.
    try std.testing.expectEqual(@as(?usize, 6), context.matchingToken(2, .l_paren, .r_paren));
    const body_open = 8;
    try std.testing.expectEqual(std.zig.Token.Tag.l_brace, tokens[body_open].tag);
    try std.testing.expectEqual(@as(?usize, tokens.len - 2), context.matchingToken(body_open, .l_brace, .r_brace));
}

test "statement and scope helpers find enclosing structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    const tokens = context.tokens;
    var inner_return: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .keyword_return) {
            inner_return = index;
            break;
        }
    }
    const semicolon = context.statementEnd(inner_return).?;
    try std.testing.expectEqual(std.zig.Token.Tag.semicolon, tokens[semicolon].tag);
    const opening = context.enclosingOpeningBrace(inner_return).?;
    try std.testing.expectEqual(std.zig.Token.Tag.l_brace, tokens[opening].tag);
    try std.testing.expectEqual(semicolon + 1, context.enclosingScopeEnd(inner_return).?);
    try std.testing.expectEqual(@as(?usize, null), context.enclosingOpeningBrace(0));
    try std.testing.expectEqual(@as(?usize, null), context.enclosingScopeEnd(0));
}

test "explainedByComment reads the last line and the comment line above the first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn f() void {\n" ++
        "    // Why the first call is safe.\n" ++
        "    first();\n" ++
        "    second(\n" ++
        "        1,\n" ++
        "    ); // Why the second is.\n" ++
        "    third(\"// not a comment\");\n" ++
        "}\n";
    var fixture = try Fixture.init(arena.allocator(), source);
    const context = fixture.run(arena.allocator());
    var calls: [3]usize = undefined;
    var count: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 2 or context.tokens[index + 1].tag != .l_paren) continue;
        calls[count] = index;
        count += 1;
    }
    try std.testing.expect(context.explainedByComment(calls[0], calls[0] + 2));
    try std.testing.expect(context.explainedByComment(calls[1], calls[1] + 4));
    // The line above ends a statement; only a comment-only line explains.
    try std.testing.expect(!context.explainedByComment(calls[2], calls[2] + 3));
}

test "comptime evaluation and compile-time-known calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const limit = 4;\n" ++
        "const top = parse(\"1\");\n" ++
        "fn run(text: []const u8) error{Busy}!void {\n" ++
        "    const local = 2;\n" ++
        "    _ = comptime parse(text);\n" ++
        "    comptime {\n" ++
        "        _ = parse(text);\n" ++
        "    }\n" ++
        "    _ = std.fmt.parseInt(u8, \"7\", limit);\n" ++
        "    _ = div(i32, -5, .floor);\n" ++
        "    _ = parse(text);\n" ++
        "    _ = div(i32, local, 3);\n" ++
        "    _ = std.Thread.getCpuCount();\n" ++
        "}\n";
    var fixture = try Fixture.init(arena.allocator(), source);
    const context = fixture.run(arena.allocator());
    var evaluated: std.ArrayList(bool) = .empty;
    var known: std.ArrayList(bool) = .empty;
    for (context.tokens, 0..) |token, opening| {
        if (token.tag != .l_paren or opening < 2 or context.tokens[opening - 1].tag != .identifier or
            context.tokens[opening - 2].tag == .keyword_fn) continue;
        const start = tokens_util.callExpressionStart(context.tokens, opening).?;
        try evaluated.append(arena.allocator(), context.comptimeEvaluated(start));
        try known.append(arena.allocator(), context.comptimeKnownCall(start, opening));
    }
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, false, false, false, false }, evaluated.items);
    try std.testing.expectEqualSlices(bool, &.{ true, false, false, true, true, false, false, false }, known.items);
}

test "refersToBinding skips member names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), "const x = x + y.x;");
    const context = fixture.run(arena.allocator());
    try std.testing.expect(context.refersToBinding(3, "x"));
    try std.testing.expect(!context.refersToBinding(3, "y"));
    try std.testing.expect(!context.refersToBinding(7, "x"));
}

test "namesIo accepts the usual spellings and declared Io types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), "fn f(init: Init, loop: std.Io, other: Io, count: u8) void { _ = .{ init.io, loop, other, count }; }");
    const context = fixture.run(arena.allocator());
    // The identifiers inside the tuple, which starts at token 27.
    var named: [4]bool = undefined;
    var count: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or index < 27 or count == named.len) continue;
        if (context.tokens[index + 1].tag == .period) continue;
        named[count] = context.namesIo(index);
        count += 1;
    }
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, &named);
}

test "loopKeyword finds the loop a body brace belongs to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), "fn f(it: anytype) void { var i: u8 = 0; while (it.next()) |x| : (i += 1) { _ = x; } if (i > 0) { for (0..2) |_| {} } }");
    const context = fixture.run(arena.allocator());
    // The braces after the function body: the while body, the if block and the for body.
    var found: [3]?usize = undefined;
    var count: usize = 0;
    var body_seen = false;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .l_brace) continue;
        if (!body_seen) {
            body_seen = true;
            continue;
        }
        found[count] = context.loopKeyword(index);
        count += 1;
        if (count == found.len) break;
    }
    try std.testing.expectEqual(std.zig.Token.Tag.keyword_while, context.tokens[found[0].?].tag);
    try std.testing.expectEqual(@as(?usize, null), found[1]);
    try std.testing.expectEqual(std.zig.Token.Tag.keyword_for, context.tokens[found[2].?].tag);
}

test "statementDiverges recognizes terminators and noreturn calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(),
        \\fn fail() noreturn { @trap(); }
        \\fn note() void {}
        \\fn f() void {
        \\    return;
        \\    @panic("x");
        \\    std.process.exit(1);
        \\    std.debug.panic("{d}", .{1});
        \\    fail();
        \\    note();
        \\    std.process.exit(1) catch {};
        \\    x = 1;
        \\}
    );
    const context = fixture.run(arena.allocator());
    var verdicts: [8]bool = undefined;
    var count: usize = 0;
    var last_fn: usize = 0;
    for (context.tokens, 0..) |token, index| if (token.tag == .keyword_fn) {
        last_fn = index;
    };
    var start = context.functionRange(last_fn).?.body_start + 1;
    while (count < verdicts.len) : (count += 1) {
        verdicts[count] = context.statementDiverges(start);
        start = context.statementEnd(start).? + 1;
    }
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, true, false, false, false }, &verdicts);
}

test "run hands the rule a tree and scope index of its source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator(), test_source);
    const context = fixture.run(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), context.tree.rootDecls().len);
    try std.testing.expect(context.scopes.findBinding(1) != null);
}
