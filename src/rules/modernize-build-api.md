# `modernize-build-api`

Reports removed `std.Build.args` and `LazyPath.basename` access, the deprecated
`addTranslateC` build step, and deprecated Windows resource compilation APIs.

**Why it matters.** Zig 0.17 moves passthru arguments out of the configure
phase. A Run step now forwards them with `addPassthruArgs()`. C translation
moves to the official translate-c package and its `Translator` API.
Lazy path names are only available during make steps. Windows resource
compilation moves to an external package in Zig 0.18; the corresponding module
API is deprecated in 0.17.

**When it matters.** Enabled by the `modernize` profile. These migrations change
surrounding build logic and receive guidance without a fix. Explicit receiver
types, immutable aliases, and known `std.Build` module/compile-step factories
provide proof. The rule also recognizes a proven compile step's `root_module`.
Custom receivers, mutable inferred bindings, unknown factories, and shadowed
standard-library imports are skipped.

See [Run-step passthru arguments](https://ziglang.org/download/0.17.0/release-notes.html#Run-Step-Passthru-Args)
and [C translation migration](https://ziglang.org/download/0.17.0/release-notes.html#C-Translation-Moving-to-External-Package).
