pub const build_options = @import("build_options");

comptime {
    @setEvalBranchQuota(50_000);
}

/// Findings and fixes over source text; the one entry point for lint engines.
pub const analysis = @import("analysis.zig");
pub const filesystem = @import("filesystem.zig");
pub const uri = @import("uri.zig");

/// Source-text models: tokens, scopes, type sites, open documents, byte edits.
pub const syntax = struct {
    pub const annotations = @import("syntax/annotations.zig");
    pub const cursor = @import("syntax/cursor.zig");
    pub const declaration_summary = @import("syntax/declaration_summary.zig");
    pub const document = @import("syntax/document.zig");
    pub const language_reference = @import("syntax/language_reference.zig");
    pub const scope = @import("syntax/scope.zig");
    pub const symbol_query = @import("syntax/symbol_query.zig");
    pub const text_edits = @import("syntax/text_edits.zig");
    pub const tokens = @import("syntax/tokens.zig");
    pub const types = @import("syntax/types.zig");
};

/// Boundary to the patched Zig compiler: protocol, process, session, bootstrap.
pub const compiler = struct {
    pub const bootstrap = @import("compiler/bootstrap.zig");
    pub const build_configuration = @import("compiler/build_configuration.zig");
    pub const build_graph = @import("compiler/build_graph.zig");
    pub const client = @import("compiler/client.zig");
    pub const compile_units = @import("compiler/compile_units.zig");
    pub const generated_sources = @import("compiler/generated_sources.zig");
    pub const process = @import("compiler/process.zig");
    pub const protocol = @import("compiler/protocol.zig");
    pub const session = @import("compiler/session.zig");
    pub const zig_environment = @import("compiler/zig_environment.zig");
    pub const zig_fmt = @import("compiler/zig_fmt.zig");
};

/// Workspace-level checks shared by the CLI and the language server.
pub const project = struct {
    pub const check = @import("project/check.zig");
    pub const check_cache = @import("project/check_cache.zig");
    pub const config = @import("project/config.zig");
    pub const describe = @import("project/describe.zig");
    pub const imported_deprecations = @import("project/imported_deprecations.zig");
    pub const module_sites = @import("project/module_sites.zig");
};

/// The language server transport; the only layer that speaks LSP.
pub const lsp = struct {
    pub const code_actions = @import("lsp/code_actions.zig");
    pub const compiler_backend = @import("lsp/compiler_backend.zig");
    pub const completion = @import("lsp/completion.zig");
    pub const diagnostics = @import("lsp/diagnostics.zig");
    pub const hover = @import("lsp/hover.zig");
    pub const hover_markdown = @import("lsp/hover_markdown.zig");
    pub const navigation = @import("lsp/navigation.zig");
    pub const presentation = @import("lsp/presentation.zig");
    pub const rename = @import("lsp/rename.zig");
    pub const server = @import("lsp/server.zig");
    pub const services = @import("lsp/services.zig");
};

pub const allocation_lifecycle = @import("rules/lifecycle/allocation_lifecycle.zig");
pub const summaries = @import("rules/summaries.zig");
pub const rule_catalog = @import("rules/catalog.zig");
pub const rule_docs = @import("rules/rule_docs.zig");
pub const project_rules = @import("rules/project.zig");

test {
    _ = analysis;
    _ = filesystem;
    _ = uri;
    _ = syntax.annotations;
    _ = syntax.cursor;
    _ = syntax.declaration_summary;
    _ = syntax.document;
    _ = syntax.language_reference;
    _ = syntax.scope;
    _ = syntax.symbol_query;
    _ = syntax.text_edits;
    _ = syntax.tokens;
    _ = syntax.types;
    _ = compiler.bootstrap;
    _ = compiler.build_configuration;
    _ = compiler.build_graph;
    _ = compiler.client;
    _ = compiler.compile_units;
    _ = compiler.generated_sources;
    _ = compiler.process;
    _ = compiler.protocol;
    _ = compiler.session;
    _ = compiler.zig_environment;
    _ = compiler.zig_fmt;
    _ = project.check;
    _ = project.check_cache;
    _ = project.config;
    _ = project.describe;
    _ = project.imported_deprecations;
    _ = project.module_sites;
    _ = lsp.code_actions;
    _ = lsp.compiler_backend;
    _ = lsp.completion;
    _ = lsp.diagnostics;
    _ = lsp.hover;
    _ = lsp.hover_markdown;
    _ = lsp.navigation;
    _ = lsp.presentation;
    _ = lsp.rename;
    _ = lsp.server;
    _ = lsp.services;
    _ = allocation_lifecycle;
    _ = summaries;
    _ = rule_catalog;
    _ = rule_docs;
    _ = project_rules;
    // Reached only through their registries otherwise, which does not run their tests.
    _ = @import("actions/context.zig");
    _ = @import("actions/lsp_adapter.zig");
    _ = @import("actions/project.zig");
    _ = @import("actions/registry.zig");
    _ = @import("test_reachability.zig");
}
