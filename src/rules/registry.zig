const RuleRun = @import("context.zig").RuleRun;

const cleanup_after_fallible_operation = @import("cleanup_after_fallible_operation.zig");
const cleanup_lifecycle = @import("cleanup_lifecycle.zig");
const container_invalidation = @import("container_invalidation.zig");
const error_idioms = @import("error_idioms.zig");
const escaping_storage = @import("escaping_storage.zig");
const invalidated_container_view = @import("invalidated_container_view.zig");
const inclusive_index_bound = @import("inclusive_index_bound.zig");
const needless_defer_block = @import("needless_defer_block.zig");
const needless_empty_else = @import("needless_empty_else.zig");
const optional_switch_idioms = @import("optional_switch_idioms.zig");
const prefer_testing_expect_equal_strings = @import("prefer_testing_expect_equal_strings.zig");
const redundant_boolean_if = @import("redundant_boolean_if.zig");
const redundant_optional_unwrap = @import("redundant_optional_unwrap.zig");
const returning_local_slice = @import("returning_local_slice.zig");
const returning_released_value = @import("returning_released_value.zig");
const testing_idioms = @import("testing_idioms.zig");
const unsigned_reverse_loop = @import("unsigned_reverse_loop.zig");
const unsafe_orelse_unreachable = @import("unsafe_orelse_unreachable.zig");

pub fn run(context: RuleRun) !void {
    try cleanup_after_fallible_operation.run(context);
    try cleanup_lifecycle.run(context);
    try container_invalidation.run(context);
    try escaping_storage.run(context);
    try invalidated_container_view.run(context);
    try inclusive_index_bound.run(context);
    try needless_defer_block.run(context);
    try needless_empty_else.run(context);
    try redundant_boolean_if.run(context);
    try returning_local_slice.run(context);
    try returning_released_value.run(context);
    try unsigned_reverse_loop.run(context);
    try unsafe_orelse_unreachable.run(context);
    try redundant_optional_unwrap.run(context);
    try error_idioms.run(context);
    try optional_switch_idioms.run(context);
    try prefer_testing_expect_equal_strings.run(context);
    try testing_idioms.run(context);
}

test {
    _ = cleanup_after_fallible_operation;
    _ = cleanup_lifecycle;
    _ = container_invalidation;
    _ = error_idioms;
    _ = escaping_storage;
    _ = invalidated_container_view;
    _ = inclusive_index_bound;
    _ = needless_defer_block;
    _ = needless_empty_else;
    _ = prefer_testing_expect_equal_strings;
    _ = redundant_boolean_if;
    _ = redundant_optional_unwrap;
    _ = returning_local_slice;
    _ = returning_released_value;
    _ = optional_switch_idioms;
    _ = testing_idioms;
    _ = unsigned_reverse_loop;
    _ = unsafe_orelse_unreachable;
}
