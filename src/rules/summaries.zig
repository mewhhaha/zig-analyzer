const std = @import("std");

const types = @import("types.zig");

pub const Source = struct {
    file_index: usize,
    path: ?[]const u8 = null,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
};

pub const ParameterEffect = enum { borrowed, released, escaped, unknown };

pub const FunctionSummary = struct {
    file_index: usize,
    name: []const u8,
    parameter_names: []const []const u8,
    parameter_effects: []ParameterEffect,
    returns_owned: bool = false,
    return_release: ?[]const u8 = null,
    allocator_parameter: ?usize = null,
    unresolved: bool = false,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    body_start: usize,
    body_end: usize,
};

pub const OwnedReturn = struct {
    release: []const u8,
};

const ImportAlias = struct {
    source: [:0]const u8,
    name: []const u8,
    target_file_index: usize,
};

pub const Index = struct {
    functions: []FunctionSummary,
    resource_contracts: []const types.ResourceContract,
    import_aliases: []const ImportAlias,
    owned_tokens: []const []const std.zig.Token,

    pub fn deinit(index: *Index, allocator: std.mem.Allocator) void {
        for (index.functions) |function| {
            allocator.free(function.parameter_names);
            allocator.free(function.parameter_effects);
        }
        allocator.free(index.functions);
        allocator.free(index.import_aliases);
        for (index.owned_tokens) |tokens| allocator.free(tokens);
        allocator.free(index.owned_tokens);
        index.* = undefined;
    }

    pub fn parameterEffect(index: Index, callable: []const u8, parameter: usize) ParameterEffect {
        if (index.releaseContract(callable)) |contract| {
            if (parameter == 0) return .released;
            _ = contract;
        }
        const function = index.uniqueFunction(callable) orelse return .unknown;
        if (function.unresolved or parameter >= function.parameter_effects.len) return .unknown;
        return function.parameter_effects[parameter];
    }

    pub fn parameterEffectForCall(
        index: Index,
        source: []const u8,
        callable: []const u8,
        parameter: usize,
    ) ParameterEffect {
        if (index.releaseContract(callable)) |_| {
            if (parameter == 0) return .released;
        }
        const separator = std.mem.indexOfScalar(u8, callable, '.') orelse {
            if (index.sourceHasLocalBinding(source, callable)) return .unknown;
            const file_index = index.fileIndexForSource(source) orelse return .unknown;
            const function = index.uniqueFunctionInFile(file_index, callable) orelse return .unknown;
            if (function.unresolved or parameter >= function.parameter_effects.len) return .unknown;
            return function.parameter_effects[parameter];
        };
        if (std.mem.indexOfScalar(u8, callable[separator + 1 ..], '.') != null) return .unknown;
        const target_file = index.importedFile(source, callable[0..separator]) orelse return .unknown;
        const function = index.uniqueFunctionInFile(target_file, callable[separator + 1 ..]) orelse return .unknown;
        if (function.unresolved or parameter >= function.parameter_effects.len) return .unknown;
        return function.parameter_effects[parameter];
    }

    pub fn ownedReturn(index: Index, callable: []const u8) ?OwnedReturn {
        if (index.acquireContract(callable)) |contract| return .{ .release = callableBaseName(contract.release) };
        const function = index.uniqueFunction(callable) orelse return null;
        if (function.unresolved or !function.returns_owned) return null;
        return .{ .release = function.return_release orelse "free" };
    }

    pub fn ownedReturnCall(
        index: Index,
        source: []const u8,
        receiver: ?[]const u8,
        name: []const u8,
    ) ?OwnedReturn {
        for (index.resource_contracts) |contract| {
            if (!std.mem.eql(u8, callableBaseName(contract.acquire), name)) continue;
            const separator = std.mem.lastIndexOfScalar(u8, contract.acquire, '.');
            if (separator) |position| {
                const actual_receiver = receiver orelse continue;
                if (!std.mem.eql(u8, contract.acquire[0..position], actual_receiver)) continue;
            } else if (receiver != null) continue;
            return .{ .release = callableBaseName(contract.release) };
        }
        if (receiver) |alias| {
            const target_file = index.importedFile(source, alias) orelse return null;
            const function = index.uniqueFunctionInFile(target_file, name) orelse return null;
            if (function.unresolved or !function.returns_owned) return null;
            return .{ .release = function.return_release orelse "free" };
        } else if (index.sourceHasLocalBinding(source, name)) return null;
        const file_index = index.fileIndexForSource(source) orelse return null;
        const function = index.uniqueFunctionInFile(file_index, name) orelse return null;
        if (function.unresolved or !function.returns_owned) return null;
        return .{ .release = function.return_release orelse "free" };
    }

    fn ownedReturnForCall(index: Index, source: []const u8, callable: []const u8) ?OwnedReturn {
        if (index.acquireContract(callable)) |contract| {
            return .{ .release = callableBaseName(contract.release) };
        }
        const separator = std.mem.indexOfScalar(u8, callable, '.') orelse {
            if (index.sourceHasLocalBinding(source, callable)) return null;
            const file_index = index.fileIndexForSource(source) orelse return null;
            const function = index.uniqueFunctionInFile(file_index, callable) orelse return null;
            if (function.unresolved or !function.returns_owned) return null;
            return .{ .release = function.return_release orelse "free" };
        };
        if (std.mem.indexOfScalar(u8, callable[separator + 1 ..], '.') != null) return null;
        const target_file = index.importedFile(source, callable[0..separator]) orelse return null;
        const function = index.uniqueFunctionInFile(target_file, callable[separator + 1 ..]) orelse return null;
        if (function.unresolved or !function.returns_owned) return null;
        return .{ .release = function.return_release orelse "free" };
    }

    fn uniqueFunction(index: Index, callable: []const u8) ?FunctionSummary {
        const name = callableBaseName(callable);
        var selected: ?FunctionSummary = null;
        for (index.functions) |function| {
            if (!std.mem.eql(u8, function.name, name)) continue;
            if (selected != null) return null;
            selected = function;
        }
        return selected;
    }

    fn uniqueFunctionInFile(index: Index, file_index: usize, name: []const u8) ?FunctionSummary {
        var selected: ?FunctionSummary = null;
        for (index.functions) |function| {
            if (function.file_index != file_index or !std.mem.eql(u8, function.name, name)) continue;
            if (selected != null) return null;
            selected = function;
        }
        return selected;
    }

    fn acquireContract(index: Index, callable: []const u8) ?types.ResourceContract {
        for (index.resource_contracts) |contract| {
            if (callableMatches(callable, contract.acquire)) return contract;
        }
        return null;
    }

    fn releaseContract(index: Index, callable: []const u8) ?types.ResourceContract {
        for (index.resource_contracts) |contract| {
            if (callableMatches(callable, contract.release)) return contract;
        }
        return null;
    }

    fn importedFile(index: Index, source: []const u8, alias: []const u8) ?usize {
        var selected: ?usize = null;
        for (index.import_aliases) |import_alias| {
            if (import_alias.source.ptr != source.ptr or import_alias.source.len != source.len or
                !std.mem.eql(u8, import_alias.name, alias)) continue;
            if (selected != null and selected.? != import_alias.target_file_index) return null;
            selected = import_alias.target_file_index;
        }
        return selected;
    }

    fn fileIndexForSource(index: Index, source: []const u8) ?usize {
        var selected: ?usize = null;
        for (index.functions) |function| {
            if (function.source.ptr != source.ptr or function.source.len != source.len) continue;
            if (selected != null and selected.? != function.file_index) return null;
            selected = function.file_index;
        }
        return selected;
    }

    fn sourceHasLocalBinding(index: Index, source: []const u8, name: []const u8) bool {
        var tokens: ?[]const std.zig.Token = null;
        for (index.functions) |function| {
            if (function.source.ptr != source.ptr or function.source.len != source.len) continue;
            tokens = function.tokens;
            for (function.parameter_names) |parameter| {
                if (std.mem.eql(u8, parameter, name)) return true;
            }
        }
        const source_tokens = tokens orelse return false;
        for (source_tokens, 0..) |token, token_index| {
            if ((token.tag != .keyword_const and token.tag != .keyword_var) or
                token_index + 1 >= source_tokens.len or source_tokens[token_index + 1].tag != .identifier) continue;
            if (std.mem.eql(u8, tokenText(source, source_tokens[token_index + 1]), name)) return true;
        }
        return false;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    sources: []const Source,
    configuration: types.Configuration,
) !Index {
    var functions: std.ArrayList(FunctionSummary) = .empty;
    var import_aliases: std.ArrayList(ImportAlias) = .empty;
    var owned_tokens: std.ArrayList([]const std.zig.Token) = .empty;
    for (sources) |source_file| {
        const tokens = source_file.tokens orelse tokens: {
            const allocated = try tokenize(allocator, source_file.source);
            try owned_tokens.append(allocator, allocated);
            break :tokens allocated;
        };
        try collectFunctions(allocator, source_file, tokens, &functions);
        try collectImportAliases(allocator, source_file, tokens, sources, &import_aliases);
    }
    const index: Index = .{
        .functions = try functions.toOwnedSlice(allocator),
        .resource_contracts = configuration.resource_contracts,
        .import_aliases = try import_aliases.toOwnedSlice(allocator),
        .owned_tokens = try owned_tokens.toOwnedSlice(allocator),
    };
    markRecursiveFunctions(index);
    inferDirectEffects(index, configuration);
    for (0..index.functions.len) |_| {
        if (!propagateCallEffects(index)) break;
    }
    return index;
}

fn collectFunctions(
    allocator: std.mem.Allocator,
    source_file: Source,
    tokens: []const std.zig.Token,
    functions: *std.ArrayList(FunctionSummary),
) !void {
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= tokens.len or
            tokens[fn_index + 1].tag != .identifier or tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, fn_index + 2) orelse continue;
        var body_start = parameters_end + 1;
        while (body_start < tokens.len and tokens[body_start].tag != .l_brace and
            tokens[body_start].tag != .semicolon) : (body_start += 1)
        {}
        if (body_start == tokens.len or tokens[body_start].tag != .l_brace) continue;
        const body_end = matchingToken(tokens, body_start) orelse continue;
        const parameters = try collectParameterNames(
            allocator,
            source_file.source,
            tokens,
            fn_index + 3,
            parameters_end,
        );
        const effects = try allocator.alloc(ParameterEffect, parameters.len);
        @memset(effects, .borrowed);
        try functions.append(allocator, .{
            .file_index = source_file.file_index,
            .name = tokenText(source_file.source, tokens[fn_index + 1]),
            .parameter_names = parameters,
            .parameter_effects = effects,
            .source = source_file.source,
            .tokens = tokens,
            .body_start = body_start,
            .body_end = body_end,
        });
    }
}

fn collectImportAliases(
    allocator: std.mem.Allocator,
    source_file: Source,
    tokens: []const std.zig.Token,
    sources: []const Source,
    import_aliases: *std.ArrayList(ImportAlias),
) !void {
    const source_path = source_file.path orelse return;
    var brace_depth: usize = 0;
    for (tokens, 0..) |token, index| {
        if (token.tag == .l_brace) {
            brace_depth += 1;
            continue;
        }
        if (token.tag == .r_brace) {
            brace_depth -|= 1;
            continue;
        }
        if (brace_depth != 0 or token.tag != .keyword_const or index + 5 >= tokens.len or
            tokens[index + 1].tag != .identifier or tokens[index + 2].tag != .equal or
            tokens[index + 3].tag != .builtin or
            !std.mem.eql(u8, tokenText(source_file.source, tokens[index + 3]), "@import") or
            tokens[index + 4].tag != .l_paren or tokens[index + 5].tag != .string_literal) continue;
        const literal = tokenText(source_file.source, tokens[index + 5]);
        const spelling = std.zig.string_literal.parseAlloc(allocator, literal) catch |err| switch (err) {
            error.InvalidLiteral => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(spelling);
        if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
        const directory = std.fs.path.dirname(source_path) orelse "";
        const resolved = try std.fs.path.resolve(allocator, &.{ "/", directory, spelling });
        defer allocator.free(resolved);
        const target_path = std.mem.trimStart(u8, resolved, "/");
        const target_file_index = for (sources) |candidate| {
            const candidate_path = candidate.path orelse continue;
            if (std.mem.eql(u8, candidate_path, target_path)) break candidate.file_index;
        } else continue;
        try import_aliases.append(allocator, .{
            .source = source_file.source,
            .name = tokenText(source_file.source, tokens[index + 1]),
            .target_file_index = target_file_index,
        });
    }
}

fn collectParameterNames(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var segment_start = start;
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (parameterName(source, tokens, segment_start, index)) |name| try names.append(allocator, name);
                segment_start = index + 1;
            },
            else => {},
        }
    }
    if (parameterName(source, tokens, segment_start, end)) |name| try names.append(allocator, name);
    return try names.toOwnedSlice(allocator);
}

fn parameterName(source: []const u8, tokens: []const std.zig.Token, start: usize, end: usize) ?[]const u8 {
    for (tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and tokens[index + 1].tag == .colon) return tokenText(source, token);
    }
    return null;
}

fn inferDirectEffects(index: Index, configuration: types.Configuration) void {
    for (index.functions) |*function| {
        if (function.unresolved) continue;
        for (function.parameter_names, 0..) |parameter_name, parameter| {
            for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, use_index| {
                if (token.tag != .identifier or !std.mem.eql(u8, tokenText(function.source, token), parameter_name)) continue;
                if (useIsDirectRelease(function.*, use_index, configuration.resource_contracts)) {
                    mergeEffect(&function.parameter_effects[parameter], .released);
                    continue;
                }
                if (statementStartsWith(function.tokens, use_index, .keyword_return) or
                    useIsStored(function.*, use_index))
                {
                    mergeEffect(&function.parameter_effects[parameter], .escaped);
                }
            }
        }
        if (directOwnedReturn(function.*, configuration.resource_contracts)) |owned| {
            function.returns_owned = true;
            function.return_release = owned.release;
            function.allocator_parameter = owned.allocator_parameter;
        }
    }
}

const DirectOwnedReturn = struct { release: []const u8, allocator_parameter: ?usize = null };

fn directOwnedReturn(function: FunctionSummary, contracts: []const types.ResourceContract) ?DirectOwnedReturn {
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, index| {
        if (token.tag != .keyword_return) continue;
        const statement_end = statementEnd(function.tokens, index, function.body_end);
        var call_open = index + 1;
        while (call_open < statement_end) : (call_open += 1) {
            if (function.tokens[call_open].tag != .l_paren) continue;
            const callable = callableBefore(function.source, function.tokens, call_open) orelse continue;
            for (contracts) |contract| if (callableMatches(callable, contract.acquire)) {
                return .{ .release = callableBaseName(contract.release) };
            };
            const method = callableBaseName(callable);
            const release = allocationRelease(method) orelse continue;
            return .{
                .release = release,
                .allocator_parameter = allocatorParameter(function, callable),
            };
        }
    }
    return null;
}

fn allocatorParameter(function: FunctionSummary, callable: []const u8) ?usize {
    const separator = std.mem.lastIndexOfScalar(u8, callable, '.') orelse return null;
    const receiver = callable[0..separator];
    if (std.mem.indexOfScalar(u8, receiver, '.') != null) return null;
    for (function.parameter_names, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter, receiver)) return index;
    }
    return null;
}

fn propagateCallEffects(index: Index) bool {
    var changed = false;
    for (index.functions) |*caller| {
        if (caller.unresolved) continue;
        for (caller.tokens[caller.body_start + 1 .. caller.body_end], caller.body_start + 1..) |token, call_open| {
            if (token.tag != .l_paren) continue;
            const callable = callableBefore(caller.source, caller.tokens, call_open) orelse continue;
            const call_end = matchingToken(caller.tokens, call_open) orelse continue;
            const method = callableBaseName(callable);
            const method_call = std.mem.indexOfScalar(u8, callable, '.') != null;
            const imported_call = if (std.mem.indexOfScalar(u8, callable, '.')) |separator|
                std.mem.indexOfScalar(u8, callable[separator + 1 ..], '.') == null and
                    index.importedFile(caller.source, callable[0..separator]) != null
            else
                false;
            if ((method_call and (std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy") or
                std.mem.eql(u8, method, "close") or std.mem.eql(u8, method, "deinit") or
                std.mem.eql(u8, method, "release")) and !imported_call) or index.releaseContract(callable) != null) continue;
            for (caller.parameter_names, 0..) |parameter_name, caller_parameter| {
                const argument = exactArgumentIndex(caller.source, caller.tokens, parameter_name, call_open + 1, call_end) orelse continue;
                const effect = index.parameterEffectForCall(caller.source, callable, argument);
                const before = caller.parameter_effects[caller_parameter];
                mergeEffect(&caller.parameter_effects[caller_parameter], effect);
                changed = changed or before != caller.parameter_effects[caller_parameter];
            }
            if (!statementStartsWith(caller.tokens, call_open, .keyword_return) or caller.returns_owned) continue;
            const owned = index.ownedReturnForCall(caller.source, callable) orelse continue;
            caller.returns_owned = true;
            caller.return_release = owned.release;
            changed = true;
        }
    }
    return changed;
}

fn mergeEffect(current: *ParameterEffect, incoming: ParameterEffect) void {
    if (incoming == .borrowed or current.* == incoming) return;
    if (current.* == .borrowed) {
        current.* = incoming;
        return;
    }
    current.* = .unknown;
}

fn markRecursiveFunctions(index: Index) void {
    for (index.functions, 0..) |_, start| {
        var visited: [256]bool = @splat(false);
        if (index.functions.len > visited.len) return;
        if (reachesFunction(index, start, start, &visited)) {
            index.functions[start].unresolved = true;
            @memset(index.functions[start].parameter_effects, .unknown);
        }
    }
}

fn reachesFunction(index: Index, current: usize, target: usize, visited: []bool) bool {
    if (visited[current]) return false;
    visited[current] = true;
    const function = index.functions[current];
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, call_open| {
        if (token.tag != .l_paren) continue;
        const callable = callableBefore(function.source, function.tokens, call_open) orelse continue;
        const called = uniqueFunctionIndexForCall(index, function, callable) orelse continue;
        if (called == target or reachesFunction(index, called, target, visited)) return true;
    }
    return false;
}

fn uniqueFunctionIndexForCall(index: Index, caller: FunctionSummary, callable: []const u8) ?usize {
    const separator = std.mem.indexOfScalar(u8, callable, '.');
    const file_index = if (separator) |position|
        index.importedFile(caller.source, callable[0..position]) orelse return null
    else
        caller.file_index;
    const name = if (separator) |position| callable[position + 1 ..] else callable;
    if (std.mem.indexOfScalar(u8, name, '.') != null) return null;
    var selected: ?usize = null;
    for (index.functions, 0..) |function, function_index| {
        if (function.file_index != file_index or !std.mem.eql(u8, function.name, name)) continue;
        if (selected != null) return null;
        selected = function_index;
    }
    return selected;
}

fn useIsDirectRelease(function: FunctionSummary, use_index: usize, contracts: []const types.ResourceContract) bool {
    if (use_index >= 3 and function.tokens[use_index - 1].tag == .l_paren) {
        const callable = callableBefore(function.source, function.tokens, use_index - 1) orelse return false;
        const method = callableBaseName(callable);
        if (std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy") or
            std.mem.eql(u8, method, "close") or std.mem.eql(u8, method, "deinit") or
            std.mem.eql(u8, method, "release")) return true;
        for (contracts) |contract| if (callableMatches(callable, contract.release)) return true;
    }
    if (use_index + 3 < function.body_end and function.tokens[use_index + 1].tag == .period and
        function.tokens[use_index + 2].tag == .identifier and function.tokens[use_index + 3].tag == .l_paren)
    {
        const method = tokenText(function.source, function.tokens[use_index + 2]);
        if (std.mem.eql(u8, method, "free") or std.mem.eql(u8, method, "destroy") or
            std.mem.eql(u8, method, "close") or std.mem.eql(u8, method, "deinit") or
            std.mem.eql(u8, method, "release")) return true;
    }
    return false;
}

fn useIsStored(function: FunctionSummary, use_index: usize) bool {
    var cursor = use_index;
    while (cursor > function.body_start + 1) {
        cursor -= 1;
        switch (function.tokens[cursor].tag) {
            .equal => return cursor == 0 or function.tokens[cursor - 1].tag != .identifier or
                !std.mem.eql(u8, tokenText(function.source, function.tokens[cursor - 1]), "_"),
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn exactArgumentIndex(
    source: []const u8,
    tokens: []const std.zig.Token,
    parameter_name: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var argument: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    for (tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (segmentIsIdentifier(source, tokens, segment_start, index, parameter_name)) return argument;
                argument += 1;
                segment_start = index + 1;
            },
            else => {},
        }
    }
    return if (segmentIsIdentifier(source, tokens, segment_start, end, parameter_name)) argument else null;
}

fn segmentIsIdentifier(
    source: []const u8,
    tokens: []const std.zig.Token,
    start: usize,
    end: usize,
    expected: []const u8,
) bool {
    return end == start + 1 and tokens[start].tag == .identifier and
        std.mem.eql(u8, tokenText(source, tokens[start]), expected);
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

fn statementEnd(tokens: []const std.zig.Token, start: usize, limit: usize) usize {
    var index = start;
    while (index < limit and tokens[index].tag != .semicolon) : (index += 1) {}
    return index;
}

fn callableBefore(source: []const u8, tokens: []const std.zig.Token, call_open: usize) ?[]const u8 {
    if (call_open == 0 or tokens[call_open - 1].tag != .identifier) return null;
    var start = call_open - 1;
    while (start >= 2 and tokens[start - 1].tag == .period and tokens[start - 2].tag == .identifier) start -= 2;
    return source[tokens[start].loc.start..tokens[call_open - 1].loc.end];
}

fn callableMatches(callable: []const u8, contract: []const u8) bool {
    return std.mem.eql(u8, callable, contract);
}

fn callableBaseName(callable: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, callable, '.') orelse return callable;
    return callable[separator + 1 ..];
}

fn allocationRelease(method: []const u8) ?[]const u8 {
    const free_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "dupe", "dupeZ", "realloc" };
    for (free_methods) |candidate| if (std.mem.eql(u8, method, candidate)) return "free";
    if (std.mem.eql(u8, method, "create")) return "destroy";
    return null;
}

fn matchingToken(tokens: []const std.zig.Token, opening: usize) ?usize {
    const closing_tag: std.zig.Token.Tag = switch (tokens[opening].tag) {
        .l_paren => .r_paren,
        .l_brace => .r_brace,
        .l_bracket => .r_bracket,
        else => return null,
    };
    const opening_tag = tokens[opening].tag;
    var depth: usize = 0;
    for (tokens[opening..], opening..) |token, index| {
        if (token.tag == opening_tag) depth += 1;
        if (token.tag != closing_tag) continue;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

test "summaries propagate releases and owned returns through direct calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/release.zig", .source = "pub fn release(allocator: anytype, bytes: []u8) void { allocator.free(bytes); }" },
        .{ .file_index = 1, .path = "src/operations.zig", .source = "const releasing = @import(\"release.zig\"); fn forward(allocator: anytype, bytes: []u8) void { releasing.release(allocator, bytes); } fn make(allocator: anytype) ![]u8 { return allocator.alloc(u8, 4); }" },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.released, index.parameterEffect("forward", 1));
    try std.testing.expectEqualStrings("free", index.ownedReturn("make").?.release);
}

test "recursive and ambiguous calls remain opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn loop(bytes: []u8) void { loop(bytes); } fn inspect(bytes: []u8) void { _ = bytes.len; } fn inspect(value: usize) void { _ = value; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffect("loop", 0));
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffect("inspect", 0));
}

test "qualified summaries require a proven import alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller: [:0]const u8 =
        "const inspection = @import(\"inspect.zig\"); fn run(bytes: []u8, object: anytype) void { inspection.inspect(bytes); object.inspect(bytes); }";
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/inspect.zig", .source = "pub fn inspect(bytes: []u8) void { _ = bytes.len; }" },
        .{ .file_index = 1, .path = "src/main.zig", .source = caller },
        .{ .file_index = 2, .path = "src/unrelated.zig", .source = "pub fn inspect(bytes: []u8) void { global = bytes; }" },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.borrowed, index.parameterEffectForCall(caller, "inspection.inspect", 0));
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffectForCall(caller, "object.inspect", 0));
}

test "owned return summaries do not apply to unrelated object methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller: [:0]const u8 =
        "const creation = @import(\"create.zig\"); fn run(object: anytype) void { _ = creation.make(); _ = object.make(); }";
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/create.zig", .source = "pub fn make(allocator: anytype) ![]u8 { return allocator.alloc(u8, 4); }" },
        .{ .file_index = 1, .path = "src/main.zig", .source = caller },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturnCall(caller, "creation", "make") != null);
    try std.testing.expect(index.ownedReturnCall(caller, "object", "make") == null);
}
