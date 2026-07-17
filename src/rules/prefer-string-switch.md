# `prefer-string-switch`

Reports three or more adjacent-style `std.mem.eql` string comparisons over the same subject.

**Why it matters.** `std.meta.stringToEnum` or `std.StaticStringMap` exposes the closed dispatch set and avoids repeated scans.

**When it matters.** Comparisons must use `u8`, distinct string literals, and one stable subject. Choosing the mapped value type is design work, so no automatic edit is offered.
