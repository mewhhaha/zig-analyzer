# Install zig-analyzer

## Release archive

Release `0.16.0-1` supports x86_64 Linux and includes the patched compiler
backend. Download both files from the GitHub release, then verify and extract
the archive from the [releases page](https://github.com/mewhhaha/zig-analyzer/releases):

```sh
sha256sum --check zig-analyzer-0.16.0-1-x86_64-linux.tar.xz.sha256
tar -xf zig-analyzer-0.16.0-1-x86_64-linux.tar.xz
./zig-analyzer-0.16.0-1-x86_64-linux/bin/zig-analyzer doctor
```

Keep the extracted directory together: `bin/zig-analyzer` locates the bundled
compiler under `libexec/zig-analyzer`. To make the command available globally,
move the directory to a stable location and symlink the executable:

```sh
mkdir -p ~/.local/opt ~/.local/bin
mv zig-analyzer-0.16.0-1-x86_64-linux ~/.local/opt/
ln -s ~/.local/opt/zig-analyzer-0.16.0-1-x86_64-linux/bin/zig-analyzer ~/.local/bin/zig-analyzer
```

The machine still needs Zig 0.16.0 on `PATH`; `zig-analyzer doctor` verifies
both it and the bundled backend.

## Build and install from source

### Requirements

- Git
- Zig 0.16.0 exactly
- A network connection for the Zig source and package downloads

The patched compiler backend is also Zig 0.16.0. A project pinned to another
Zig release can still use syntax features and lint diagnostics, but its
compiler-backed results would describe the wrong language version.

### Build

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

The executable can be placed on `PATH` with a symlink while its backend and
real files remain in the checkout. The resolved executable path lets the
analyzer find `zig-out/backend` from any project directory:

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

## Verify the CLI

From any project directory:

```sh
/absolute/path/to/zig-analyzer/zig-out/bin/zig-analyzer check .
```

The command exits nonzero while findings remain. See the
[linting guide](linting.md) for profiles, per-rule configuration, source
suppressions, and safe automatic fixes.
