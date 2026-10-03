# `modernize-build-api`

Reports removed `std.Build.args` access and the deprecated `addTranslateC`
build step on scoped bindings explicitly typed `*std.Build`.

**Why it matters.** Zig 0.17 moves passthru arguments out of the configure
phase. A Run step now forwards them with `addPassthruArgs()`. C translation
moves to the official translate-c package and its `Translator` API.

**When it matters.** Enabled by the `modernize` profile. Both migrations change
surrounding build logic and receive guidance without a fix. The receiver's
type must refer to the standard-library import. Custom receivers, nested
members, and locally shadowed bindings are skipped.

See [Run-step passthru arguments](https://ziglang.org/download/0.17.0/release-notes.html#Run-Step-Passthru-Args)
and [C translation migration](https://ziglang.org/download/0.17.0/release-notes.html#C-Translation-Moving-to-External-Package).
