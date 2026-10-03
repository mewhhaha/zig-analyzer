# `modernize-build-api`

Reports removed `std.Build.args` and `LazyPath.basename` access, the deprecated
`addTranslateC` build step, Windows resource compilation APIs, legacy Run
argument wrappers, `lazyDependency`, and the old two-argument `findProgram` call.

**Why it matters.** Zig 0.17 moves passthru arguments out of the configure
phase. A Run step now forwards them with `addPassthruArgs()`. C translation
moves to the official translate-c package and its `Translator` API.
Lazy path names are only available during make steps. Windows resource
compilation moves to an external package in Zig 0.18; the corresponding module
API is deprecated in 0.17.

Run argument methods now accept options for prefixes, suffixes, and absolute
paths. The seven plain wrappers (`addArtifactArg`, `addFileArg`,
`addOutputFileArg`, `addFileContentArg`, `addOutputDirectoryArg`,
`addDirectoryArg`, and `addDepFileOutputArg`) delegate to the corresponding
`*Arg2` method with empty options (`.{}`). Their fixes rename the method and
insert the empty options argument, preserving expressions, comments, and
trailing commas.
Prefixed and decorated wrappers receive guidance: moving prefixes or suffixes
into options changes argument order and requires reviewing evaluation order.

`dependencyLazy` returns `error.LazyDependencyNeeded` instead of an optional.
Propagate that error through helpers to `build()` so the build runner can fetch
the package and retry configuration. Optional handling needs a manual update.
The old `findProgram(names, paths)` call also needs review: Zig 0.17 accepts
`.{ .names = names }`, searches configured prefixes and `PATH`, and returns an
optional. Use `findProgramLazy` when the result is only needed during make;
configure-time lookup poisons the configuration cache.

**When it matters.** Enabled by the `modernize` profile. Only the plain Run
wrappers receive automatic fixes; other migrations receive guidance. Explicit
receiver types, immutable namespace/type aliases, and known `std.Build`
module/compile/Run factories provide proof. The rule recognizes `Run.create`
and a proven compile step's `root_module`.
Custom receivers, mutable inferred bindings, unknown factories, and shadowed
standard-library imports are skipped.

See [Run-step passthru arguments](https://ziglang.org/download/0.17.0/release-notes.html#Run-Step-Passthru-Args)
and [C translation migration](https://ziglang.org/download/0.17.0/release-notes.html#C-Translation-Moving-to-External-Package).
The release notes also cover [Run argument options](https://ziglang.org/download/0.17.0/release-notes.html#Build-System),
[lazy dependencies](https://ziglang.org/download/0.17.0/release-notes.html#Lazy-Dependency-Ergonomic-Enhancements),
and [program lookup](https://ziglang.org/download/0.17.0/release-notes.html#findProgram).
