//! Language-server exchange tests, grouped by feature. They drive the public
//! server API through a scripted transport and need no patched compiler.
test {
    _ = @import("lsp/hover.zig");
    _ = @import("lsp/navigation.zig");
    _ = @import("lsp/completion.zig");
    _ = @import("lsp/code_actions.zig");
    _ = @import("lsp/presentation.zig");
    _ = @import("lsp/diagnostics.zig");
    _ = @import("lsp/session.zig");
}
