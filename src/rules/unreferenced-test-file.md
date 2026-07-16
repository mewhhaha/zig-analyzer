# `unreferenced-test-file`

[Rule index](RULES.md)

Reports a test source file that is neither imported by another Zig file nor
referenced from `build.zig`.

**Why it matters.** Zig only runs tests reachable from the selected root, so an
orphaned test file can give a false impression of coverage.

**When it matters.** It is a project scan rule for test-like paths containing
test declarations.
