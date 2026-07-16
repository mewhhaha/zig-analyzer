# `banned-identifier`

[Rule index](RULES.md)

Reports use of a project-configured identifier or dotted path.

**Why it matters.** Projects can prevent deprecated, unsafe, non-portable, or
policy-incompatible APIs and provide a migration hint at the use site.

**When it matters.** The rule activates when `lints.banned` entries are
configured; it has no built-in project-specific blacklist.
