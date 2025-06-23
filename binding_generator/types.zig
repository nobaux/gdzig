const std = @import("std");
const enums = @import("enums.zig");

const Allocator = std.mem.Allocator;
const GdExtensionApi = @import("GdExtensionApi.zig");

pub const ident_width = 4;
pub const StringSizeMap = std.StringHashMapUnmanaged(i64);
pub const StringBoolMap = std.StringHashMapUnmanaged(bool);
pub const StringVoidMap = std.StringHashMapUnmanaged(void);
pub const StringStringMap = std.StringHashMapUnmanaged([]const u8);

pub const CodegenConfig = struct {
    conf: []const u8,
    gdextension_h_path: []const u8,
    mode: enums.Mode,
    output: []const u8,
};
