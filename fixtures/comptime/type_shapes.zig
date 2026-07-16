pub const Color = enum { red, green, blue };

pub const Message = union(enum) {
    text: []const u8,
    number: u32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

const GeneratedKind = enum { enumeration, tagged_union, structure };

fn Generated(comptime kind: GeneratedKind) type {
    return switch (kind) {
        .enumeration => enum { pending, complete },
        .tagged_union => union(enum) { success: u32, failure: []const u8 },
        .structure => struct { name: []const u8, count: usize },
    };
}

pub const GeneratedEnum = Generated(.enumeration);
pub const GeneratedEnumAlias = GeneratedEnum;
pub const GeneratedUnion = Generated(.tagged_union);
pub const GeneratedStruct = Generated(.structure);

pub const Untagged = union { integer: u32, floating: f32 };
pub const Failure = error{Unavailable};
