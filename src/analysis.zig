const semantic = @import("rules/semantic.zig");

pub const Level = semantic.Level;
pub const Rule = semantic.Rule;
pub const Configuration = semantic.Configuration;
pub const LintProfile = semantic.LintProfile;
pub const Edit = semantic.Edit;
pub const ActionKind = semantic.ActionKind;
pub const Fix = semantic.Fix;
pub const Finding = semantic.Finding;
pub const RelatedSpan = semantic.RelatedSpan;
pub const ResolvedShape = semantic.ResolvedShape;

pub const parseConfiguration = semantic.parseConfiguration;
pub const suppressionWarning = semantic.suppressionWarning;
pub const findings = semantic.findings;
pub const findingsWithTokens = semantic.findingsWithTokens;
pub const findingsWithShapes = semantic.findingsWithShapes;
pub const fileNameFinding = semantic.fileNameFinding;
pub const isSuppressed = semantic.isSuppressed;

test {
    _ = semantic;
}
