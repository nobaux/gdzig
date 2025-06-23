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

pub const CodegenContext = struct {
    allocator: Allocator,
    func_name_map: StringStringMap,
    class_size_map: StringSizeMap,
    engine_class_map: StringBoolMap,
    singletons_map: StringStringMap,
    func_pointers_map: StringStringMap,
    func_docs_map: StringStringMap,
    all_classes: std.ArrayListUnmanaged([]const u8),
    all_engine_classes: std.ArrayListUnmanaged([]const u8),
    depends: std.ArrayListUnmanaged([]const u8),
    api: GdExtensionApi,

    pub fn init(allocator: Allocator, api: GdExtensionApi) !CodegenContext {
        return CodegenContext{
            .allocator = allocator,
            .func_name_map = .empty,
            .class_size_map = .empty,
            .engine_class_map = .empty,
            .singletons_map = .empty,
            .func_pointers_map = .empty,
            .func_docs_map = .empty,
            .all_classes = .empty,
            .all_engine_classes = .empty,
            .depends = .empty,
            .api = api,
        };
    }

    pub fn deinit(self: *CodegenContext) void {
        self.func_name_map.deinit(self.allocator);
        self.class_size_map.deinit(self.allocator);
        self.engine_class_map.deinit(self.allocator);
        self.singletons_map.deinit(self.allocator);
        self.func_pointers_map.deinit(self.allocator);
        self.func_docs_map.deinit(self.allocator);
        self.all_classes.deinit(self.allocator);
        self.all_engine_classes.deinit(self.allocator);
        self.depends.deinit(self.allocator);
    }

    // Hash map wrapper methods
    pub fn putFuncName(self: *CodegenContext, key: []const u8, value: []const u8) !void {
        try self.func_name_map.put(self.allocator, key, value);
    }

    pub fn getFuncName(self: *CodegenContext, key: []const u8) ?[]const u8 {
        return self.func_name_map.get(key);
    }

    pub fn getOrPutFuncName(self: *CodegenContext, key: []const u8) !StringStringMap.GetOrPutResult {
        return self.func_name_map.getOrPut(self.allocator, key);
    }

    pub fn putClassSize(self: *CodegenContext, key: []const u8, value: i64) !void {
        try self.class_size_map.put(self.allocator, key, value);
    }

    pub fn getClassSize(self: *CodegenContext, key: []const u8) ?i64 {
        return self.class_size_map.get(key);
    }

    pub fn putEngineClass(self: *CodegenContext, key: []const u8, value: bool) !void {
        try self.engine_class_map.put(self.allocator, key, value);
    }

    pub fn getEngineClass(self: *CodegenContext, key: []const u8) ?bool {
        return self.engine_class_map.get(key);
    }

    pub fn containsEngineClass(self: *CodegenContext, key: []const u8) bool {
        return self.engine_class_map.contains(key);
    }

    pub fn putSingleton(self: *CodegenContext, key: []const u8, value: []const u8) !void {
        try self.singletons_map.put(self.allocator, key, value);
    }

    pub fn getSingleton(self: *CodegenContext, key: []const u8) ?[]const u8 {
        return self.singletons_map.get(key);
    }

    pub fn containsSingleton(self: *CodegenContext, key: []const u8) bool {
        return self.singletons_map.contains(key);
    }

    pub fn putFuncPointer(self: *CodegenContext, key: []const u8, value: []const u8) !void {
        try self.func_pointers_map.put(self.allocator, key, value);
    }

    pub fn getFuncPointer(self: *CodegenContext, key: []const u8) ?[]const u8 {
        return self.func_pointers_map.get(key);
    }

    pub fn containsFuncPointer(self: *CodegenContext, key: []const u8) bool {
        return self.func_pointers_map.contains(key);
    }

    pub fn putFuncDoc(self: *CodegenContext, key: []const u8, value: []const u8) !void {
        try self.func_docs_map.put(self.allocator, key, value);
    }

    pub fn getFuncDoc(self: *CodegenContext, key: []const u8) ?[]const u8 {
        return self.func_docs_map.get(key);
    }

    pub fn containsFuncDoc(self: *CodegenContext, key: []const u8) bool {
        return self.func_docs_map.contains(key);
    }

    // Array list wrapper methods
    pub fn appendClass(self: *CodegenContext, value: []const u8) !void {
        try self.all_classes.append(self.allocator, value);
    }

    pub fn appendEngineClass(self: *CodegenContext, value: []const u8) !void {
        try self.all_engine_classes.append(self.allocator, value);
    }

    pub fn appendDependency(self: *CodegenContext, value: []const u8) !void {
        try self.depends.append(self.allocator, value);
    }

    pub fn clearDependencies(self: *CodegenContext) void {
        self.depends.clearRetainingCapacity();
    }
};
