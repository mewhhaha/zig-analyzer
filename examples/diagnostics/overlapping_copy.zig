pub fn shiftLeft(buffer: []u8) void {
    // expect: aliased-memcpy
    @memcpy(buffer[0 .. buffer.len - 1], buffer[1..]);
}
