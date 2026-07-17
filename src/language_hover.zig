const std = @import("std");

const language_reference = "https://ziglang.org/documentation/master/";

pub const Description = struct {
    syntax: []const u8,
    category: []const u8,
    summary: []const u8,
    reference: []const u8,
};

pub fn describe(
    allocator: std.mem.Allocator,
    spelling: []const u8,
    tag: std.zig.Token.Tag,
) !?Description {
    if (keywordSummary(tag)) |summary| return .{
        .syntax = spelling,
        .category = "keyword",
        .summary = summary,
        .reference = language_reference ++ "#Keyword-Reference",
    };
    if (tag == .builtin) return try builtinDescription(allocator, spelling);
    if (literalDescription(spelling, tag)) |description| return description;
    if (tokenSummary(tag)) |token| return .{
        .syntax = spelling,
        .category = token.category,
        .summary = token.summary,
        .reference = try std.fmt.allocPrint(allocator, "{s}{s}", .{ language_reference, token.anchor }),
    };
    if (tag != .identifier or !std.zig.isPrimitive(spelling)) return null;
    return try primitiveDescription(allocator, spelling);
}

fn builtinDescription(allocator: std.mem.Allocator, spelling: []const u8) !?Description {
    const builtin = std.zig.BuiltinFn.list.get(spelling) orelse return null;
    return .{
        .syntax = builtinSyntax(builtin.tag) orelse try genericBuiltinSyntax(allocator, spelling, builtin.param_count),
        .category = "builtin function",
        .summary = builtinSummary(builtin.tag),
        .reference = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ language_reference, spelling }),
    };
}

fn genericBuiltinSyntax(
    allocator: std.mem.Allocator,
    spelling: []const u8,
    parameter_count: ?u8,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("{s}(", .{spelling});
    if (parameter_count) |count| {
        for (0..count) |index| {
            if (index != 0) try writer.writer.writeAll(", ");
            try writer.writer.print("arg{d}", .{index + 1});
        }
    } else {
        try writer.writer.writeAll("...");
    }
    try writer.writer.writeByte(')');
    return try writer.toOwnedSlice();
}

fn builtinSyntax(tag: std.zig.BuiltinFn.Tag) ?[]const u8 {
    return switch (tag) {
        .import => "@import(comptime target: []const u8) anytype",
        .as => "@as(comptime T: type, expression: anytype) T",
        .int_cast => "@intCast(int: anytype) anytype",
        .float_cast => "@floatCast(value: anytype) anytype",
        .int_from_float => "@intFromFloat(float: anytype) anytype",
        .float_from_int => "@floatFromInt(int: anytype) anytype",
        .bit_cast => "@bitCast(value: anytype) anytype",
        .ptr_cast => "@ptrCast(value: anytype) anytype",
        .truncate => "@truncate(integer: anytype) anytype",
        .TypeOf => "@TypeOf(...) type",
        .type_info => "@typeInfo(comptime T: type) std.builtin.Type",
        .type_name => "@typeName(T: type) *const [N:0]u8",
        .size_of => "@sizeOf(comptime T: type) comptime_int",
        .bit_size_of => "@bitSizeOf(comptime T: type) comptime_int",
        .align_of => "@alignOf(comptime T: type) comptime_int",
        .field => "@field(value: anytype, comptime name: []const u8) anytype",
        .has_decl => "@hasDecl(comptime Container: type, comptime name: []const u8) bool",
        .has_field => "@hasField(comptime Container: type, comptime name: []const u8) bool",
        .compile_error => "@compileError(comptime message: []const u8) noreturn",
        .compile_log => "@compileLog(...) void",
        .panic => "@panic(message: []const u8) noreturn",
        .This => "@This() type",
        .in_comptime => "@inComptime() bool",
        .error_name => "@errorName(err: anyerror) []const u8",
        .tag_name => "@tagName(value: anytype) [:0]const u8",
        .memset => "@memset(dest, elem) void",
        .memcpy => "@memcpy(dest, source) void",
        .memmove => "@memmove(dest, source) void",
        .min => "@min(a, b, ...) T",
        .max => "@max(a, b, ...) T",
        .offset_of => "@offsetOf(comptime T: type, comptime field_name: []const u8) comptime_int",
        .bit_offset_of => "@bitOffsetOf(comptime T: type, comptime field_name: []const u8) comptime_int",
        .int_from_enum => "@intFromEnum(value: anytype) anytype",
        .enum_from_int => "@enumFromInt(integer: anytype) anytype",
        .int_from_ptr => "@intFromPtr(value: anytype) usize",
        .ptr_from_int => "@ptrFromInt(address: usize) anytype",
        .field_parent_ptr => "@fieldParentPtr(comptime field_name: []const u8, field_pointer: anytype) anytype",
        .embed_file => "@embedFile(comptime path: []const u8) *const [N:0]u8",
        .src => "@src() std.builtin.SourceLocation",
        else => null,
    };
}

fn builtinSummary(tag: std.zig.BuiltinFn.Tag) []const u8 {
    return switch (tag) {
        .import => "Imports the file at `target` and returns its namespace type, or a ZON file's interpreted value. `target` is either a path relative to the importing file or the name of a module declared in the build, whose root source file is imported.",
        .embed_file => "Embeds a file's bytes into the compilation as a comptime constant pointer to a null-terminated byte array. The path resolves relative to the importing file, like `@import`.",
        .as => "Performs a type coercion, converting a value to the explicitly supplied result type. The coercion is allowed only when the conversion is unambiguous and safe, and it is the preferred way to convert between types whenever possible.",
        .int_cast => "Converts between integer types while preserving the numerical value; a value the result type cannot represent is safety-checked illegal behavior. Use `@truncate` instead to deliberately discard high bits.",
        .float_cast => "Converts between floating-point types using the inferred result type.",
        .int_from_float => "Converts a floating-point value to an integer by discarding the fractional part; a result outside the target integer type is safety-checked illegal behavior.",
        .float_from_int => "Converts an integer value to a floating-point value.",
        .bit_cast => "Reinterprets a value's bit pattern as another type of the same bit size — a memory-representation cast, not a numeric conversion, so `@as(u32, @bitCast(@as(f32, 1.0)))` yields the float's encoding rather than 1.",
        .ptr_cast => "Changes a pointer's type while preserving its address.",
        .addrspace_cast => "Changes a pointer's address-space type while preserving its address.",
        .align_cast => "Asserts that a pointer has the alignment required by the inferred result type.",
        .const_cast => "Removes a pointer's `const` qualification without changing its address.",
        .volatile_cast => "Removes a pointer's `volatile` qualification without changing its address.",
        .truncate => "Keeps the least-significant bits of an integer in the inferred smaller integer type.",
        .int_from_bool => "Converts `false` to zero and `true` to one in the inferred integer type.",
        .int_from_enum => "Returns the integer tag value of an enum value.",
        .enum_from_int => "Converts an integer tag value to an enum value of the inferred result type; an integer with no matching tag in an exhaustive enum is safety-checked illegal behavior.",
        .int_from_error => "Returns the integer representation of an error value.",
        .error_from_int => "Converts an integer representation to an error value.",
        .int_from_ptr => "Returns the integer address of a pointer.",
        .ptr_from_int => "Creates a pointer with the supplied integer address and inferred pointer type.",
        .TypeOf => "Returns the type of an expression — or the peer-resolved type of several — by analyzing the operands at compile time without evaluating any runtime side effects.",
        .type_info => "Returns a reflection description of a type as a `std.builtin.Type` union. Fields and declarations of structs, unions, enums, and error sets are reported in source order.",
        .type_name => "Returns the fully qualified name of a type as a null-terminated string constant.",
        .Int, .Enum, .Union, .Struct, .Pointer, .Fn, .Vector, .Tuple => "Constructs a type from compile-time type information.",
        .size_of => "Returns the number of bytes it takes to store `T` in memory, as a target-specific compile-time constant. The size includes any padding the ABI inserts, so it is also the stride between consecutive elements of an array of `T`. Types that exist only at compile time, such as `comptime_int` and `type`, report 0.",
        .bit_size_of => "Returns the number of bits it takes to store `T` in memory when packed, ignoring ABI padding: `bool` is 1 bit here where `@sizeOf` reports a full byte.",
        .align_of => "Returns the target-specific ABI alignment of `T` in bytes — the guarantee every aligned load and store of the type relies on, and the alignment C code would use for the same type.",
        .offset_of => "Returns the byte offset of a field from the start of its container, taking the ABI layout and padding into account.",
        .bit_offset_of => "Returns the bit offset of a field from the start of its container, which distinguishes fields sharing a byte in a packed layout.",
        .field => "Accesses a field or declaration by a compile-time-known string, so reflection code can reach members whose names are computed rather than written literally.",
        .FieldType => "Returns the type of a named field in a container type.",
        .field_parent_ptr => "Recovers a pointer to a parent container from a pointer to one of its fields.",
        .has_decl => "Reports whether a container has a declaration with the requested name.",
        .has_field => "Reports whether a container has a field with the requested name.",
        .This => "Returns the innermost struct, enum, union, or opaque type containing the call, letting an anonymous container refer to itself. At file scope it returns the struct the file itself represents.",
        .in_comptime => "Reports whether evaluation is currently happening at compile time.",
        .compile_error => "Emits a compile error with a compile-time-known message.",
        .compile_log => "Prints compile-time values during semantic analysis and then fails the build if reached.",
        .set_eval_branch_quota => "Raises the compile-time branch quota for the current evaluation.",
        .set_runtime_safety => "Enables or disables runtime safety checks for the current scope.",
        .set_float_mode => "Selects the floating-point optimization mode for the current scope.",
        .branch_hint => "Supplies a branch-probability hint to the optimizer.",
        .panic => "Invokes the root panic handler with a message and does not return.",
        .trap => "Emits a target trap instruction and does not return.",
        .breakpoint => "Requests a debugger breakpoint at this point in the program.",
        .error_name => "Returns the name of an error value.",
        .tag_name => "Returns the source name of an enum or tagged-union value.",
        .error_return_trace => "Returns the current error return trace when error tracing is enabled.",
        .src => "Returns compile-time source-location information for the call site.",
        .atomic_load, .atomic_store, .atomic_rmw, .cmpxchg_strong, .cmpxchg_weak => "Performs an atomic memory operation with explicit ordering semantics.",
        .memcpy => "Copies elements into `dest` from `source` and asserts the two have the same element count. The regions must not overlap; use `@memmove` when they may.",
        .memmove => "Copies elements into `dest` from `source`, handling overlapping regions correctly at the cost of ruling out some optimizations `@memcpy` allows.",
        .memset => "Sets all elements of `dest` — a mutable slice or pointer to an array — to `elem`, which is coerced to the element type. For securely zeroing sensitive memory, use `std.crypto.secureZero` instead so the write cannot be optimized away.",
        .add_with_overflow, .sub_with_overflow, .mul_with_overflow, .shl_with_overflow => "Performs integer arithmetic and returns both the result and whether overflow occurred.",
        .div_exact => "Divides integers and asserts that the division has no remainder.",
        .div_floor => "Divides numbers and rounds the result toward negative infinity.",
        .div_trunc => "Divides numbers and rounds the result toward zero.",
        .mod => "Returns a modulus with the sign convention of the divisor.",
        .rem => "Returns a remainder with the sign convention of the dividend.",
        .shl_exact, .shr_exact => "Shifts an integer and asserts that no non-zero bits are discarded.",
        .clz => "Counts leading zero bits in an integer.",
        .ctz => "Counts trailing zero bits in an integer.",
        .pop_count => "Counts set bits in an integer.",
        .byte_swap => "Reverses the byte order of an integer.",
        .bit_reverse => "Reverses the bit order of an integer.",
        .min, .max => "Returns the minimum or maximum of the supplied values.",
        .abs, .sqrt, .sin, .cos, .tan, .exp, .exp2, .log, .log2, .log10, .floor, .ceil, .round, .trunc, .mul_add => "Performs the named numeric operation using compiler-provided semantics.",
        .splat, .shuffle, .select, .reduce => "Performs a compile-time-described vector operation.",
        .prefetch => "Hints that memory should be fetched into a target cache before it is used.",
        .union_init => "Initializes a named field of a union whose field name is known at compile time.",
        .call => "Calls a function with an explicitly selected call modifier and argument tuple.",
        .@"export" => "Exports a value under compile-time-specified linkage options.",
        .@"extern" => "Creates a reference to an externally defined symbol.",
        .c_import, .c_include, .c_define, .c_undef => "Participates in compile-time C translation inside an `@cImport` expression.",
        .c_va_arg, .c_va_copy, .c_va_end, .c_va_start => "Operates on a C variable-argument list.",
        .frame, .Frame, .frame_address, .return_address => "Inspects an async frame or target-dependent call-frame address.",
        .wasm_memory_size, .wasm_memory_grow => "Queries or grows WebAssembly linear memory.",
        .work_item_id, .work_group_size, .work_group_id => "Queries the current accelerator work item or work group.",
        .disable_instrumentation, .disable_intrinsics => "Controls compiler-generated instrumentation or intrinsic lowering for a declaration.",
        else => "Invokes a compiler-provided operation. Its arguments and result are defined by the Zig language reference.",
    };
}

fn literalDescription(spelling: []const u8, tag: std.zig.Token.Tag) ?Description {
    return switch (tag) {
        .number_literal => .{
            .syntax = spelling,
            .category = if (numberLiteralIsFloat(spelling)) "floating-point literal" else "integer literal",
            .summary = if (numberLiteralIsFloat(spelling))
                "A compile-time-known floating-point value of type `comptime_float` until coerced to another numeric type."
            else
                "An arbitrary-precision compile-time integer of type `comptime_int` until coerced to another numeric type.",
            .reference = if (numberLiteralIsFloat(spelling))
                language_reference ++ "#Float-Literals"
            else
                language_reference ++ "#Integer-Literals",
        },
        .string_literal => .{
            .syntax = "\"...\"",
            .category = "string literal",
            .summary = "A constant pointer to a sentinel-terminated byte array. Its type records both the byte length and the trailing zero sentinel.",
            .reference = language_reference ++ "#String-Literals-and-Unicode-Code-Point-Literals",
        },
        .multiline_string_literal_line => .{
            .syntax = "\\\\...",
            .category = "multiline string literal",
            .summary = "One source line of a multiline byte-string literal; indentation before the `\\\\` marker is not part of the value.",
            .reference = language_reference ++ "#Multiline-String-Literals",
        },
        .char_literal => .{
            .syntax = spelling,
            .category = "Unicode code point literal",
            .summary = "A compile-time integer containing one Unicode code point, with type `comptime_int` until coerced.",
            .reference = language_reference ++ "#String-Literals-and-Unicode-Code-Point-Literals",
        },
        else => null,
    };
}

fn numberLiteralIsFloat(spelling: []const u8) bool {
    return std.mem.indexOfAny(u8, spelling, ".eEpP") != null;
}

const TokenDescription = struct {
    category: []const u8,
    summary: []const u8,
    anchor: []const u8 = "#Operators",
};

fn tokenSummary(tag: std.zig.Token.Tag) ?TokenDescription {
    return switch (tag) {
        .plus, .plus_equal => operator("Adds numeric operands. Integer overflow is safety-checked illegal behavior; `+=` assigns the result."),
        .plus_percent, .plus_percent_equal => operator("Adds integers with two's-complement wrapping on overflow; `+%=` assigns the result."),
        .plus_pipe, .plus_pipe_equal => operator("Adds integers with saturation at the destination type's bounds; `+|=` assigns the result."),
        .minus, .minus_equal => operator("Negates one numeric operand or subtracts two operands. Integer overflow is safety-checked; `-=` assigns the result."),
        .minus_percent, .minus_percent_equal => operator("Subtracts integers with two's-complement wrapping on overflow; `-%=` assigns the result."),
        .minus_pipe, .minus_pipe_equal => operator("Subtracts integers with saturation at the destination type's bounds; `-|=` assigns the result."),
        .asterisk, .asterisk_equal => operator("Declares a pointer type, dereferences through `.*`, or multiplies numeric operands; `*=` assigns a product."),
        .asterisk_percent, .asterisk_percent_equal => operator("Multiplies integers with two's-complement wrapping on overflow; `*%=` assigns the result."),
        .asterisk_pipe, .asterisk_pipe_equal => operator("Multiplies integers with saturation at the destination type's bounds; `*|=` assigns the result."),
        .asterisk_asterisk => operator("Two adjacent pointer type markers, commonly forming a pointer-to-pointer type."),
        .slash, .slash_equal => operator("Divides numeric operands; `/=` assigns the quotient."),
        .percent, .percent_equal => operator("Computes an integer remainder; `%=` assigns the remainder."),
        .equal => operator("Assigns a value, introduces a declaration initializer, or separates a field from its default value."),
        .equal_equal => operator("Tests two values for equality."),
        .bang_equal => operator("Tests two values for inequality."),
        .bang => operator("Computes boolean negation or combines an error set with a payload type to form an error union."),
        .angle_bracket_left => operator("Tests whether the left operand is less than the right operand."),
        .angle_bracket_left_equal => operator("Tests whether the left operand is less than or equal to the right operand."),
        .angle_bracket_right => operator("Tests whether the left operand is greater than the right operand."),
        .angle_bracket_right_equal => operator("Tests whether the left operand is greater than or equal to the right operand."),
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_equal => operator("Shifts integer bits left; the assignment form stores the result."),
        .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_left_pipe_equal => operator("Shifts integer bits left with saturation; the assignment form stores the result."),
        .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_right_equal => operator("Shifts integer bits right; the assignment form stores the result."),
        .ampersand, .ampersand_equal => operator("Takes an address in prefix position or computes bitwise AND; `&=` assigns the bitwise result."),
        .pipe, .pipe_equal => operator("Delimits captures or computes bitwise OR; `|=` assigns the bitwise result."),
        .pipe_pipe => operator("Merges two error sets into an error set containing members from both."),
        .caret, .caret_equal => operator("Computes bitwise XOR; `^=` assigns the result."),
        .tilde => operator("Computes bitwise complement."),
        .plus_plus => operator("Concatenates arrays whose lengths are known at compile time."),
        .question_mark => operator("Forms an optional type, whose values are either `null` or a payload."),
        .period_asterisk => operator("Dereferences a pointer value."),
        .period => punctuation("Selects a member, begins an enum literal, or begins an anonymous aggregate initializer."),
        .ellipsis2 => punctuation("Separates the lower and upper bounds of a range or slice; the upper bound is exclusive."),
        .ellipsis3 => punctuation("Separates the bounds of an inclusive range, including the upper value."),
        .equal_angle_bracket_right => punctuation("Separates a `switch` prong's selector from its result expression."),
        .arrow => punctuation("Separates an async frame pointer type from its result type."),
        .semicolon => punctuationWithAnchor("Terminates a declaration, assignment, or expression statement.", "#Grammar"),
        .comma => punctuation("Separates arguments, fields, elements, captures, or declarations in a list."),
        .colon => punctuation("Separates a binding or field from its type, introduces a label, or specifies a sentinel."),
        .l_paren, .r_paren => punctuation("Delimits grouped expressions, function parameters, call arguments, and control-flow conditions."),
        .l_brace, .r_brace => punctuation("Delimits a block, container body, or aggregate initializer."),
        .l_bracket, .r_bracket => punctuation("Delimits array and pointer types, indexing expressions, slices, and array literals."),
        else => null,
    };
}

fn operator(summary: []const u8) TokenDescription {
    return .{ .category = "operator", .summary = summary };
}

fn punctuation(summary: []const u8) TokenDescription {
    return .{ .category = "punctuation", .summary = summary };
}

fn punctuationWithAnchor(summary: []const u8, anchor: []const u8) TokenDescription {
    return .{ .category = "punctuation", .summary = summary, .anchor = anchor };
}

fn primitiveDescription(allocator: std.mem.Allocator, spelling: []const u8) !Description {
    const category = if (primitiveValueSummary(spelling) != null) "primitive value" else "primitive type";
    const summary = primitiveValueSummary(spelling) orelse try primitiveTypeSummary(allocator, spelling);
    return .{
        .syntax = spelling,
        .category = category,
        .summary = summary,
        .reference = if (primitiveValueSummary(spelling) != null)
            language_reference ++ "#Primitive-Values"
        else
            language_reference ++ "#Primitive-Types",
    };
}

fn primitiveValueSummary(spelling: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, spelling, "true")) return "The boolean value representing truth.";
    if (std.mem.eql(u8, spelling, "false")) return "The boolean value representing falsehood.";
    if (std.mem.eql(u8, spelling, "null")) return "The value representing the absence of a value in an optional type.";
    if (std.mem.eql(u8, spelling, "undefined")) return "A value whose contents are unspecified. Reading it before assigning a valid value is illegal behavior.";
    return null;
}

fn primitiveTypeSummary(allocator: std.mem.Allocator, spelling: []const u8) ![]const u8 {
    if (integerType(spelling)) |integer| {
        return try std.fmt.allocPrint(
            allocator,
            "{s} {s} integer type with {s} bits.",
            .{ if (integer.signed) "A" else "An", if (integer.signed) "signed" else "unsigned", integer.bits },
        );
    }
    if (floatBits(spelling)) |bits| return try std.fmt.allocPrint(allocator, "An IEEE-754 floating-point type with {s} bits.", .{bits});
    const summaries = std.StaticStringMap([]const u8).initComptime(.{
        .{ "anyerror", "The global error set containing every error value in the program." },
        .{ "anyopaque", "A type-erased opaque value that is used behind pointers." },
        .{ "bool", "A boolean type whose values are `true` and `false`." },
        .{ "comptime_float", "The arbitrary-precision type of floating-point literals known at compile time." },
        .{ "comptime_int", "The arbitrary-precision type of integer literals known at compile time." },
        .{ "isize", "A signed integer type with the same bit width as a pointer on the target." },
        .{ "noreturn", "The type of expressions that do not return control to their caller." },
        .{ "type", "The type of all Zig types. Values of this type are known at compile time." },
        .{ "usize", "An unsigned integer type with the same bit width as a pointer on the target." },
        .{ "void", "A zero-bit type with exactly one value: `{}`." },
    });
    if (summaries.get(spelling)) |summary| return summary;
    if (std.mem.startsWith(u8, spelling, "c_")) {
        return "A target-dependent numeric type provided for C ABI compatibility.";
    }
    if (std.mem.eql(u8, spelling, "anyframe")) return "A type-erased async function frame pointer.";
    return "A compiler-provided primitive type.";
}

const IntegerType = struct {
    signed: bool,
    bits: []const u8,
};

fn integerType(spelling: []const u8) ?IntegerType {
    if (spelling.len < 2 or (spelling[0] != 'i' and spelling[0] != 'u')) return null;
    for (spelling[1..]) |character| if (!std.ascii.isDigit(character)) return null;
    return .{ .signed = spelling[0] == 'i', .bits = spelling[1..] };
}

fn floatBits(spelling: []const u8) ?[]const u8 {
    if (spelling.len < 2 or spelling[0] != 'f') return null;
    for (spelling[1..]) |character| if (!std.ascii.isDigit(character)) return null;
    return spelling[1..];
}

fn keywordSummary(tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (tag) {
        .keyword_addrspace => "Specifies the address space of a pointer or global value.",
        .keyword_align => "Specifies or queries a value's alignment.",
        .keyword_allowzero => "Allows a pointer to have address zero instead of reserving it for `null`.",
        .keyword_and => "Computes boolean conjunction without evaluating the right operand when the left operand is false.",
        .keyword_anyframe => "Names a type-erased async function frame pointer.",
        .keyword_anytype => "Declares a generic function parameter whose type is inferred at the call site.",
        .keyword_asm => "Introduces an inline assembly expression.",
        .keyword_break => "Exits a loop or labeled block, optionally supplying a value.",
        .keyword_callconv => "Specifies a function's calling convention.",
        .keyword_catch => "Handles the error case of an error union and can capture the error value.",
        .keyword_comptime => "Requires an expression, parameter, or variable to be evaluated at compile time.",
        .keyword_const => "Declares a binding that cannot be reassigned. On a pointer type, it prevents mutation through that pointer.",
        .keyword_continue => "Starts the next iteration of a loop, optionally targeting a loop label.",
        .keyword_defer => "Runs an expression when control leaves the current scope.",
        .keyword_else => "Provides the alternative branch of an `if`, `switch`, `while`, or `for` expression.",
        .keyword_enum => "Declares an enum type with a named set of integer-backed values.",
        .keyword_errdefer => "Runs an expression only when the current function or block returns an error.",
        .keyword_error => "Declares an error set or names an error value.",
        .keyword_export => "Exports a declaration as a symbol visible to other objects at link time.",
        .keyword_extern => "Declares a value or container with an externally defined ABI or layout.",
        .keyword_fn => "Declares a function or introduces a function type.",
        .keyword_for => "Iterates over one or more indexable values, optionally with an index range.",
        .keyword_if => "Selects a branch from a boolean, optional, or error-union condition.",
        .keyword_inline => "Requests call-site function expansion or compile-time loop unrolling.",
        .keyword_linksection => "Places a declaration in a named object-file section.",
        .keyword_noalias => "Promises that a pointer parameter does not alias another pointer for the duration of the call.",
        .keyword_noinline => "Prevents a function from being inlined.",
        .keyword_nosuspend => "Asserts that an async expression does not suspend.",
        .keyword_opaque => "Declares a type whose size and layout are intentionally unavailable.",
        .keyword_or => "Computes boolean disjunction without evaluating the right operand when the left operand is true.",
        .keyword_orelse => "Evaluates a fallback expression when an optional value is `null`.",
        .keyword_packed => "Requests packed, bit-level layout for a struct or union.",
        .keyword_pub => "Makes a declaration visible outside its containing namespace.",
        .keyword_resume => "Resumes a suspended async function frame.",
        .keyword_return => "Returns control and an optional value from the current function.",
        .keyword_struct => "Declares a struct type or namespace with named fields and declarations.",
        .keyword_suspend => "Suspends an async function and returns control to its resumer.",
        .keyword_switch => "Selects exactly one branch by exhaustively matching a value.",
        .keyword_test => "Declares a test included by `zig test` when reachable from the test root.",
        .keyword_threadlocal => "Gives a container-level variable separate storage for each thread.",
        .keyword_try => "Propagates an error from an error union; otherwise yields its success value.",
        .keyword_union => "Declares a bare or tagged union type.",
        .keyword_unreachable => "Asserts that control flow cannot reach this expression; reaching it is illegal behavior.",
        .keyword_var => "Declares a mutable binding. Variables must be initialized before use.",
        .keyword_volatile => "Requires pointer accesses to be emitted as observable volatile operations.",
        .keyword_while => "Repeats an expression while a boolean or optional condition succeeds.",
        else => null,
    };
}

test "describes keywords and arbitrary-width integer types" {
    const keyword = (try describe(std.testing.allocator, "const", .keyword_const)).?;
    try std.testing.expectEqualStrings("keyword", keyword.category);
    try std.testing.expect(std.mem.indexOf(u8, keyword.summary, "cannot be reassigned") != null);

    const integer = (try describe(std.testing.allocator, "i37", .identifier)).?;
    defer std.testing.allocator.free(integer.summary);
    try std.testing.expectEqualStrings("primitive type", integer.category);
    try std.testing.expectEqualStrings("A signed integer type with 37 bits.", integer.summary);

    try std.testing.expect(try describe(std.testing.allocator, "value", .identifier) == null);
}

test "describes builtins operators literals and punctuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const builtin = (try describe(arena.allocator(), "@intCast", .builtin)).?;
    try std.testing.expectEqualStrings("builtin function", builtin.category);
    try std.testing.expect(std.mem.startsWith(u8, builtin.syntax, "@intCast("));
    try std.testing.expect(std.mem.endsWith(u8, builtin.reference, "#@intCast"));

    const addition = (try describe(arena.allocator(), "+", .plus)).?;
    try std.testing.expectEqualStrings("operator", addition.category);
    try std.testing.expect(std.mem.indexOf(u8, addition.summary, "overflow") != null);

    const literal = (try describe(arena.allocator(), "0x1.fp4", .number_literal)).?;
    try std.testing.expectEqualStrings("floating-point literal", literal.category);
    try std.testing.expect(std.mem.indexOf(u8, literal.summary, "comptime_float") != null);

    const terminator = (try describe(arena.allocator(), ";", .semicolon)).?;
    try std.testing.expectEqualStrings("punctuation", terminator.category);
    try std.testing.expect(std.mem.indexOf(u8, terminator.summary, "Terminates") != null);
}
