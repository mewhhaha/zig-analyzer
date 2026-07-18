test {
    _ = @import("compiler/comptime_pipeline.zig");
    _ = @import("compiler/conditional_api.zig");
    _ = @import("compiler/indirect_type_lookup.zig");
    _ = @import("compiler/parsed_configuration.zig");
    _ = @import("compiler/recursive_wrapper.zig");
    _ = @import("compiler/reflected_strategy.zig");
    _ = @import("compiler/reified_flags.zig");
    _ = @import("diagnostics/memory_management.zig");
    _ = @import("diagnostics/overlapping_copy.zig");
    _ = @import("diagnostics/unsigned_reverse_loop.zig");
    _ = @import("diagnostics/padded_equality.zig");
    _ = @import("diagnostics/discarded_error.zig");
    _ = @import("diagnostics/idiomatic_style.zig");
    _ = @import("diagnostics/lifetime_mistakes.zig");
    _ = @import("diagnostics/action_results.zig");
    _ = @import("diagnostics/use_after_release.zig");
    _ = @import("diagnostics/dangling_slice.zig");
    _ = @import("diagnostics/helper_release.zig");
    _ = @import("lsp/imports/main.zig");
    _ = @import("lsp/hover.zig");
    _ = @import("lsp/language_hover.zig");
    _ = @import("lsp/scoped_rename.zig");
    _ = @import("lsp/stdlib_completion.zig");
    _ = @import("lsp/struct_fields.zig");
}
