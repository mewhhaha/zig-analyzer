pub const default_limit: u32 = 42;

pub const MessagePool = struct {
    pub const Message = struct {
        pub const Ping = struct {};
    };
};

pub fn clampToLimit(value: u32) u32 {
    return @min(value, default_limit);
}
