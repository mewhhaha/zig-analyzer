# `line-length`

Reports source lines longer than 100 display columns.

**Why it matters.** `zig fmt` cannot wrap every string, comment, or chained expression, so a project limit needs a separate policy check.

**When it matters.** Off until configured explicitly. A line containing one unsplittable token or URL is exempt, and UTF-8 code points are counted rather than bytes.
