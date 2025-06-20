const std = @import("std");
const enums = @import("enums.zig");

pub const IdentWidth = 4;
pub const StringSizeMap = std.StringHashMap(i64);
pub const StringBoolMap = std.StringHashMap(bool);
pub const StringVoidMap = std.StringHashMap(void);
pub const StringStringMap = std.StringHashMap([]const u8);

pub const CodegenConfig = struct {
    conf: []const u8,
    gdextension_h_path: []const u8,
    mode: enums.Mode,
    output: []const u8,
};
