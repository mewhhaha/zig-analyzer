pub const Store = struct {
    /// Opens the store with the given capacity.
    pub fn init(capacity: usize) Store {
        _ = capacity;
        return .{};
    }

    /// Releases every resource owned by the store.
    pub fn close(self: *Store) void {
        _ = self;
    }
};
