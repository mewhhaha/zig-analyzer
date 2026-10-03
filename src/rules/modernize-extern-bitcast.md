# `modernize-extern-bitcast`

Reports `@bitCast` calls with a proven `extern struct` or `extern union` source
or destination, which Zig 0.17 no longer permits.

**Why it matters.** The new logical-bit definition excludes these native-layout
types. Code that reinterprets memory may need `@ptrCast` or an `extern union`,
with an explicit review of alignment, lifetime, and the intended representation.

**When it matters.** Enabled by the `modernize` profile. Scoped type declarations
and aliases, explicit local and parameter types, complete initializers, and
`@as` result types establish the proof. Packed and regular containers, pointers,
indexed elements, member projections, unknown imported types, and shadowed
bindings are skipped. The rule gives migration guidance without an automatic
edit because memory reinterpretation requires choices the syntax cannot prove.

See [Zig 0.17 `@bitCast` changes](https://ziglang.org/download/0.17.0/release-notes.html#codebitCastcode-changes).
