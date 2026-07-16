test {
    _ = @import("compiler/comptime_pipeline.zig");
    _ = @import("compiler/conditional_api.zig");
    _ = @import("compiler/indirect_type_lookup.zig");
    _ = @import("compiler/parsed_configuration.zig");
    _ = @import("compiler/recursive_wrapper.zig");
    _ = @import("compiler/reflected_strategy.zig");
    _ = @import("diagnostics/memory_management.zig");
    _ = @import("diagnostics/idiomatic_style.zig");
    _ = @import("diagnostics/lifetime_mistakes.zig");
    _ = @import("diagnostics/action_results.zig");
    _ = @import("zls/imports/main.zig");
    _ = @import("zls/hover.zig");
    _ = @import("zls/scoped_rename.zig");
    _ = @import("zls/stdlib_completion.zig");
    _ = @import("zls/struct_fields.zig");
}
