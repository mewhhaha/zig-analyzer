# `prefer-string-switch`

Reports three or more adjacent-style `std.mem.eql` string comparisons that map
the same subject to simple values.

**Why it matters.** `std.meta.stringToEnum` or `std.StaticStringMap` exposes the closed dispatch set and avoids repeated scans.

**When it matters.** Comparisons must use `u8`, distinct string literals, one
stable subject, and simple value arms. Branches containing statement blocks
remain explicit. Choosing the mapped value type is design work, so no automatic
edit is offered.
