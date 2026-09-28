# `self-assignment`

[Rule index](RULES.md)

Reports an assignment where the left-hand side and right-hand side evaluate to the same variable or field path.

**Why it matters.** Assigning a value to itself (`x = x;` or `self.field = self.field;`) has no effect and almost always indicates a bug, such as a typographical error in an initializer or setter where a parameter name was shadowed or misspelled. If the intent was to silence an unused variable warning, Zig uses `_ = x;` instead.

**When it matters.** It applies to assignment statements where both sides are identical paths, excluding shadowing variable declarations like `var x = x;`.
