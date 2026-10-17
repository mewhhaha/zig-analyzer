//! Tests of the allocation lifecycle engine, through the findings of whole files.
const std = @import("std");

const allocation_lifecycle = @import("../allocation_lifecycle.zig");
const findings = allocation_lifecycle.findings;
const findingsWithConfiguration = allocation_lifecycle.findingsWithConfiguration;
const freeFinding = @import("reports.zig").freeFinding;
const summaries = @import("../../summaries.zig");
const types = @import("../../types.zig");

test "warns when an allocation has no release" {
    const source = "fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); _ = buffer; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "buffer") != null);
}

test "accepts deferred and explicit releases" {
    const source =
        "fn clean(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16); defer allocator.free(buffer);" ++
        "const node = try allocator.create(u32); allocator.destroy(node); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a deferred pool deinit reclaims the pool's allocations" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "var pool: MemoryPool = .empty;" ++
        "defer pool.deinit(a);" ++
        "const first = try pool.create(a);" ++
        "const second = try pool.create(a);" ++
        "_ = first; _ = second; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an errdefer pool deinit alone still warns about the success path" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "var pool: MemoryPool = .empty;" ++
        "errdefer pool.deinit(a);" ++
        "const first = try pool.create(a);" ++
        "_ = first; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "errdefer alone still warns about the success path" {
    const source = "fn leak(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); errdefer allocator.free(buffer); _ = buffer; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "returning an allocation transfers ownership" {
    const source = "fn owned(allocator: std.mem.Allocator) ![]u8 { const buffer = try allocator.dupe(u8, \"zig\"); return normalize(buffer); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "container declarations do not inherit allocations from their methods" {
    const source =
        "const AOF = struct {" ++
        "pub const ReplayClient = struct {" ++
        "client: *Client," ++
        "fn init(allocator: std.mem.Allocator) !ReplayClient {" ++
        "const client = try allocator.create(Client);" ++
        "errdefer allocator.destroy(client);" ++
        "return .{ .client = client };" ++
        "}" ++
        "fn deinit(self: *ReplayClient, allocator: std.mem.Allocator) void { allocator.destroy(self.client); }" ++
        "};" ++
        "};";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "storing an allocation in an owner transfers ownership" {
    const source =
        "fn attach(self: *Owner, allocator: std.mem.Allocator) !void {" ++
        "const client = try allocator.create(Client);" ++
        "self.client = client;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "field insertion is not confused with a same named owner method" {
    const source =
        "const Table = struct { names: List, allocator: std.mem.Allocator," ++
        "fn append(self: *Table, name: []const u8) !void {" ++
        "const owned_name = try self.allocator.dupe(u8, name);" ++
        "errdefer self.allocator.free(owned_name);" ++
        "try self.names.append(self.allocator, owned_name); } };";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "passing an allocation to an unknown call is treated as an escape" {
    const source =
        "fn attach(allocator: std.mem.Allocator) !void {" ++
        "const client = try allocator.create(Client);" ++
        "register(client);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "conditional container insertion or cleanup transfers an owned aggregate" {
    const source: [:0]const u8 =
        "const Link = struct { start: usize, end: usize, source: []u8, fn deinit(self: *Link, allocator: std.mem.Allocator) void { allocator.free(self.source); } };" ++
        "fn parseLink(allocator: std.mem.Allocator) !Link { return .{ .start = 0, .end = 1, .source = try allocator.dupe(u8, \"link\") }; }" ++
        "fn parse(allocator: std.mem.Allocator) !List { var links: List = .empty; " ++
        "const link = try parseLink(allocator); if (link.start <= link.end) links.appendAssumeCapacity(link) else { " ++
        "var discarded = link; discarded.deinit(allocator); } return links; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "passing an allocation to a proven borrowing helper does not transfer ownership" {
    const source =
        "fn inspect(bytes: []u8) void { _ = bytes.len; }" ++
        "fn leak(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "inspect(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "copying allocation bytes into a container does not transfer ownership" {
    const source =
        "fn append(allocator: std.mem.Allocator, output: *List) !void {" ++
        "const line = try std.fmt.allocPrint(allocator, \"value\", .{});" ++
        "try output.appendSlice(allocator, line);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "a proven releasing helper discharges caller ownership" {
    const source =
        "fn release(allocator: std.mem.Allocator, bytes: []u8) void { allocator.free(bytes); }" ++
        "fn clean(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "release(allocator, bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "summary-backed releases participate in double release and use-after proof" {
    const source =
        "fn release(allocator: std.mem.Allocator, bytes: []u8) void { allocator.free(bytes); }" ++
        "fn misuse(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "release(allocator, bytes);" ++
        "release(allocator, bytes);" ++
        "_ = bytes[0];" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var saw_double_release = false;
    var saw_use_after_release = false;
    for (found) |finding| switch (finding.rule) {
        .double_release => saw_double_release = true,
        .use_after_release => saw_use_after_release = true,
        else => {},
    };
    try std.testing.expect(saw_double_release);
    try std.testing.expect(saw_use_after_release);
}

test "errdefer and success cleanup are not a double release" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "errdefer allocator.free(bytes);" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "optional capture cleanup releases an optional owned return" {
    const source =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 16); }" ++
        "fn run(allocator: std.mem.Allocator) void {" ++
        "const maybe_bytes = make(allocator) catch null;" ++
        "if (maybe_bytes) |bytes| { defer allocator.free(bytes); inspect(bytes); }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an indirect helper transfer remains conservative" {
    const source =
        "fn register(bytes: []u8) void { store(bytes); }" ++
        "fn attach(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "register(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an opaque fallible call may take ownership before returning an error" {
    const source =
        "const Finding = struct { edits: []Edit };" ++
        "fn emit(finding: Finding) !void { try findings.append(finding); }" ++
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const edits = try allocator.alloc(Edit, 1);" ++
        "try emit(.{ .edits = edits });" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a fallible method may take errdefer-protected ownership" {
    const source =
        "const Worker = struct { future: Future, state: *State };" ++
        "fn start(options: Options) !Worker {" ++
        "const path = try options.allocator.dupe(u8, options.path);" ++
        "errdefer options.allocator.free(path);" ++
        "const state = try options.allocator.create(State);" ++
        "errdefer options.allocator.destroy(state);" ++
        "const future = try options.io.concurrent(loop, .{ state, path });" ++
        "errdefer comptime unreachable;" ++
        "return .{ .future = future, .state = state };" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "breaking an allocation from a labeled block transfers ownership" {
    const source =
        "fn attach(allocator: std.mem.Allocator) !*Client {" ++
        "return owner: {" ++
        "const client = try allocator.create(Client);" ++
        "break :owner client;" ++
        "};" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an owned allocation may clean itself up" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const shell = try Shell.create(allocator);" ++
        "defer shell.destroy();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arena allocations inherit the arena lifetime" {
    const source =
        "fn run(shell: *Shell) !void {" ++
        "const children = try shell.arena.allocator().alloc(u8, 16);" ++
        "_ = children;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arena allocations cannot be released through an unrelated allocator" {
    const source =
        "fn bad(other: std.mem.Allocator, arena: *std.heap.ArenaAllocator) !void {" ++
        "const bytes = try arena.allocator().dupe(u8, \"x\"); other.free(bytes); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, found[0].rule);
}

test "cleanup of a shadowing binding does not release the allocation" {
    const source =
        "fn leak(allocator: std.mem.Allocator, other: *Client) !void {" ++
        "const client = try allocator.create(Client);" ++
        "{ const client = other; allocator.destroy(client); }" ++
        "_ = client;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "release may wrap the owned pointer" {
    const source = "fn clean(allocator: std.mem.Allocator) !void { const buffer = try allocator.alloc(u8, 16); defer allocator.free(@constCast(buffer)); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested labeled allocation expressions do not cross their enclosing scope" {
    const source =
        "fn resolve(b: std.mem.Allocator, existing: ?[]u8) void {" ++
        "const sha = existing orelse fetch: {" ++
        "const result = command();" ++
        "break :fetch b.dupe(u8, result);" ++
        "}; _ = sha; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(std.mem.find(u8, found[0].message, "sha") != null);
}

test "cleanup registered after a fallible operation warns" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "try initialize(buffer);" ++
        "defer allocator.free(buffer);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.cleanup_after_fallible_operation, found[0].rule);
}

test "allocation release must match method and allocator" {
    const wrong_method =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.destroy(buffer);" ++
        "}";
    const method_findings = try findings(std.testing.allocator, wrong_method);
    defer freeFindings(std.testing.allocator, method_findings);
    try std.testing.expectEqual(@as(usize, 1), method_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, method_findings[0].rule);

    const wrong_allocator =
        "fn run(allocator: std.mem.Allocator, other: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "other.free(buffer);" ++
        "}";
    const allocator_findings = try findings(std.testing.allocator, wrong_allocator);
    defer freeFindings(std.testing.allocator, allocator_findings);
    try std.testing.expectEqual(@as(usize, 1), allocator_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, allocator_findings[0].rule);
}

test "releasing an owned field does not release its parent allocation" {
    const source =
        "fn createButton(allocator: std.mem.Allocator, label: []const u8) !*Button {" ++
        "const self = try allocator.create(Button);" ++
        "errdefer allocator.destroy(self);" ++
        "self.label = try allocator.dupe(u8, label);" ++
        "errdefer allocator.free(self.label);" ++
        "return self;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arbitrary create methods are not assumed to allocate" {
    const source =
        "fn run(protocol: *Protocol) !void {" ++
        "const result = try protocol.create();" ++
        "result.send();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "opaque methods may take ownership of pool allocations" {
    const source =
        "fn run(self: *Server, allocator: std.mem.Allocator) !void {" ++
        "const socket = try self.socket_pool.create(allocator);" ++
        "socket.read();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "async operations take ownership of non-buffer pool arguments" {
    const source =
        "fn run(self: *Client, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "const completion = self.completion_pool.create(allocator) catch unreachable;" ++
        "socket.write(loop, completion, .{ .slice = \"ping\" }, Client, self, callback);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "async writes continue borrowing their buffer argument" {
    const source =
        "fn run(self: *Client, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "const bytes = allocator.alloc(u8, 4) catch unreachable;" ++
        "socket.write(loop, completion, bytes, Client, self, callback);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "async write callbacks can release the submitted buffer" {
    const source =
        "const Client = struct { fn writeCallback(self: *Client, loop: anytype, completion: anytype, socket: anytype, buffer: anytype, result: anytype) void {" ++
        "_ = self; _ = loop; _ = completion; _ = socket; _ = buffer; _ = result; } };" ++
        "const Server = struct { buffer_pool: Pool, fn send(self: *Server, allocator: std.mem.Allocator, socket: anytype, loop: anytype) void {" ++
        "_ = allocator; const bytes = self.buffer_pool.create(allocator) catch unreachable; socket.write(loop, completion, .{ .slice = bytes[0..4] }, Server, self, writeCallback); }" ++
        "fn writeCallback(self: *Server, loop: anytype, completion: anytype, socket: anytype, buffer: anytype, result: anytype) void {" ++
        "_ = loop; _ = completion; _ = socket; _ = result; self.buffer_pool.destroy(@alignCast(@as(*[4096]u8, @ptrFromInt(@intFromPtr(buffer.slice.ptr))))); } };";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "inline optional defer releases an optional allocation" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const maybe_bytes: ?[]u8 = try allocator.alloc(u8, 4);" ++
        "defer if (maybe_bytes) |bytes| allocator.free(bytes);" ++
        "try consume(maybe_bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "non-allocator dupe methods may pair with destroy" {
    const source =
        "fn run(parsed: anytype) void {" ++
        "const edited_tree = parsed.tree.dupe();" ++
        "defer edited_tree.destroy();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "dupe methods use a proven allocator receiver" {
    const wrapper_source =
        "fn run(index_slice: anytype, gpa: std.mem.Allocator, ip: anytype) !void {" ++
        "const indices = try index_slice.dupe(gpa, ip);" ++
        "defer gpa.free(indices);" ++
        "}";
    const wrapper_findings = try findings(std.testing.allocator, wrapper_source);
    defer freeFindings(std.testing.allocator, wrapper_findings);
    try std.testing.expectEqual(@as(usize, 0), wrapper_findings.len);

    const allocator_source =
        "fn run(a: std.mem.Allocator, other: std.mem.Allocator, bytes: []const u8) !void {" ++
        "const copy = try a.dupe(u8, bytes);" ++
        "defer other.free(copy);" ++
        "}";
    const allocator_findings = try findings(std.testing.allocator, allocator_source);
    defer freeFindings(std.testing.allocator, allocator_findings);
    try std.testing.expectEqual(@as(usize, 1), allocator_findings.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, allocator_findings[0].rule);
}

test "standard allocation helpers use their allocator argument" {
    const source =
        "fn run(allocator: std.mem.Allocator, parts: []const []const u8) !void {" ++
        "const joined = try std.mem.concat(allocator, u8, parts);" ++
        "_ = joined.len;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "allocator printing and sentinel duplication retain ownership" {
    const source =
        "fn leak(a: std.mem.Allocator) !void { const text = try a.print(\"{s}\", .{\"name\"}); _ = text.len; }" ++
        "fn clean(a: std.mem.Allocator) !void { const text = try a.printSentinel(\"literal\", .{}, 0); defer a.free(text); }" ++
        "fn cleanDuplicate(a: std.mem.Allocator) !void { const text = try a.dupeSentinel(u8, \"name\", 0); defer a.free(text); }" ++
        "fn write(allocator: *std.Io.Writer) !void { try allocator.print(\"literal\", .{}); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "allocator fields preserve provenance through standard helpers" {
    const source =
        "fn run(self: *State) !void {" ++
        "const path = try std.fs.path.resolve(self.alloc, &.{\"a\", \"b\"});" ++
        "defer self.alloc.free(path);" ++
        "const text = try std.fmt.allocPrint(self.alloc, \"{s}\", .{path});" ++
        "defer self.alloc.free(text);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "different allocator fields remain distinct provenance" {
    const source =
        "fn run(self: *State, other: *State) !void {" ++
        "const text = try std.fmt.allocPrint(self.alloc, \"value\", .{});" ++
        "defer other.alloc.free(text);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.mismatched_allocation_release, found[0].rule);
}

test "wrapper release methods and methods of the owned value are not allocator mismatches" {
    const source =
        "const Map = struct { inner: Inner," ++
        "fn put(self: *Map, value: []const u8) !void { const copy = try self.copy(value); errdefer self.free(copy); try self.inner.put(copy); }" ++
        "fn copy(self: Map, value: []const u8) ![]u8 { return self.inner.allocator.dupe(u8, value); }" ++
        "fn free(self: Map, value: []const u8) void { self.inner.allocator.free(value); } };" ++
        "const FreeSet = struct { bits: []u8," ++
        "fn open(gpa: std.mem.Allocator) !FreeSet { return .{ .bits = try gpa.alloc(u8, 4) }; }" ++
        "fn deinit(set: *FreeSet, gpa: std.mem.Allocator) void { gpa.free(set.bits); }" ++
        "fn free(set: *FreeSet, address: usize) void { set.bits[address] = 0; } };" ++
        "fn run(gpa: std.mem.Allocator) !void { var set = try FreeSet.open(gpa); defer set.deinit(gpa); set.free(2); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .mismatched_allocation_release);
}

test "returning only the length of an allocation leaks it" {
    const source =
        "fn count(gpa: std.mem.Allocator, text: []const u8) !usize { const copy = try gpa.dupe(u8, text); return copy.len; }" ++
        "fn first(gpa: std.mem.Allocator, n: usize) !u8 { const bytes = try gpa.alloc(u8, n); return blk: { break :blk bytes[0]; }; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |finding| try std.testing.expectEqual(types.Rule.unreleased_allocation, finding.rule);
}

test "pointer casts and many-item pointers of an allocation carry its ownership" {
    const source =
        "fn first(gpa: std.mem.Allocator) !Holder { const a = try gpa.alloc(u8, 1); errdefer gpa.free(a); try validate(); return .{ .first = &a[0] }; }" ++
        "fn header(gpa: std.mem.Allocator, n: usize) !*Header { const bytes = try gpa.alignedAlloc(u8, .of(Header), n);" ++
        "const result: *Header = @ptrCast(@alignCast(bytes.ptr)); result.* = .{}; return result; }" ++
        "fn grow(self: *List, gpa: std.mem.Allocator, n: usize) !void { const bytes = try gpa.alloc(u8, n);" ++
        "var other = List{ .bytes = bytes.ptr, .len = n }; other.len = n; self.* = other; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "releasing a full-length reslice releases the allocation" {
    const clean =
        "fn run(a: std.mem.Allocator, n: usize) !void { const s = try a.alloc(u8, n); defer a.free(s[0..n]); s[0] = 1; }" ++
        "fn whole(a: std.mem.Allocator, n: usize) !void { const s = try a.alloc(u8, n); defer a.free(s[0..s.len]); s[0] = 1; }";
    const clean_found = try findings(std.testing.allocator, clean);
    defer freeFindings(std.testing.allocator, clean_found);
    try std.testing.expectEqual(@as(usize, 0), clean_found.len);
    // A shorter slice, or one that drops the sentinel, is not the allocation.
    const partial =
        "fn run(a: std.mem.Allocator, n: usize) !void { const s = try a.alloc(u8, n); defer a.free(s[0..1]); s[0] = 1; }" ++
        "fn sentinel(a: std.mem.Allocator, n: usize) !void { const s = try a.allocSentinel(u8, n, 0); defer a.free(s[0..n]); s[0] = 1; }";
    const partial_found = try findings(std.testing.allocator, partial);
    defer freeFindings(std.testing.allocator, partial_found);
    try std.testing.expectEqual(@as(usize, 2), partial_found.len);
}

test "a stack-first allocator falling back to an arena needs no release" {
    const source =
        "fn tunnels(arena: std.mem.Allocator, n: usize) !usize { var buffer: [2]usize = undefined;" ++
        "var bfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&buffer), arena);" ++
        "const items = try bfa.allocator().alloc(usize, n); items[0] = 1; return items.len; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "double release and use after release are reported in straight line code" {
    const double_release_source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "allocator.free(buffer);" ++
        "}";
    const double_findings = try findings(std.testing.allocator, double_release_source);
    defer freeFindings(std.testing.allocator, double_findings);
    var saw_double = false;
    for (double_findings) |finding| {
        if (finding.rule == .double_release) saw_double = true;
    }
    try std.testing.expect(saw_double);

    const use_source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "_ = buffer[0];" ++
        "}";
    const use_findings = try findings(std.testing.allocator, use_source);
    defer freeFindings(std.testing.allocator, use_findings);
    var saw_use = false;
    for (use_findings) |finding| {
        if (finding.rule == .use_after_release) saw_use = true;
    }
    try std.testing.expect(saw_use);
}

test "released slice metadata remains usable without reading freed memory" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "const buffer = try a.alloc(u8, 16);" ++
        "a.free(buffer);" ++
        "_ = @intFromPtr(buffer.ptr);" ++
        "_ = buffer.len;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .use_after_release);
}

test "passing a released value is not by itself proof of a memory read" {
    const source =
        "fn run(a: std.mem.Allocator, owner: anytype) !void {" ++
        "const buffer = try a.alloc(u8, 16);" ++
        "a.free(buffer);" ++
        "_ = owner.isAllocated(buffer);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .use_after_release);
}

test "overwriting an owning allocation before release is reported" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "var buffer = try allocator.alloc(u8, 16);" ++
        "buffer = try allocator.alloc(u8, 32);" ++
        "defer allocator.free(buffer);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| {
        if (finding.rule == .overwritten_owning_value) saw_overwrite = true;
    }
    try std.testing.expect(saw_overwrite);
}

test "allocations through a binding derived from a local arena are exempt" {
    const source =
        "fn tally(gpa: std.mem.Allocator) !void {" ++
        "var scratch = std.heap.ArenaAllocator.init(gpa);" ++
        "defer scratch.deinit();" ++
        "const aa = scratch.allocator();" ++
        "const counts = try aa.alloc(usize, 4);" ++
        "_ = counts;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned-return summaries recognize direct local arena allocator calls" {
    const source =
        "const Stored = struct { bytes: []u8 };" ++
        "fn copy(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 4); }" ++
        "fn store(gpa: std.mem.Allocator) !Stored {" ++
        "var storage = std.heap.ArenaAllocator.init(gpa);" ++
        "errdefer storage.deinit();" ++
        "const bytes = try copy(storage.allocator());" ++
        "const stored: Stored = .{ .bytes = bytes };" ++
        "try finish();" ++
        "return stored;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "declared arena allocator fields inherit their owner lifetime" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"RequestContext.allocator"};
    const source: [:0]const u8 =
        "const RequestContext = struct { allocator: std.mem.Allocator };" ++
        "fn render(context: RequestContext) !void {" ++
        "const label = try context.allocator.dupe(u8, \"ready\");" ++
        "_ = label;" ++
        "}";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arena allocator fields survive owned-return summaries" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"RequestContext.allocator"};
    const source: [:0]const u8 =
        "const RequestContext = struct { allocator: std.mem.Allocator };" ++
        "fn makeLabel(context: RequestContext) ![]u8 {" ++
        "return context.allocator.dupe(u8, \"ready\");" ++
        "}" ++
        "fn render(context: RequestContext) !void {" ++
        "const label = try makeLabel(context);" ++
        "_ = label;" ++
        "}";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "named arena fields survive owned-return summaries" {
    const source =
        "const Builder = struct { arena: std.mem.Allocator };" ++
        "fn makeLabel(builder: *Builder) ![]u8 { return builder.arena.dupe(u8, \"ready\"); }" ++
        "fn render(builder: *Builder) !void { const label = try makeLabel(builder); _ = label; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "arena allocator field contracts require the declared owner type" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"RequestContext.allocator"};
    const source: [:0]const u8 =
        "const PersistentContext = struct { allocator: std.mem.Allocator };" ++
        "fn render(context: PersistentContext) !void {" ++
        "const label = try context.allocator.dupe(u8, \"ready\");" ++
        "_ = label;" ++
        "}";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "declared arena allocator parameters propagate through private calls" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"render.allocator"};
    const source: [:0]const u8 =
        "fn label(allocator: std.mem.Allocator) !void {" ++
        "const text = try allocator.dupe(u8, \"ready\");" ++
        "_ = text;" ++
        "}" ++
        "pub fn render(allocator: std.mem.Allocator) !void {" ++
        "try label(allocator);" ++
        "}";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "documented arena allocator parameters propagate through private calls" {
    const source: [:0]const u8 =
        "fn makeLabel(allocator: std.mem.Allocator) !void { const text = try allocator.dupe(u8, \"ready\"); _ = text; }\n" ++
        "/// The allocator should be an arena owned by the request.\n" ++
        "pub fn render(allocator: std.mem.Allocator) !void { try makeLabel(allocator); }\n";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "ordinary allocator documentation does not imply an arena lifetime" {
    const source: [:0]const u8 =
        "/// The caller owns memory returned through this allocator.\n" ++
        "pub fn render(allocator: std.mem.Allocator) !void { const text = try allocator.dupe(u8, \"ready\"); _ = text; }\n";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "container documentation does not declare a function arena lifetime" {
    const source: [:0]const u8 =
        "//! The allocator should be an arena for module-owned scratch functions.\n" ++
        "pub fn render(allocator: std.mem.Allocator) !void { const text = try allocator.dupe(u8, \"ready\"); _ = text; }\n";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "uncontracted public allocator parameters still require releases" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"preview.allocator"};
    const source: [:0]const u8 =
        "pub fn render(allocator: std.mem.Allocator) !void {" ++
        "const text = try allocator.dupe(u8, \"ready\");" ++
        "_ = text;" ++
        "}";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "private allocation functions called only with an arena allocator are exempt" {
    const source =
        "fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "var arena = std.heap.ArenaAllocator.init(gpa);" ++
        "defer arena.deinit();" ++
        "const a = arena.allocator();" ++
        "try normalize(a, input);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "private allocation functions remain checked when any caller uses a general allocator" {
    const source =
        "fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "defer alloc.free(lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "try normalize(gpa, input);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| if (finding.rule == .overwritten_owning_value) {
        saw_overwrite = true;
    };
    try std.testing.expect(saw_overwrite);
}

test "public allocation functions remain checked despite local arena callers" {
    const source =
        "pub inline fn normalize(alloc: std.mem.Allocator, input: []const u8) !void {" ++
        "var lowered = try alloc.dupe(u8, input);" ++
        "lowered = try alloc.dupe(u8, lowered);" ++
        "defer alloc.free(lowered);" ++
        "}" ++
        "fn run(gpa: std.mem.Allocator, input: []const u8) !void {" ++
        "var arena = std.heap.ArenaAllocator.init(gpa);" ++
        "defer arena.deinit();" ++
        "try normalize(arena.allocator(), input);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var saw_overwrite = false;
    for (found) |finding| if (finding.rule == .overwritten_owning_value) {
        saw_overwrite = true;
    };
    try std.testing.expect(saw_overwrite);
}

test "releasing a field of the same name is not a release of the local binding" {
    const source =
        "fn rename(self: *Thing, a: std.mem.Allocator, new: []const u8) !void {" ++
        "const name = try a.dupe(u8, new);" ++
        "a.free(self.name);" ++
        "self.name = name;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "custom allocator free does not release its backing buffer argument" {
    const source =
        "fn run(a: std.mem.Allocator, bitmap: anytype, ptr: [*]u8) !void {" ++
        "const backing = try a.alloc(u8, 16);" ++
        "defer a.free(backing);" ++
        "bitmap.free(backing, ptr);" ++
        "_ = backing.ptr;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "custom allocator free releases its final allocation argument" {
    const source =
        "fn run(a: std.mem.Allocator, bitmap: anytype, backing: []u8) !void {" ++
        "const ptr = try bitmap.alloc(u8, backing, 16);" ++
        "bitmap.free(backing, ptr);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned wrapper values may use conventional cleanup methods" {
    const source =
        "fn rasterize(a: std.mem.Allocator) !Bitmap { return .{ .data = try a.alloc(u8, 16) }; }" ++
        "fn createThing(a: std.mem.Allocator) !*Thing { const thing = try a.create(Thing); return thing; }" ++
        "fn run(a: std.mem.Allocator) !void {" ++
        "var bitmap = try rasterize(a);" ++
        "defer bitmap.deinit(a);" ++
        "const thing = try createThing(a);" ++
        "defer thing.shutdown();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned returns allocated by an arena parameter need no individual cleanup" {
    const source =
        "fn nodesAtLoc(arena: std.mem.Allocator) ![]Node { return arena.alloc(Node, 4); }" ++
        "fn run(arena: std.mem.Allocator) !void {" ++
        "const nodes = try nodesAtLoc(arena);" ++
        "_ = nodes;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned returns allocated through an arena field need no individual cleanup" {
    const source =
        "fn nodesAtLoc(allocator: std.mem.Allocator) ![]Node { return allocator.alloc(Node, 4); }" ++
        "fn run(context: anytype) !void {" ++
        "const nodes = try nodesAtLoc(context.state.arena);" ++
        "_ = nodes;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "qualified constructors passed an arena inherit its lifetime" {
    const source =
        "const ZigTag = struct { const node = struct { fn create(allocator: std.mem.Allocator) !*Node { return allocator.create(Node); } }; };" ++
        "fn run(context: anytype) !void {" ++
        "const node = try ZigTag.node.create(context.state.arena);" ++
        "_ = node;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "qualified init calls do not inherit unrelated local summaries" {
    const source =
        "fn init(a: std.mem.Allocator) !Owner { return .{ .bytes = try a.alloc(u8, 4) }; }" ++
        "fn run() void { var random = std.Random.DefaultPrng.init(1); _ = random.random(); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "derived allocation passed to an unqualified free wrapper transfers ownership" {
    const source =
        "fn run(a: std.mem.Allocator) !void {" ++
        "const memory = try a.alloc(u8, 8);" ++
        "free(null, memory.ptr, memory.len);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "reassigning the binding after release ends the released lifetime" {
    const source =
        "fn refill(a: std.mem.Allocator) !void {" ++
        "var buf = try a.alloc(u8, 16);" ++
        "a.free(buf);" ++
        "buf = try a.alloc(u8, 32);" ++
        "fill(buf);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "realloc of the binding itself does not overwrite the owning value" {
    const source =
        "fn grow(a: std.mem.Allocator) !void {" ++
        "var buf = try a.alloc(u8, 8);" ++
        "buf = try a.realloc(buf, 16);" ++
        "a.free(buf);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "memory builtins borrow allocations" {
    const source =
        "fn zero(a: std.mem.Allocator) !void {" ++
        "const counts = try a.alloc(u8, 4);" ++
        "@memset(counts, 0);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "formatting allocation metadata does not transfer ownership" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 4); std.debug.print(\"{d}\", .{bytes.len}); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "formatting an allocation does not transfer ownership" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 4); std.debug.print(\"{s}\", .{bytes}); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "reader allocRemaining returns memory owned by its allocator argument" {
    const source =
        "fn readAll(reader: *Reader, allocator: std.mem.Allocator) !void {" ++
        "const bytes = try reader.interface.allocRemaining(allocator, .unlimited);" ++
        "var tokens = std.mem.tokenizeAny(u8, bytes, \" \");" ++
        "_ = tokens.next();" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "double release offers deletion of the duplicate statement" {
    const source =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const buffer = try allocator.alloc(u8, 16);" ++
        "allocator.free(buffer);" ++
        "allocator.free(buffer);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var double: ?types.Finding = null;
    for (found) |finding| {
        if (finding.rule == .double_release) double = finding;
    }
    try std.testing.expect(double != null);
    try std.testing.expectEqual(@as(usize, 1), double.?.fixes.len);
    try std.testing.expect(!double.?.fixes[0].fix_all);
    const edit = double.?.fixes[0].edits[0];
    try std.testing.expectEqualStrings("", edit.replacement);
    try std.testing.expectEqualStrings("allocator.free(buffer);", source[edit.span.start..edit.span.end]);
}

test "aggregate errdefer cannot overlap direct field cleanup" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame {" ++
        "const payload = try allocator.dupe(u8, \"frame\");" ++
        "const frame = try allocator.create(Frame);" ++
        "errdefer allocator.free(payload); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator);" ++
        "try decodeChildren(); return frame; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var double_release_count: usize = 0;
    for (found) |finding| if (finding.rule == .double_release) {
        double_release_count += 1;
        try std.testing.expect(std.mem.find(u8, finding.message, "owned field 'payload'") != null);
    };
    try std.testing.expectEqual(@as(usize, 1), double_release_count);
}

test "aggregate errdefer without earlier field cleanup stays clean" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame {" ++
        "const payload = try allocator.dupe(u8, \"frame\");" ++
        "const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator);" ++
        "try decodeChildren(); return frame; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .double_release);
}

test "aggregate errdefer ignores field cleanup from a closed sibling scope" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator, alternate: bool) !*Frame {" ++
        "if (alternate) { const payload = try allocator.dupe(u8, \"old\"); errdefer allocator.free(payload); allocator.free(payload); }" ++
        "const payload = try allocator.dupe(u8, \"frame\"); const frame = try allocator.create(Frame);" ++
        "errdefer allocator.destroy(frame); frame.* = .{ .payload = payload }; errdefer frame.deinit(allocator); return frame; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .double_release);
}

test "aggregate cleanup only overlaps fields released from its receiver" {
    const source =
        "const Frame = struct { payload: []u8, other: *Frame, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.other.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame { const payload = try allocator.dupe(u8, \"frame\");" ++
        "errdefer allocator.free(payload); const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload, .other = undefined }; errdefer frame.deinit(allocator); return frame; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .double_release);
}

test "conditional errdefer cleanup does not prove an aggregate double release" {
    const source =
        "const Frame = struct { payload: []u8, fn deinit(self: *Frame, allocator: std.mem.Allocator) void {" ++
        "allocator.free(self.payload); allocator.destroy(self); } };" ++
        "fn decode(allocator: std.mem.Allocator) !*Frame { var transferred = false;" ++
        "const payload = try allocator.dupe(u8, \"frame\"); errdefer if (!transferred) allocator.free(payload);" ++
        "const frame = try allocator.create(Frame); errdefer allocator.destroy(frame);" ++
        "frame.* = .{ .payload = payload }; transferred = true; errdefer frame.deinit(allocator); return frame; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    for (found) |finding| try std.testing.expect(finding.rule != .double_release);
}

test "declared resource pairs participate in allocation lifecycle proof" {
    var configuration = types.Configuration.defaults();
    configuration.resource_contracts = &.{.{ .acquire = "Db.open", .release = "Db.close" }};
    const leaking_source: [:0]const u8 =
        "fn run() !void { const connection = try Db.open(); _ = connection.id; }";
    const leaking = try findingsWithConfiguration(std.testing.allocator, leaking_source, configuration);
    defer freeFindings(std.testing.allocator, leaking);
    try std.testing.expectEqual(@as(usize, 1), leaking.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, leaking[0].rule);

    const released_source: [:0]const u8 =
        "fn run() !void { const connection = try Db.open(); defer Db.close(connection); }";
    const released = try findingsWithConfiguration(std.testing.allocator, released_source, configuration);
    defer freeFindings(std.testing.allocator, released);
    try std.testing.expectEqual(@as(usize, 0), released.len);
}

test "nested aggregate returns transfer every contained allocation" {
    const source =
        "fn init(allocator: std.mem.Allocator) !Owner {" ++
        "const first = try allocator.alloc(u8, 4);" ++
        "errdefer allocator.free(first);" ++
        "const second = try allocator.alloc(u8, 8);" ++
        "errdefer allocator.free(second);" ++
        "return .{ .first = .{ .bytes = first }, .second = .{ .bytes = second } };" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "inferred owned returns participate in allocation lifecycle proof" {
    const source: [:0]const u8 =
        "fn make(allocator: std.mem.Allocator) ![]u8 { return allocator.alloc(u8, 4); }" ++
        "fn run(allocator: std.mem.Allocator) !void { const bytes = try make(allocator); _ = bytes.len; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "owned helper returns backed by a Build parameter use its arena" {
    const source: [:0]const u8 =
        "fn make(b: *std.Build) ![]u8 { return b.allocator.alloc(u8, 4); }" ++
        "fn build(b: *std.Build) !void { const bytes = try make(b); _ = bytes.len; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "local method owned returns participate in allocation lifecycle proof" {
    const source: [:0]const u8 =
        "const Packet = struct { fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "fn send(allocator: std.mem.Allocator, packet: *const Packet) !void { const bytes = try packet.encode(allocator); _ = bytes.len; }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "implicit method receiver allocators retain release provenance" {
    const source: [:0]const u8 =
        "const Store = struct { allocator: std.mem.Allocator, fn make(self: *Store) ![]u8 { return self.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void { const bytes = try store.make(); defer store.allocator.free(bytes); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "implicit method receiver allocator contracts inherit arena lifetime" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"Store.allocator"};
    const source: [:0]const u8 =
        "const Store = struct { allocator: std.mem.Allocator, fn make(self: *Store) ![]u8 { return self.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void { const bytes = try store.make(); _ = bytes; }";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested allocator field contracts inherit arena lifetime" {
    var configuration = types.Configuration.defaults();
    configuration.arena_allocator_contracts = &.{"RequestContext.storage.allocator"};
    const source: [:0]const u8 =
        "const RequestContext = struct { storage: Storage };" ++
        "fn render(context: RequestContext) !void { const bytes = try context.storage.allocator.alloc(u8, 4); _ = bytes; }";
    const found = try findingsWithConfiguration(std.testing.allocator, source, configuration);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "nested implicit receiver allocators retain release provenance" {
    const source: [:0]const u8 =
        "const Store = struct { state: State, fn make(self: *Store) ![]u8 { return self.state.allocator.alloc(u8, 4); } };" ++
        "fn load(store: *Store) !void { const bytes = try store.make(); defer store.state.allocator.free(bytes); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "owned return wrappers compose allocator release provenance" {
    const source: [:0]const u8 =
        "fn allocate(context: Context) ![]u8 { return context.allocator.alloc(u8, 4); }" ++
        "fn make(state: State) ![]u8 { return allocate(state.context); }" ++
        "fn load(state: State) !void { const bytes = try make(state); defer state.context.allocator.free(bytes); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "passing a local method allocation to a borrowing method does not transfer ownership" {
    const source: [:0]const u8 =
        "const Packet = struct { fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { _ = self; return allocator.alloc(u8, 4); } };" ++
        "const Queue = struct { fn decodeAndEnqueue(self: *Queue, bytes: []const u8) !void { _ = self; _ = bytes.len; } };" ++
        "fn send(allocator: std.mem.Allocator, packet: *const Packet, queue: *Queue) !void {" ++
        "const bytes = try packet.encode(allocator); try queue.decodeAndEnqueue(bytes); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "writing an owned slice does not transfer its ownership" {
    const source: [:0]const u8 =
        "fn render(allocator: std.mem.Allocator, output: *List) ![]u8 { return output.toOwnedSlice(allocator); }" ++
        "fn write(io: Io, allocator: std.mem.Allocator, output: *List, file: File) !void {" ++
        "const html = try render(allocator, output); try file.writeStreamingAll(io, html); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "encoded buffers remain owned after decoder calls" {
    const source: [:0]const u8 =
        "const Packet = struct { payload: []u8, fn encode(self: *const Packet, allocator: std.mem.Allocator) ![]u8 { " ++
        "const encoded = try allocator.alloc(u8, self.payload.len); @memcpy(encoded, self.payload); return encoded; } " ++
        "fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Packet { return .{ .payload = try allocator.dupe(u8, bytes) }; } };" ++
        "const Queue = struct { allocator: std.mem.Allocator, fn decodeAndEnqueue(self: *Queue, bytes: []const u8) !void { " ++
        "_ = try Packet.decode(self.allocator, bytes); } };" ++
        "pub fn main() !void { var debug_allocator = std.heap.DebugAllocator(.{}){}; const allocator = debug_allocator.allocator(); " ++
        "var queue: Queue = undefined; const first: Packet = undefined; const serialized = try first.encode(allocator); " ++
        "try queue.decodeAndEnqueue(serialized); }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]summaries.Source{.{ .file_index = 0, .source = source }};
    const summary_index = try summaries.build(arena.allocator(), &sources, types.Configuration.defaults());
    try std.testing.expect(summary_index.ownedReturnCall(source, "first", "encode") != null);
    try std.testing.expectEqual(summaries.ParameterEffect.borrowed, summary_index.parameterEffectForCall(source, "queue.decodeAndEnqueue", 0));
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "owned method returns without allocator provenance accept visible cleanup" {
    const source: [:0]const u8 =
        "const Renderer = struct { fn render(renderer: Renderer, allocator: std.mem.Allocator) ![]u8 { " ++
        "_ = renderer; var writer: Writer = .init(allocator); return writer.toOwnedSlice(); } };" ++
        "fn show(renderer: Renderer) !void { const rendered = try renderer.render(std.testing.allocator); " ++
        "defer std.testing.allocator.free(rendered); }";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "cleanup in only one conditional branch leaves an allocation unreleased" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, release: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "if (release) { allocator.free(bytes); }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
    try std.testing.expect(std.mem.find(u8, found[0].message, "not released or transferred on every path") != null);
}

test "cleanup in every conditional branch releases an allocation" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, first: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "if (first) { allocator.free(bytes); } else { allocator.free(bytes); }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "cleanup in only one switch branch leaves an allocation unreleased" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, choice: u8) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "switch (choice) { 0 => { allocator.free(bytes); }, else => {} }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "cleanup in every switch branch releases an allocation" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, choice: u8) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "switch (choice) { 0 => { allocator.free(bytes); }, else => { allocator.free(bytes); } }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an early return before cleanup leaves an allocation unreleased" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, stop: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "if (stop) return;" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "ownership return on one branch and cleanup on the other discharge every path" {
    const source: [:0]const u8 =
        "fn take(allocator: std.mem.Allocator, transfer: bool) ![]u8 {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "if (transfer) return bytes;" ++
        "allocator.free(bytes);" ++
        "return &.{};" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "errdefer covers propagated errors while success cleanup covers fallthrough" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "errdefer allocator.free(bytes);" ++
        "try fallible();" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "propagated error before success cleanup leaves an allocation unreleased" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "try fallible();" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "a local alias does not transfer allocation ownership" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "const alias = bytes;" ++
        "_ = alias.len;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "converting an allocation pointer to an integer does not transfer ownership" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "const address = @intFromPtr(bytes.ptr);" ++
        "_ = address;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "storing ownership in a local aggregate transfers the allocation" {
    const source: [:0]const u8 =
        "const Session = struct { event: *Event };" ++
        "fn open(allocator: std.mem.Allocator) !Session {" ++
        "const event = try allocator.create(Event);" ++
        "const session: Session = .{ .event = event };" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a fallible operation after a local aggregate move can leak its allocation" {
    const source: [:0]const u8 =
        "const Session = struct { event: *Event };" ++
        "fn open(allocator: std.mem.Allocator) !Session {" ++
        "const event = try allocator.create(Event);" ++
        "const session: Session = .{ .event = event };" ++
        "try finish();" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "errdefer protects a local aggregate move across later errors" {
    const source: [:0]const u8 =
        "const Session = struct { event: *Event };" ++
        "fn open(allocator: std.mem.Allocator) !Session {" ++
        "const event = try allocator.create(Event);" ++
        "errdefer allocator.destroy(event);" ++
        "const session: Session = .{ .event = event };" ++
        "try finish();" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "errdefer protects aggregate moves through every conditional branch" {
    const source: [:0]const u8 =
        "const Session = struct { event: *Event, mode: u8 };" ++
        "fn open(allocator: std.mem.Allocator, alternate: bool) !Session {" ++
        "const event = try allocator.create(Event);" ++
        "errdefer allocator.destroy(event);" ++
        "const session: Session = if (alternate) .{ .event = event, .mode = 1 } else .{ .event = event, .mode = 0 };" ++
        "try finish();" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "errdefer protects a populated slice moved through nested aggregates" {
    const source: [:0]const u8 =
        "const Command = struct { argv: [][]u8, mode: u8 };" ++
        "const Terminal = struct { command: Command, screen: Screen };" ++
        "fn open(allocator: std.mem.Allocator, argv: []const []const u8, alternate: bool) !Terminal {" ++
        "const argv_owned = try allocator.alloc([]u8, argv.len);" ++
        "errdefer { for (argv_owned) |value| allocator.free(value); allocator.free(argv_owned); }" ++
        "for (argv, argv_owned) |source_value, *destination| destination.* = try allocator.dupe(u8, source_value);" ++
        "const command: Command = if (alternate) .{ .argv = argv_owned, .mode = 1 } else .{ .argv = argv_owned, .mode = 0 };" ++
        "try finish();" ++
        "return .{ .command = command, .screen = try Screen.init(allocator) };" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "fallible nested aggregate return needs error cleanup for a local move" {
    const source: [:0]const u8 =
        "const Command = struct { bytes: []u8 };" ++
        "const Session = struct { command: Command, screen: Screen };" ++
        "fn open(allocator: std.mem.Allocator) !Session {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "const command: Command = .{ .bytes = bytes };" ++
        "return .{ .command = command, .screen = try Screen.init(allocator) };" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "an aggregate move in only one conditional branch does not transfer every path" {
    const source: [:0]const u8 =
        "const Session = struct { event: ?*Event };" ++
        "fn open(allocator: std.mem.Allocator, include: bool) !Session {" ++
        "const event = try allocator.create(Event);" ++
        "const session: Session = if (include) .{ .event = event } else .{ .event = null };" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "storing allocation metadata does not transfer ownership" {
    const source: [:0]const u8 =
        "const Metadata = struct { length: usize };" ++
        "fn inspect(allocator: std.mem.Allocator) !Metadata {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "const metadata: Metadata = .{ .length = bytes.len };" ++
        "return metadata;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "errdefer protects setup before ownership moves into a local aggregate" {
    const source: [:0]const u8 =
        "const Session = struct { first: *Event, second: *Event, future: Future };" ++
        "fn open(allocator: std.mem.Allocator) !Session {" ++
        "const first = try allocator.create(Event);" ++
        "errdefer allocator.destroy(first);" ++
        "const second = try allocator.create(Event);" ++
        "errdefer allocator.destroy(second);" ++
        "const future = try start(first, second);" ++
        "const session: Session = .{ .first = first, .second = second, .future = future };" ++
        "return session;" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "cleanup inside a for loop does not cover zero iterations" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, values: []const u8) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "for (values) |_| { allocator.free(bytes); break; }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "an early return from a loop bypasses trailing cleanup" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, values: []const u8, stop: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "for (values) |_| { if (stop) return; }" ++
        "allocator.free(bytes);" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "cleanup before leaving an infinite loop releases an allocation" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "while (true) { allocator.free(bytes); break; }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a break before loop cleanup leaves an allocation unreleased" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, skip: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "while (true) { if (skip) break; allocator.free(bytes); break; }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(types.Rule.unreleased_allocation, found[0].rule);
}

test "loop else and break paths may provide their own cleanup" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, keep_going: bool, stop: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "while (keep_going) { if (stop) { allocator.free(bytes); break; } } else { allocator.free(bytes); }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "continue paths reach loop else cleanup" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator, keep_going: bool, skip: bool) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "while (keep_going) { if (skip) continue; allocator.free(bytes); break; } else { allocator.free(bytes); }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "cleanup before a labeled break releases an allocation" {
    const source: [:0]const u8 =
        "fn run(allocator: std.mem.Allocator) !void {" ++
        "const bytes = try allocator.alloc(u8, 16);" ++
        "outer: while (true) { allocator.free(bytes); break :outer; }" ++
        "}";
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

fn freeFindings(allocator: std.mem.Allocator, found: []types.Finding) void {
    for (found) |finding| freeFinding(allocator, finding);
    allocator.free(found);
}

fn countRule(source: [:0]const u8, rule: types.Rule) !usize {
    const found = try findings(std.testing.allocator, source);
    defer freeFindings(std.testing.allocator, found);
    var count: usize = 0;
    for (found) |finding| {
        if (finding.rule == rule) count += 1;
    }
    return count;
}

test "re-acquiring a binding between releases starts a new lifetime" {
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "fn run(a: std.mem.Allocator) !void { var s = try a.alloc(u8, 4); a.free(s); s = try a.alloc(u8, 8); a.free(s); }",
        .double_release,
    ));
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "fn run(a: std.mem.Allocator) !void { var l = try make(a); l.deinit(a); l = try make(a); defer l.deinit(a); }" ++
            "fn make(a: std.mem.Allocator) !std.ArrayList(u8) { return try .initCapacity(a, 1); }",
        .double_release,
    ));
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn run(a: std.mem.Allocator) !void { var s = try a.alloc(u8, 4); a.free(s); a.free(s); }",
        .double_release,
    ));
}

test "destroy through a pool is not a double release of a recycled item" {
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "fn run(pool: *Pool) !void { const a = try pool.create(); pool.destroy(a); const b = try pool.create(); _ = b; pool.destroy(a); }",
        .double_release,
    ));
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn run(allocator: std.mem.Allocator) !void { const a = try allocator.create(u8); allocator.destroy(a); allocator.destroy(a); }",
        .double_release,
    ));
}

test "a pointer to an array from a slice allocation is released by destroy or free" {
    const helper =
        "fn block(allocator: std.mem.Allocator) error{OutOfMemory}!*align(64) [64]u8 {" ++
        "const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(64), 64); return bytes[0..64]; }";
    for ([_][:0]const u8{
        helper ++ "fn run(a: std.mem.Allocator) !void { const b = try block(a); defer a.destroy(b); b[0] = 1; }",
        helper ++ "fn run(a: std.mem.Allocator) !void { const b = try block(a); defer a.free(b); b[0] = 1; }",
    }) |source| {
        const found = try findings(std.testing.allocator, source);
        defer freeFindings(std.testing.allocator, found);
        try std.testing.expectEqual(@as(usize, 0), found.len);
    }
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        helper ++ "fn run(a: std.mem.Allocator) !void { const b = try block(a); b[0] = 1; }",
        .unreleased_allocation,
    ));
    // A slice return still needs `free`.
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn bytes(a: std.mem.Allocator) ![]u8 { return a.alloc(u8, 4); }" ++
            "fn run(a: std.mem.Allocator) !void { const b = try bytes(a); defer a.destroy(b); }",
        .mismatched_allocation_release,
    ));
}

test "leaks in tests and through the build graph allocator are not reported" {
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "test \"scratch\" { const a = std.testing.allocator; const b = try a.alloc(u8, 4); try check(); a.free(b); }" ++
            "test \"late\" { const a = std.testing.allocator; const b = try a.alloc(u8, 4); try check(); defer a.free(b); }",
        .unreleased_allocation,
    ));
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "test \"late\" { const a = std.testing.allocator; const b = try a.alloc(u8, 4); try check(); defer a.free(b); }",
        .cleanup_after_fallible_operation,
    ));
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "pub fn build(b: *std.Build) void { const exes = b.allocator.alloc(u8, 6) catch @panic(\"OOM\"); _ = exes; }" ++
            "const Lib = struct { builder: *std.Build, fn name(self: Lib) ![]u8 { const text = try std.fmt.allocPrint(self.builder.allocator, \"x\", .{}); _ = text; } };" ++
            "fn step(b: *std.Build) !void { const gpa = b.allocator; const node = try gpa.create(u8); _ = node; }",
        .unreleased_allocation,
    ));
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn leak(a: std.mem.Allocator) !void { const b = try a.alloc(u8, 4); try check(); a.free(b); }",
        .unreleased_allocation,
    ));
}

test "a writer over a freed buffer is a use after release" {
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn run(io: std.Io, gpa: std.mem.Allocator) !void { const buf = try gpa.alloc(u8, 64);" ++
            " var w = std.Io.File.stdout().writer(io, buf); gpa.free(buf);" ++
            " try w.interface.print(\"hi\", .{}); try w.interface.flush(); }",
        .use_after_release,
    ));
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn run(gpa: std.mem.Allocator) !void { const buf = try gpa.alloc(u8, 64);" ++
            " var w: std.Io.Writer = .fixed(buf); gpa.free(buf); try w.writeAll(\"hi\"); }",
        .use_after_release,
    ));
    // Released after the last use, deferred, or with the writer pointed elsewhere first.
    for ([_][:0]const u8{
        "fn run(io: std.Io, gpa: std.mem.Allocator) !void { const buf = try gpa.alloc(u8, 64);" ++
            " var w = std.Io.File.stdout().writer(io, buf); try w.interface.flush(); gpa.free(buf); }",
        "fn run(io: std.Io, gpa: std.mem.Allocator) !void { const buf = try gpa.alloc(u8, 64); defer gpa.free(buf);" ++
            " var w = std.Io.File.stdout().writer(io, buf); try w.interface.flush(); }",
        "fn run(io: std.Io, gpa: std.mem.Allocator, other: []u8) !void { const buf = try gpa.alloc(u8, 64);" ++
            " var w = std.Io.File.stdout().writer(io, buf); gpa.free(buf);" ++
            " w = std.Io.File.stdout().writer(io, other); try w.interface.flush(); }",
    }) |source| try std.testing.expectEqual(@as(usize, 0), try countRule(source, .use_after_release));
}

test "a freed duplicate printed afterwards is a use after release" {
    try std.testing.expectEqual(@as(usize, 1), try countRule(
        "fn run(gpa: std.mem.Allocator) !void { const s = try gpa.dupe(u8, \"x\"); gpa.free(s); std.debug.print(\"{s}\", .{s}); }",
        .use_after_release,
    ));
    try std.testing.expectEqual(@as(usize, 0), try countRule(
        "fn run(gpa: std.mem.Allocator) !void { const s = try gpa.dupe(u8, \"x\"); std.debug.print(\"{s}\", .{s}); gpa.free(s); }",
        .use_after_release,
    ));
}
