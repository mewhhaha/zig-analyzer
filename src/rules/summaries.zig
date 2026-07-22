const std = @import("std");

const syntax_scope = @import("../syntax_scope.zig");
const owned_call = @import("owned_call.zig");
const types = @import("types.zig");

pub const Source = struct {
    file_index: usize,
    path: ?[]const u8 = null,
    source: [:0]const u8,
    tokens: ?[]const std.zig.Token = null,
};

pub const ParameterEffect = enum { borrowed, released, escaped, unknown };

pub const BorrowKind = enum { pointer, slice };

pub const BorrowedReturn = struct {
    parameter: usize,
    field: []const u8,
    kind: BorrowKind,
};

pub const PartialIo = enum { none, read, write };

pub const ContainerMutation = struct {
    parameter: usize,
    field: []const u8,
    method: []const u8,
};

const TokenRange = struct { start: usize, end: usize };

pub const FunctionSummary = struct {
    file_index: usize,
    declaration_start: usize,
    name: []const u8,
    container_name: ?[]const u8 = null,
    parameter_names: []const []const u8,
    parameter_effects: []ParameterEffect,
    parameter_escapes: []bool,
    returns_owned: bool = false,
    return_release: ?[]const u8 = null,
    allocator_parameter: ?usize = null,
    allocator_parameter_member: ?[]const u8 = null,
    borrowed_return: ?BorrowedReturn = null,
    partial_io: PartialIo = .none,
    container_mutation: ?ContainerMutation = null,
    unresolved: bool = false,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    return_type_start: usize,
    body_start: usize,
    body_end: usize,
    parent_function: ?usize = null,
    externally_visible: bool = false,
    nested_function_ranges: []const TokenRange = &.{},
};

pub fn parameterDocumentsArena(function: FunctionSummary, parameter_name: []const u8) bool {
    for (function.parameter_names) |parameter| {
        if (std.mem.eql(u8, parameter, parameter_name)) break;
    } else return false;

    var modifier_start = function.declaration_start;
    while (modifier_start > 0) switch (function.tokens[modifier_start - 1].tag) {
        .keyword_pub,
        .keyword_export,
        .keyword_extern,
        .keyword_inline,
        .keyword_noinline,
        => modifier_start -= 1,
        else => break,
    };
    var documentation_start = modifier_start;
    while (documentation_start > 0 and function.tokens[documentation_start - 1].tag == .doc_comment) {
        documentation_start -= 1;
    }
    if (documentation_start == modifier_start) return false;
    const documentation = function.source[function.tokens[documentation_start].loc.start..function.tokens[modifier_start].loc.start];
    return std.ascii.indexOfIgnoreCase(documentation, "allocator should be an arena") != null;
}

pub const OwnedReturn = struct {
    release: []const u8,
    allocator_parameter: ?usize = null,
    allocator_parameter_member: ?[]const u8 = null,
};

const ImportAlias = struct {
    source: [:0]const u8,
    name: []const u8,
    target_file_index: usize,
};

const FileSummary = struct {
    file_index: usize,
    source: [:0]const u8,
    function_start: usize,
    function_end: usize,
    local_bindings: std.StringHashMapUnmanaged(void),
};

pub const Index = struct {
    functions: []FunctionSummary,
    files: []FileSummary,
    resource_contracts: []const types.ResourceContract,
    arena_allocator_contracts: []const []const u8,
    import_aliases: []const ImportAlias,
    owned_tokens: []const []const std.zig.Token,
    owned_member_paths: std.ArrayList([]u8) = .empty,

    pub fn deinit(index: *Index, allocator: std.mem.Allocator) void {
        for (index.functions) |function| {
            allocator.free(function.parameter_names);
            allocator.free(function.parameter_effects);
            allocator.free(function.parameter_escapes);
            allocator.free(function.nested_function_ranges);
        }
        allocator.free(index.functions);
        for (index.files) |*file| file.local_bindings.deinit(allocator);
        allocator.free(index.files);
        allocator.free(index.import_aliases);
        for (index.owned_tokens) |tokens| allocator.free(tokens);
        allocator.free(index.owned_tokens);
        for (index.owned_member_paths.items) |path| allocator.free(path);
        index.owned_member_paths.deinit(allocator);
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
        const method = callableBaseName(callable);
        if (std.mem.eql(u8, method, "dupe") or std.mem.eql(u8, method, "dupeZ")) return .borrowed;
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
        const receiver = callable[0..separator];
        const target_file = if (index.sourceHasLocalBinding(source, receiver))
            null
        else
            index.importedFile(source, receiver);
        const file_index = target_file orelse index.fileIndexForSource(source) orelse return .unknown;
        const function = index.uniqueFunctionInFile(file_index, callable[separator + 1 ..]) orelse return .unknown;
        const function_parameter = parameter + @intFromBool(target_file == null and functionCallHasReceiver(function, receiver));
        if (function.unresolved or function_parameter >= function.parameter_effects.len) return .unknown;
        return function.parameter_effects[function_parameter];
    }

    pub fn parameterEscapesForCall(
        index: Index,
        source: []const u8,
        callable: []const u8,
        parameter: usize,
    ) bool {
        const separator = std.mem.indexOfScalar(u8, callable, '.') orelse {
            if (index.sourceHasLocalBinding(source, callable)) return false;
            const file_index = index.fileIndexForSource(source) orelse return false;
            const function = index.uniqueFunctionInFile(file_index, callable) orelse return false;
            return !function.unresolved and parameter < function.parameter_escapes.len and function.parameter_escapes[parameter];
        };
        if (std.mem.indexOfScalar(u8, callable[separator + 1 ..], '.') != null) return false;
        const receiver = callable[0..separator];
        const target_file = if (index.sourceHasLocalBinding(source, receiver))
            null
        else
            index.importedFile(source, receiver);
        const file_index = target_file orelse index.fileIndexForSource(source) orelse return false;
        const function = index.uniqueFunctionInFile(file_index, callable[separator + 1 ..]) orelse return false;
        const function_parameter = parameter + @intFromBool(target_file == null and functionCallHasReceiver(function, receiver));
        return !function.unresolved and function_parameter < function.parameter_escapes.len and function.parameter_escapes[function_parameter];
    }

    pub fn ownedReturn(index: Index, callable: []const u8) ?OwnedReturn {
        if (index.acquireContract(callable)) |contract| return .{ .release = callableBaseName(contract.release) };
        const function = index.uniqueFunction(callable) orelse return null;
        return ownedReturnFromFunction(function);
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
            const target_file = if (index.sourceHasLocalBinding(source, alias))
                null
            else
                index.importedFile(source, alias);
            const file_index = target_file orelse index.fileIndexForSource(source) orelse return null;
            const function = index.uniqueFunctionInFile(file_index, name) orelse local: {
                if (target_file != null) return null;
                const container_name = index.receiverContainerName(source, alias) orelse return null;
                break :local index.functionInContainer(file_index, container_name, name) orelse return null;
            };
            if (target_file == null and function.parameter_names.len == 0) return null;
            const owned = ownedReturnFromFunction(function) orelse return null;
            if (target_file != null or !functionCallHasReceiver(function, alias) or owned.allocator_parameter == null) return owned;
            return .{
                .release = owned.release,
                .allocator_parameter = if (owned.allocator_parameter.? == 0) null else owned.allocator_parameter.? - 1,
                .allocator_parameter_member = owned.allocator_parameter_member,
            };
        } else if (index.sourceHasLocalBinding(source, name)) return null;
        const file_index = index.fileIndexForSource(source) orelse return null;
        const function = index.uniqueFunctionInFile(file_index, name) orelse return null;
        return ownedReturnFromFunction(function);
    }

    pub fn borrowedReturnCall(
        index: Index,
        source: []const u8,
        receiver: ?[]const u8,
        name: []const u8,
    ) ?BorrowedReturn {
        const function = index.functionForCall(source, receiver, name) orelse return null;
        if (function.unresolved) return null;
        return function.borrowed_return;
    }

    pub fn partialIoReturnCall(
        index: Index,
        source: []const u8,
        receiver: ?[]const u8,
        name: []const u8,
    ) PartialIo {
        const function = index.functionForCall(source, receiver, name) orelse return .none;
        if (function.unresolved) return .none;
        return function.partial_io;
    }

    pub fn containerMutationCall(
        index: Index,
        source: []const u8,
        receiver: ?[]const u8,
        name: []const u8,
    ) ?ContainerMutation {
        const function = index.functionForCall(source, receiver, name) orelse return null;
        if (function.unresolved) return null;
        return function.container_mutation;
    }

    pub fn hasImportedLifecycleFacts(index: Index, source: []const u8) bool {
        for (index.import_aliases) |import_alias| {
            if (import_alias.source.ptr != source.ptr or import_alias.source.len != source.len) continue;
            const file = index.fileForIndex(import_alias.target_file_index) orelse continue;
            for (index.functions[file.function_start..file.function_end]) |function| {
                if (ownedReturnFromFunction(function) != null) return true;
                if (function.unresolved) continue;
                for (function.parameter_effects) |effect| switch (effect) {
                    .borrowed, .released => return true,
                    .escaped, .unknown => {},
                };
            }
        }
        return false;
    }

    pub fn functionContaining(
        index: Index,
        source: []const u8,
        token_index: usize,
    ) ?FunctionSummary {
        const file = index.fileForSource(source) orelse return null;
        var selected: ?FunctionSummary = null;
        for (index.functions[file.function_start..file.function_end]) |function| {
            if (token_index <= function.body_start or token_index >= function.body_end) continue;
            if (selected == null or function.body_start > selected.?.body_start) selected = function;
        }
        const function = selected orelse return null;
        const unique = index.uniqueFunctionInFile(file.file_index, function.name) orelse return null;
        if (unique.body_start != function.body_start) return null;
        return function;
    }

    fn ownedReturnForCall(index: Index, source: []const u8, callable: []const u8) ?OwnedReturn {
        if (index.acquireContract(callable)) |contract| {
            return .{ .release = callableBaseName(contract.release) };
        }
        const separator = std.mem.indexOfScalar(u8, callable, '.') orelse {
            if (index.sourceHasLocalBinding(source, callable)) return null;
            const file_index = index.fileIndexForSource(source) orelse return null;
            const function = index.uniqueFunctionInFile(file_index, callable) orelse return null;
            return ownedReturnFromFunction(function);
        };
        if (std.mem.indexOfScalar(u8, callable[separator + 1 ..], '.') != null) return null;
        const receiver = callable[0..separator];
        const target_file = if (index.sourceHasLocalBinding(source, receiver))
            index.fileIndexForSource(source) orelse return null
        else
            index.importedFile(source, receiver) orelse return null;
        const function_name = callable[separator + 1 ..];
        const function = index.uniqueFunctionInFile(target_file, function_name) orelse local: {
            if (!index.sourceHasLocalBinding(source, receiver)) return null;
            const container_name = index.receiverContainerName(source, receiver) orelse return null;
            break :local index.functionInContainer(target_file, container_name, function_name) orelse return null;
        };
        return ownedReturnFromFunction(function);
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

    fn functionHasReceiver(function: FunctionSummary) bool {
        return function.parameter_names.len != 0 and std.mem.eql(u8, function.parameter_names[0], "self");
    }

    fn functionCallHasReceiver(function: FunctionSummary, receiver: []const u8) bool {
        if (functionHasReceiver(function)) return true;
        return function.parameter_names.len != 0 and receiver.len != 0 and std.ascii.isLower(receiver[0]);
    }

    fn functionForCall(index: Index, source: []const u8, receiver: ?[]const u8, name: []const u8) ?FunctionSummary {
        if (receiver) |call_receiver| {
            if (!index.sourceHasLocalBinding(source, call_receiver)) {
                if (index.importedFile(source, call_receiver)) |target_file| {
                    return index.uniqueFunctionInFile(target_file, name);
                }
            }
            const file_index = index.fileIndexForSource(source) orelse return null;
            const function = index.uniqueFunctionInFile(file_index, name) orelse return null;
            if (function.parameter_names.len == 0) return null;
            return function;
        }
        if (index.sourceHasLocalBinding(source, name)) return null;
        const file_index = index.fileIndexForSource(source) orelse return null;
        return index.uniqueFunctionInFile(file_index, name);
    }

    fn uniqueFunctionInFile(index: Index, file_index: usize, name: []const u8) ?FunctionSummary {
        const file = index.fileForIndex(file_index) orelse return null;
        var selected: ?FunctionSummary = null;
        for (index.functions[file.function_start..file.function_end]) |function| {
            if (!std.mem.eql(u8, function.name, name)) continue;
            if (selected != null) return null;
            selected = function;
        }
        return selected;
    }

    fn functionInContainer(
        index: Index,
        file_index: usize,
        container_name: []const u8,
        function_name: []const u8,
    ) ?FunctionSummary {
        const file = index.fileForIndex(file_index) orelse return null;
        var selected: ?FunctionSummary = null;
        for (index.functions[file.function_start..file.function_end]) |function| {
            if (!std.mem.eql(u8, function.name, function_name) or function.container_name == null or
                !std.mem.eql(u8, function.container_name.?, container_name)) continue;
            if (selected != null) return null;
            selected = function;
        }
        return selected;
    }

    fn receiverContainerName(
        index: Index,
        source: []const u8,
        receiver: []const u8,
    ) ?[]const u8 {
        if (receiver.len != 0 and std.ascii.isUpper(receiver[0])) return receiver;
        const file = index.fileForSource(source) orelse return null;
        if (file.function_start == file.function_end) return null;
        const tokens = index.functions[file.function_start].tokens;
        var selected: ?[]const u8 = null;
        for (tokens, 0..) |token, receiver_index| {
            if (token.tag != .identifier or !std.mem.eql(u8, tokenText(source, token), receiver) or
                receiver_index + 2 >= tokens.len or tokens[receiver_index + 1].tag != .colon) continue;
            var type_name: ?[]const u8 = null;
            var type_index = receiver_index + 2;
            while (type_index < tokens.len and tokens[type_index].tag != .comma and
                tokens[type_index].tag != .r_paren) : (type_index += 1)
            {
                if (tokens[type_index].tag == .identifier) type_name = tokenText(source, tokens[type_index]);
            }
            const candidate = type_name orelse continue;
            if (selected) |known| {
                if (!std.mem.eql(u8, known, candidate)) return null;
            } else {
                selected = candidate;
            }
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
        return (index.fileForSource(source) orelse return null).file_index;
    }

    fn sourceHasLocalBinding(index: Index, source: []const u8, name: []const u8) bool {
        const file = index.fileForSource(source) orelse return false;
        return file.local_bindings.contains(name);
    }

    fn fileForSource(index: Index, source: []const u8) ?FileSummary {
        for (index.files) |file| {
            if (file.source.ptr == source.ptr and file.source.len == source.len) return file;
        }
        return null;
    }

    fn fileForIndex(index: Index, file_index: usize) ?FileSummary {
        for (index.files) |file| if (file.file_index == file_index) return file;
        return null;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    sources: []const Source,
    configuration: types.Configuration,
) !Index {
    var functions: std.ArrayList(FunctionSummary) = .empty;
    var files: std.ArrayList(FileSummary) = .empty;
    var import_aliases: std.ArrayList(ImportAlias) = .empty;
    var owned_tokens: std.ArrayList([]const std.zig.Token) = .empty;
    errdefer {
        for (functions.items) |function| {
            allocator.free(function.parameter_names);
            allocator.free(function.parameter_effects);
            allocator.free(function.parameter_escapes);
            allocator.free(function.nested_function_ranges);
        }
        functions.deinit(allocator);
        for (files.items) |*file| file.local_bindings.deinit(allocator);
        files.deinit(allocator);
        import_aliases.deinit(allocator);
        for (owned_tokens.items) |tokens| allocator.free(tokens);
        owned_tokens.deinit(allocator);
    }
    for (sources) |source_file| {
        const tokens = source_file.tokens orelse tokens: {
            const allocated = try tokenize(allocator, source_file.source);
            owned_tokens.append(allocator, allocated) catch |err| {
                allocator.free(allocated);
                return err;
            };
            break :tokens allocated;
        };
        const function_start = functions.items.len;
        try collectFunctions(allocator, source_file, tokens, &functions);
        var local_bindings: std.StringHashMapUnmanaged(void) = .empty;
        errdefer local_bindings.deinit(allocator);
        for (functions.items[function_start..]) |function| {
            for (function.parameter_names) |parameter| try local_bindings.put(allocator, parameter, {});
        }
        for (tokens, 0..) |token, token_index| {
            if ((token.tag != .keyword_const and token.tag != .keyword_var) or
                token_index + 1 >= tokens.len or tokens[token_index + 1].tag != .identifier) continue;
            if (token_index + 3 < tokens.len and tokens[token_index + 2].tag == .equal and
                tokens[token_index + 3].tag == .builtin and
                std.mem.eql(u8, tokenText(source_file.source, tokens[token_index + 3]), "@import")) continue;
            try local_bindings.put(allocator, tokenText(source_file.source, tokens[token_index + 1]), {});
        }
        try collectImportAliases(allocator, source_file, tokens, sources, &import_aliases);
        try files.append(allocator, .{
            .file_index = source_file.file_index,
            .source = source_file.source,
            .function_start = function_start,
            .function_end = functions.items.len,
            .local_bindings = local_bindings,
        });
    }
    try collectNestedFunctionRanges(allocator, functions.items);
    var index: Index = index: {
        const owned_functions = try functions.toOwnedSlice(allocator);
        errdefer {
            for (owned_functions) |function| {
                allocator.free(function.parameter_names);
                allocator.free(function.parameter_effects);
                allocator.free(function.parameter_escapes);
                allocator.free(function.nested_function_ranges);
            }
            allocator.free(owned_functions);
        }
        const owned_files = try files.toOwnedSlice(allocator);
        errdefer {
            for (owned_files) |*file| file.local_bindings.deinit(allocator);
            allocator.free(owned_files);
        }
        const owned_import_aliases = try import_aliases.toOwnedSlice(allocator);
        errdefer allocator.free(owned_import_aliases);
        const all_owned_tokens = try owned_tokens.toOwnedSlice(allocator);
        errdefer {
            for (all_owned_tokens) |tokens| allocator.free(tokens);
            allocator.free(all_owned_tokens);
        }
        break :index .{
            .functions = owned_functions,
            .files = owned_files,
            .resource_contracts = configuration.resource_contracts,
            .arena_allocator_contracts = configuration.arena_allocator_contracts,
            .import_aliases = owned_import_aliases,
            .owned_tokens = all_owned_tokens,
        };
    };
    errdefer index.deinit(allocator);
    try markRecursiveFunctions(allocator, index);
    inferDirectEffects(index, configuration);
    for (0..index.functions.len) |_| {
        if (!try propagateCallEffects(allocator, &index)) break;
    }
    return index;
}

fn collectNestedFunctionRanges(allocator: std.mem.Allocator, functions: []FunctionSummary) !void {
    const nested_ranges = try allocator.alloc(std.ArrayList(TokenRange), functions.len);
    defer allocator.free(nested_ranges);
    for (nested_ranges) |*ranges| ranges.* = .empty;
    errdefer for (nested_ranges) |*ranges| ranges.deinit(allocator);
    for (functions) |candidate| {
        const parent = candidate.parent_function orelse continue;
        try nested_ranges[parent].append(allocator, .{ .start = candidate.body_start, .end = candidate.body_end });
    }
    for (functions, nested_ranges) |*function, *ranges| {
        function.nested_function_ranges = try ranges.toOwnedSlice(allocator);
    }
}

fn collectFunctions(
    allocator: std.mem.Allocator,
    source_file: Source,
    tokens: []const std.zig.Token,
    functions: *std.ArrayList(FunctionSummary),
) !void {
    var function_stack: std.ArrayList(usize) = .empty;
    defer function_stack.deinit(allocator);
    for (tokens, 0..) |token, fn_index| {
        if (token.tag != .keyword_fn or fn_index + 2 >= tokens.len or
            tokens[fn_index + 1].tag != .identifier or tokens[fn_index + 2].tag != .l_paren) continue;
        const parameters_end = matchingToken(tokens, fn_index + 2) orelse continue;
        const body_start = syntax_scope.functionBodyAfterParameters(tokens, parameters_end) orelse continue;
        const body_end = matchingToken(tokens, body_start) orelse continue;
        const parameters = try collectParameterNames(
            allocator,
            source_file.source,
            tokens,
            fn_index + 3,
            parameters_end,
        );
        errdefer allocator.free(parameters);
        const effects = try allocator.alloc(ParameterEffect, parameters.len);
        errdefer allocator.free(effects);
        @memset(effects, .borrowed);
        const escapes = try allocator.alloc(bool, parameters.len);
        errdefer allocator.free(escapes);
        @memset(escapes, false);
        while (function_stack.getLastOrNull()) |candidate| {
            if (functions.items[candidate].body_end > fn_index) break;
            _ = function_stack.pop();
        }
        const parent_function = function_stack.getLastOrNull();
        const function_index = functions.items.len;
        try function_stack.append(allocator, function_index);
        try functions.append(allocator, .{
            .file_index = source_file.file_index,
            .declaration_start = fn_index,
            .name = tokenText(source_file.source, tokens[fn_index + 1]),
            .container_name = containerNameContaining(source_file.source, tokens, fn_index),
            .parameter_names = parameters,
            .parameter_effects = effects,
            .parameter_escapes = escapes,
            .source = source_file.source,
            .tokens = tokens,
            .return_type_start = parameters_end + 1,
            .body_start = body_start,
            .body_end = body_end,
            .parent_function = parent_function,
            .externally_visible = visible: {
                var modifier_index = fn_index;
                while (modifier_index > 0) {
                    modifier_index -= 1;
                    switch (tokens[modifier_index].tag) {
                        .keyword_pub, .keyword_export => break :visible true,
                        .semicolon, .l_brace, .r_brace => break :visible false,
                        else => {},
                    }
                }
                break :visible false;
            },
        });
    }
}

fn containerNameContaining(
    source: []const u8,
    tokens: []const std.zig.Token,
    target: usize,
) ?[]const u8 {
    var selected: ?[]const u8 = null;
    var selected_opening: usize = 0;
    for (tokens[0..target], 0..) |token, declaration_index| {
        if (token.tag != .keyword_const or declaration_index + 4 >= target or
            tokens[declaration_index + 1].tag != .identifier or tokens[declaration_index + 2].tag != .equal or
            tokens[declaration_index + 3].tag != .keyword_struct or tokens[declaration_index + 4].tag != .l_brace) continue;
        const closing = matchingToken(tokens, declaration_index + 4) orelse continue;
        if (closing <= target or declaration_index + 4 < selected_opening) continue;
        selected = tokenText(source, tokens[declaration_index + 1]);
        selected_opening = declaration_index + 4;
    }
    return selected;
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
    errdefer names.deinit(allocator);
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
                if (tokenBelongsToNestedFunction(function.*, use_index)) continue;
                if (token.tag != .identifier or !std.mem.eql(u8, tokenText(function.source, token), parameter_name)) continue;
                if (useIsDirectRelease(function.*, use_index, configuration.resource_contracts)) {
                    mergeEffect(
                        &function.parameter_effects[parameter],
                        if (effectUseIsUnconditional(function.*, use_index)) .released else .unknown,
                    );
                    continue;
                }
                if (parameterUseIsCopied(function.*, use_index)) continue;
                if ((statementStartsWith(function.tokens, use_index, .keyword_return) or
                    useIsStored(function.*, use_index)) and parameterUseDefinitelyEscapes(function.*, use_index))
                {
                    function.parameter_escapes[parameter] = true;
                    mergeEffect(&function.parameter_effects[parameter], .escaped);
                }
            }
            if (borrowedAliasEscapes(function.*, parameter_name)) {
                function.parameter_escapes[parameter] = true;
            }
        }
        if (directOwnedReturn(function.*, configuration.resource_contracts)) |owned| {
            function.returns_owned = true;
            function.return_release = owned.release;
            function.allocator_parameter = owned.allocator_parameter;
            function.allocator_parameter_member = owned.allocator_parameter_member;
        } else {
            function.borrowed_return = directBorrowedReturn(function.*);
        }
        function.partial_io = directPartialIoReturn(function.*);
        function.container_mutation = directContainerMutation(function.*);
    }
}

fn parameterUseIsCopied(function: FunctionSummary, use_index: usize) bool {
    var call_open = use_index;
    while (call_open > function.body_start + 1) {
        call_open -= 1;
        switch (function.tokens[call_open].tag) {
            .l_paren => {
                const call_end = matchingToken(function.tokens, call_open) orelse continue;
                if (call_end <= use_index) continue;
                const callable = callableBefore(function.source, function.tokens, call_open) orelse return false;
                const method = callableBaseName(callable);
                return std.mem.eql(u8, method, "dupe") or std.mem.eql(u8, method, "dupeZ");
            },
            .semicolon, .l_brace => return false,
            else => {},
        }
    }
    return false;
}

fn directContainerMutation(function: FunctionSummary) ?ContainerMutation {
    const methods = [_][]const u8{
        "append",
        "appendNTimes",
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
        "put",
        "putNoClobber",
        "fetchPut",
        "getOrPut",
        "rehash",
    };
    for (function.parameter_names, 0..) |parameter_name, parameter| {
        for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, use_index| {
            if (tokenBelongsToNestedFunction(function, use_index) or token.tag != .identifier or
                !std.mem.eql(u8, tokenText(function.source, token), parameter_name) or use_index + 3 >= function.body_end or
                function.tokens[use_index + 1].tag != .period or function.tokens[use_index + 2].tag != .identifier) continue;
            const direct_method = function.tokens[use_index + 3].tag == .l_paren;
            if (!direct_method and (use_index + 5 >= function.body_end or function.tokens[use_index + 3].tag != .period or
                function.tokens[use_index + 4].tag != .identifier or function.tokens[use_index + 5].tag != .l_paren)) continue;
            const method_index = use_index + @as(usize, if (direct_method) 2 else 4);
            const method = tokenText(function.source, function.tokens[method_index]);
            for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) {
                return .{
                    .parameter = parameter,
                    .field = if (direct_method) "" else tokenText(function.source, function.tokens[use_index + 2]),
                    .method = method,
                };
            };
        }
    }
    return null;
}

fn borrowedAliasEscapes(function: FunctionSummary, parameter_name: []const u8) bool {
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, declaration_index| {
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= function.body_end or
            function.tokens[declaration_index + 1].tag != .identifier) continue;
        const declaration_end = statementEnd(function.tokens, declaration_index, function.body_end);
        var equal_index = declaration_index + 2;
        while (equal_index < declaration_end and function.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
        if (equal_index == declaration_end or !knownBorrowingAlias(function, parameter_name, equal_index + 1, declaration_end)) continue;
        const scope_end = enclosingScopeEnd(function.tokens, declaration_index) orelse continue;
        const alias = tokenText(function.source, function.tokens[declaration_index + 1]);
        for (function.tokens[declaration_end + 1 .. @min(scope_end, function.body_end)], declaration_end + 1..) |use, use_index| {
            if (use.tag == .identifier and std.mem.eql(u8, tokenText(function.source, use), alias) and
                parameterUseDefinitelyEscapes(function, use_index)) return true;
        }
    }
    return false;
}

fn knownBorrowingAlias(function: FunctionSummary, parameter_name: []const u8, start: usize, end: usize) bool {
    var parameter_use: ?usize = null;
    for (function.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and std.mem.eql(u8, tokenText(function.source, token), parameter_name)) {
            parameter_use = index;
        }
    }
    const use_index = parameter_use orelse return false;
    if (start + 1 == end and use_index == start) return true;
    for (function.tokens[start..end], start..) |token, index| {
        if (token.tag == .identifier and index + 1 < end and function.tokens[index + 1].tag == .l_paren) {
            const callable = callableBefore(function.source, function.tokens, index + 1) orelse continue;
            if (std.mem.eql(u8, callable, "std.mem.trim") or std.mem.eql(u8, callable, "std.mem.trimLeft") or
                std.mem.eql(u8, callable, "std.mem.trimRight")) return true;
        }
        if (index > use_index and std.mem.eql(u8, tokenText(function.source, token), "..")) return true;
    }
    return false;
}

fn parameterUseDefinitelyEscapes(function: FunctionSummary, use_index: usize) bool {
    if (use_index + 2 < function.body_end and function.tokens[use_index + 1].tag == .period and
        std.mem.eql(u8, tokenText(function.source, function.tokens[use_index + 2]), "len")) return false;
    if (use_index + 1 < function.body_end and function.tokens[use_index + 1].tag == .l_bracket) {
        const bracket_end = matchingToken(function.tokens, use_index + 1) orelse return false;
        var is_slice = false;
        for (function.tokens[use_index + 2 .. bracket_end]) |token| {
            if (token.tag == .ellipsis2 or token.tag == .ellipsis3) {
                is_slice = true;
                break;
            }
        }
        if (!is_slice) return false;
    }
    if (statementStartsWith(function.tokens, use_index, .keyword_return)) {
        return use_index + 2 >= function.body_end or function.tokens[use_index + 1].tag != .period or
            !std.mem.eql(u8, tokenText(function.source, function.tokens[use_index + 2]), "len");
    }
    var equal_index = use_index;
    while (equal_index > function.body_start + 1) {
        equal_index -= 1;
        switch (function.tokens[equal_index].tag) {
            .equal => break,
            .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    if (function.tokens[equal_index].tag != .equal) return false;
    var cursor = equal_index;
    while (cursor > function.body_start + 1) {
        cursor -= 1;
        switch (function.tokens[cursor].tag) {
            .period, .l_bracket => return true,
            .keyword_const, .keyword_var, .semicolon, .l_brace, .r_brace => return false,
            else => {},
        }
    }
    return false;
}

fn directBorrowedReturn(function: FunctionSummary) ?BorrowedReturn {
    const kind = declaredBorrowKind(function) orelse return null;
    var selected: ?BorrowedReturn = null;
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, return_index| {
        if (tokenBelongsToNestedFunction(function, return_index) or token.tag != .keyword_return) continue;
        const return_end = statementEnd(function.tokens, return_index, function.body_end);
        if (return_index + 1 < return_end and function.tokens[return_index + 1].tag == .keyword_error) continue;
        const borrowed = borrowed: {
            const direct_parameter = return_index + 2 == return_end and
                function.tokens[return_index + 1].tag == .identifier;
            const sliced_parameter = return_index + 2 < return_end and
                function.tokens[return_index + 1].tag == .identifier and
                function.tokens[return_index + 2].tag == .l_bracket and
                (matchingToken(function.tokens, return_index + 2) orelse return_end) + 1 == return_end;
            if (direct_parameter or sliced_parameter) {
                const returned_name = tokenText(function.source, function.tokens[return_index + 1]);
                for (function.parameter_names, 0..) |parameter_name, parameter| {
                    if (std.mem.eql(u8, returned_name, parameter_name)) {
                        break :borrowed BorrowedReturn{ .parameter = parameter, .field = "", .kind = kind };
                    }
                }
            }
            for (function.parameter_names, 0..) |parameter_name, parameter| {
                for (function.tokens[return_index + 1 .. return_end], return_index + 1..) |candidate, use_index| {
                    if (candidate.tag != .identifier or !std.mem.eql(u8, tokenText(function.source, candidate), parameter_name) or
                        use_index + 2 >= return_end or function.tokens[use_index + 1].tag != .period or
                        function.tokens[use_index + 2].tag != .identifier) continue;
                    const first_field = tokenText(function.source, function.tokens[use_index + 2]);
                    const field = if (std.mem.eql(u8, first_field, "items")) "" else first_field;
                    break :borrowed BorrowedReturn{ .parameter = parameter, .field = field, .kind = kind };
                }
            }
            break :borrowed null;
        } orelse return null;
        if (selected) |known| {
            if (known.parameter != borrowed.parameter or known.kind != borrowed.kind or
                !std.mem.eql(u8, known.field, borrowed.field)) return null;
        } else {
            selected = borrowed;
        }
    }
    return selected;
}

fn declaredBorrowKind(function: FunctionSummary) ?BorrowKind {
    var pointer = false;
    var index = function.return_type_start;
    while (index < function.body_start) : (index += 1) {
        if (function.tokens[index].tag == .l_bracket and index + 1 < function.body_start and
            function.tokens[index + 1].tag == .r_bracket) return .slice;
        if (function.tokens[index].tag == .asterisk) pointer = true;
    }
    return if (pointer) .pointer else null;
}

fn directPartialIoReturn(function: FunctionSummary) PartialIo {
    var selected: PartialIo = .none;
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, return_index| {
        if (tokenBelongsToNestedFunction(function, return_index) or token.tag != .keyword_return) continue;
        const return_end = statementEnd(function.tokens, return_index, function.body_end);
        if (return_index + 1 < return_end and function.tokens[return_index + 1].tag == .keyword_error) continue;
        var returned: PartialIo = .none;
        for (function.tokens[return_index + 1 .. return_end], return_index + 1..) |candidate, method_index| {
            if (candidate.tag != .identifier or method_index == 0 or method_index + 1 >= return_end or
                function.tokens[method_index - 1].tag != .period or function.tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = matchingToken(function.tokens, method_index + 1) orelse continue;
            if (call_end + 1 != return_end) continue;
            const method = tokenText(function.source, candidate);
            if (partialReadMethod(method)) returned = .read;
            if (std.mem.eql(u8, method, "write")) returned = .write;
            break;
        }
        if (returned == .none) return .none;
        if (selected != .none and selected != returned) return .none;
        selected = returned;
    }
    return selected;
}

fn partialReadMethod(method: []const u8) bool {
    const methods = [_][]const u8{ "read", "readVec", "readSliceShort", "pread", "readv", "preadv" };
    for (methods) |candidate| if (std.mem.eql(u8, method, candidate)) return true;
    return false;
}

const DirectOwnedReturn = struct {
    release: []const u8,
    allocator_parameter: ?usize = null,
    allocator_parameter_member: ?[]const u8 = null,
};

fn directOwnedReturn(function: FunctionSummary, contracts: []const types.ResourceContract) ?DirectOwnedReturn {
    var selected: ?DirectOwnedReturn = null;
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, token_index| {
        if (tokenBelongsToNestedFunction(function, token_index)) continue;
        if (token.tag != .keyword_return) continue;
        const statement_end = statementEnd(function.tokens, token_index, function.body_end);
        if (token_index + 1 < statement_end and function.tokens[token_index + 1].tag == .keyword_error) continue;
        const possible_owned: ?DirectOwnedReturn = owned: {
            const returns_binding = token_index + 2 == statement_end and function.tokens[token_index + 1].tag == .identifier;
            const returns_binding_slice = token_index + 2 < statement_end and
                function.tokens[token_index + 1].tag == .identifier and function.tokens[token_index + 2].tag == .l_bracket and
                (matchingToken(function.tokens, token_index + 2) orelse statement_end) + 1 == statement_end;
            if (returns_binding or returns_binding_slice) {
                const binding_name = tokenText(function.source, function.tokens[token_index + 1]);
                if (directOwnedBinding(function, token_index, binding_name, contracts)) |binding_owned| break :owned binding_owned;
            }
            var call_open = token_index + 1;
            while (call_open < statement_end) : (call_open += 1) {
                if (function.tokens[call_open].tag != .l_paren) continue;
                const callable = callableBefore(function.source, function.tokens, call_open) orelse continue;
                const call_end = matchingToken(function.tokens, call_open) orelse continue;
                if (call_end > statement_end) continue;
                for (contracts) |contract| if (callableMatches(callable, contract.acquire)) {
                    break :owned .{ .release = callableBaseName(contract.release) };
                };
                const release = allocationReleaseForCallable(callable) orelse continue;
                const provenance = allocatorProvenance(function, callable, call_open, call_end);
                break :owned .{
                    .release = release,
                    .allocator_parameter = if (provenance) |known| known.parameter else null,
                    .allocator_parameter_member = if (provenance) |known| known.member else null,
                };
            }
            break :owned null;
        };
        const owned = possible_owned orelse return null;
        if (selected) |known| {
            if (!std.mem.eql(u8, known.release, owned.release) or
                known.allocator_parameter != owned.allocator_parameter or
                !optionalTextEql(known.allocator_parameter_member, owned.allocator_parameter_member)) return null;
        } else {
            selected = owned;
        }
    }
    return selected;
}

fn directOwnedBinding(
    function: FunctionSummary,
    return_index: usize,
    binding_name: []const u8,
    contracts: []const types.ResourceContract,
) ?DirectOwnedReturn {
    const transferred_before_return = transferred: {
        const retaining_methods = [_][]const u8{
            "append",
            "appendAssumeCapacity",
            "insert",
            "put",
            "putAssumeCapacity",
        };
        for (function.tokens[function.body_start + 1 .. return_index], function.body_start + 1..) |token, call_open| {
            if (tokenBelongsToNestedFunction(function, call_open) or token.tag != .l_paren) continue;
            const call_end = matchingToken(function.tokens, call_open) orelse continue;
            if (call_end >= return_index or exactArgumentIndex(
                function.source,
                function.tokens,
                binding_name,
                call_open + 1,
                call_end,
            ) == null) continue;
            const callable = callableBefore(function.source, function.tokens, call_open) orelse {
                if (call_open != 0 and function.tokens[call_open - 1].tag == .builtin and
                    std.mem.eql(u8, tokenText(function.source, function.tokens[call_open - 1]), "@call")) break :transferred true;
                continue;
            };
            const method = callableBaseName(callable);
            for (retaining_methods) |candidate| if (std.mem.eql(u8, method, candidate)) break :transferred true;
        }
        for (function.tokens[function.body_start + 1 .. return_index], function.body_start + 1..) |token, use_index| {
            if (tokenBelongsToNestedFunction(function, use_index) or token.tag != .identifier or
                !std.mem.eql(u8, tokenText(function.source, token), binding_name)) continue;
            if (useIsStored(function, use_index) and parameterUseDefinitelyEscapes(function, use_index)) break :transferred true;
        }
        break :transferred false;
    };
    if (transferred_before_return) return null;
    if (errdeferReleaseForBinding(function, binding_name, return_index)) |release| {
        return .{ .release = release };
    }
    var declaration_index = return_index;
    while (declaration_index > function.body_start + 1) {
        declaration_index -= 1;
        const token = function.tokens[declaration_index];
        if ((token.tag != .keyword_const and token.tag != .keyword_var) or declaration_index + 3 >= return_index or
            function.tokens[declaration_index + 1].tag != .identifier or
            !std.mem.eql(u8, tokenText(function.source, function.tokens[declaration_index + 1]), binding_name)) continue;
        const scope_end = enclosingScopeEnd(function.tokens, declaration_index) orelse continue;
        if (scope_end < return_index) continue;
        const declaration_end = statementEnd(function.tokens, declaration_index, return_index);
        if (declaration_end >= return_index) continue;
        var equal_index = declaration_index + 2;
        while (equal_index < declaration_end and function.tokens[equal_index].tag != .equal) : (equal_index += 1) {}
        if (equal_index == declaration_end) continue;
        var call_open = equal_index + 1;
        while (call_open < declaration_end and function.tokens[call_open].tag != .l_paren) : (call_open += 1) {}
        if (call_open == declaration_end) continue;
        const callable = callableBefore(function.source, function.tokens, call_open) orelse continue;
        const call_end = matchingToken(function.tokens, call_open) orelse continue;
        if (call_end > declaration_end) continue;
        for (contracts) |contract| if (callableMatches(callable, contract.acquire)) {
            return .{ .release = callableBaseName(contract.release) };
        };
        const release = allocationReleaseForCallable(callable) orelse continue;
        const provenance = allocatorProvenance(function, callable, call_open, call_end);
        return .{
            .release = release,
            .allocator_parameter = if (provenance) |known| known.parameter else null,
            .allocator_parameter_member = if (provenance) |known| known.member else null,
        };
    }
    return null;
}

fn errdeferReleaseForBinding(
    function: FunctionSummary,
    binding_name: []const u8,
    return_index: usize,
) ?[]const u8 {
    var defer_index = return_index;
    while (defer_index > function.body_start + 1) {
        defer_index -= 1;
        const token = function.tokens[defer_index];
        if (token.tag != .keyword_errdefer) continue;
        const scope_end = enclosingScopeEnd(function.tokens, defer_index) orelse continue;
        if (scope_end < return_index) continue;
        const statement_end = statementEnd(function.tokens, defer_index, return_index);
        if (statement_end >= return_index) continue;
        for (function.tokens[defer_index + 1 .. statement_end], defer_index + 1..) |candidate, method_index| {
            if (candidate.tag == .keyword_if) break;
            if (candidate.tag != .identifier) continue;
            const method = tokenText(function.source, candidate);
            const recognized = std.mem.eql(u8, method, "deinit") or std.mem.eql(u8, method, "free") or
                std.mem.eql(u8, method, "destroy") or std.mem.eql(u8, method, "close") or
                std.mem.eql(u8, method, "release");
            if (!recognized) continue;
            if (method_index >= 2 and function.tokens[method_index - 1].tag == .period and
                std.mem.eql(u8, tokenText(function.source, function.tokens[method_index - 2]), binding_name)) return method;
            if (method_index + 1 >= statement_end or function.tokens[method_index + 1].tag != .l_paren) continue;
            const call_end = matchingToken(function.tokens, method_index + 1) orelse continue;
            for (function.tokens[method_index + 2 .. @min(call_end, statement_end)]) |argument| {
                if (argument.tag == .identifier and std.mem.eql(u8, tokenText(function.source, argument), binding_name)) return method;
            }
        }
    }
    return null;
}

const AllocatorProvenance = struct {
    parameter: usize,
    member: ?[]const u8 = null,
};

fn allocatorProvenance(function: FunctionSummary, callable: []const u8, call_open: usize, call_end: usize) ?AllocatorProvenance {
    if (owned_call.standardAllocatorArgument(callable)) |argument_index| {
        if (parameterProvenanceAtArgument(function, call_open + 1, call_end, argument_index)) |provenance| {
            return provenance;
        }
        const separator = std.mem.lastIndexOfScalar(u8, callable, '.') orelse return null;
        if (std.mem.eql(u8, callable[separator + 1 ..], "toOwnedSlice")) {
            const receiver = callable[0..separator];
            if (std.mem.indexOfScalar(u8, receiver, '.') == null) {
                return localAllocatorProvenance(function, receiver, call_open);
            }
        }
        return null;
    }
    const separator = std.mem.lastIndexOfScalar(u8, callable, '.') orelse return null;
    const receiver = callable[0..separator];
    for (function.parameter_names, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter, receiver)) return .{ .parameter = index };
        if (receiver.len > parameter.len + 1 and std.mem.startsWith(u8, receiver, parameter) and
            receiver[parameter.len] == '.')
        {
            return .{ .parameter = index, .member = receiver[parameter.len + 1 ..] };
        }
    }
    if (std.mem.indexOfScalar(u8, receiver, '.') == null) {
        if (localAllocatorProvenance(function, receiver, call_open)) |provenance| return provenance;
    }
    for (function.parameter_names, 0..) |parameter, index| {
        if (std.ascii.indexOfIgnoreCase(parameter, "alloc") == null and
            !std.mem.eql(u8, parameter, "gpa") and !std.mem.eql(u8, parameter, "arena")) continue;
        if (exactArgumentIndex(function.source, function.tokens, parameter, call_open + 1, call_end) != null) {
            return .{ .parameter = index };
        }
    }
    return null;
}

fn localAllocatorProvenance(
    function: FunctionSummary,
    binding_name: []const u8,
    before: usize,
) ?AllocatorProvenance {
    var declaration_index = before;
    while (declaration_index > function.body_start + 1) {
        declaration_index -= 1;
        if ((function.tokens[declaration_index].tag != .keyword_const and
            function.tokens[declaration_index].tag != .keyword_var) or
            declaration_index + 2 >= before or function.tokens[declaration_index + 1].tag != .identifier or
            !std.mem.eql(u8, tokenText(function.source, function.tokens[declaration_index + 1]), binding_name)) continue;
        const declaration_end = statementEnd(function.tokens, declaration_index, before);
        var init_open = declaration_index + 2;
        while (init_open < declaration_end) : (init_open += 1) {
            if (function.tokens[init_open].tag != .identifier or
                !std.mem.eql(u8, tokenText(function.source, function.tokens[init_open]), "init") or
                init_open + 1 >= declaration_end or function.tokens[init_open + 1].tag != .l_paren) continue;
            const init_end = matchingToken(function.tokens, init_open + 1) orelse continue;
            if (init_end > declaration_end) continue;
            return parameterProvenanceAtArgument(function, init_open + 2, init_end, 0);
        }
    }
    return null;
}

fn propagateCallEffects(allocator: std.mem.Allocator, index: *Index) !bool {
    var changed = false;
    for (index.functions) |*caller| {
        if (caller.unresolved) continue;
        for (caller.tokens[caller.body_start + 1 .. caller.body_end], caller.body_start + 1..) |token, call_open| {
            if (tokenBelongsToNestedFunction(caller.*, call_open)) continue;
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
                const reported_effect = index.parameterEffectForCall(caller.source, callable, argument);
                const effect = if (reported_effect == .released and !effectUseIsUnconditional(caller.*, call_open))
                    .unknown
                else
                    reported_effect;
                if (index.parameterEscapesForCall(caller.source, callable, argument)) {
                    changed = changed or !caller.parameter_escapes[caller_parameter];
                    caller.parameter_escapes[caller_parameter] = true;
                }
                const before = caller.parameter_effects[caller_parameter];
                mergeEffect(&caller.parameter_effects[caller_parameter], effect);
                changed = changed or before != caller.parameter_effects[caller_parameter];
            }
        }
        if (caller.returns_owned) continue;
        var selected: ?DirectOwnedReturn = null;
        for (caller.tokens[caller.body_start + 1 .. caller.body_end], caller.body_start + 1..) |token, return_index| {
            if (tokenBelongsToNestedFunction(caller.*, return_index) or token.tag != .keyword_return) continue;
            const return_end = statementEnd(caller.tokens, return_index, caller.body_end);
            if (return_index + 1 < return_end and caller.tokens[return_index + 1].tag == .keyword_error) continue;
            const possible_returned: ?DirectOwnedReturn = returned: {
                for (caller.tokens[return_index + 1 .. return_end], return_index + 1..) |candidate, call_open| {
                    if (candidate.tag != .l_paren) continue;
                    const call_end = matchingToken(caller.tokens, call_open) orelse continue;
                    if (call_end + 1 != return_end) continue;
                    const callable = callableBefore(caller.source, caller.tokens, call_open) orelse continue;
                    const owned = index.ownedReturnForCall(caller.source, callable) orelse continue;
                    var allocator_parameter: ?usize = null;
                    var allocator_parameter_member: ?[]const u8 = null;
                    if (owned.allocator_parameter) |callee_allocator_parameter| {
                        if (parameterProvenanceAtArgument(
                            caller.*,
                            call_open + 1,
                            call_end,
                            callee_allocator_parameter,
                        )) |provenance| {
                            allocator_parameter = provenance.parameter;
                            allocator_parameter_member = try composeAllocatorMemberPath(
                                allocator,
                                &index.owned_member_paths,
                                provenance.member,
                                owned.allocator_parameter_member,
                            );
                        }
                    }
                    break :returned DirectOwnedReturn{
                        .release = owned.release,
                        .allocator_parameter = allocator_parameter,
                        .allocator_parameter_member = allocator_parameter_member,
                    };
                }
                break :returned null;
            };
            const returned = possible_returned orelse {
                selected = null;
                break;
            };
            if (selected) |known| {
                if (!std.mem.eql(u8, known.release, returned.release) or
                    known.allocator_parameter != returned.allocator_parameter or
                    !optionalTextEql(known.allocator_parameter_member, returned.allocator_parameter_member))
                {
                    selected = null;
                    break;
                }
            } else {
                selected = returned;
            }
        }
        if (selected) |owned| {
            caller.returns_owned = true;
            caller.return_release = owned.release;
            caller.allocator_parameter = owned.allocator_parameter;
            caller.allocator_parameter_member = owned.allocator_parameter_member;
            changed = true;
        }
    }
    return changed;
}

fn composeAllocatorMemberPath(
    allocator: std.mem.Allocator,
    owned_paths: *std.ArrayList([]u8),
    prefix: ?[]const u8,
    suffix: ?[]const u8,
) !?[]const u8 {
    if (prefix == null) return suffix;
    if (suffix == null) return prefix;
    const path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix.?, suffix.? });
    errdefer allocator.free(path);
    try owned_paths.append(allocator, path);
    return path;
}

fn ownedReturnFromFunction(function: FunctionSummary) ?OwnedReturn {
    if (function.unresolved or !function.returns_owned) return null;
    return .{
        .release = function.return_release orelse "free",
        .allocator_parameter = function.allocator_parameter,
        .allocator_parameter_member = function.allocator_parameter_member,
    };
}

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn mergeEffect(current: *ParameterEffect, incoming: ParameterEffect) void {
    if (incoming == .borrowed or current.* == incoming) return;
    if (current.* == .borrowed) {
        current.* = incoming;
        return;
    }
    current.* = .unknown;
}

const VisitState = enum { unvisited, active, complete };

fn markRecursiveFunctions(allocator: std.mem.Allocator, index: Index) !void {
    const states = try allocator.alloc(VisitState, index.functions.len);
    defer allocator.free(states);
    @memset(states, .unvisited);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);
    for (index.functions, 0..) |_, function_index| {
        if (states[function_index] == .unvisited) {
            try visitFunction(allocator, index, function_index, states, &stack);
        }
    }
}

fn visitFunction(
    allocator: std.mem.Allocator,
    index: Index,
    function_index: usize,
    states: []VisitState,
    stack: *std.ArrayList(usize),
) !void {
    states[function_index] = .active;
    try stack.append(allocator, function_index);
    const function = index.functions[function_index];
    for (function.tokens[function.body_start + 1 .. function.body_end], function.body_start + 1..) |token, call_open| {
        if (tokenBelongsToNestedFunction(function, call_open) or token.tag != .l_paren) continue;
        const callable = callableBefore(function.source, function.tokens, call_open) orelse continue;
        const called = uniqueFunctionIndexForCall(index, function, callable) orelse continue;
        switch (states[called]) {
            .unvisited => try visitFunction(allocator, index, called, states, stack),
            .active => {
                var cycle_start = stack.items.len;
                while (cycle_start > 0) {
                    cycle_start -= 1;
                    if (stack.items[cycle_start] == called) break;
                }
                for (stack.items[cycle_start..]) |recursive_function| {
                    index.functions[recursive_function].unresolved = true;
                    @memset(index.functions[recursive_function].parameter_effects, .unknown);
                    @memset(index.functions[recursive_function].parameter_escapes, false);
                }
            },
            .complete => {},
        }
    }
    std.debug.assert(stack.pop().? == function_index);
    states[function_index] = .complete;
}

fn tokenBelongsToNestedFunction(function: FunctionSummary, token_index: usize) bool {
    for (function.nested_function_ranges) |range| {
        if (token_index > range.start and token_index < range.end) return true;
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
    const file = index.fileForIndex(file_index) orelse return null;
    var selected: ?usize = null;
    for (index.functions[file.function_start..file.function_end], file.function_start..) |function, function_index| {
        if (!std.mem.eql(u8, function.name, name)) continue;
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

fn effectUseIsUnconditional(function: FunctionSummary, use_index: usize) bool {
    const opening = enclosingOpening(function.tokens, use_index) orelse return false;
    const registration = if (opening == function.body_start) registration: {
        const statement_start = statementStart(function.tokens, use_index, function.body_start + 1);
        if (rangeContainsConditionalEffect(function.tokens, statement_start, use_index)) return false;
        break :registration statement_start;
    } else registration: {
        if (opening == 0 or function.tokens[opening - 1].tag != .keyword_defer or
            enclosingOpening(function.tokens, opening - 1) != function.body_start or
            rangeContainsConditionalEffect(function.tokens, opening + 1, use_index)) return false;
        break :registration opening - 1;
    };
    for (function.tokens[function.body_start + 1 .. registration], function.body_start + 1..) |token, index| {
        if (tokenBelongsToNestedFunction(function, index)) continue;
        if (token.tag == .keyword_return or token.tag == .keyword_try) return false;
    }
    return true;
}

fn rangeContainsConditionalEffect(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| switch (token.tag) {
        .keyword_if,
        .keyword_switch,
        .keyword_while,
        .keyword_for,
        .keyword_errdefer,
        => return true,
        else => {},
    };
    return false;
}

fn statementStart(tokens: []const std.zig.Token, index: usize, lower_bound: usize) usize {
    var start = index;
    while (start > lower_bound) {
        switch (tokens[start - 1].tag) {
            .semicolon, .l_brace, .r_brace => break,
            else => start -= 1,
        }
    }
    return start;
}

fn enclosingOpening(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) return cursor;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
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

fn parameterProvenanceAtArgument(
    function: FunctionSummary,
    start: usize,
    end: usize,
    target_argument: usize,
) ?AllocatorProvenance {
    var argument: usize = 0;
    var segment_start = start;
    var depth: usize = 0;
    for (function.tokens[start..end], start..) |token, index| {
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => depth -|= 1,
            .comma => if (depth == 0) {
                if (argument == target_argument) return parameterProvenanceInSegment(function, segment_start, index);
                argument += 1;
                segment_start = index + 1;
            },
            else => {},
        }
    }
    return if (argument == target_argument) parameterProvenanceInSegment(function, segment_start, end) else null;
}

fn parameterProvenanceInSegment(function: FunctionSummary, start: usize, end: usize) ?AllocatorProvenance {
    for (function.parameter_names, 0..) |parameter, parameter_index| {
        if (segmentIsIdentifier(function.source, function.tokens, start, end, parameter)) {
            return .{ .parameter = parameter_index };
        }
        if (end > start + 2 and function.tokens[start].tag == .identifier and
            std.mem.eql(u8, tokenText(function.source, function.tokens[start]), parameter) and
            segmentIsMemberPath(function.tokens, start + 1, end))
        {
            return .{
                .parameter = parameter_index,
                .member = function.source[function.tokens[start + 2].loc.start..function.tokens[end - 1].loc.end],
            };
        }
    }
    return null;
}

fn segmentIsMemberPath(tokens: []const std.zig.Token, start: usize, end: usize) bool {
    if ((end - start) % 2 != 0) return false;
    for (tokens[start..end], start..) |token, index| {
        const expected: std.zig.Token.Tag = if ((index - start) % 2 == 0) .period else .identifier;
        if (token.tag != expected) return false;
    }
    return true;
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
    return owned_call.releaseForMethod(method);
}

fn allocationReleaseForCallable(callable: []const u8) ?[]const u8 {
    return owned_call.releaseForCallable(callable);
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

fn enclosingScopeEnd(tokens: []const std.zig.Token, index: usize) ?usize {
    var depth: usize = 0;
    var cursor = index;
    const opening = while (cursor > 0) {
        cursor -= 1;
        switch (tokens[cursor].tag) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) break cursor;
                depth -= 1;
            },
            else => {},
        }
    } else return null;
    return matchingToken(tokens, opening);
}

fn tokenText(source: []const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

fn tokenize(allocator: std.mem.Allocator, source: [:0]const u8) ![]const std.zig.Token {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) break;
    }
    return try tokens.toOwnedSlice(allocator);
}

test "summary build releases partial state after allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const sources = [_]Source{
                .{
                    .file_index = 0,
                    .path = "src/release.zig",
                    .source = "pub fn release(allocator: anytype, bytes: []u8) void { allocator.free(bytes); }",
                },
                .{
                    .file_index = 1,
                    .path = "src/operations.zig",
                    .source = "const releasing = @import(\"release.zig\"); fn forward(allocator: anytype, bytes: []u8) void { releasing.release(allocator, bytes); }",
                },
            };
            var index = try build(allocator, &sources, types.Configuration.defaults());
            defer index.deinit(allocator);
        }
    }.run, .{});
}

test "summaries propagate releases and owned returns through direct calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/release.zig", .source = "pub fn release(allocator: anytype, bytes: []u8) void { allocator.free(bytes); }" },
        .{ .file_index = 1, .path = "src/operations.zig", .source = "const releasing = @import(\"release.zig\"); fn forward(allocator: anytype, bytes: []u8) void { releasing.release(allocator, bytes); } fn make(allocator: anytype) ![]u8 { return allocator.alloc(u8, 4); } fn forwardMake(allocator: anytype) ![]u8 { return make(allocator); }" },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.released, index.parameterEffect("forward", 1));
    try std.testing.expectEqualStrings("free", index.ownedReturn("make").?.release);
    try std.testing.expectEqual(@as(?usize, 0), index.ownedReturn("make").?.allocator_parameter);
    try std.testing.expectEqual(@as(?usize, 0), index.ownedReturn("forwardMake").?.allocator_parameter);
}

test "conditional releases do not become parameter release proofs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn releaseSometimes(allocator: std.mem.Allocator, bytes: []u8, enabled: bool) void {" ++
            "if (enabled) allocator.free(bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffect("releaseSometimes", 1));
}

test "release summaries require registration before earlier error exits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn releaseAfterFallible(allocator: std.mem.Allocator, bytes: []u8) !void {" ++
            "try prepare(); allocator.free(bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffect("releaseAfterFallible", 1));
}

test "top-level defer supplies an unconditional release summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn releaseOnExit(allocator: std.mem.Allocator, bytes: []u8) void {" ++
            "defer allocator.free(bytes); _ = bytes.len; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.released, index.parameterEffect("releaseOnExit", 1));
}

test "conditional release effects stay opaque through wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn releaseNow(allocator: std.mem.Allocator, bytes: []u8) void { allocator.free(bytes); }" ++
            "fn releaseSometimes(allocator: std.mem.Allocator, bytes: []u8, enabled: bool) void {" ++
            "if (enabled) releaseNow(allocator, bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffect("releaseSometimes", 1));
}

test "summaries retain ownership returned through a local binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn createThing(allocator: std.mem.Allocator) !*Thing { const thing = try allocator.create(Thing); return thing; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("createThing").?;
    try std.testing.expectEqualStrings("destroy", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "summaries retain ownership returned through a local binding slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn encode(allocator: std.mem.Allocator, used: usize) ![]u8 { const bytes = try allocator.alloc(u8, 8); return bytes[0..used]; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("encode").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "a stored parameter returned as an alias is not a new owned return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn retain(allocator: std.mem.Allocator, values: *List, value: []u8) ![]u8 {" ++
            "errdefer allocator.free(value); try values.append(allocator, value); return value; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("retain") == null);
}

test "an allocation stored before return is exposed as a borrowed alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "const Registry = struct { allocator: std.mem.Allocator, entries: List, " ++
            "fn append(self: *Registry) !*Entry { const entry = try self.allocator.create(Entry); " ++
            "self.entries.appendAssumeCapacity(entry); return entry; } };",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("append") == null);
}

test "an errdefer protected parameter returned directly remains owned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn passThrough(allocator: std.mem.Allocator, value: []u8) ![]u8 {" ++
            "errdefer allocator.free(value); return value; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqualStrings("free", index.ownedReturn("passThrough").?.release);
}

test "qualified allocation helpers retain allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return utils.dupe(u8, allocator, bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "standard allocation helpers retain allocator provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 { return std.mem.concat(allocator, u8, parts); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "owned returns retain allocator fields on parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(context: Context, bytes: []const u8) ![]u8 { return context.allocator.dupe(u8, bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
    try std.testing.expectEqualStrings("allocator", owned.allocator_parameter_member.?);
}

test "owned returns retain nested allocator paths on parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(context: Context, bytes: []const u8) ![]u8 { return context.storage.allocator.dupe(u8, bytes); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
    try std.testing.expectEqualStrings("storage.allocator", owned.allocator_parameter_member.?);
}

test "owned return wrappers compose allocator member paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn allocate(context: Context) ![]u8 { return context.allocator.alloc(u8, 4); }" ++
            "fn make(state: State) ![]u8 { return allocate(state.context); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
    try std.testing.expectEqualStrings("context.allocator", owned.allocator_parameter_member.?);
}

test "owned writer returns retain their initializer allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn render(allocator: std.mem.Allocator) ![]u8 { var writer: std.Io.Writer.Allocating = .init(allocator); defer writer.deinit(); try writer.writer.writeAll(\"ready\"); return writer.toOwnedSlice(); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("render").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "owned returns resolve through local method receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Packet = struct { fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "fn send(allocator: std.mem.Allocator, packet: *const Packet) !void { const bytes = try packet.encode(allocator); _ = bytes; }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturnCall(source, "packet", "encode").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "owned method returns retain implicit receiver allocator fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Store = struct { allocator: std.mem.Allocator, fn make(self: *Store) ![]u8 { return self.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void { _ = try store.make(); }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturnCall(source, "store", "make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, null), owned.allocator_parameter);
    try std.testing.expectEqualStrings("allocator", owned.allocator_parameter_member.?);
}

test "owned returns resolve through named receiver parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Renderer = struct { fn render(renderer: Renderer, allocator: std.mem.Allocator) ![]u8 { _ = renderer; return allocator.alloc(u8, 4); } };" ++
        "fn show(renderer: Renderer, allocator: std.mem.Allocator) !void { _ = try renderer.render(allocator); }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturnCall(source, "renderer", "render").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "local receivers shadow import aliases in ownership summaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller: [:0]const u8 =
        "const server = @import(\"server.zig\");" ++
        "const Local = struct { fn make(self: *Local, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "fn run(server: *Local, allocator: std.mem.Allocator) !void { _ = try server.make(allocator); }";
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/server.zig", .source = "pub fn make(allocator: std.mem.Allocator) !*u8 { return allocator.create(u8); }" },
        .{ .file_index = 1, .path = "src/main.zig", .source = caller },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturnCall(caller, "server", "make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "parameter effects resolve through local method receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Queue = struct { fn inspect(self: *Queue, bytes: []const u8) void { _ = self; _ = bytes.len; } };" ++
        "fn send(queue: *Queue, bytes: []const u8) void { queue.inspect(bytes); }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.borrowed, index.parameterEffectForCall(source, "queue.inspect", 0));
}

test "field methods do not resolve to same named container methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Queue = struct { entries: List, fn append(self: *Queue, value: []u8) void { _ = self; _ = value.len; }" ++
        "fn store(self: *Queue, value: []u8) !void { try self.entries.append(value); } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.unknown, index.parameterEffectForCall(source, "self.entries.append", 0));
    try std.testing.expect(!index.parameterEscapesForCall(source, "self.entries.append", 0));
}

test "returning a duplicate does not make its source parameter escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Packet = struct { payload: []u8, fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Packet {" ++
        "return .{ .payload = try allocator.dupe(u8, bytes[1..]) }; } };" ++
        "const Queue = struct { fn add(self: *Queue, bytes: []const u8, allocator: std.mem.Allocator) !void { _ = self; _ = try Packet.decode(allocator, bytes); } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.borrowed, index.parameterEffectForCall(source, "queue.add", 0));
}

test "decoder methods borrow input retained only through a duplicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Packet = struct { kind: u8, payload: []u8, fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Packet {" ++
        "if (bytes.len < 5) return error.Short; const length = bytes[1]; if (length != bytes.len - 5) return error.Length;" ++
        "return .{ .kind = bytes[0], .payload = try allocator.dupe(u8, bytes[5..]) }; } fn deinit(self: *Packet, allocator: std.mem.Allocator) void { allocator.free(self.payload); } };" ++
        "const Queue = struct { fn decodeAndEnqueue(self: *Queue, allocator: std.mem.Allocator, bytes: []const u8) !void {" ++
        "var packet = try Packet.decode(allocator, bytes); errdefer packet.deinit(allocator); try self.append(packet); } fn append(self: *Queue, packet: Packet) !void { _ = self; _ = packet; } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.borrowed, index.parameterEffectForCall(source, "queue.decodeAndEnqueue", 1));
}

test "toOwnedSlice returns memory owned by its allocator argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn render(allocator: std.mem.Allocator, list: *List) ![]u8 { return list.toOwnedSlice(allocator); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("render").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
    try std.testing.expect(index.borrowedReturnCall(sources[0].source, null, "render") == null);
}

test "mixed owned and borrowed returns remain opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn choose(allocator: std.mem.Allocator, list: *List, allocate: bool) ![]u8 { if (allocate) return allocator.alloc(u8, 4); return list.items; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("choose") == null);
    try std.testing.expect(index.borrowedReturnCall(sources[0].source, null, "choose") == null);
}

test "matching owned return branches produce one ownership contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn choose(allocator: std.mem.Allocator, duplicate: bool) ![]u8 { if (duplicate) return allocator.dupe(u8, \"x\"); return allocator.alloc(u8, 4); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("choose").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "error returns do not obscure an owned success return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(allocator: std.mem.Allocator, ready: bool) ![]u8 { if (!ready) return error.NotReady; return allocator.alloc(u8, 4); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const owned = index.ownedReturn("make").?;
    try std.testing.expectEqualStrings("free", owned.release);
    try std.testing.expectEqual(@as(?usize, 0), owned.allocator_parameter);
}

test "propagated ownership requires every success return to be owned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 4); }" ++
        "fn choose(allocator: std.mem.Allocator, list: *List, allocate: bool) ![]u8 { " ++
        "if (allocate) return make(allocator); return list.items; }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("choose") == null);
}

test "transformed owned calls do not become owned return contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 4); }" ++
        "fn length(allocator: std.mem.Allocator) !usize { return (try make(allocator)).len; }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("length") == null);
}

test "owned bindings do not cross sibling lexical scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn make(allocator: std.mem.Allocator, allocate: bool) ![]const u8 { " ++
            "if (allocate) { const bytes = try allocator.alloc(u8, 4); errdefer allocator.free(bytes); _ = bytes; } " ++
            "{ const bytes = \"static\"; return bytes; } }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("make") == null);
}

test "borrowed aliases do not escape through sibling lexical scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn inspect(bytes: []const u8, fallback: []const u8) void { " ++
        "{ const view = bytes[0..]; _ = view.len; } { const view = fallback; global.view = view; } }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(!index.parameterEscapesForCall(source, "inspect", 0));
}

test "summaries do not infer ownership from arbitrary create methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn createThing(protocol: *Protocol) !*Thing { return protocol.create(); }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.ownedReturn("createThing") == null);
}

test "summaries exclude nested function bodies from enclosing functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]Source{.{
        .file_index = 0,
        .source = "fn outer(bytes: []u8) type { return struct { fn inner(bytes: []u8) void { allocator.free(bytes); } }; }",
    }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(ParameterEffect.borrowed, index.parameterEffect("outer", 0));
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
    try std.testing.expect(index.hasImportedLifecycleFacts(caller));
}

test "imports without ownership facts skip cross-file lifecycle analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const caller: [:0]const u8 = "const command = @import(\"command.zig\"); fn run() void { command.execute(); }";
    const sources = [_]Source{
        .{ .file_index = 0, .path = "src/command.zig", .source = "pub fn execute() void {}" },
        .{ .file_index = 1, .path = "src/main.zig", .source = caller },
    };
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(!index.hasImportedLifecycleFacts(caller));
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

test "summaries retain receiver field borrows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Catalog = struct { records: List, " ++
        "fn find(self: *Catalog, index: usize) *Record { return &self.records.items[index]; } " ++
        "fn view(self: *Catalog) []Record { return self.records.items[0..]; } " ++
        "fn remove(self: *Catalog) void { _ = self.records.orderedRemove(0); } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const pointer = index.borrowedReturnCall(source, "catalog", "find").?;
    const view = index.borrowedReturnCall(source, "catalog", "view").?;
    try std.testing.expectEqual(BorrowKind.pointer, pointer.kind);
    try std.testing.expectEqualStrings("records", pointer.field);
    try std.testing.expectEqual(BorrowKind.slice, view.kind);
    try std.testing.expectEqualStrings("records", view.field);
    const mutation = index.containerMutationCall(source, "catalog", "remove").?;
    try std.testing.expectEqual(@as(usize, 0), mutation.parameter);
    try std.testing.expectEqualStrings("records", mutation.field);
}

test "summaries retain direct container mutations through pointer parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "fn grow(values: *List) !void { try values.ensureTotalCapacity(a, 64); }" ++
        "fn add(map: *Map) !void { try map.put(2, 2); }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    const growth = index.containerMutationCall(source, null, "grow").?;
    const insertion = index.containerMutationCall(source, null, "add").?;
    try std.testing.expectEqual(@as(usize, 0), growth.parameter);
    try std.testing.expectEqualStrings("", growth.field);
    try std.testing.expectEqual(@as(usize, 0), insertion.parameter);
    try std.testing.expectEqualStrings("", insertion.field);
}

test "summaries identify partial IO wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Socket = struct { stream: Stream, fn send(self: *Socket, bytes: []const u8) !usize { return self.stream.write(bytes); } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(PartialIo.write, index.partialIoReturnCall(source, "socket", "send"));
}

test "mixed direct and synthetic IO counts remain opaque" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Socket = struct { stream: Stream, fn send(self: *Socket, bytes: []const u8, skip: bool) !usize { " ++
        "if (skip) return bytes.len; return self.stream.write(bytes); } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expectEqual(PartialIo.none, index.partialIoReturnCall(source, "socket", "send"));
}

test "value getters and transformed IO results do not become borrow or partial IO contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Catalog = struct { records: List, " ++
        "fn count(self: *Catalog) usize { return self.records.items.len; } };" ++
        "const Socket = struct { stream: Stream, " ++
        "fn paddedSend(self: *Socket, bytes: []const u8) !usize { return try self.stream.write(bytes) + 1; } };";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.borrowedReturnCall(source, "catalog", "count") == null);
    try std.testing.expectEqual(PartialIo.none, index.partialIoReturnCall(source, "socket", "paddedSend"));
}

test "definite parameter escapes survive unrelated opaque uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: [:0]const u8 =
        "const Entry = struct { text: []const u8 };" ++
        "fn parse(line: []const u8) Entry { const raw = std.mem.trim(u8, line, \" \" ); " ++
        "_ = std.mem.eql(u8, raw, \"x\"); return .{ .text = raw }; }" ++
        "fn length(raw: []const u8) usize { return raw.len; }";
    const sources = [_]Source{.{ .file_index = 0, .source = source }};
    const index = try build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(index.parameterEscapesForCall(source, "parse", 0));
    try std.testing.expect(!index.parameterEscapesForCall(source, "length", 0));
}
