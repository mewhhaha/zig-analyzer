# unreported-partial-send

Reports uses of the deprecated `std.Io.net.Socket.sendMany` API, whose error result discards the number of messages already sent.

**Why it matters.** A failed batch may already have sent some messages. Retrying the entire batch can resend those messages, while dropping the batch can lose its unsent messages. `sendManyTimeout(..., .none)` reports both the optional error and the number of messages sent.

**When it matters.** This correctness rule is a warning by default. It follows proven standard-library socket types and value aliases, including typed parameters and local variables. Custom sockets, unknown factories, member projections, shadowed imports, and mutable namespace or type aliases are skipped.

The replacement returns a tuple rather than `!void`, so the rule provides advice without an automatic edit. Review progress and errors together before deciding whether to retry the remaining messages.

The behavior and replacement are documented in [Zig 0.17's socket implementation](https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/Io/net.zig).
