//! The cross-file ownership engine. It summarizes every file once, then runs
//! the checks that need a callee's summary from another file: the
//! file-local lifecycle engines re-run with summaries, and the owned-field
//! cleanup proofs.
const allocation_lifecycle = @import("../lifecycle/allocation_lifecycle.zig");
const summaries = @import("../summaries.zig");
const types = @import("../types.zig");
const owned_fields = @import("owned_fields.zig");
const run_module = @import("run.zig");
const summary_checks = @import("summary_checks.zig");

/// Rules only this engine reports.
pub const rules = owned_fields.rules;

/// Rules a file-local engine owns and this engine re-runs with cross-file
/// summaries, adding findings that need a callee in another file.
pub const refines = [_]types.Rule{
    .missing_errdefer,
    .discarded_read_count,
    .discarded_write_count,
    .invalidated_element_pointer,
    .invalidated_container_view,
    .iterator_invalidated_during_loop,
    .local_storage_escape,
    .returning_released_value,
} ++ allocation_lifecycle.rules;

const summary_rules = refines ++ rules;

pub fn run(project_run: run_module.ProjectRun) !void {
    if (!project_run.configuration.anyEnabled(&summary_rules)) return;
    const sources = try project_run.allocator.alloc(summaries.Source, project_run.files.len);
    for (project_run.files, sources, 0..) |file, *source, file_index| source.* = .{
        .file_index = file_index,
        .path = file.path,
        .source = file.source,
        .tokens = file.tokens,
    };
    const summary_index = try summaries.build(project_run.allocator, sources, project_run.configuration);
    try owned_fields.findIncompleteOwnedFieldCleanup(project_run, summary_index);
    try summary_checks.findDeferredOwnedEscapes(project_run, summary_index);
    for (0..project_run.files.len) |file_index| try summary_checks.checkFile(project_run, file_index, summary_index);
}
