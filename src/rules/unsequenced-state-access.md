# `unsequenced-state-access`

Reports an aggregate literal that copies a mutable local into one field while
another field calls a state-changing method on the same local.

**Why it matters.** The copied field can retain the state from before the method
call. A parser initializer can therefore store its lexer at one position while
storing a token read from the next position.

**When it matters.** The rule recognizes mutable local bindings and a narrow set
of conventional advancing or container-mutation methods in sibling aggregate
fields. Calls and copies in separate statements, immutable bindings, and methods
without an established state-changing meaning are ignored.
