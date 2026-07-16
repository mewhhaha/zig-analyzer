pub const default_limit: u32 = 42;

pub fn clampToLimit(value: u32) u32 {
    return @min(value, default_limit);
}
