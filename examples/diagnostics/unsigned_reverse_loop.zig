pub fn visitBackwards(values: []const u8) void {
    var index: usize = values.len - 1;
    // expect: unsigned-reverse-loop
    while (index >= 0) : (index -= 1) {
        _ = values[index];
    }
}
