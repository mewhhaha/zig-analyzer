# The patched Zig compiler

Compiler-backed answers come from a Zig compiler with one added capability: it
runs as a long-lived process and answers analysis requests over an
authenticated loopback protocol. This directory holds everything that
distinguishes that compiler from upstream Zig.

| File | Role |
| --- | --- |
| `analysis.patch` | The change to upstream Zig, as a `git diff`. Adds `src/AnalysisSymbols.zig` and edits `src/IncrementalDebugServer.zig`, `src/Zcu.zig`, `src/Zcu/PerThread.zig` and `src/main.zig`. |
| `protocol_invariant.zig` | Contract tests that the patch and the analyzer agree on the wire protocol. Part of `zig build test`. |

The wire format is `src/compiler/protocol.zig`. It is shared: the analyzer
imports it, and bootstrap copies it into the compiler checkout as
`src/AnalysisProtocol.zig`, which the patch imports. The patch therefore never
carries a copy of it.

## What is pinned

- The Zig release is `minimum_zig_version` in `build.zig.zon`. `build.zig`
  derives `build_options.zig_version` from it, and the host `zig`, the backend
  checkout, CI and the documentation all follow.
- The upstream commit that release is tagged at is `zig_commit` in `build.zig`.
  Bootstrap clones the tag and refuses a checkout at any other commit.
- The CI checksum of the Zig archive is in `.github/actions/setup-zig/action.yml`.
- Literal `"0.17.0"` strings inside `analysis.patch` (the hello handshake) are
  checked against `zig_version` by `protocol_invariant.zig`.

## How the backend is built

`zig build backend` (`src/compiler/bootstrap.zig`):

1. clones the pinned tag into `.zig-analyzer/zig-<version>`;
2. applies `analysis.patch` and installs `src/compiler/protocol.zig`;
3. builds without LLVM into `zig-out/backend` (about 15 minutes cold);
4. writes `zig-out/backend/zig-analyzer-backend.json` with the Zig version and
   commit, the protocol version, and a SHA-256 over `analysis.patch` and
   `protocol.zig`.

Editing either input makes the backend stale: the next `zig build backend`
resets the checkout to the pinned commit, reapplies the inputs and rebuilds,
and `zig-analyzer doctor` reports the mismatch until then. With unchanged
inputs it is a no-op, which is also what lets CI restore `zig-out/backend` from
a cache keyed on those inputs.

At run time the analyzer starts the backend with `ZIG_ANALYZER_PORT=0`; the
backend binds a free loopback port and announces it on stderr, so concurrent
analyzers never collide.

## Editing the patch

Iterating through the full bootstrap is slow. Instead, edit the checkout:

```sh
zig build backend                  # once, to create .zig-analyzer/zig-<version>
cd .zig-analyzer/zig-<version>
# edit src/AnalysisSymbols.zig, src/IncrementalDebugServer.zig, ...
zig build -Dno-lib -Denable-llvm=false -Ddebug-extensions=true -Dno-bin   # type-check, about 30 s
```

Then regenerate the patch from that checkout. The new file needs an intent to
add, and `src/AnalysisProtocol.zig` must stay out:

```sh
git add -N src/AnalysisSymbols.zig
git diff -- src/AnalysisSymbols.zig src/IncrementalDebugServer.zig \
    src/Zcu.zig src/Zcu/PerThread.zig src/main.zig > ../../compiler/analysis.patch
```

(Add any further file you touched to the path list.) Back in the repository
root, run `zig build backend` to rebuild from the patch, then
`zig build backend-test`.

## Protocol version

`version` in `src/compiler/protocol.zig` identifies the wire format. Bump it
whenever a struct layout, tag value or message order changes. A backend whose
manifest names another protocol version is rejected by the analyzer and by
`doctor`, so the bump forces every stale backend to be rebuilt. A change that
leaves the wire format alone (a bug fix inside the patch) needs no bump; the
digest already marks the backend stale.

When adding a request, follow the steps in
[EXTENDING.md](../EXTENDING.md#extend-compiler-backed-analysis);
`protocol_invariant.zig` fails if the patch names a protocol declaration that
does not exist, writes a tag the protocol lacks, or does not serve a request the
client sends.

## Porting to a new Zig release

1. Change `minimum_zig_version` in `build.zig.zon` and `zig_commit` in
   `build.zig`. Find the commit with
   `git ls-remote https://codeberg.org/ziglang/zig refs/tags/<version>`.
2. Update the Zig archive checksum in `.github/actions/setup-zig/action.yml`
   (published on <https://ziglang.org/download/>).
3. Run `zig build backend`. The patch will probably not apply; fix the checkout
   by hand (`git apply --3way` helps) and regenerate the patch as above.
4. Replace the literal version strings in the patch that
   `protocol_invariant.zig` reports.
5. Bump the protocol `version` if the port changed the wire format.
6. Run `zig build backend-test` and fix the clients of whatever changed
   upstream (standard-library renames, build-system API changes).
7. Run the `modernize-*` rules over the new release's changes (see
   `docs/zig-0.17.0-lint-audit.md` for how the previous release was audited)
   and `zig build ci`.
8. Reset the release suffix in `build.zig.zon` (`0.18.0-1`) and write
   `docs/release-<version>.md`; see [CONTRIBUTING.md](../CONTRIBUTING.md).
