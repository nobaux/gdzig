const Config = @This();

build_target: []const u8,
extension_api: fs.File,
gdextension_interface: fs.File,
output: fs.Dir,
verbosity: Verbosity,

pub const Verbosity = enum {
    quiet,
    verbose,
};

pub fn deinit(self: *Config, allocator: Allocator) void {
    allocator.free(self.build_target);
    self.gdextension_interface.close();
    self.extension_api.close();
    self.output.close();
}

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
