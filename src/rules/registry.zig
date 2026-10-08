const RuleRun = @import("context.zig").RuleRun;

const rule_modules = .{
    // hazards/: code that compiles but misbehaves
    @import("hazards/aliased_memcpy.zig"),
    @import("hazards/allocation_size_overflow.zig"),
    @import("hazards/concurrency_hazards.zig"),
    @import("hazards/copied_io_interface.zig"),
    @import("hazards/directory_iteration_not_enabled.zig"),
    @import("hazards/discarded_must_use.zig"),
    @import("hazards/discarded_read_count.zig"),
    @import("hazards/discarded_write_count.zig"),
    @import("hazards/identical_bitwise_operands.zig"),
    @import("hazards/identical_comparison_operands.zig"),
    @import("hazards/identical_conditional_branches.zig"),
    @import("hazards/identical_logical_operands.zig"),
    @import("hazards/inclusive_index_bound.zig"),
    @import("hazards/invariant_loop_condition.zig"),
    @import("hazards/io_contract_hazards.zig"),
    @import("hazards/nan_comparison.zig"),
    @import("hazards/padded_byte_compare.zig"),
    @import("hazards/self_assignment.zig"),
    @import("hazards/truncating_intcast.zig"),
    @import("hazards/unchecked_first_element.zig"),
    @import("hazards/unchecked_slice_reinterpretation.zig"),
    @import("hazards/unconditional_busy_loop.zig"),
    @import("hazards/undefined_readvec_destination.zig"),
    @import("hazards/unsafe_orelse_unreachable.zig"),
    @import("hazards/unsequenced_state_access.zig"),
    @import("hazards/unsigned_arithmetic_guards.zig"),
    @import("hazards/unsigned_reverse_loop.zig"),
    @import("hazards/usize_in_packed_struct.zig"),

    // idioms/: advice to rewrite into a clearer or cheaper equivalent
    @import("idioms/catch_idioms.zig"),
    @import("idioms/combine_identical_switch_prongs.zig"),
    @import("idioms/comparison_idioms.zig"),
    @import("idioms/comptime_idioms.zig"),
    @import("idioms/container_idioms.zig"),
    @import("idioms/error_idioms.zig"),
    @import("idioms/expect_equal_argument_order.zig"),
    @import("idioms/memory_idioms.zig"),
    @import("idioms/mixed_bitwise_arithmetic.zig"),
    @import("idioms/needless_cast.zig"),
    @import("idioms/needless_defer_block.zig"),
    @import("idioms/needless_else_after_terminator.zig"),
    @import("idioms/needless_empty_else.zig"),
    @import("idioms/negated_comptime_expression.zig"),
    @import("idioms/optional_switch_idioms.zig"),
    @import("idioms/pointer_to_allocator.zig"),
    @import("idioms/prefer_allocator_dupe.zig"),
    @import("idioms/prefer_append_slice.zig"),
    @import("idioms/prefer_arena.zig"),
    @import("idioms/prefer_buffered_writer.zig"),
    @import("idioms/prefer_div_ceil.zig"),
    @import("idioms/prefer_early_return.zig"),
    @import("idioms/prefer_empty_slice_len.zig"),
    @import("idioms/prefer_eql_over_order.zig"),
    @import("idioms/prefer_expression_initializer.zig"),
    @import("idioms/prefer_log_over_print.zig"),
    @import("idioms/prefer_loop_else.zig"),
    @import("idioms/prefer_map_get_or_put.zig"),
    @import("idioms/prefer_math_pow.zig"),
    @import("idioms/prefer_memcpy.zig"),
    @import("idioms/prefer_memset.zig"),
    @import("idioms/prefer_min_max.zig"),
    @import("idioms/prefer_multi_sequence_for.zig"),
    @import("idioms/prefer_optional_capture.zig"),
    @import("idioms/prefer_optional_while_capture.zig"),
    @import("idioms/prefer_orelse.zig"),
    @import("idioms/prefer_range_for.zig"),
    @import("idioms/prefer_scalar_needle.zig"),
    @import("idioms/prefer_string_switch.zig"),
    @import("idioms/prefer_switch.zig"),
    @import("idioms/prefer_testing_expect_equal.zig"),
    @import("idioms/prefer_testing_expect_equal_strings.zig"),
    @import("idioms/prefer_try.zig"),
    @import("idioms/prefer_vector_reduce.zig"),
    @import("idioms/prefer_write_byte.zig"),
    @import("idioms/redundant_boolean_if.zig"),
    @import("idioms/redundant_boolean_negation.zig"),
    @import("idioms/redundant_optional_unwrap.zig"),
    @import("idioms/redundant_slice_end.zig"),
    @import("idioms/testing_idioms.zig"),
    @import("idioms/type_expression_idioms.zig"),
    @import("idioms/unbraced_multiline_if.zig"),
    @import("idioms/vector_literals.zig"),

    // lifecycle/: lifetime of owned values
    @import("lifecycle/allocation_lifecycle.zig"),
    @import("lifecycle/child_process.zig"),
    @import("lifecycle/cleanup_lifecycle.zig"),
    @import("lifecycle/container_invalidation.zig"),
    @import("lifecycle/discarded_realloc_result.zig"),
    @import("lifecycle/discarded_resource.zig"),
    @import("lifecycle/escaping_storage.zig"),
    @import("lifecycle/invalidated_container_view.zig"),
    @import("lifecycle/many_pointer_lengths.zig"),
    @import("lifecycle/missing_container_deinit.zig"),
    @import("lifecycle/missing_errdefer.zig"),
    @import("lifecycle/missing_resource_cleanup.zig"),
    @import("lifecycle/returning_local_slice.zig"),
    @import("lifecycle/returning_released_value.zig"),

    // modernize/: Zig version migration
    @import("modernize/modernize.zig"),
    @import("modernize/modernize_containers.zig"),
    @import("modernize/modernize_layout.zig"),

    // semantic/: proofs over scope, container, and declaration facts
    @import("semantic/binding_mutation.zig"),
    @import("semantic/compiler_hygiene.zig"),
    @import("semantic/containers.zig"),
    @import("semantic/unresolved_names.zig"),
    @import("semantic/unused_private_declaration.zig"),

    // style/: naming, layout, and discipline policies
    @import("style/assertion_free_branching.zig"),
    @import("style/assertion_free_test.zig"),
    @import("style/banned_identifier.zig"),
    @import("style/function_length.zig"),
    @import("style/imports.zig"),
    @import("style/line_length.zig"),
    @import("style/official_style.zig"),
    @import("style/parameter_order.zig"),
    @import("style/quadratic_front_removal.zig"),
    @import("style/todo_comment.zig"),
    @import("style/unbounded_loop.zig"),
};

/// Every engine that reports findings, file-local or project-wide.
pub const engines = rule_modules ++ .{@import("project.zig")};

/// Runs the file-local modules that have a rule enabled.
pub fn run(context: RuleRun) !void {
    inline for (rule_modules) |rule_module| {
        if (context.configuration.anyEnabled(&rule_module.rules)) try rule_module.run(context);
    }
}

test "every rule is owned by exactly one engine" {
    const std = @import("std");
    const Rule = @import("types.zig").Rule;
    var owners: [@typeInfo(Rule).@"enum".field_names.len]usize = @splat(0);
    inline for (engines) |engine| {
        for (engine.rules) |rule| owners[@backingInt(rule)] += 1;
    }
    for (std.enums.values(Rule)) |rule| {
        if (owners[@backingInt(rule)] != 1) {
            std.debug.print("rule {s} has {d} owners\n", .{ rule.code(), owners[@backingInt(rule)] });
            return error.RuleOwnership;
        }
    }
}

test "refined rules are owned by a file-local engine" {
    const std = @import("std");
    const project = @import("project.zig");
    @setEvalBranchQuota(100_000);
    inline for (project.refines) |rule| {
        var owned = false;
        inline for (rule_modules) |engine| {
            for (engine.rules) |engine_rule| owned = owned or engine_rule == rule;
        }
        if (!owned) {
            std.debug.print("refined rule {s} has no file-local owner\n", .{rule.code()});
            return error.RuleOwnership;
        }
    }
}

test {
    _ = rule_modules;
    _ = @import("test_support.zig");
}
