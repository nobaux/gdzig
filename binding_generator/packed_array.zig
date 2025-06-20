const std = @import("std");
const mzvr = @import("mvzr");
const GdExtensionApi = @import("extension_api.zig");
const StreamBuilder = @import("stream_builder.zig").DefaultStreamBuilder;
const enums = @import("enums.zig");
const types = @import("types.zig");

const Mode = enums.Mode;
const CodegenConfig = types.CodegenConfig;

pub const regex = mzvr.compile("^Packed([a-zA-Z0-9])+Array$") orelse @compileError("Failed to compile regex");

pub fn generate(class: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder, config: CodegenConfig) !void {
    _ = code_builder;

    const packed_array_type: []const u8 = class.name["Packed".len..(class.name.len - "Array".len)];

    if (config.mode == .verbose) {
        std.debug.print("Packed array type: {s}\n", .{packed_array_type});
    }
}
