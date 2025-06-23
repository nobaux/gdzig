const Config = @This();

arch: Arch,
extension_api: fs.File,
gdextension_interface: fs.File,
output: fs.Dir,
precision: Precision,
verbosity: Verbosity,

pub const Arch = enum {
    double,
    float,
};

pub const Precision = enum(u8) {
    @"32" = 32,
    @"64" = 64,
};

pub const Verbosity = enum {
    quiet,
    verbose,
};

pub fn buildConfiguration(self: *Config) []const u8 {
    return switch (self.arch) {
        .double => switch (self.precision) {
            .@"32" => "double_32",
            .@"64" => "double_64",
        },
        .float => switch (self.precision) {
            .@"32" => "float_32",
            .@"64" => "float_64",
        },
    };
}

pub fn deinit(self: *Config) void {
    self.gdextension_interface.close();
    self.extension_api.close();
    self.output.close();
}

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
