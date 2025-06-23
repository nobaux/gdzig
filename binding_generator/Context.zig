pub const Context = @This();

allocator: Allocator,
api: GodotApi,
config: CodegenConfig,

all_classes: ArrayList([]const u8) = .empty,
all_engine_classes: ArrayList([]const u8) = .empty,
class_sizes: StringHashMap(i64) = .empty,
depends: ArrayList([]const u8) = .empty,
engine_classes: StringHashMap(bool) = .empty,
func_docs: StringHashMap([]const u8) = .empty,
func_names: StringHashMap([]const u8) = .empty,
func_pointers: StringHashMap([]const u8) = .empty,
singletons: StringHashMap([]const u8) = .empty,

const func_case: case.Case = .camel;

const base_type_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "int", "i64" },
    .{ "int8", "i8" },
    .{ "uint8", "u8" },
    .{ "int16", "i16" },
    .{ "uint16", "u16" },
    .{ "int32", "i32" },
    .{ "uint32", "u32" },
    .{ "int64", "i64" },
    .{ "uint64", "u64" },
    .{ "float", "f32" },
    .{ "double", "f64" },
});

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

pub fn build(allocator: Allocator, api: GodotApi, config: CodegenConfig) !Context {
    var self = Context{
        .allocator = allocator,
        .api = api,
        .config = config,
    };

    try self.parseGdExtensionHeaders();
    try self.parseClassSizes();
    try self.parseSingletons();
    try self.parseEngineClasses();

    return self;
}

fn parseEngineClasses(self: *Context) !void {
    for (self.api.classes) |bc| {
        // TODO: why?
        if (std.mem.eql(u8, bc.name, "ClassDB")) {
            continue;
        }

        try self.engine_classes.put(self.allocator, bc.name, bc.is_refcounted);
    }

    for (self.api.native_structures) |ns| {
        try self.engine_classes.put(self.allocator, ns.name, false);
    }
}

fn parseClassSizes(self: *Context) !void {
    for (self.api.builtin_class_sizes) |bcs| {
        if (!std.mem.eql(u8, bcs.build_configuration, self.config.conf)) {
            continue;
        }

        for (bcs.sizes) |sz| {
            try self.class_sizes.put(self.allocator, sz.name, sz.size);
        }
    }
}

fn parseSingletons(self: *Context) !void {
    for (self.api.singletons) |sg| {
        try self.singletons.put(self.allocator, sg.name, sg.type);
    }
}

fn parseGdExtensionHeaders(self: *Context) !void {
    const header_file = try std.fs.openFileAbsolute(self.config.gdextension_h_path, .{});
    var buffered_reader = std.io.bufferedReader(header_file.reader());
    const reader = buffered_reader.reader();

    const name_doc = "@name";

    var buf: [1024]u8 = undefined;
    var fn_name: ?[]const u8 = null;
    var fp_type: ?[]const u8 = null;
    const safe_ident_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

    var doc_stream: std.ArrayListUnmanaged(u8) = .empty;
    const doc_writer: std.ArrayListUnmanaged(u8).Writer = doc_stream.writer(self.allocator);

    var doc_start: ?usize = null;
    var doc_end: ?usize = null;
    var doc_line_buf: [1024]u8 = undefined;
    var doc_line_temp: [1024]u8 = undefined;

    while (true) {
        const line: []const u8 = reader.readUntilDelimiterOrEof(&buf, '\n') catch break orelse break;

        const contains_name_doc = std.mem.indexOf(u8, line, name_doc) != null;

        // getting function docs
        if (std.mem.indexOf(u8, line, "/*")) |i| if (i >= 0) {
            doc_start = doc_stream.items.len;

            if (line.len <= 3) {
                continue;
            }
        };

        // we are in a doc comment
        if (doc_start != null) {
            const is_last_line = std.mem.containsAtLeast(u8, line, 1, "*/");

            if (line.len > 0) {
                @memcpy(doc_line_buf[0 .. line.len - 2], line[2..]);
                var doc_line = doc_line_buf[0 .. line.len - 2];

                if (is_last_line) {
                    // remove the trailing "*/"
                    const len = std.mem.replace(u8, doc_line, "*/", "", &doc_line_temp);
                    doc_line = doc_line_temp[0..len];
                }

                if (!contains_name_doc and !(is_last_line and doc_line.len == 0)) {
                    try doc_writer.writeAll("/// ");
                    try doc_writer.writeAll(try self.allocator.dupe(u8, doc_line));
                    try doc_writer.writeAll("\n");
                }

                if (is_last_line) {
                    doc_end = doc_stream.items.len;
                }
            }
        }

        // getting function pointers
        if (contains_name_doc) {
            const name_index = std.mem.indexOf(u8, line, name_doc).?;
            const start = name_index + name_doc.len + 1; // +1 to skip the space after @name
            fn_name = try self.allocator.dupe(u8, line[start..]);
            fp_type = null;
        } else if (std.mem.startsWith(u8, line, "typedef")) {
            if (fn_name == null) continue; // skip if we don't have a function name yet

            var iterator = std.mem.splitSequence(u8, line, " ");
            _ = iterator.next(); // skip "typedef"
            const const_or_return_type = iterator.next().?; // skip the return type
            if (std.mem.eql(u8, const_or_return_type, "const")) {
                // skip "const" keyword
                _ = iterator.next();
            }

            const fp_type_slice = iterator.next().?;
            const start = std.mem.indexOfAny(u8, fp_type_slice, safe_ident_chars).?;
            const end = std.mem.indexOf(u8, fp_type_slice[start..], ")").?;
            fp_type = try self.allocator.dupe(u8, fp_type_slice[start..(end + start)]);
        }

        if (fn_name) |_| if (fp_type) |_| {
            try self.func_pointers.put(self.allocator, fp_type.?, fn_name.?);

            if (doc_start) |start_index| if (doc_end) |end_index| {
                const doc_text = try self.allocator.dupe(u8, doc_stream.items[start_index..end_index]);
                try self.func_docs.put(self.allocator, fp_type.?, doc_text);
            };

            fn_name = null;
            fp_type = null;
            doc_start = null;
            doc_end = null;
        };
    }
}

pub fn addDependType(self: *Context, type_name: []const u8) !void {
    var depend_type = util.childType(type_name);

    if (std.mem.startsWith(u8, depend_type, "TypedArray")) {
        depend_type = depend_type[11 .. depend_type.len - 1];
        try self.depends.append(self.allocator, "Array");
    }

    if (std.mem.startsWith(u8, depend_type, "Ref(")) {
        depend_type = depend_type[4 .. depend_type.len - 1];
        try self.depends.append(self.allocator, "Ref");
    }

    const pos = std.mem.indexOf(u8, depend_type, ".");

    if (pos) |p| {
        try self.depends.append(self.allocator, depend_type[0..p]);
    } else {
        try self.depends.append(self.allocator, depend_type);
    }
}

pub fn correctName(self: *Context, name: []const u8) []const u8 {
    if (std.zig.Token.keywords.has(name)) {
        return std.fmt.allocPrint(self.allocator, "@\"{s}\"", .{name}) catch unreachable;
    }

    return name;
}

pub fn correctType(self: *Context, type_name: []const u8, meta: []const u8) []const u8 {
    var correct_type = if (meta.len > 0) meta else type_name;
    if (correct_type.len == 0) return "void";

    if (std.mem.eql(u8, correct_type, "float")) {
        return "f64";
    } else if (std.mem.eql(u8, correct_type, "int")) {
        return "i64";
    } else if (std.mem.eql(u8, correct_type, "Nil")) {
        return "Variant";
    } else if (base_type_map.has(correct_type)) {
        return base_type_map.get(correct_type).?;
    } else if (std.mem.startsWith(u8, correct_type, "typedarray::")) {
        //simplified to just use array instead
        return "Array";
    } else if (util.isEnum(correct_type)) {
        const cls = util.getEnumClass(correct_type);
        if (std.mem.eql(u8, cls, "GlobalConstants")) {
            return std.fmt.allocPrint(self.allocator, "global.{s}", .{util.getEnumName(correct_type)}) catch unreachable;
        } else {
            return util.getEnumName(correct_type);
        }
    }

    if (std.mem.startsWith(u8, correct_type, "const ")) {
        correct_type = correct_type[6..];
    }

    if (self.isRefCounted(correct_type)) {
        return std.fmt.allocPrint(self.allocator, "?{s}", .{correct_type}) catch unreachable;
    } else if (self.isEngineClass(correct_type)) {
        return std.fmt.allocPrint(self.allocator, "?{s}", .{correct_type}) catch unreachable;
    } else if (correct_type[correct_type.len - 1] == '*') {
        return std.fmt.allocPrint(self.allocator, "?*{s}", .{correct_type[0 .. correct_type.len - 1]}) catch unreachable;
    }
    return correct_type;
}

pub fn getArgumentsTypes(ctx: *Context, fn_node: GodotApi.Builtin.Constructor, buf: []u8) []const u8 {
    var pos: usize = 0;
    if (@hasField(@TypeOf(fn_node), "arguments")) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = ctx.correctType(a.type, "");
                if (arg_type[0] == '*' or arg_type[0] == '?') {
                    std.mem.copyForwards(u8, buf[pos..], arg_type[1..]);
                    buf[pos] = std.ascii.toUpper(buf[pos]);
                    pos += arg_type.len - 1;
                } else {
                    std.mem.copyForwards(u8, buf[pos..], arg_type);
                    buf[pos] = std.ascii.toUpper(buf[pos]);
                    pos += arg_type.len;
                }
            }
        }
    }
    return buf[0..pos];
}

pub fn getReturnType(self: *Context, method: GodotApi.GdMethod) []const u8 {
    return switch (method) {
        .builtin => |bc| self.correctType(bc.return_type, ""),
        .class => |cls| if (cls.return_value) |ret| self.correctType(ret.type, ret.meta) else "void",
    };
}

pub fn getZigFuncName(self: *Context, godot_func_name: []const u8) []const u8 {
    const result = self.func_names.getOrPut(self.allocator, godot_func_name) catch unreachable;

    if (!result.found_existing) {
        result.value_ptr.* = self.correctName(case.allocTo(self.allocator, func_case, godot_func_name) catch unreachable);
    }

    return result.value_ptr.*;
}

pub fn getVariantTypeName(self: *Context, class_name: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const nnn = case.bufTo(&buf, .snake, class_name) catch unreachable;
    return std.fmt.allocPrint(self.allocator, "godot.c.GDEXTENSION_VARIANT_TYPE_{s}", .{std.ascii.upperString(&buf, nnn)}) catch unreachable;
}

pub fn isRefCounted(self: *Context, type_name: []const u8) bool {
    const real_type = util.childType(type_name);
    if (self.engine_classes.get(real_type)) |v| {
        return v;
    }
    return false;
}

pub fn isEngineClass(self: *Context, type_name: []const u8) bool {
    const real_type = util.childType(type_name);
    return std.mem.eql(u8, real_type, "Object") or self.engine_classes.contains(real_type);
}

pub fn isSingleton(self: *Context, class_name: []const u8) bool {
    return self.singletons.contains(class_name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMapUnmanaged;

const case = @import("case");

const GodotApi = @import("GodotApi.zig");
const util = @import("util.zig");

const CodegenConfig = @import("types.zig").CodegenConfig;
