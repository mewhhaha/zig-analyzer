const std = @import("std");
const nextTagBefore = @import("../../syntax/tokens.zig").nextTagBefore;
const syntax_scope = @import("../../syntax/scope.zig");
const RuleRun = @import("../context.zig").RuleRun;
const container_types = @import("../container_types.zig");
const types = @import("../types.zig");
const support = @import("../test_support.zig");

pub const rules = [_]types.Rule{
    .deprecated_declaration,
    // Reported by the same deprecation index once a host resolves
    // `@import("std")` to the installed standard library; never file-locally.
    .removed_std_api,
    .useless_error_return,
    .exposed_private_type,
    .exposed_private_error_set,
    .mutated_container_copy,
};

pub fn run(context: RuleRun) !void {
    try findUselessErrorReturns(context);
    try findExposedPrivateTypes(context);
    try @import("../modernize/deprecated_declarations.zig").runLocal(context);
    try findMutatedContainerCopies(context);
}

fn findUselessErrorReturns(context: RuleRun) !void {
    const level = context.level(.useless_error_return);
    if (level == .off) return;
    var candidates: std.ArrayList(UselessErrorReturn) = .empty;
    defer candidates.deinit(context.allocator);
    var uses: std.StringHashMapUnmanaged(FunctionUses) = .empty;
    defer uses.deinit(context.allocator);
    for (context.tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or isExported(context, fn_index) or isPublic(context, fn_index) or
            fn_index + 2 >= context.tokens.len or context.tokens[fn_index + 1].tag != .identifier) continue;
        const opening = nextTag(context.tokens, fn_index + 1, .l_paren) orelse continue;
        const parameters_end = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        const body_open = syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end) orelse continue;
        const error_separator = firstTag(context.tokens, parameters_end + 1, body_open, .bang) orelse continue;
        // A named error set is a contract the function fulfils, as is the
        // signature of a function an anonymous struct hands to its caller.
        if (namesErrorSet(context, parameters_end, error_separator) or insideHandedStruct(context, fn_index)) continue;
        const body_end = context.matchingToken(body_open, .l_brace, .r_brace) orelse continue;
        if (!bodyIsProvenInfallible(context, body_open + 1, body_end)) continue;
        try candidates.append(context.allocator, .{ .name_index = fn_index + 1, .error_separator = error_separator });
        try uses.put(context.allocator, context.tokenText(fn_index + 1), .{});
    }
    if (candidates.items.len == 0) return;
    // Every mention of a candidate's name, found in one pass for all of them.
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier) continue;
        const found = uses.getPtr(context.tokenText(index)) orelse continue;
        if (index + 1 >= context.tokens.len or context.tokens[index + 1].tag != .l_paren) {
            found.value.add(index);
        } else if (callRequiresErrorUnion(context, index)) {
            found.error_union_call.add(index);
        }
    }
    for (candidates.items) |candidate| {
        const name = context.tokenText(candidate.name_index);
        const found = uses.get(name).?;
        if (found.value.besides(candidate.name_index) or found.error_union_call.besides(candidate.name_index)) continue;
        try context.emit(.{
            .rule = .useless_error_return,
            .level = level,
            .span = context.tokens[candidate.error_separator].loc,
            .message = try context.allocator.print(
                "function '{s}' returns an error union, but its fully visible body has no operation that can fail",
                .{name},
            ),
        });
    }
}

/// A private function whose infallible body still returns an error union,
/// reported unless its name is used where the error union is needed.
const UselessErrorReturn = struct { name_index: usize, error_separator: usize };

/// Where a name occurs as a value (`f` not called) and in calls whose result
/// is tried or caught.
const FunctionUses = struct {
    value: Occurrences = .{},
    error_union_call: Occurrences = .{},

    /// How many times, and where first, enough to tell whether one occurs
    /// anywhere but at a given token.
    const Occurrences = struct {
        count: usize = 0,
        first: usize = 0,

        fn add(occurrences: *Occurrences, index: usize) void {
            if (occurrences.count == 0) occurrences.first = index;
            occurrences.count += 1;
        }

        fn besides(occurrences: Occurrences, index: usize) bool {
            return occurrences.count > 1 or (occurrences.count == 1 and occurrences.first != index);
        }
    };
};

/// Whether the return type names its error set (`Error!T`, `error{A}!T`)
/// rather than inferring it (`!T`), looking past `align`, `addrspace`,
/// `linksection` and `callconv` after the parameters.
fn namesErrorSet(context: RuleRun, parameters_end: usize, bang: usize) bool {
    const tokens = context.tokens;
    var cursor = parameters_end + 1;
    while (cursor + 1 < bang and tokens[cursor + 1].tag == .l_paren) switch (tokens[cursor].tag) {
        .keyword_align, .keyword_addrspace, .keyword_linksection, .keyword_callconv => {
            cursor = (context.matchingToken(cursor + 1, .l_paren, .r_paren) orelse return true) + 1;
        },
        else => break,
    };
    return cursor != bang;
}

/// Whether the function at `fn_index` belongs to an anonymous struct passed
/// as an argument or accessed in place (`struct { fn f() ... }.f`), whose
/// receiver sets the signature.
fn insideHandedStruct(context: RuleRun, fn_index: usize) bool {
    const tokens = context.tokens;
    const opening = context.enclosingOpeningBrace(fn_index) orelse return false;
    if (opening < 2 or tokens[opening - 1].tag != .keyword_struct) return false;
    if (tokens[opening - 2].tag == .l_paren or tokens[opening - 2].tag == .comma) return true;
    const closing = context.scopes.matchingToken(opening) orelse return false;
    return closing + 1 < tokens.len and tokens[closing + 1].tag == .period;
}

/// Whether the call whose name is at `index` is caught or tried.
fn callRequiresErrorUnion(context: RuleRun, index: usize) bool {
    const closing = context.matchingToken(index + 1, .l_paren, .r_paren) orelse return false;
    if (closing + 1 < context.tokens.len and context.tokens[closing + 1].tag == .keyword_catch) return true;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_try => return true,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn bodyIsProvenInfallible(context: RuleRun, start: usize, end: usize) bool {
    for (context.tokens[start..end], start..) |token, index| switch (token.tag) {
        .keyword_try, .keyword_catch => return false,
        .keyword_error => return false,
        .keyword_return => if (index + 3 < end and context.tokens[index + 1].tag == .identifier and
            context.tokens[index + 2].tag == .period and context.tokens[index + 3].tag == .identifier) return false,
        .identifier => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren) return false,
        .builtin => if (index + 1 < end and context.tokens[index + 1].tag == .l_paren and
            !context.tokenIs(index, "@as") and !context.tokenIs(index, "@intCast") and
            !context.tokenIs(index, "@floatCast") and !context.tokenIs(index, "@ptrCast") and
            !context.tokenIs(index, "@enumFromInt") and !context.tokenIs(index, "@intFromEnum") and
            !context.tokenIs(index, "@fromBackingInt") and !context.tokenIs(index, "@backingInt") and
            !context.tokenIs(index, "@TypeOf")) return false,
        else => {},
    };
    return true;
}

const PrivateDeclaration = struct {
    name: []const u8,
    identifier_index: usize,
    error_set: bool,
};

fn findExposedPrivateTypes(context: RuleRun) !void {
    const type_level = context.level(.exposed_private_type);
    const error_level = context.level(.exposed_private_error_set);
    if (type_level == .off and error_level == .off) return;

    var declarations: std.ArrayList(PrivateDeclaration) = .empty;
    defer declarations.deinit(context.allocator);
    var brace_depth: usize = 0;
    for (context.tokens, 0..) |token, index| {
        switch (token.tag) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -|= 1,
            .keyword_const => if (brace_depth == 0 and index + 3 < context.tokens.len and
                context.tokens[index + 1].tag == .identifier and context.tokens[index + 2].tag == .equal)
            {
                const initializer = context.tokens[index + 3].tag;
                const names_type = initializer == .keyword_struct or initializer == .keyword_union or
                    initializer == .keyword_enum or initializer == .keyword_opaque or initializer == .keyword_error;
                if (names_type and (index == 0 or context.tokens[index - 1].tag != .keyword_pub)) {
                    try declarations.append(context.allocator, .{
                        .name = context.tokenText(index + 1),
                        .identifier_index = index + 1,
                        .error_set = initializer == .keyword_error,
                    });
                }
            },
            else => {},
        }
    }
    if (declarations.items.len == 0) return;

    for (context.tokens, 0..) |token, pub_index| {
        if (token.tag != .keyword_pub or pub_index + 1 >= context.tokens.len or
            !publicDeclarationIsReachable(context, pub_index)) continue;
        var signature_start = pub_index + 1;
        if (context.tokens[signature_start].tag == .keyword_extern or context.tokens[signature_start].tag == .keyword_export) continue;
        while (signature_start < context.tokens.len and context.tokens[signature_start].tag != .keyword_fn and
            context.tokens[signature_start].tag != .keyword_const and context.tokens[signature_start].tag != .keyword_var) : (signature_start += 1)
        {}
        if (signature_start >= context.tokens.len) continue;
        const signature_end = if (context.tokens[signature_start].tag == .keyword_fn) end: {
            if (signature_start + 1 < context.tokens.len and context.tokenIs(signature_start + 1, "main")) continue;
            const parameters_open = nextTag(context.tokens, signature_start + 1, .l_paren) orelse continue;
            const parameters_end = context.matchingToken(parameters_open, .l_paren, .r_paren) orelse continue;
            break :end syntax_scope.functionBodyAfterParameters(context.tokens, parameters_end) orelse continue;
        } else typedDeclarationEnd(context.tokens, signature_start + 1) orelse continue;
        for (declarations.items) |declaration| {
            const reference = findIdentifier(context, signature_start + 1, signature_end, declaration.name) orelse continue;
            const rule: types.Rule = if (declaration.error_set) .exposed_private_error_set else .exposed_private_type;
            const level = if (declaration.error_set) error_level else type_level;
            if (level == .off) continue;
            const related = try relatedDeclaration(context, declaration);
            // Error values are global, so callers can still match the errors;
            // what they lose is the set itself, absent from the documented API.
            const message = if (declaration.error_set)
                try context.allocator.print(
                    "public declaration exposes private error set '{s}': callers can match its errors but cannot refer to the set, which is missing from the documented API",
                    .{declaration.name},
                )
            else
                try context.allocator.print("public declaration exposes private type '{s}', which callers cannot name", .{declaration.name});
            errdefer context.allocator.free(message);
            try context.emit(.{
                .rule = rule,
                .level = level,
                .span = context.tokens[reference].loc,
                .message = message,
                .related = related,
            });
        }
    }
}

fn typedDeclarationEnd(tokens: []const std.zig.Token, start: usize) ?usize {
    var saw_colon = false;
    for (tokens[start..], start..) |token, index| switch (token.tag) {
        .colon => saw_colon = true,
        .equal, .semicolon => return if (saw_colon) index else null,
        .l_brace, .r_brace => return null,
        else => {},
    };
    return null;
}

fn publicDeclarationIsReachable(context: RuleRun, declaration_index: usize) bool {
    var enclosing = context.enclosingOpeningBrace(declaration_index);
    while (enclosing) |opening| {
        const container_declaration = containerDeclarationBefore(context, opening) orelse return false;
        if (container_declaration == 0 or context.tokens[container_declaration - 1].tag != .keyword_pub) return false;
        enclosing = context.enclosingOpeningBrace(container_declaration);
    }
    return true;
}

fn containerDeclarationBefore(context: RuleRun, opening: usize) ?usize {
    var cursor = opening;
    while (cursor > 0) {
        cursor -= 1;
        switch (context.tokens[cursor].tag) {
            .keyword_const => {
                if (cursor + 3 >= opening or context.tokens[cursor + 1].tag != .identifier or
                    context.tokens[cursor + 2].tag != .equal) return null;
                for (context.tokens[cursor + 3 .. opening]) |token| switch (token.tag) {
                    .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return cursor,
                    else => {},
                };
                return null;
            },
            .semicolon, .l_brace, .r_brace, .comma => return null,
            else => {},
        }
    }
    return null;
}

fn relatedDeclaration(context: RuleRun, declaration: PrivateDeclaration) ![]const types.RelatedSpan {
    const related = try context.allocator.alloc(types.RelatedSpan, 1);
    related[0] = .{
        .span = context.tokens[declaration.identifier_index].loc,
        .message = "private declaration is defined here",
    };
    return related;
}

fn findMutatedContainerCopies(context: RuleRun) !void {
    const level = context.level(.mutated_container_copy);
    if (level == .off) return;
    var canonical_std: ?bool = null;
    for (context.tokens, 0..) |token, var_index| {
        if (token.tag != .keyword_var or var_index + 7 >= context.tokens.len or
            context.tokens[var_index + 1].tag != .identifier) continue;
        const equal = nextTagBefore(context.tokens, var_index + 2, .equal, .semicolon) orelse continue;
        if (!hasProvenStandardContainerType(context, var_index + 2, equal, &canonical_std)) continue;
        if (equal + 4 >= context.tokens.len or context.tokens[equal + 1].tag != .identifier or
            context.tokens[equal + 2].tag != .period or context.tokens[equal + 3].tag != .identifier or
            context.tokens[equal + 4].tag != .semicolon) continue;
        const end = context.enclosingScopeEnd(var_index) orelse continue;
        const copy_name = context.tokenText(var_index + 1);
        if (identifierDeclarationCount(context, copy_name) != 1) continue;
        const original = context.source[context.tokens[equal + 1].loc.start..context.tokens[equal + 3].loc.end];
        if (fieldIsReferenced(context, equal + 5, end, original)) continue;
        const mutation = exclusivelyMutatedCopy(context, equal + 5, end, copy_name) orelse continue;
        try context.emit(.{
            .rule = .mutated_container_copy,
            .level = level,
            .span = context.tokens[mutation].loc,
            .message = try context.allocator.print(
                "local copy '{s}' mutates standard container metadata, but field '{s}' is never updated",
                .{ copy_name, original },
            ),
        });
    }
}

/// `canonical_std` remembers, once a declaration asked, whether the file
/// declares `std` once, as the standard-library import.
fn hasProvenStandardContainerType(context: RuleRun, start: usize, equal: usize, canonical_std: *?bool) bool {
    if (start + 4 >= equal or context.tokens[start].tag != .colon or
        context.tokens[start + 1].tag != .identifier or !context.tokenIs(start + 1, "std") or
        context.tokens[start + 2].tag != .period or context.tokens[start + 3].tag != .identifier or
        context.tokens[start + 4].tag != .l_paren) return false;
    if (container_types.kindOfName(context.tokenText(start + 3)) == null) return false;
    return canonical_std.* orelse {
        const canonical = identifierDeclarationCount(context, "std") == 1 and hasCanonicalStdImport(context);
        canonical_std.* = canonical;
        return canonical;
    };
}

fn hasCanonicalStdImport(context: RuleRun) bool {
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .keyword_const or index + 6 >= context.tokens.len or
            context.tokens[index + 1].tag != .identifier or !context.tokenIs(index + 1, "std") or
            context.tokens[index + 2].tag != .equal or context.tokens[index + 3].tag != .builtin or
            !context.tokenIs(index + 3, "@import") or context.tokens[index + 4].tag != .l_paren or
            context.tokens[index + 5].tag != .string_literal or !context.tokenIs(index + 5, "\"std\"") or
            context.tokens[index + 6].tag != .r_paren) continue;
        return true;
    }
    return false;
}

fn fieldIsReferenced(context: RuleRun, start: usize, end: usize, original: []const u8) bool {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or index + 2 >= end or
            context.tokens[index + 1].tag != .period or context.tokens[index + 2].tag != .identifier) continue;
        const expression = context.source[token.loc.start..context.tokens[index + 2].loc.end];
        if (std.mem.eql(u8, expression, original)) return true;
    }
    return false;
}

fn exclusivelyMutatedCopy(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
    const methods = [_][]const u8{ "append", "appendSlice", "insert", "addOne", "ensureTotalCapacity", "resize", "clearAndFree", "pop" };
    var first_mutation: ?usize = null;
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name) or
            !context.refersToBinding(index, name)) continue;
        if (index + 3 >= end or context.tokens[index + 1].tag != .period or
            context.tokens[index + 2].tag != .identifier or context.tokens[index + 3].tag != .l_paren) return null;
        for (methods) |method| {
            if (!context.tokenIs(index + 2, method)) continue;
            if (first_mutation == null) first_mutation = index;
            break;
        } else return null;
    }
    return first_mutation;
}

fn isExported(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 4) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_export or context.tokens[cursor].tag == .keyword_extern) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
    }
    return false;
}

fn isPublic(context: RuleRun, fn_index: usize) bool {
    var cursor = fn_index;
    while (cursor > 0 and fn_index - cursor < 4) {
        cursor -= 1;
        if (context.tokens[cursor].tag == .keyword_pub) return true;
        if (context.tokens[cursor].tag == .semicolon or context.tokens[cursor].tag == .l_brace) return false;
    }
    return false;
}

fn identifierDeclarationCount(context: RuleRun, name: []const u8) usize {
    var count: usize = 0;
    for (context.tokens, 0..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > 0) switch (context.tokens[index - 1].tag) {
            .keyword_fn, .keyword_const, .keyword_var, .pipe, .asterisk => {
                count += 1;
                continue;
            },
            else => {},
        };
        if (index + 1 < context.tokens.len and
            (context.tokens[index + 1].tag == .colon or context.tokens[index + 1].tag == .pipe))
        {
            count += 1;
        }
    }
    return count;
}

fn insideStandardFormatterType(context: RuleRun, start: usize, end: usize, reference: usize) bool {
    for (context.tokens[start..reference], start..) |token, opening| {
        if (token.tag != .l_paren or opening < start + 5 or
            !context.tokenIs(opening - 1, "Alt") or context.tokens[opening - 2].tag != .period or
            !context.tokenIs(opening - 3, "fmt") or context.tokens[opening - 4].tag != .period or
            !context.tokenIs(opening - 5, "std")) continue;
        const closing = context.matchingToken(opening, .l_paren, .r_paren) orelse continue;
        if (closing < end and reference < closing) return true;
    }
    return false;
}

fn nextTag(tokens: []const std.zig.Token, start: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn firstTag(tokens: []const std.zig.Token, start: usize, end: usize, tag: std.zig.Token.Tag) ?usize {
    for (tokens[start..end], start..) |token, index| if (token.tag == tag) return index;
    return null;
}

fn findIdentifier(context: RuleRun, start: usize, end: usize, name: []const u8) ?usize {
    for (context.tokens[start..end], start..) |token, index| {
        if (token.tag != .identifier or !context.tokenIs(index, name)) continue;
        if (index > start and context.tokens[index - 1].tag == .period) continue;
        if (index + 1 < end and context.tokens[index + 1].tag == .period) continue;
        if (insideStandardFormatterType(context, start, end, index)) continue;
        return index;
    }
    return null;
}

test "compiler hygiene rules report only locally proven contracts and ownership mistakes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "const Secret = struct {};\n" ++
        "const Failure = error{Bad};\n" ++
        "/// Deprecated: use current instead.\n" ++
        "const old = 1;\n" ++
        "fn flag() !bool { return true; }\n" ++
        "pub fn secret() Secret { return .{}; }\n" ++
        "pub fn fail() Failure!void { return error.Bad; }\n" ++
        "fn use(self: *State) void { _ = old; var copy: std.ArrayList(u8) = self.list; _ = copy.pop(); }\n";
    const configuration = support.only(&.{ .exposed_private_type, .exposed_private_error_set }, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var seen: [5]bool = @splat(false);
    for (found) |finding| switch (finding.rule) {
        .useless_error_return => seen[0] = true,
        .exposed_private_type => seen[1] = true,
        .exposed_private_error_set => seen[2] = true,
        .deprecated_declaration => seen[3] = true,
        .mutated_container_copy => seen[4] = true,
        else => {},
    };
    for (seen) |value| try std.testing.expect(value);
}

test "compiler hygiene ignores function types callbacks and public error contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Hooks = struct { callback: *const fn () anyerror!void, };\n" ++
        "fn callback() !void {}\n" ++
        "const hooks = Hooks{ .callback = callback };\n" ++
        "pub fn publicOperation() !void {}\n" ++
        "fn validate() !void { return ConfigError.InvalidValue; }\n" ++
        "fn constructed() !struct { value: u8 } { return .{ .value = try load() }; }\n";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .useless_error_return);
}

test "named error sets and handed-over callbacks keep their error unions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const TimeoutError = error{Canceled};\n" ++
        "fn submit(comptime Op: type) void { _ = Op; }\n" ++
        "fn timeout() void { submit(struct { fn operation() !void {} }); }\n" ++
        "const handler = struct { fn handle() !void {} }.handle;\n" ++
        "fn named() TimeoutError!u32 { return 1; }\n" ++
        "fn explicit() error{Bad}!u32 { return 1; }\n" ++
        "fn aligned() align(4) !u32 { return 1; }\n" ++
        "fn inferred() !u32 { return 1; }\n";
    const configuration = support.only(&.{.useless_error_return}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expect(found[0].span.start > std.mem.find(u8, source, "fn aligned").?);
    try std.testing.expect(found[1].span.start > std.mem.find(u8, source, "fn inferred").?);
}

test "infallible implementations keep error unions required by their callers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn setup() !void {} fn run() !void { try setup(); }\n";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .useless_error_return);
}

test "private containers do not expose their private receiver types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Secret = struct {};\n" ++
        "const FormatContext = struct {};\n" ++
        "const Private = struct { pub fn init() Private { return .{}; } };\n" ++
        "pub const Api = struct { pub fn secret() Secret { return .{}; } };\n" ++
        "pub fn formatter() std.fmt.Alt(FormatContext, render) { return .{}; }\n" ++
        "pub fn qualified() types.Secret { return .{}; }\n";
    const configuration = support.only(&.{.exposed_private_type}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    var exposed_count: usize = 0;
    for (found) |finding| {
        if (finding.rule == .exposed_private_type) exposed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), exposed_count);
}

test "public aliases publish private components under a name callers can use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Failure = error{Bad}; pub const PublicFailure = Failure || error{Other}; pub fn main() Failure!void {}\n";
    const configuration = support.only(&.{.exposed_private_error_set}, .warning);
    const found = try support.findings(arena.allocator(), run, source, configuration);
    for (found) |finding| try std.testing.expect(finding.rule != .exposed_private_error_set);
}

test "mutated container copies reject constructors and type literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn run(allocator: std.mem.Allocator) !void {\n" ++
        "    var list = std.ArrayList(u8).empty;\n" ++
        "    try list.append(allocator, 1);\n" ++
        "    var headers = namespace.Headers.ViewChangeArray{ .array = .{} };\n" ++
        "    headers.append(1);\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .mutated_container_copy);
}

test "mutated container copies omit inferred and otherwise observed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn inferred(self: *State) void { var copy = self.list; _ = copy.pop(); }\n" ++
        "fn observed(self: *State) void {\n" ++
        "    var copy: std.ArrayList(u8) = self.list;\n" ++
        "    _ = copy.pop();\n" ++
        "    consume(copy);\n" ++
        "}\n" ++
        "fn owner_used(self: *State) void {\n" ++
        "    var copy: std.ArrayList(u8) = self.list;\n" ++
        "    self.list.clearRetainingCapacity();\n" ++
        "    _ = copy.pop();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .mutated_container_copy);
}

test "mutated container copies reject shadowed standard library aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const std = @import(\"std\");\n" ++
        "fn run(std: anytype, self: *State) void {\n" ++
        "    var copy: std.ArrayList(u8) = self.list;\n" ++
        "    _ = copy.pop();\n" ++
        "}\n";
    const found = try support.findings(arena.allocator(), run, source, types.Configuration.defaults());
    for (found) |finding| try std.testing.expect(finding.rule != .mutated_container_copy);
}
