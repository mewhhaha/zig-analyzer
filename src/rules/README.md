# Rule architecture

`analysis.zig` is the stable public facade. Rule implementation lives in this
directory and receives a tokenized document through `RuleRun`; rules never
read files, publish LSP messages, or apply edits themselves.

Add an independent rule in four places:

1. Add its stable identifier, code, tier, and minimum profile to `types.zig`.
2. Add `<rule-code>.zig` with a `pub fn run(run: RuleRun) !void` entry point.
3. Register that module in `registry.zig` in deterministic diagnostic order.
4. Keep positive, negative, suppression, and fix tests beside the rule.

`RuleRun.emit` applies severity and source suppression uniformly. A rule owns
its messages and edits, and marks an edit as fix-all only when it is both
semantics-preserving and independent of project policy. The registry sorts the
combined result afterward, so modules do not depend on one another's order.

`configuration.zig` is the trust boundary for `zig-analyzer.json` and source
suppression directives. It converts JSON into the types in `types.zig`; rule
modules consume those types and never parse project configuration themselves.

Some findings share one proof and intentionally share an engine. For example,
`allocation_lifecycle.zig` recognizes an allocation once and derives missing,
late, mismatched, duplicate, post-release, and overwritten-ownership findings
from that same binding identity. Splitting those traversals by diagnostic code
would make their answers disagree. `semantic.zig` similarly owns rules that
share resolved container and scope facts. New syntax-local rules should be
separate modules; extend a shared engine only when the new finding requires the
same proof.

`project.zig` is the corresponding boundary for findings that require multiple
files. It receives normalized relative paths and complete source text from the
CLI scanner. File-local runners must not infer build reachability or compare
compile configurations from a single document.
