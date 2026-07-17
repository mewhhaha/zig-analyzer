# `todo-comment`

Reports `TODO`, `FIXME`, and `XXX` markers in line comments.

**Why it matters.** Task markers are promises; surfacing them in `check` makes the inventory visible to CI instead of only to readers of one file.

**When it matters.** Off until configured explicitly. String contents and generated sources are ignored, and the source suppression syntax can document intentional markers.
