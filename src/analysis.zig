const types = @import("rules/types.zig");
const configuration = @import("rules/configuration.zig");
const pipeline = @import("rules/pipeline.zig");
const official_style = @import("rules/style/official_style.zig");

pub const Level = types.Level;
pub const Rule = types.Rule;
pub const Configuration = types.Configuration;
pub const LintProfile = types.LintProfile;
pub const Edit = types.Edit;
pub const ActionKind = types.ActionKind;
pub const Fix = types.Fix;
pub const Finding = types.Finding;
pub const RelatedSpan = types.RelatedSpan;
pub const ResolvedShape = types.ResolvedShape;
pub const ModuleMembers = types.ModuleMembers;
pub const declarationBaseName = types.declarationBaseName;

pub const parseConfiguration = configuration.parse;
pub const suppressionWarning = configuration.suppressionWarning;
pub const suppressionEdits = configuration.suppressionEdits;
pub const Suppressions = configuration.Suppressions;
pub const findings = pipeline.findings;
pub const findingsWith = pipeline.findingsWith;
pub const moduleMemberFindings = pipeline.moduleMemberFindings;
pub const FindingsOptions = pipeline.Options;
pub const fileNameFinding = official_style.fileNameFinding;
pub const isTranslateCOutput = @import("rules/generated_source.zig").isTranslateCOutput;
pub const deprecated_declarations = @import("rules/modernize/deprecated_declarations.zig");
pub const resources = @import("rules/resources.zig");
pub const ruleDocumentationUrl = @import("rules/catalog.zig").documentationUrl;

test {
    _ = pipeline;
    _ = @import("rules/configuration.zig");
}
