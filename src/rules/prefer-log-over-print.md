# `prefer-log-over-print`

Reports `std.debug.print` outside a test block.

**Why it matters.** Debug printing is unconditional stderr output; `std.log` lets an embedding application select levels, scopes, and destinations.

**When it matters.** Tests remain silent. A per-site action changes the call to `std.log.debug`, but is not fix-all because the correct log level requires judgment.
