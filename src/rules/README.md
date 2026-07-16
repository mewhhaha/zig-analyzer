# Rule architecture

`analysis.zig` is the stable public facade. Rule implementation lives in this
directory and receives a tokenized document through `RuleRun`; rules never read
files, publish LSP messages, or apply edits themselves.

Add an independent rule in these places:

1. Add its `snake_case` identifier to `types.zig`; the stable kebab-case code is
   derived from that name. Add a tier or minimum profile only when the default
   opt-in style policy is not appropriate.
2. Add `<rule-code>.zig` with a `pub fn run(run: RuleRun) !void` entry point.
3. Add the module once to `registry.zig`'s ordered `rule_modules` tuple.
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

Each stable rule code has a neighboring `<rule-code>.md` page, linked from
`RULES.md`. A unit test requires one document, index link, and why/when section
per `Rule` member, so adding a rule is incomplete until its user-facing
rationale is documented.
