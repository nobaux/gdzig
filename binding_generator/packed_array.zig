const std = @import("std");
const mzvr = @import("mvzr");
const GdExtensionApi = @import("extension_api.zig");
const StreamBuilder = @import("stream_builder.zig").DefaultStreamBuilder;
const types = @import("types.zig");
const case = @import("case");

const CodegenConfig = types.CodegenConfig;
const CodegenContext = types.CodegenContext;

const PackedArrayType = enum {
    byte,
    int32,
    int64,
    float32,
    float64,
    string,
    vector2,
    vector3,
    color,
    vector4,
};

pub const regex = mzvr.compile("^Packed([a-zA-Z0-9])+Array$") orelse @compileError("Failed to compile regex");

pub fn generate(class: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder, config: CodegenConfig, ctx: *CodegenContext) !void {
    _ = config;
    _ = ctx;

    const array_type: PackedArrayType = try parseArrayType(class.name);

    const zig_type = switch (array_type) {
        .byte => "u8",
        .int32 => "i32",
        .int64 => "i64",
        .float32 => "f32",
        .float64 => "f64",
        .string => "[]const u8",
        .vector2 => "vector.Vector2",
        .vector3 => "vector.Vector3",
        .color => "godot.Color",
        .vector4 => "vector.Vector4",
    };

    try code_builder.printLine(1, "value: []{s},", .{zig_type});
}

fn parseArrayType(class_name: []const u8) !PackedArrayType {
    const name = class_name["Packed".len..(class_name.len - "Array".len)];

    var buf: [16]u8 = undefined;
    const name_camel = try case.bufTo(&buf, .camel, name);

    return std.meta.stringToEnum(PackedArrayType, name_camel) orelse std.debug.panic("Failed to parse array type: {s}", .{class_name});
}
