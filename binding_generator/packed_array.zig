const std = @import("std");
const mzvr = @import("mvzr");
const GdExtensionApi = @import("GdExtensionApi.zig");
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

    try code_builder.printLine(1, "value: [{d}]u8,", .{ctx.getClassSize(class.name).?});
}

fn parseArrayType(class_name: []const u8) !PackedArrayType {
    const name = class_name["Packed".len..(class_name.len - "Array".len)];

    var buf: [16]u8 = undefined;
    const name_camel = try case.bufTo(&buf, .camel, name);

    return std.meta.stringToEnum(PackedArrayType, name_camel) orelse std.debug.panic("Failed to parse array type: {s}", .{class_name});
}
