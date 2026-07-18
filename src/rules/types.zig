const std = @import("std");

pub const Level = enum {
    off,
    hint,
    information,
    warning,
    @"error",
};

pub const Rule = enum {
    unresolved_call,
    unresolved_identifier,
    unresolved_member,
    unresolved_label,
    missing_switch_prong,
    missing_struct_field,
    never_mutated_var,
    unreleased_allocation,
    defer_cleanup_in_loop,
    error_value_comparison,
    discarded_error,
    redundant_bool_comparison,
    redundant_boolean_if,
    non_exhaustive_switch_else,
    non_idiomatic_name,
    unsorted_imports,
    needless_cast,
    needless_else_after_terminator,
    needless_empty_else,
    mixed_bitwise_arithmetic,
    unused_private_declaration,
    cleanup_after_fallible_operation,
    mismatched_allocation_release,
    double_release,
    use_after_release,
    overwritten_owning_value,
    unsafe_catch_unreachable,
    lost_error_context,
    missing_resource_cleanup,
    undefined_value_escape,
    unknown_comptime_member,
    constant_comptime_condition,
    vague_type_name,
    redundant_qualified_name,
    underscore_private_name,
    non_idiomatic_file_name,
    doc_comment_style,
    public_declaration_docs,
    prefer_optional_capture,
    prefer_try,
    prefer_testing_expect_equal,
    mutable_pointer_parameter,
    redundant_comptime,
    redundant_inline,
    needless_defer_block,
    non_exhaustive_error_switch,
    duplicate_import,
    unused_import,
    redundant_import_path,
    redundant_type_qualification,
    prefer_anonymous_initializer,
    returning_local_slice,
    unsafe_orelse_unreachable,
    redundant_optional_unwrap,
    prefer_testing_expect_equal_strings,
    invalidated_container_view,
    returning_deinitialized_view,
    returning_arena_allocation,
    invalidated_element_pointer,
    defer_uses_reassigned_binding,
    error_collapsed_to_absence,
    allocation_size_overflow,
    resource_cleanup_on_error_only,
    iterator_invalidated_during_loop,
    prefer_testing_expect_equal_slices,
    prefer_testing_expect_error,
    prefer_testing_expect_approx,
    prefer_optional_presence_test,
    redundant_error_capture,
    needless_switch_else_capture,
    prefer_sentinel_termination,
    duplicate_c_import,
    unreferenced_test_file,
    conflicting_build_options,
    duplicate_module_import,
    returning_released_value,
    inclusive_index_bound,
    unsigned_reverse_loop,
    missing_errdefer,
    aliased_memcpy,
    negated_comptime_expression,
    usize_in_packed_struct,
    unbraced_multiline_if,
    unconditional_busy_loop,
    banned_identifier,
    truncating_intcast,
    padded_byte_compare,
    useless_error_return,
    exposed_private_type,
    exposed_private_error_set,
    deprecated_declaration,
    mutated_container_copy,
    prefer_range_for,
    prefer_index_of,
    prefer_memset,
    prefer_memcpy,
    prefer_string_switch,
    prefer_log_over_print,
    prefer_buffered_writer,
    prefer_arena,
    inconsistent_import_alias,
    minority_naming_style,
    inconsistent_parameter_vocabulary,
    inconsistent_error_set_style,
    modernize_managed_container,
    modernize_deprecated_io,
    modernize_deprecated_stdlib,
    function_length,
    assertion_free_branching,
    unbounded_loop,
    allocation_after_init,
    recursive_call,
    line_length,
    allocator_first_parameter,
    comptime_parameter_order,
    todo_comment,
    assertion_free_test,
    import_boundary,
    discarded_must_use,
    configuration_divergent_api,
    unreachable_public_declaration,

    pub fn code(rule: Rule) []const u8 {
        return switch (rule) {
            inline else => |known_rule| derivedRuleCode(@tagName(known_rule)),
        };
    }

    pub fn tier(rule: Rule) Tier {
        return switch (rule) {
            .unresolved_call,
            .unresolved_identifier,
            .unresolved_member,
            .unresolved_label,
            .missing_switch_prong,
            .missing_struct_field,
            .never_mutated_var,
            => .semantic,
            .unreleased_allocation,
            .defer_cleanup_in_loop,
            .error_value_comparison,
            .cleanup_after_fallible_operation,
            .mismatched_allocation_release,
            .double_release,
            .use_after_release,
            .overwritten_owning_value,
            .missing_resource_cleanup,
            .undefined_value_escape,
            .returning_local_slice,
            .invalidated_container_view,
            .returning_deinitialized_view,
            .returning_arena_allocation,
            .invalidated_element_pointer,
            .defer_uses_reassigned_binding,
            .allocation_size_overflow,
            .resource_cleanup_on_error_only,
            .iterator_invalidated_during_loop,
            .duplicate_module_import,
            .returning_released_value,
            .unsigned_reverse_loop,
            .missing_errdefer,
            .aliased_memcpy,
            .usize_in_packed_struct,
            .unconditional_busy_loop,
            .padded_byte_compare,
            .useless_error_return,
            .exposed_private_type,
            .exposed_private_error_set,
            .deprecated_declaration,
            .mutated_container_copy,
            .import_boundary,
            .discarded_must_use,
            => .correctness,
            else => .style,
        };
    }

    pub fn profile(rule: Rule) ?LintProfile {
        return switch (rule) {
            .non_idiomatic_name,
            .redundant_qualified_name,
            .underscore_private_name,
            .non_idiomatic_file_name,
            .doc_comment_style,
            => .official,
            .discarded_error,
            .redundant_bool_comparison,
            .redundant_boolean_if,
            .non_exhaustive_switch_else,
            .unsorted_imports,
            .needless_cast,
            .needless_else_after_terminator,
            .needless_empty_else,
            .mixed_bitwise_arithmetic,
            .unknown_comptime_member,
            .constant_comptime_condition,
            .prefer_optional_capture,
            .prefer_try,
            .prefer_testing_expect_equal,
            .mutable_pointer_parameter,
            .redundant_comptime,
            .redundant_inline,
            .needless_defer_block,
            .non_exhaustive_error_switch,
            .duplicate_import,
            .unused_import,
            .redundant_import_path,
            .redundant_type_qualification,
            .prefer_anonymous_initializer,
            .redundant_optional_unwrap,
            .prefer_testing_expect_equal_strings,
            .prefer_testing_expect_equal_slices,
            .prefer_testing_expect_error,
            .prefer_testing_expect_approx,
            .prefer_optional_presence_test,
            .redundant_error_capture,
            .needless_switch_else_capture,
            .prefer_sentinel_termination,
            .duplicate_c_import,
            .unreferenced_test_file,
            .conflicting_build_options,
            .inclusive_index_bound,
            .negated_comptime_expression,
            .unbraced_multiline_if,
            .prefer_range_for,
            .prefer_index_of,
            .prefer_memset,
            .prefer_memcpy,
            .prefer_string_switch,
            .prefer_log_over_print,
            .prefer_buffered_writer,
            .prefer_arena,
            => .idiomatic,
            .modernize_managed_container,
            .modernize_deprecated_io,
            .modernize_deprecated_stdlib,
            => .modernize,
            .function_length,
            .assertion_free_branching,
            .unbounded_loop,
            .allocation_after_init,
            .recursive_call,
            => .disciplined,
            .vague_type_name,
            .unsafe_catch_unreachable,
            .lost_error_context,
            .unsafe_orelse_unreachable,
            .error_collapsed_to_absence,
            .public_declaration_docs,
            => .strict,
            else => null,
        };
    }
};

pub const Tier = enum { semantic, correctness, style };

pub const BannedIdentifier = struct {
    path: []const u8,
    hint: ?[]const u8 = null,
};

pub const ImportBoundary = struct {
    from: []const u8,
    denied: []const []const u8,
};

pub const ResourceContract = struct {
    acquire: []const u8,
    release: []const u8,
};

pub const Configuration = struct {
    levels: [std.meta.fields(Rule).len]Level,
    lint_profile: LintProfile = .none,
    banned: []const BannedIdentifier = &.{},
    import_boundaries: []const ImportBoundary = &.{},
    resource_contracts: []const ResourceContract = &.{},
    must_use_contracts: []const []const u8 = &.{},
    check_excludes: []const []const u8 = &.{},
    function_length_limit: usize = 70,
    line_length_limit: usize = 100,
    line_length_allow_unsplittable: bool = true,
    todo_markers: []const []const u8 = &.{ "TODO", "FIXME", "XXX" },
    warning: ?[]const u8 = null,

    pub fn defaults() Configuration {
        var levels: [std.meta.fields(Rule).len]Level = undefined;
        for (std.enums.values(Rule)) |rule| {
            levels[@intFromEnum(rule)] = if (rule == .import_boundary or rule == .discarded_must_use or
                rule == .configuration_divergent_api or rule == .unreachable_public_declaration)
                .off
            else switch (rule.tier()) {
                .semantic => .@"error",
                .correctness => .warning,
                .style => .off,
            };
        }
        return .{ .levels = levels };
    }

    pub fn level(configuration: Configuration, rule: Rule) Level {
        return configuration.levels[@intFromEnum(rule)];
    }
};

pub const LintProfile = enum { none, official, idiomatic, strict, modernize, disciplined };

pub const Edit = struct {
    span: std.zig.Token.Loc,
    replacement: []const u8,
};

pub const ActionKind = enum {
    quickfix,
    refactor_extract,
    refactor_rewrite,
    organize_imports,
    fix_all,
};

pub const Fix = struct {
    title: []const u8,
    kind: ActionKind,
    edits: []const Edit,
    preferred: bool = false,
    fix_all: bool = false,
};

pub const Finding = struct {
    rule: Rule,
    level: Level,
    span: std.zig.Token.Loc,
    message: []const u8,
    related: []const RelatedSpan = &.{},
    fixes: []const Fix = &.{},
};

pub const RelatedSpan = struct {
    span: std.zig.Token.Loc,
    message: []const u8,
};

fn derivedRuleCode(comptime enum_name: []const u8) []const u8 {
    const code = comptime code: {
        var code_bytes: [enum_name.len]u8 = undefined;
        for (enum_name, 0..) |byte, index| {
            code_bytes[index] = if (byte == '_') '-' else byte;
        }
        break :code code_bytes;
    };
    return &code;
}

test "rule codes follow enum names" {
    try std.testing.expectEqualStrings("missing-switch-prong", Rule.missing_switch_prong.code());
    try std.testing.expectEqualStrings("padded-byte-compare", Rule.padded_byte_compare.code());
}

test "rule reference documents every rule" {
    @setEvalBranchQuota(10_000);
    const reference = @embedFile("RULES.md");
    try std.testing.expectEqual(
        std.meta.fields(Rule).len,
        std.mem.count(u8, reference, "\n- [`"),
    );

    for (std.enums.values(Rule)) |rule| {
        var heading_bytes: [128]u8 = undefined;
        const link = try std.fmt.bufPrint(&heading_bytes, "]({s}.md)", .{rule.code()});
        if (std.mem.count(u8, reference, link) != 1) {
            std.debug.print("rule reference needs exactly one '{s}' link\n", .{link});
            return error.IncompleteRuleReference;
        }
    }

    inline for (std.meta.fields(Rule)) |enum_field| {
        const document = @embedFile(comptime derivedRuleDocumentPath(enum_field.name));
        if (std.mem.indexOf(u8, document, "**Why it matters.**") == null or
            std.mem.indexOf(u8, document, "**When it matters.**") == null)
        {
            std.debug.print("rule document '{s}' needs why and when explanations\n", .{enum_field.name});
            return error.IncompleteRuleReference;
        }
    }
}

fn derivedRuleDocumentPath(comptime enum_name: []const u8) []const u8 {
    const extension = ".md";
    const path = comptime path: {
        var path_bytes: [enum_name.len + extension.len]u8 = undefined;
        for (enum_name, 0..) |byte, index| {
            path_bytes[index] = if (byte == '_') '-' else byte;
        }
        for (extension, 0..) |byte, index| path_bytes[enum_name.len + index] = byte;
        break :path path_bytes;
    };
    return &path;
}
