# Contributing

## Verify

Run the narrow test for what you changed while iterating, then `zig build ci`
before you propose a change. It is the same list CI runs: formatting, the unit,
contract and editor tests, the compiler-backed tests, and the analyzer's own
check of this repository. [DEVELOPING.md](DEVELOPING.md#verify) explains each
part and the first-time setup (the patched compiler takes about 15 minutes to
build once).

## Where changes go

- Lint rules, code actions, hover, compiler queries and configuration:
  [EXTENDING.md](EXTENDING.md) has a recipe for each. Module boundaries and
  dependency direction are in [ARCHITECTURE.md](ARCHITECTURE.md); rule and
  action contracts are in `src/rules/README.md` and `src/actions/README.md`.
- The patched Zig compiler: [compiler/README.md](compiler/README.md).
- Rule documents under `docs/rules/` are generated from the catalog by
  `zig build rule-docs`; edit only the `## Why it matters` and
  `## When it fires` sections by hand. `zig build test` fails when they drift.
- Fix a false positive by adding a template to `tests/rule_fuzz.zig` as well as
  a focused test next to the rule.

## Commits

Use a plain imperative subject line that says what the commit does, for
example `Allow cold compiler-backed CI builds to finish`, with a body when the
reason is not obvious. Keep unrelated changes in separate commits.

A release bump is its own commit: the new `.version` in `build.zig.zon` and
`docs/release-<version>.md` (indexed from `docs/README.md`), nothing else. Then
tag it as described in [DEVELOPING.md](DEVELOPING.md#publishing-a-release).
