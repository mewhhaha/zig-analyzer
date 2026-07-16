const std = @import("std");
const type_shapes = @import("type_shapes.zig");

fn Matrix(comptime Element: type, comptime rows: usize, comptime columns: usize) type {
    return struct {
        values: [rows][columns]Element,

        const Self = @This();

        fn diagonal(value: Element) Self {
            var result: Self = .{ .values = @splat(@splat(0)) };
            inline for (0..@min(rows, columns)) |index| {
                result.values[index][index] = value;
            }
            return result;
        }

        fn trace(matrix: Self) Element {
            var result: Element = 0;
            inline for (0..@min(rows, columns)) |index| {
                result += matrix.values[index][index];
            }
            return result;
        }
    };
}

const Mat3 = Matrix(u32, 3, 3);

export fn analyzerFixture() u32 {
    comptime {
        _ = type_shapes.Color;
        _ = type_shapes.Message;
        _ = type_shapes.Point;
        _ = type_shapes.GeneratedEnum;
        _ = type_shapes.GeneratedEnumAlias;
        _ = type_shapes.GeneratedUnion;
        _ = type_shapes.GeneratedStruct;
        _ = type_shapes.Untagged;
        _ = type_shapes.Failure;
    }
    return Mat3.diagonal(7).trace();
}

test "generated matrix methods are callable" {
    try std.testing.expectEqual(@as(u32, 21), analyzerFixture());
}
