# `inconsistent-error-set-style`

Reports a public error-returning function whose explicit or inferred error-set style differs from the project majority.

**Why it matters.** Mixing styles gives neither stable explicit API contracts nor consistently low ceremony.

**When it matters.** At least 20 public error-returning functions and a 90% majority are required.
