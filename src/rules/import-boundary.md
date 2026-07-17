# `import-boundary`

[Rule index](RULES.md)

Reports an import denied by a project contract in `zig-analyzer.json`.

**Why it matters.** Declared dependency direction prevents transport and other
outer layers from leaking into analysis code.

**When it matters.** Only configured source and denied path prefixes are
matched; no architectural boundary is guessed from directory names.
