pub const Context = @This();

allocator: Allocator,
api: GdExtensionApi,

all_classes: ArrayList([]const u8) = .empty,
all_engine_classes: ArrayList([]const u8) = .empty,
class_sizes: StringHashMap(i64) = .empty,
depends: ArrayList([]const u8) = .empty,
engine_classes: StringHashMap(bool) = .empty,
func_docs: StringHashMap([]const u8) = .empty,
func_names: StringHashMap([]const u8) = .empty,
func_pointers: StringHashMap([]const u8) = .empty,
singletons: StringHashMap([]const u8) = .empty,

pub fn deinit(self: *Context) void {
    self.all_classes.deinit(self.allocator);
    self.all_engine_classes.deinit(self.allocator);
    self.class_sizes.deinit(self.allocator);
    self.depends.deinit(self.allocator);
    self.engine_classes.deinit(self.allocator);
    self.func_docs.deinit(self.allocator);
    self.func_names.deinit(self.allocator);
    self.func_pointers.deinit(self.allocator);
    self.singletons.deinit(self.allocator);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMapUnmanaged;

const GdExtensionApi = @import("GdExtensionApi.zig");
