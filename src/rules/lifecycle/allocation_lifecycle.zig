//! The allocation lifecycle engine. It recognizes each allocation once and
//! derives every ownership finding about that binding from the same proof.
//! The parts of the proof live under `allocation_lifecycle/`:
//!
//! - `allocation.zig`: what an allocation records and the values that make one;
//! - `arena.zig`: whether an arena-like allocator frees it with everything else;
//! - `scans.zig`: the lexical release, escape and transfer scans of a binding;
//! - `statement_tables.zig`: the per-block tables the scans and the walk share;
//! - `paths.zig`: the walk that proves a release or transfer on every path;
//! - `reports.zig`: the findings besides a leak, from the same binding;
//! - `tests.zig`: the engine's tests, through the findings of whole files.
const std = @import("std");

const syntax_scope = @import("../../syntax/scope.zig");
const cleanup_after_fallible_operation = @import("cleanup_after_fallible_operation.zig");
const resources = @import("../resources.zig");
const ownership_edge_cases = @import("ownership_edge_cases.zig");
const container_release = @import("container_release.zig");
const RuleRun = @import("../context.zig").RuleRun;
const summaries = @import("../summaries.zig");
const types = @import("../types.zig");
const tokenize = @import("../../syntax/tokens.zig").tokenize;
const TokenRange = @import("../../syntax/tokens.zig").Range;
const allocationFromValue = @import("allocation_lifecycle/allocation.zig").allocationFromValue;
const arena = @import("allocation_lifecycle/arena.zig");
const DeclarationsByName = arena.DeclarationsByName;
const allocatorIsArenaBacked = arena.allocatorIsArenaBacked;
const allocatorMatchesArenaContract = arena.allocatorMatchesArenaContract;
const allocatorParameterIsAlwaysArenaBacked = arena.allocatorParameterIsAlwaysArenaBacked;
const valueReceivesBuildArena = arena.valueReceivesBuildArena;
const ownershipLeavesScope = @import("allocation_lifecycle/scans.zig").ownershipLeavesScope;
const statement_tables = @import("allocation_lifecycle/statement_tables.zig");
const OwnershipCache = statement_tables.OwnershipCache;
const bindingSpans = statement_tables.bindingSpans;
const paths = @import("allocation_lifecycle/paths.zig");
const ownership_live = paths.ownership_live;
const ownershipLeavesAllPaths = paths.ownershipLeavesAllPaths;
const reports = @import("allocation_lifecycle/reports.zig");
const ReceiverCleanups = reports.ReceiverCleanups;
const bindingReleasedWith = reports.bindingReleasedWith;
const deferDeinitializesReceiver = reports.deferDeinitializesReceiver;
const findMismatchedRelease = reports.findMismatchedRelease;
const findOverlappingAggregateErrdefers = reports.findOverlappingAggregateErrdefers;
const findReleaseOrderingIssues = reports.findReleaseOrderingIssues;
const freeFinding = reports.freeFinding;

/// Every ownership finding of a file. Besides the binding-identity engine in
/// this module it runs two token-pattern passes that share its codes.
pub const rules = [_]types.Rule{
    .unreleased_allocation,
    .cleanup_after_fallible_operation,
    .mismatched_allocation_release,
    .double_release,
    .use_after_release,
    .overwritten_owning_value,
    .partial_ownership_transfer,
};

pub fn run(context: RuleRun) !void {
    const found = try findingsWithSyntax(
        context.allocator,
        context.source,
        context.tree,
        context.tokens,
        context.scopes,
        context.configuration,
    );
    for (found) |finding| try context.emit(finding);
    try ownership_edge_cases.run(context);
    try container_release.run(context);
    try cleanup_after_fallible_operation.run(context);
}

pub fn findings(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) ![]types.Finding {
    return findingsWithConfiguration(allocator, source, types.Configuration.defaults());
}

pub fn findingsWithConfiguration(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    configuration: types.Configuration,
) ![]types.Finding {
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var scope_index = try syntax_scope.Index.init(allocator, source, tokens);
    defer scope_index.deinit();
    return findingsWithSyntax(
        allocator,
        source,
        &tree,
        tokens,
        &scope_index,
        configuration,
    );
}

pub fn findingsWithSyntax(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    configuration: types.Configuration,
) ![]types.Finding {
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source, .tokens = tokens }};
    var summary_index = try summaries.build(allocator, &sources, configuration);
    defer summary_index.deinit(allocator);
    return findingsWithSummaries(allocator, source, tree, tokens, scope_index, summary_index, configuration);
}

pub fn findingsWithSummaries(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tree: *const std.zig.Ast,
    tokens: []const std.zig.Token,
    scope_index: *const syntax_scope.Index,
    summary_index: summaries.Index,
    configuration: types.Configuration,
) ![]types.Finding {
    var found: std.ArrayList(types.Finding) = .empty;
    errdefer {
        for (found.items) |finding| freeFinding(allocator, finding);
        found.deinit(allocator);
    }
    var declarations: DeclarationsByName = .{ .allocator = allocator, .source = source, .tokens = tokens };
    defer declarations.deinit();
    var receiver_cleanups: ReceiverCleanups = .{};
    defer receiver_cleanups.answers.deinit(allocator);
    var ownership_cache: OwnershipCache = .{ .allocator = allocator };
    defer ownership_cache.deinit();
    var spans_buffer: std.ArrayList(TokenRange) = .empty;
    defer spans_buffer.deinit(allocator);
    // The scans below visit a binding's uses through the identifier table.
    _ = try scope_index.identifiers();

    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        const declaration = tree.fullVarDecl(node) orelse continue;
        const initializer = declaration.ast.init_node.unwrap() orelse continue;
        const declaration_index: usize = declaration.ast.mut_token;
        if (declaration_index + 2 >= tokens.len) continue;
        const binding_index = declaration_index + 1;
        if (tokens[binding_index].tag != .identifier) continue;
        const binding_name = source[tokens[binding_index].loc.start..tokens[binding_index].loc.end];
        if (std.mem.eql(u8, binding_name, "_")) continue;
        const statement_end = scope_index.statementEnd(declaration_index) orelse continue;
        var allocation = allocationFromValue(source, tree, tokens, scope_index, initializer, summary_index) orelse continue;
        const arena_backed = valueReceivesBuildArena(tree, tokens, scope_index, initializer) or if (allocation.allocator_source) |allocator_name|
            std.ascii.findIgnoreCase(allocator_name, "arena") != null or
                (allocation.allocator_member != null and
                    std.ascii.findIgnoreCase(allocation.allocator_member.?, "arena") != null) or
                try allocatorIsArenaBacked(&declarations, allocator_name) or
                allocatorMatchesArenaContract(
                    source,
                    tokens,
                    scope_index,
                    declaration_index,
                    allocator_name,
                    allocation.allocator_member,
                    summary_index.arena_allocator_contracts,
                ) or
                try allocatorParameterIsAlwaysArenaBacked(
                    source,
                    tokens,
                    scope_index,
                    &declarations,
                    declaration_index,
                    allocator_name,
                    summary_index,
                )
        else
            false;
        const scope_end = scope_index.enclosingScopeEnd(declaration_index) orelse continue;
        if (statement_end >= scope_end) continue;
        const spans = try bindingSpans(
            &ownership_cache,
            tree,
            tokens,
            scope_index,
            declaration_index,
            binding_name,
            statement_end + 1,
            scope_end,
            &spans_buffer,
        );
        if (allocation.array_pointer and std.mem.eql(u8, allocation.release, "free") and
            bindingReleasedWith(source, tokens, scope_index, binding_name, binding_index, scope_end, spans, "destroy"))
        {
            allocation.release = "destroy";
        }
        const mismatched_release = try findMismatchedRelease(
            allocator,
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            scope_end,
            spans,
            allocation,
            configuration,
            &found,
        );
        if (arena_backed) continue;
        // A leak in a test is reported by `std.testing.allocator` itself.
        const report_leaks = !scope_index.insideTestBlock(declaration_index);
        const cleanup_registered_after_fallible_operation = try findReleaseOrderingIssues(
            allocator,
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            declaration_index,
            statement_end,
            scope_end,
            spans,
            allocation,
            summary_index,
            configuration,
            report_leaks,
            &found,
        );
        if (!report_leaks) continue;
        const lexical_cleanup = ownershipLeavesScope(
            source,
            tokens,
            scope_index,
            binding_name,
            binding_index,
            statement_end + 1,
            scope_end,
            spans,
            allocation.release,
            summary_index,
        );
        const path_cleanup = ownershipLeavesAllPaths(
            source,
            tree,
            tokens,
            scope_index,
            node,
            binding_name,
            binding_index,
            allocation,
            summary_index,
            ownership_live,
            &ownership_cache,
        );
        const cleanup = if (path_cleanup) |proven|
            if (proven == .missing and lexical_cleanup == .errdefer_only)
                .errdefer_only
            else if (proven == .missing and lexical_cleanup == .released and cleanup_registered_after_fallible_operation)
                .released
            else
                proven
        else
            lexical_cleanup;
        if (cleanup == .released or mismatched_release) continue;
        const ownership_is_path_incomplete = path_cleanup == .missing and lexical_cleanup == .released;
        // 'defer pool.deinit(...)' reclaims everything the pool handed out.
        if (allocation.receiver) |receiver_name| {
            if (try deferDeinitializesReceiver(
                allocator,
                &receiver_cleanups,
                source,
                tokens,
                scope_index,
                receiver_name,
                declaration_index,
                scope_end,
            )) continue;
        }
        // The build graph frees whatever `b.allocator` hands out.
        if (allocation.allocator_source) |allocator_name| {
            if (resources.buildGraphAllocator(source, tokens, scope_index, allocator_name, declaration_index)) continue;
        }

        const message = switch (cleanup) {
            .released => unreachable,
            .errdefer_only => try allocator.print(
                "allocation '{s}' from {s} is released by errdefer only; the success path has no visible {s} or ownership return",
                .{ binding_name, allocation.method, allocation.release },
            ),
            .missing => if (ownership_is_path_incomplete)
                try allocator.print(
                    "allocation '{s}' from {s} is not released or transferred on every path before leaving this scope",
                    .{ binding_name, allocation.method },
                )
            else
                try allocator.print(
                    "allocation '{s}' from {s} has no visible {s} or ownership return before leaving this scope",
                    .{ binding_name, allocation.method, allocation.release },
                ),
        };
        errdefer allocator.free(message);
        try found.append(allocator, .{
            .rule = .unreleased_allocation,
            .level = configuration.level(.unreleased_allocation),
            .span = tokens[binding_index].loc,
            .message = message,
        });
    }
    try findOverlappingAggregateErrdefers(allocator, source, tokens, scope_index, configuration, &found);
    return try found.toOwnedSlice(allocator);
}

test {
    _ = @import("allocation_lifecycle/tests.zig");
}
