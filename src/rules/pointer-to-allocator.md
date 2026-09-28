# pointer-to-allocator

Reports function parameters or struct fields typed as `*std.mem.Allocator` or `*Allocator`.

**Why it matters.** `std.mem.Allocator` is an interface struct that consists of a type-erased pointer and a vtable pointer (`@sizeOf(std.mem.Allocator) == 16`). It is designed to be passed and stored by value. Passing a pointer to an allocator adds an unnecessary level of pointer indirection and prevents callers from passing allocator instances directly (such as `arena.allocator()`, `gpa.allocator()`, or `testing.allocator`).

**When it matters.** Whenever passing or storing a `std.mem.Allocator`. Concrete allocators (such as `std.heap.ArenaAllocator`) may be passed by pointer when their lifetime or state is managed across functions.
