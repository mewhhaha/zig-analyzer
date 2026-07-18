# `prefer-log-over-print`

Reports `std.debug.print` outside test blocks and executable entrypoint files.

**Why it matters.** Debug printing is unconditional stderr output; `std.log` lets an embedding application select levels, scopes, and destinations.

**When it matters.** Tests and files defining `main` or `build` may intentionally
write command output. A per-site action changes other calls to `std.log.debug`,
but is not fix-all because the correct log level requires judgment.
