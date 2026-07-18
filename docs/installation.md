# Build and install from source

zig-analyzer currently has no packaged release. Keep a source checkout and
point clients at the executable built inside it.

## Requirements

- Git
- Zig 0.16.0 exactly
- A network connection for the Zig source and package downloads

The patched compiler backend is also Zig 0.16.0. A project pinned to another
Zig release can still use syntax features and lint diagnostics, but its
compiler-backed results would describe the wrong language version.

## Build

```sh
git clone https://github.com/mewhhaha/zig-analyzer.git
cd zig-analyzer
zig version
zig build -Doptimize=ReleaseFast
zig build backend
zig-out/bin/zig-analyzer doctor
```

`zig version` must print `0.16.0`. The backend step clones the pinned Zig
source, applies the analyzer patch, and builds `zig-out/backend/bin/zig`. Keep
`zig-out/bin/zig-analyzer` and `zig-out/backend/` together in this checkout;
copying only the language-server executable loses compiler-backed analysis.

The executable can be placed on `PATH` with a symlink while its real files
remain in the checkout:

```sh
mkdir -p ~/.local/bin
ln -s /absolute/path/to/zig-analyzer/zig-out/bin/zig-analyzer ~/.local/bin/zig-analyzer
```

Rebuild after pulling changes:

```sh
git pull --ff-only
zig build -Doptimize=ReleaseFast
zig build backend
zig-out/bin/zig-analyzer doctor
```

The backend bootstrap is incremental and reuses a compatible existing build.

## Make the backend available to another project

The language server currently resolves its backend as `zig-out/backend`
relative to the editor workspace. For a Zig 0.16 project, link the backend
from the source checkout before starting the editor in that project:

```sh
cd /path/to/zig-project
mkdir -p zig-out
ln -s /absolute/path/to/zig-analyzer/zig-out/backend zig-out/backend
```

Do not create this link for a project pinned to a different Zig version. In
that case the server deliberately falls back to syntax and lint analysis.

## Verify the CLI

From any project directory:

```sh
/absolute/path/to/zig-analyzer/zig-out/bin/zig-analyzer check .
```

The command exits nonzero while findings remain. See the root
[README](../README.md#use-it) for profiles, per-rule configuration, source
suppressions, and safe automatic fixes.
