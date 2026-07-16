pub const Headers = struct {
    pub const View = ViewStorage;
};

const ViewStorage = struct {
    /// Headers decoded from the used message body.
    slice: []const u8,
};
