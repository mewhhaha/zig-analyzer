# Editor setup

Install zig-analyzer by following the [installation guide](installation.md).
Every editor must start the executable with the `lsp` argument. Use an absolute
path unless `zig-analyzer` is already on `PATH`.

## Helix

Add this to the global `~/.config/helix/languages.toml`, or save it as
`.helix/languages.toml` in one project:

```toml
[language-server.zig-analyzer]
command = "/absolute/path/to/zig-analyzer/zig-out/bin/zig-analyzer"
args = ["lsp"]
required-root-patterns = ["build.zig.zon", ".git"]

[[language]]
name = "zig"
language-servers = ["zig-analyzer"]
auto-format = true
```

Start Helix from the project root. Verify the merged configuration with:

```sh
hx --health zig
```

If the project was already open, run `:lsp-restart`. Do not list both
zig-analyzer and ZLS unless duplicate diagnostics and competing edits are
intentional. See the [Helix language configuration reference](https://docs.helix-editor.com/languages.html)
for configuration-merging details.

## Neovim 0.11 or newer

Neovim 0.11 includes native language-server configuration. Add this to the
Lua configuration loaded during startup:

```lua
vim.lsp.config("zig_analyzer", {
  cmd = {
    "/absolute/path/to/zig-analyzer/zig-out/bin/zig-analyzer",
    "lsp",
  },
  filetypes = { "zig" },
  root_markers = { "build.zig.zon", ".git" },
})

vim.lsp.enable("zig_analyzer")
```

Optional format-on-save configuration:

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.zig",
  callback = function(event)
    vim.lsp.buf.format({
      bufnr = event.buf,
      name = "zig_analyzer",
    })
  end,
})
```

Open a Zig file and run `:checkhealth vim.lsp` and `:LspInfo`. If a Neovim
distribution enables ZLS automatically, disable its Zig setup so only one
server publishes diagnostics and formatting edits. See Neovim's
[LSP documentation](https://neovim.io/doc/user/lsp.html) for the native
configuration API.

## Features beyond the basics

Most features need no configuration; a few depend on what the editor
supports.

- **Diagnostics** are pushed (`publishDiagnostics`) unless the editor pulls
  them (`textDocument/diagnostic`) and accepts `workspace/diagnostic/refresh`,
  as VS Code and recent Neovim versions do. Such an editor gets diagnostics only
  by pulling, never both ways, and is asked to pull again when compile errors
  arrive or a dependency or `zig-analyzer.json` changes.
- **Document highlights** mark the occurrences of the binding under the
  cursor, declarations and assignments as writes. Helix uses them for
  `select_references_to_symbol_under_cursor` (`space h`); in Neovim call
  `vim.lsp.buf.document_highlight()`, for example from a `CursorHold`
  autocommand.
- **Folding ranges** cover blocks, containers, multi-line argument lists,
  runs of comment and doc-comment lines, multi-line strings and the import
  block. Neovim folds with them after
  `vim.o.foldexpr = "v:lua.vim.lsp.foldexpr()"` and `vim.o.foldmethod = "expr"`.
- **Selection ranges** grow a selection through the syntax nodes around the
  cursor (Expand Selection in VS Code, `vim.lsp.buf.selection_range()` in
  Neovim versions that have it). Helix expands selections with tree-sitter
  instead.
- **Range formatting** applies only the `zig fmt` changes on the selected
  lines (Helix `=`, `vim.lsp.buf.format({ range = ... })`). A change that
  cannot be separated from changes elsewhere is left for whole-document
  formatting.
- **Document links** open the file an `@import("x.zig")` or `@embedFile`
  names, and in `build.zig.zon` the package a dependency's `.path` names.
- **Rename** answers `prepareRename` for editors that send it, so a name that
  cannot be renamed (a primitive type, `_`, a name nothing declares) is refused
  before you type the new one.
- **Inlay hints** include `caller frees` after a call whose result the caller
  owns: the ownership summaries the leak rules use say the function returns
  memory from its allocator argument (not an arena) that the caller releases
  with `free` (`caller destroys` for `destroy`). Only functions of the same
  file are summarized. Enable inlay hints with `display-inlay-hints = true`
  under `[editor.lsp]` in Helix, or `vim.lsp.inlay_hint.enable()` in Neovim.

### Run test lenses

A **Run test** code lens sits above every named `test` block. It carries the
command `zig-analyzer.runTest` with the file's URI and the test name. When the
editor sends the command to the server, the server runs
`zig test <file> --test-filter "<name>"` from the file's directory in the
background, shows whether the test passed, and writes the output to the
language server log. `zig test` builds the file on its own, so a test whose
file imports build modules does not compile this way, and the filter also
selects other tests whose names contain the given one.

- **VS Code**, through a generic language client: click the lens. The result
  appears as a notification and the output in the client's Output panel.
- **Neovim**: show lenses with `vim.lsp.codelens.refresh()` (for example on
  `BufEnter` and `InsertLeave`) and run the one on the cursor line with
  `vim.lsp.codelens.run()`. Neovim does not write the server's log messages
  by default; to see the output, run the test in a terminal instead:

  ```lua
  vim.lsp.commands["zig-analyzer.runTest"] = function(command)
    local path = vim.uri_to_fname(command.arguments[1])
    vim.cmd("botright split | terminal zig test "
      .. vim.fn.shellescape(path) .. " --test-filter "
      .. vim.fn.shellescape(command.arguments[2]))
  end
  ```

- **Helix** does not show code lenses. `:lsp-workspace-command` lists
  `zig-analyzer.runTest` but sends it without the lens's arguments, which the
  server rejects without running anything.

## Project configuration

Place `zig-analyzer.json` in the project root; the server uses the nearest one
above each file. A small configuration that enables idiomatic guidance is:

```json
{
  "lints": {
    "profile": "idiomatic"
  }
}
```

The [linting guide](linting.md) documents stricter profiles, individual rule
levels, project contracts, and source suppression directives.
