pub const build_options = @import("build_options");
pub const analysis = @import("analysis.zig");
pub const backend_bootstrap = @import("backend_bootstrap.zig");
pub const compiler_protocol = @import("compiler_protocol.zig");
pub const compiler_client = @import("compiler_client.zig");
pub const compiler_session = @import("compiler_session.zig");
pub const document = @import("document.zig");
pub const lsp_server = @import("lsp_server.zig");
pub const allocation_lifecycle = @import("rules/allocation_lifecycle.zig");
pub const memory_lint = allocation_lifecycle;
pub const project_check = @import("project_check.zig");

test {
    _ = analysis;
    _ = backend_bootstrap;
    _ = compiler_protocol;
    _ = compiler_client;
    _ = compiler_session;
    _ = document;
    _ = lsp_server;
    _ = allocation_lifecycle;
    _ = memory_lint;
    _ = project_check;
}
