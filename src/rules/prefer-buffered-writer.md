# `prefer-buffered-writer`

Reports writes through a directly obtained unbuffered writer inside a loop.

**Why it matters.** Repeated small writes can turn one logical operation into many syscalls.

**When it matters.** The writer must be locally bound from `.writer()` or stdout. Writer parameters are ignored because their caller may already buffer them.
