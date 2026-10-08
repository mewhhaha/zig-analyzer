const std = @import("std");

pub const Header = struct {
    flag: u8,
    count: u32,
};

pub fn headersEqual(left: Header, right: Header) bool {
    // expect: padded-byte-compare
    return std.mem.eql(u8, std.mem.asBytes(&left), std.mem.asBytes(&right));
}
