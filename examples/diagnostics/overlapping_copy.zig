pub fn shiftLeft(buffer: []u8) void {
    @memcpy(buffer[0 .. buffer.len - 1], buffer[1..]);
}
