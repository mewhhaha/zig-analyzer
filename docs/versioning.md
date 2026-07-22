# Versioning

zig-analyzer's version is derived from the Zig release it supports, not from
its own feature history.

## Scheme

A release version has the form `<zig-release>-<n>`, for example `0.16.0-1`.

- The base names the Zig release the analyzer and its patched compiler
  backend are built against.
- The suffix starts at 1 and increments with each zig-analyzer release for
  that Zig version: `0.16.0-1`, `0.16.0-2`, and so on.

The suffix orders releases and nothing more; a bump may contain changes of
any size, including new rules, changed diagnostics, or changed configuration
behavior. The base version is the compatibility statement: every release
supports exactly one Zig version.

When support moves to a new Zig release, the base version changes and the
suffix resets, so the first release supporting Zig 0.17.0 would be
`0.17.0-1`.

Development builds between releases carry a `-dev` suffix, as in
`0.16.0-dev`. `zig-analyzer version` prints the analyzer version, the
supported Zig version, and the compiler-backend protocol version.

## Relation to semantic versioning

The suffix occupies the pre-release position of a semantic version, so
version-aware tooling orders `0.16.0-2` before a plain `0.16.0`. A plain base
version is never published, so ordering among published releases is
consistent. Read the scheme as "Zig release plus release counter" rather
than as a semantic-versioning promise.

## Zig compatibility

Compiler-backed analysis requires the exact Zig release named by the base
version. Against a project pinned to a different Zig release, the analyzer
deliberately falls back to syntax features and lint diagnostics; the
[installation guide](installation.md) describes this behavior.

## Current status

The current packaged release is `0.16.0-3`. The
[installation guide](installation.md) describes the release archive and source
build.
