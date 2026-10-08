fn refresh() !void {
    return error.Unavailable;
}

pub fn continueAfterFailure() void {
    // expect: discarded-error
    refresh() catch {};
}
