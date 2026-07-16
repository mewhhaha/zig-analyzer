# Zig-native action architecture

Selection-driven refactors live here rather than in the diagnostic registry.
`registry.zig` tokenizes the document once and passes one `ActionRun` to the
expression, ownership, language, and testing families. Each candidate contains
a complete set of byte edits; the LSP boundary converts them to UTF-16 workspace
edits without a resolve request.

Add an action to the closest existing family. A genuinely new family is
registered once in `registry.zig`'s ordered `action_modules` tuple; the tuple is
the composition order and the test-import list.

An action must establish its preconditions before appearing. Syntax facts are
enough for explicit error sets, optional annotations, allocator provenance,
format literals, and simple build declarations. Tagged-union materialization and
comptime refactors also accept compiler-resolved shapes. If field types, capture
preservation, ownership, or an insertion target cannot be proven, omit the
action rather than generating a plausible-looking edit.

`project.zig` owns actions spanning open files. Build repair requires one package
import, one matching module source, and one `build.zig`. C-import extraction
requires identical blocks and an LSP client advertising document changes plus
file creation. Local action modules must not inspect the filesystem or construct
protocol objects.

`lsp_adapter.zig` is the transport exception: it maps action kinds, byte spans,
URI edits, and created files into LSP values. It contains no rewrite policy.
Action engines must not import it or `lsp`; the server calls it only after a
candidate has been proven.

Actions that add error policy, change ownership, generate declarations, or
create files are explicit and never participate in fix-all. Only an independently
proven diagnostic fix may opt into fix-all through the rule registry.
