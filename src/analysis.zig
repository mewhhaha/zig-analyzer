const types = @import("rules/types.zig");
const configuration = @import("rules/configuration.zig");
const pipeline = @import("rules/pipeline.zig");
const official_style = @import("rules/style/official_style.zig");

pub const Level = types.Level;
pub const Rule = types.Rule;
pub const Configuration = types.Configuration;
pub const LintProfile = types.LintProfile;
pub const NamingConventions = types.NamingConventions;
pub const Edit = types.Edit;
pub const ActionKind = types.ActionKind;
pub const Fix = types.Fix;
pub const Finding = types.Finding;
pub const RelatedSpan = types.RelatedSpan;
pub const ResolvedShape = types.ResolvedShape;
pub const ModuleMembers = types.ModuleMembers;
pub const ModuleExposure = types.ModuleExposure;
pub const declarationBaseName = types.declarationBaseName;

pub const parseConfiguration = configuration.parse;
pub const configurationForPath = configuration.forPath;
pub const pathMatches = configuration.pathMatches;
pub const suppressionWarning = configuration.suppressionWarning;
pub const suppressionEdits = configuration.suppressionEdits;
pub const Suppressions = configuration.Suppressions;
pub const ruleNamed = configuration.ruleNamed;
pub const nearestRuleCode = configuration.nearestRuleCode;
pub const DidYouMean = configuration.DidYouMean;
pub const findings = pipeline.findings;
pub const findingsWith = pipeline.findingsWith;
pub const moduleMemberFindings = pipeline.moduleMemberFindings;
pub const FindingsOptions = pipeline.Options;
pub const fileNameFinding = official_style.fileNameFinding;
pub const isTranslateCOutput = @import("rules/generated_source.zig").isTranslateCOutput;
pub const hasGeneratedHeader = @import("rules/generated_source.zig").hasGeneratedHeader;
pub const excessive_nesting_notice = pipeline.excessive_nesting_notice;
pub const deprecated_declarations = @import("rules/modernize/deprecated_declarations.zig");
pub const resources = @import("rules/resources.zig");
pub const container_types = @import("rules/container_types.zig");
pub const deinit_poison = @import("rules/style/missing_deinit_poison.zig");
pub const ruleDocumentationUrl = @import("rules/catalog.zig").documentationUrl;
pub const owned_results = @import("rules/owned_results.zig");

test {
    _ = pipeline;
    _ = owned_results;
    _ = @import("rules/configuration.zig");
}
