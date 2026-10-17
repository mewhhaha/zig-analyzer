//! "caller frees" inlay hints: after each call whose result the caller owns,
//! by the ownership summaries the lifecycle rules use (see
//! `rules/owned_results.zig`). The summaries cover the document itself, so
//! calls into other files get no hint.
const std = @import("std");

const lsp = @import("lsp");

const analysis = @import("../analysis.zig");
const document_module = @import("../syntax/document.zig");
const services_module = @import("services.zig");

const Document = document_module.Document;
const Services = services_module.Services;
const OwnedResult = analysis.owned_results.OwnedResult;

pub fn inlayHints(
    services: Services,
    arena: std.mem.Allocator,
    document: *const Document,
    requested_range: lsp.types.Range,
) ![]const lsp.types.InlayHint {
    const configuration = try services.linter.configuration(arena, document);
    const calls = try services.ownership_hints.calls(arena, document, configuration);
    var hints: std.ArrayList(lsp.types.InlayHint) = .empty;
    for (calls) |call| {
        const position = document.range(.{ .start = call.end, .end = call.end }).start;
        if (lsp.offsets.orderPosition(position, requested_range.start) == .lt or
            lsp.offsets.orderPosition(position, requested_range.end) == .gt) continue;
        try hints.append(arena, .{
            .position = position,
            .label = .{ .string = if (call.destroys) "caller destroys" else "caller frees" },
            .paddingLeft = true,
            .tooltip = .{ .string = if (call.destroys)
                "The caller owns the returned memory and releases it with the allocator's destroy."
            else
                "The caller owns the returned memory and releases it with the allocator's free." },
        });
    }
    return try hints.toOwnedSlice(arena);
}

/// The owned-result calls of each open document, kept while its text and the
/// contracts the summaries read stay the same: summarizing the file is the
/// expensive part, and editors ask for hints again on every scroll.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        identity: u64,
        calls: []const Call,
    };

    pub const Call = struct {
        /// Just past the call's closing parenthesis.
        end: usize,
        /// Released with `destroy` rather than `free`.
        destroys: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(cache: *Cache) void {
        var entries = cache.entries.iterator();
        while (entries.next()) |entry| {
            cache.allocator.free(entry.key_ptr.*);
            cache.allocator.free(entry.value_ptr.calls);
        }
        cache.entries.deinit(cache.allocator);
        cache.* = undefined;
    }

    pub fn remove(cache: *Cache, uri: []const u8) void {
        const entry = cache.entries.fetchRemove(uri) orelse return;
        cache.allocator.free(entry.key);
        cache.allocator.free(entry.value.calls);
    }

    /// The calls of `document` in source order, summarized again only when
    /// its text or the contracts changed since the last request.
    fn calls(cache: *Cache, arena: std.mem.Allocator, document: *const Document, configuration: analysis.Configuration) ![]const Call {
        const identity = identityOf(document.source, configuration);
        if (cache.entries.get(document.uri)) |entry| if (entry.identity == identity) return entry.calls;
        const found = try analysis.owned_results.calls(arena, document.source, document.tokens, &document.scopes, configuration);
        std.mem.sort(OwnedResult, found, {}, struct {
            fn lessThan(_: void, left: OwnedResult, right: OwnedResult) bool {
                return left.end < right.end;
            }
        }.lessThan);
        const owned_calls = try cache.allocator.alloc(Call, found.len);
        errdefer cache.allocator.free(owned_calls);
        for (found, owned_calls) |owned, *call| call.* = .{ .end = owned.end, .destroys = std.mem.eql(u8, owned.release, "destroy") };
        const entry: Entry = .{ .identity = identity, .calls = owned_calls };
        if (cache.entries.getPtr(document.uri)) |previous| {
            cache.allocator.free(previous.calls);
            previous.* = entry;
        } else {
            const uri = try cache.allocator.dupe(u8, document.uri);
            errdefer cache.allocator.free(uri);
            try cache.entries.put(cache.allocator, uri, entry);
        }
        return owned_calls;
    }

    /// Identifies the text and the configuration the summaries read, its
    /// resource and arena contracts. A version number would not do: it moves
    /// before the edited text is parsed, and a reopened document starts over.
    fn identityOf(source: []const u8, configuration: analysis.Configuration) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(source);
        std.hash.autoHashStrat(&hasher, configuration.resource_contracts, .Deep);
        std.hash.autoHashStrat(&hasher, configuration.arena_allocator_contracts, .Deep);
        return hasher.final();
    }
};
