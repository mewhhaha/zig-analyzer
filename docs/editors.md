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

## Project configuration

Place `zig-analyzer.json` in the directory from which the editor starts the
server. A small configuration that enables idiomatic guidance is:

```json
{
  "lints": {
    "profile": "idiomatic"
  }
}
```

The [linting guide](linting.md) documents stricter profiles, individual rule
levels, project contracts, and source suppression directives.
