const RuleRun = @import("context.zig").RuleRun;

const rule_modules = .{
    @import("aliased_memcpy.zig"),
    @import("banned_identifier.zig"),
    @import("cleanup_after_fallible_operation.zig"),
    @import("cleanup_lifecycle.zig"),
    @import("container_invalidation.zig"),
    @import("copied_io_interface.zig"),
    @import("directory_iteration_not_enabled.zig"),
    @import("discarded_must_use.zig"),
    @import("discarded_read_count.zig"),
    @import("discarded_write_count.zig"),
    @import("escaping_storage.zig"),
    @import("invalidated_container_view.zig"),
    @import("inclusive_index_bound.zig"),
    @import("missing_errdefer.zig"),
    @import("needless_defer_block.zig"),
    @import("needless_empty_else.zig"),
    @import("negated_comptime_expression.zig"),
    @import("redundant_boolean_if.zig"),
    @import("returning_local_slice.zig"),
    @import("returning_released_value.zig"),
    @import("unbraced_multiline_if.zig"),
    @import("unconditional_busy_loop.zig"),
    @import("unchecked_first_element.zig"),
    @import("undefined_readvec_destination.zig"),
    @import("unsigned_reverse_loop.zig"),
    @import("unsafe_orelse_unreachable.zig"),
    @import("usize_in_packed_struct.zig"),
    @import("redundant_optional_unwrap.zig"),
    @import("error_idioms.zig"),
    @import("optional_switch_idioms.zig"),
    @import("prefer_testing_expect_equal_strings.zig"),
    @import("testing_idioms.zig"),
    @import("truncating_intcast.zig"),
    @import("padded_byte_compare.zig"),
    @import("compiler_hygiene.zig"),
    @import("prefer_expression_initializer.zig"),
    @import("combine_identical_switch_prongs.zig"),
    @import("prefer_optional_while_capture.zig"),
    @import("prefer_loop_else.zig"),
    @import("prefer_orelse.zig"),
    @import("memory_idioms.zig"),
    @import("prefer_multi_sequence_for.zig"),
    @import("prefer_early_return.zig"),
    @import("prefer_switch.zig"),
    @import("helping_hand.zig"),
    @import("modernize.zig"),
    @import("discipline_policy.zig"),
    @import("invariant_loop_condition.zig"),
};

pub fn run(context: RuleRun) !void {
    inline for (rule_modules) |rule_module| try rule_module.run(context);
}

test {
    _ = rule_modules;
}
