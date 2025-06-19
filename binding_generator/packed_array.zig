const std = @import("std");
const mzvr = @import("mvzr");
const GdExtensionApi = @import("extension_api.zig");
const StreamBuilder = @import("stream_builder.zig").StreamBuilder(u8, 1024 * 1024);
const enums = @import("enums.zig");

const Mode = enums.Mode;

pub const regex = mzvr.compile("^Packed([a-zA-Z0-9])+Array$") orelse @compileError("Failed to compile regex");

pub fn generate(class: GdExtensionApi.BuiltinClass, mode: Mode, code_builder: *StreamBuilder) !void {
    _ = code_builder;

    const packed_array_type: []const u8 = class.name["Packed".len..(class.name.len - "Array".len)];

    if (mode == .verbose) {
        std.debug.print("Packed array type: {s}\n", .{packed_array_type});
    }
}
