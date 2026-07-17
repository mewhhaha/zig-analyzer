# `comptime-parameter-order`

Reports a `comptime` parameter following a runtime parameter.

**Why it matters.** Comptime parameters configure a function; placing configuration first groups the call site's constant part and matches common standard-library APIs.

**When it matters.** External signatures are exempt. The rule reports only ordering and does not rearrange parameters or call sites.
