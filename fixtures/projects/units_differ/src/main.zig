const options = @import("build_options");

const Threaded = struct {
    pub fn start() u8 {
        return 1;
    }
};

const Single = struct {
    pub fn start() u8 {
        return 2;
    }
};

/// Chosen by the build configuration.
const Backend = if (options.threaded) Threaded else Single;

pub fn main() void {
    _ = Backend.start();
}
