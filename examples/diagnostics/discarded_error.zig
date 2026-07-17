fn refresh() !void {
    return error.Unavailable;
}

pub fn continueAfterFailure() void {
    refresh() catch {};
}
