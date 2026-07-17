# `inconsistent-import-alias`

Reports an import alias that differs from the dominant alias for the same module across the scanned project.

**Why it matters.** One module with several local names makes cross-file reading and search unnecessarily difficult.

**When it matters.** A convention requires at least 20 samples and a 90% majority. Generated sources are excluded.
