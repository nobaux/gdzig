const std = @import("std");
const C = @import("gdextension");
const case = @import("case");
const mzvr = @import("mvzr");
const packed_array = @import("packed_array.zig");
const enums = @import("enums.zig");

const Allocator = std.mem.Allocator;
const GdExtensionApi = @import("extension_api.zig");
const StreamBuilder = @import("stream_builder.zig").StreamBuilder;
const mem = std.mem;
const string = []const u8;
const Mode = enums.Mode;
const ProcType = enums.ProcType;

var outpath: []const u8 = undefined;

var mode: Mode = .quiet;

var temp_buf: *StreamBuilder(u8, 1024 * 1024) = undefined;

var cwd: std.fs.Dir = undefined;

const func_case: case.Case = .camel;
var func_name_map: StringStringMap = undefined;

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"addrspace"},
    .{"align"},
    .{"and"},
    .{"asm"},
    .{"async"},
    .{"await"},
    .{"break"},
    .{"catch"},
    .{"comptime"},
    .{"const"},
    .{"continue"},
    .{"defer"},
    .{"else"},
    .{"enum"},
    .{"errdefer"},
    .{"error"},
    .{"export"},
    .{"extern"},
    .{"for"},
    .{"if"},
    .{"inline"},
    .{"noalias"},
    .{"noinline"},
    .{"nosuspend"},
    .{"opaque"},
    .{"or"},
    .{"orelse"},
    .{"packed"},
    .{"anyframe"},
    .{"pub"},
    .{"resume"},
    .{"return"},
    .{"linksection"},
    .{"callconv"},
    .{"struct"},
    .{"suspend"},
    .{"switch"},
    .{"test"},
    .{"threadlocal"},
    .{"try"},
    .{"union"},
    .{"unreachable"},
    .{"usingnamespace"},
    .{"var"},
    .{"volatile"},
    .{"allowzero"},
    .{"while"},
    .{"anytype"},
    .{"fn"},
});

const IdentWidth = 4;
const StringSizeMap = std.StringHashMap(i64);
const StringBoolMap = std.StringHashMap(bool);
const StringVoidMap = std.StringHashMap(void);
const StringStringMap = std.StringHashMap(string);

var class_size_map: StringSizeMap = undefined;
var engine_class_map: StringBoolMap = undefined;

const base_type_map = std.StaticStringMap(string).initComptime(.{
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

const builtin_type_map = std.StaticStringMap(void).initComptime(.{
    .{"i8"},
    .{"u8"},
    .{"i16"},
    .{"u16"},
    .{"i32"},
    .{"u32"},
    .{"i64"},
    .{"u64"},
    .{"bool"},
    .{"f32"},
    .{"f64"},
    .{"c_int"},
});

const native_type_map = std.StaticStringMap(void).initComptime(.{
    .{"Vector2"},
    .{"Vector2i"},
    .{"Vector3"},
    .{"Vector3i"},
    .{"Vector4"},
    .{"Vector4i"},
});

var singletons_map: StringStringMap = undefined;
var all_classes: std.ArrayList(string) = undefined;
var all_engine_classes: std.ArrayList(string) = undefined;
var depends: std.ArrayList(string) = undefined;

pub fn toSnakeCase(in: []const u8, buf: []u8) []const u8 {
    return case.bufTo(buf, .snake, in) catch @panic("toSnakeCase failed");
}

fn parseClassSizes(api: GdExtensionApi, conf_name: string) !void {
    for (api.builtin_class_sizes) |bcs| {
        if (!std.mem.eql(u8, bcs.build_configuration, conf_name)) {
            continue;
        }

        for (bcs.sizes) |sz| {
            try class_size_map.put(sz.name, sz.size);
        }
    }
}

fn parseSingletons(api: GdExtensionApi) !void {
    for (api.singletons) |sg| {
        try singletons_map.put(sg.name, sg.type);
    }
}

fn parseFunctionPointers(allocator: Allocator, header_path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    const header_file = try std.fs.openFileAbsolute(header_path, .{});
    var buffered_reader = std.io.bufferedReader(header_file.reader());
    const reader = buffered_reader.reader();

    var fp_map = std.StringHashMapUnmanaged([]const u8){};

    const name_doc = "@name";

    var buf: [1024]u8 = undefined;
    var fn_name: ?[]const u8 = null;
    var fp_type: ?[]const u8 = null;
    const safe_ident_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

    while (true) {
        const line: []const u8 = reader.readUntilDelimiterOrEof(&buf, '\n') catch break orelse break;

        if (std.mem.containsAtLeast(u8, line, 1, name_doc)) {
            const name_index = std.mem.indexOf(u8, line, name_doc).?;
            const start = name_index + name_doc.len + 1; // +1 to skip the space after @name
            fn_name = try allocator.dupe(u8, line[start..]);
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
            fp_type = try allocator.dupe(u8, fp_type_slice[start..(end + start)]);
        }

        if (fn_name) |_| if (fp_type) |_| {
            try fp_map.putNoClobber(allocator, fp_type.?, fn_name.?);

            fn_name = null;
            fp_type = null;
        };
    }

    return fp_map;
}

fn isStringType(type_name: string) bool {
    return mem.eql(u8, type_name, "String") or mem.eql(u8, type_name, "StringName");
}

fn childType(type_name: string) string {
    var child_type = type_name;
    while (child_type[0] == '?' or child_type[0] == '*') {
        child_type = child_type[1..];
    }
    return child_type;
}

fn isRefCounted(type_name: string) bool {
    const real_type = childType(type_name);
    if (engine_class_map.get(real_type)) |v| {
        return v;
    }
    return false;
}

fn isEngineClass(type_name: string) bool {
    const real_type = childType(type_name);
    return mem.eql(u8, real_type, "Object") or engine_class_map.contains(real_type);
}

fn isSingleton(type_name: string) bool {
    return singletons_map.contains(type_name);
}

fn isBitfield(type_name: string) bool {
    return mem.startsWith(u8, type_name, "bitfield::");
}

fn isEnum(type_name: string) bool {
    return mem.startsWith(u8, type_name, "enum::") or isBitfield(type_name);
}

fn getEnumClass(type_name: string) string {
    const pos = mem.lastIndexOf(u8, type_name, ".");
    if (pos) |p| {
        if (isBitfield(type_name)) {
            return type_name[10..p];
        } else {
            return type_name[6..p];
        }
    } else {
        return "GlobalConstants";
    }
}

fn getEnumName(type_name: string) string {
    const pos = mem.lastIndexOf(u8, type_name, ":");
    if (pos) |p| {
        return type_name[p + 1 ..];
    } else {
        return type_name;
    }
}

fn getVariantTypeName(class_name: string) string {
    var buf: [256]u8 = undefined;
    const nnn = toSnakeCase(class_name, &buf);
    return temp_buf.bufPrint("godot.GDEXTENSION_VARIANT_TYPE_{s}", .{std.ascii.upperString(&buf, nnn)}) catch unreachable;
}

fn addDependType(type_name: string) !void {
    var depend_type = childType(type_name);

    if (mem.startsWith(u8, depend_type, "TypedArray")) {
        depend_type = depend_type[11 .. depend_type.len - 1];
        try depends.append("Array");
    }

    if (mem.startsWith(u8, depend_type, "Ref(")) {
        depend_type = depend_type[4 .. depend_type.len - 1];
        try depends.append("Ref");
    }

    const pos = mem.indexOf(u8, depend_type, ".");
    if (pos) |p| {
        try depends.append(depend_type[0..p]);
    } else {
        try depends.append(depend_type);
    }
}

fn correctType(type_name: string, meta: string) string {
    var correct_type = if (meta.len > 0) meta else type_name;
    if (correct_type.len == 0) return "void";

    if (mem.eql(u8, correct_type, "float")) {
        return "f64";
    } else if (mem.eql(u8, correct_type, "int")) {
        return "i64";
    } else if (mem.eql(u8, correct_type, "Nil")) {
        return "Variant";
    } else if (base_type_map.has(correct_type)) {
        return base_type_map.get(correct_type).?;
    } else if (mem.startsWith(u8, correct_type, "typedarray::")) {
        //simplified to just use array instead
        return "Array";
    } else if (isEnum(correct_type)) {
        const cls = getEnumClass(correct_type);
        if (mem.eql(u8, cls, "GlobalConstants")) {
            return temp_buf.bufPrint("global.{s}", .{getEnumName(correct_type)}) catch unreachable;
        } else {
            return getEnumName(correct_type);
        }
    }

    if (mem.startsWith(u8, correct_type, "const ")) {
        correct_type = correct_type[6..];
    }

    if (isRefCounted(correct_type)) {
        return temp_buf.bufPrint("?{s}", .{correct_type}) catch unreachable;
    } else if (isEngineClass(correct_type)) {
        return temp_buf.bufPrint("?{s}", .{correct_type}) catch unreachable;
    } else if (correct_type[correct_type.len - 1] == '*') {
        return temp_buf.bufPrint("?*{s}", .{correct_type[0 .. correct_type.len - 1]}) catch unreachable;
    }
    return correct_type;
}

fn correctName(name: string) string {
    if (keywords.has(name)) {
        return temp_buf.bufPrint("@\"{s}\"", .{name}) catch unreachable;
    }

    return name;
}

fn generateGlobalEnums(api: GdExtensionApi, allocator: std.mem.Allocator) !void {
    var code_builder = try StreamBuilder(u8, 100 * 1024).init(allocator);
    defer code_builder.deinit();

    for (api.global_enums) |ge| {
        if (std.mem.startsWith(u8, ge.name, "Variant.")) continue;

        try code_builder.printLine(0, "pub const {s} = i64;", .{ge.name});
        for (ge.values) |v| {
            try code_builder.printLine(0, "pub const {s}:i64 = {d};", .{ v.name, v.value });
        }
    }

    try all_classes.append("global");
    const file_name = try std.mem.concat(allocator, u8, &.{ outpath, "/global.zig" });
    defer allocator.free(file_name);
    try cwd.writeFile(.{ .sub_path = file_name, .data = code_builder.getWritten() });
}

fn parseEngineClasses(api: GdExtensionApi) !void {
    for (api.classes) |bc| {
        // TODO: why?
        if (mem.eql(u8, bc.name, "ClassDB")) {
            continue;
        }

        try engine_class_map.put(bc.name, bc.is_refcounted);
    }

    for (api.native_structures) |ns| {
        try engine_class_map.put(ns.name, false);
    }
}

fn hasAnyMethod(class_node: anytype) bool {
    if (@hasField(@TypeOf(class_node), "constructors")) {
        if (class_node.constructors.len > 0) return true;
    }
    if (@hasField(@TypeOf(class_node), "has_destructor")) {
        if (class_node.has_destructor) return true;
    }
    if (class_node.methods != null) {
        return true;
    }
    if (@hasField(@TypeOf(class_node), "members")) {
        if (class_node.members) |ms| {
            if (ms.len > 0) return true;
        }
    }
    if (@hasField(@TypeOf(class_node), "indexing_return_type")) return true;
    if (@hasField(@TypeOf(class_node), "is_keyed")) {
        if (class_node.is_keyed) return true;
    }
    return false;
}

fn getArgumentsTypes(fn_node: anytype, buf: []u8) string {
    var pos: usize = 0;
    if (@hasField(@TypeOf(fn_node), "arguments")) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = correctType(a.type, "");
                if (arg_type[0] == '*' or arg_type[0] == '?') {
                    mem.copyForwards(u8, buf[pos..], arg_type[1..]);
                    buf[pos] = std.ascii.toUpper(buf[pos]);
                    pos += arg_type.len - 1;
                } else {
                    mem.copyForwards(u8, buf[pos..], arg_type);
                    buf[pos] = std.ascii.toUpper(buf[pos]);
                    pos += arg_type.len;
                }
            }
        }
    }
    return buf[0..pos];
}

fn generateProc(code_builder: anytype, fn_node: anytype, allocator: mem.Allocator, class_name: string, func_name: string, return_type_orig: string, comptime proc_type: ProcType) !void {
    const zig_func_name = getZigFuncName(allocator, func_name);

    var return_type: string = undefined;
    if (std.mem.startsWith(u8, return_type_orig, "*")) {
        return_type = try temp_buf.bufPrint("?{s}", .{return_type_orig});
    } else {
        return_type = return_type_orig;
    }

    if (proc_type == .Constructor) {
        var buf: [256]u8 = undefined;
        const atypes = getArgumentsTypes(fn_node, &buf);
        if (atypes.len > 0) {
            const temp_atypes_func_name = try temp_buf.bufPrint("{s}_from_{s}", .{ func_name, atypes });
            const atypes_func_name = getZigFuncName(allocator, temp_atypes_func_name);

            try code_builder.print(0, "pub fn {s}(", .{atypes_func_name});
        } else {
            try code_builder.print(0, "pub fn {s}(", .{zig_func_name});
        }
    } else {
        try code_builder.print(0, "pub fn {s}(", .{zig_func_name});
    }

    const is_const = (proc_type == .BuiltinClassMethod or proc_type == .EngineClassMethod) and fn_node.is_const;
    const is_static = (proc_type == .BuiltinClassMethod or proc_type == .EngineClassMethod) and fn_node.is_static;
    const is_vararg = proc_type != .Constructor and proc_type != .Destructor and fn_node.is_vararg;

    var args = std.ArrayList(string).init(allocator);
    defer args.deinit();
    var arg_types = std.ArrayList(string).init(allocator);
    defer arg_types.deinit();
    const need_return = !mem.eql(u8, return_type, "void");
    var is_first_arg = true;
    if (!is_static) {
        if (proc_type == .BuiltinClassMethod or proc_type == .Destructor) {
            if (is_const) {
                _ = try code_builder.writer.write("self: Self");
            } else {
                _ = try code_builder.writer.write("self: *Self");
            }

            is_first_arg = false;
        } else if (proc_type == .EngineClassMethod) {
            _ = try code_builder.writer.write("self: anytype");
            is_first_arg = false;
        }
    }
    const arg_name_postfix = "_"; //to avoid shadowing member function, which is not allowed in Zig

    if (proc_type != .Destructor) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = correctType(a.type, "");
                const arg_name = temp_buf.bufPrint("{s}{s}", .{ a.name, arg_name_postfix }) catch unreachable; //correctName(a.name);
                // //constructors use Variant to store each argument, which use double/int64_t for float/int internally
                // if (proc_type == .Constructor) {
                //     if (mem.eql(u8, arg_type, "f32")) {}
                // }
                try addDependType(arg_type);
                if (!is_first_arg) {
                    _ = try code_builder.writer.write(", ");
                }
                is_first_arg = false;
                if (isEngineClass(arg_type)) {
                    try code_builder.writer.print("{s}: anytype", .{arg_name});
                } else {
                    if ((proc_type != .Constructor or !isStringType(class_name)) and (isStringType(arg_type))) {
                        try code_builder.writer.print("{s}: anytype", .{arg_name});
                    } else {
                        try code_builder.writer.print("{s}: {s}", .{ arg_name, arg_type });
                    }
                }

                try args.append(arg_name);
                try arg_types.append(arg_type);
            }
        }

        if (is_vararg) {
            if (!is_first_arg) {
                _ = try code_builder.writer.write(", ");
            }
            const arg_name = "varargs";
            try code_builder.writer.print("{s}: anytype", .{arg_name});
            try args.append(arg_name);
            try arg_types.append("anytype");
        }
    }

    try code_builder.printLine(0, ") {s} {{", .{return_type});
    if (need_return) {
        try addDependType(return_type);
        if (return_type[0] == '?') {
            try code_builder.printLine(1, "var result:{s} = null;", .{return_type});
        } else {
            try code_builder.printLine(1, "var result:{0s} = @import(\"std\").mem.zeroes({0s});", .{return_type});
        }
    }

    var arg_array: string = "null";
    var arg_count: string = "0";

    if (is_vararg) {
        try code_builder.writeLine(1, "const fields = @import(\"std\").meta.fields(@TypeOf(varargs));");
        try code_builder.printLine(1, "var args:[fields.len + {d}]*const godot.Variant = undefined;", .{args.items.len - 1});
        for (0..args.items.len - 1) |i| {
            if (isStringType(arg_types.items[i])) {
                try code_builder.printLine(1, "args[{d}] = &godot.Variant.initFrom(godot.String.initFromLatin1Chars({s}));", .{ i, args.items[i] });
            } else {
                try code_builder.printLine(1, "args[{d}] = &godot.Variant.initFrom({s});", .{ i, args.items[i] });
            }
        }
        try code_builder.writeLine(1, "inline for(fields, 0..)|f, i|{");
        try code_builder.printLine(2, "args[{d}+i] = &godot.Variant.initFrom(@field(varargs, f.name));", .{args.items.len - 1});
        try code_builder.writeLine(1, "}");

        arg_array = "@ptrCast(&args)";
        arg_count = "args.len";
    } else if (args.items.len > 0) {
        try code_builder.printLine(1, "var args:[{d}]godot.GDExtensionConstTypePtr = undefined;", .{args.items.len});
        for (0..args.items.len) |i| {
            if (isEngineClass(arg_types.items[i])) {
                try code_builder.printLine(1, "if(@typeInfo(@TypeOf({1s})) == .@\"struct\") {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr(&{1s})); }}", .{ i, args.items[i] });
                try code_builder.printLine(1, "else if(@typeInfo(@TypeOf({1s})) == .optional) {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr(&{1s}.?)); }}", .{ i, args.items[i] });
                try code_builder.printLine(1, "else if(@typeInfo(@TypeOf({1s})) == .pointer) {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr({1s})); }}", .{ i, args.items[i] });
                try code_builder.printLine(1, "else {{ args[{0d}] = null; }}", .{i});
            } else {
                if ((proc_type != .Constructor or !isStringType(class_name)) and (isStringType(arg_types.items[i]))) {
                    try code_builder.printLine(1, "if(@TypeOf({2s}) == {1s}) {{ args[{0d}] = @ptrCast(&{2s}); }} else {{ args[{0d}] = @ptrCast(&{1s}.initFromLatin1Chars({2s})); }}", .{ i, arg_types.items[i], args.items[i] });
                } else {
                    try code_builder.printLine(1, "args[{d}] = @ptrCast(&{s});", .{ i, args.items[i] });
                }
            }
        }
        arg_array = "@ptrCast(&args)";
        arg_count = "args.len";
    }

    const enum_type_name = getVariantTypeName(class_name);
    const result_string = if (need_return) "@ptrCast(&result)" else "null";

    switch (proc_type) {
        .UtilityFunction => {
            try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrUtilityFunction = null; };");
            try code_builder.writeLine(1, "if( Binding.method == null ) {");
            try code_builder.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{func_name});
            try code_builder.printLine(2, "Binding.method = godot.variantGetPtrUtilityFunction(@ptrCast(&func_name), {d});", .{fn_node.hash});
            try code_builder.writeLine(1, "}");
            try code_builder.printLine(1, "Binding.method.?({s}, {s}, {s});", .{ result_string, arg_array, arg_count });
        },
        .EngineClassMethod => {
            const self_ptr = if (is_static) "null" else "@ptrCast(godot.getGodotObjectPtr(self).*)";

            try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionMethodBindPtr = null; };");
            try code_builder.writeLine(1, "if( Binding.method == null ) {");
            try code_builder.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{func_name});
            try code_builder.printLine(2, "Binding.method = godot.classdbGetMethodBind(@ptrCast(godot.getClassName({s})), @ptrCast(&func_name), {d});", .{ class_name, fn_node.hash });
            try code_builder.writeLine(1, "}");
            if (is_vararg) {
                try code_builder.writeLine(1, "var err:godot.GDExtensionCallError = undefined;");
                if (std.mem.eql(u8, return_type, "Variant")) {
                    try code_builder.printLine(1, "godot.objectMethodBindCall(Binding.method.?, {s}, @ptrCast(@alignCast(&args[0])), args.len, &result, &err);", .{self_ptr});
                } else {
                    try code_builder.writeLine(1, "var ret:Variant = Variant.init();");
                    try code_builder.printLine(1, "godot.objectMethodBindCall(Binding.method.?, {s}, @ptrCast(@alignCast(&args[0])), args.len, &ret, &err);", .{self_ptr});
                    if (need_return) {
                        try code_builder.printLine(1, "result = ret.as({s});", .{return_type});
                    }
                }
            } else {
                if (isEngineClass(return_type)) {
                    try code_builder.writeLine(1, "var godot_object:?*anyopaque = null;");
                    try code_builder.printLine(1, "godot.objectMethodBindPtrcall(Binding.method.?, {s}, {s}, @ptrCast(&godot_object));", .{ self_ptr, arg_array });
                    try code_builder.printLine(1, "result = {s}{{ .godot_object = godot_object }};", .{childType(return_type)});
                } else {
                    try code_builder.printLine(1, "godot.objectMethodBindPtrcall(Binding.method.?, {s}, {s}, {s});", .{ self_ptr, arg_array, result_string });
                }
            }
        },
        .BuiltinClassMethod => {
            try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrBuiltInMethod = null; };");
            try code_builder.writeLine(1, "if( Binding.method == null ) {");
            try code_builder.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{func_name});
            try code_builder.printLine(2, "Binding.method = godot.variantGetPtrBuiltinMethod({s}, @ptrCast(&func_name.value), {d});", .{ enum_type_name, fn_node.hash });
            try code_builder.writeLine(1, "}");
            if (is_static) {
                try code_builder.printLine(1, "Binding.method.?(null, {s}, {s}, {s});", .{ arg_array, result_string, arg_count });
            } else {
                try code_builder.printLine(1, "Binding.method.?(@ptrCast(@constCast(&self.value)), {s}, {s}, {s});", .{ arg_array, result_string, arg_count });
            }
        },
        .Constructor => {
            try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrConstructor = null; };");
            try code_builder.writeLine(1, "if( Binding.method == null ) {");
            try code_builder.printLine(2, "Binding.method = godot.variantGetPtrConstructor({s}, {d});", .{ enum_type_name, fn_node.index });
            try code_builder.writeLine(1, "}");
            try code_builder.printLine(1, "Binding.method.?(@ptrCast(&result), {s});", .{arg_array});
        },
        .Destructor => {
            try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrDestructor = null; };");
            try code_builder.writeLine(1, "if( Binding.method == null ) {");
            try code_builder.printLine(2, "Binding.method = godot.variantGetPtrDestructor({s});", .{enum_type_name});
            try code_builder.writeLine(1, "}");
            try code_builder.writeLine(1, "Binding.method.?(@ptrCast(&self.value));");
        },
    }

    if (need_return) {
        try code_builder.writeLine(1, "return result;");
    }
    try code_builder.writeLine(0, "}");
}

fn generateConstructor(class_node: anytype, code_builder: anytype, allocator: mem.Allocator) !void {
    const class_name = correctName(class_node.name);

    const string_class_extra_constructors_code =
        \\pub fn initFromLatin1Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNewWithLatin1CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf8Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNewWithUtf8CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf16Chars(chars:[]const godot.char16_t) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNewWithUtf16CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf32Chars(chars:[]const godot.char32_t) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNewWithUtf32CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromWideChars(chars:[]const godot.wchar_t) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNewWithWideCharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
    ;

    const string_name_class_extra_constructors_code =
        \\pub fn initStaticFromLatin1Chars(chars:[:0]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNameNewWithLatin1Chars(@ptrCast(&self.value), chars.ptr, 1);
        \\    return self;
        \\}
        \\pub fn initFromLatin1Chars(chars:[:0]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNameNewWithLatin1Chars(@ptrCast(&self.value), chars.ptr, 0);
        \\    return self;
        \\}
        \\pub fn initFromUtf8Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.stringNameNewWithUtf8CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
    ;

    if (@hasField(@TypeOf(class_node), "constructors")) {
        if (mem.eql(u8, class_name, "String")) {
            try code_builder.writeLine(0, string_class_extra_constructors_code);
        }
        if (mem.eql(u8, class_name, "StringName")) {
            try code_builder.writeLine(0, string_name_class_extra_constructors_code);
        }

        for (class_node.constructors) |c| {
            try generateProc(code_builder, c, allocator, class_name, "init", "Self", .Constructor);
        }

        if (class_node.has_destructor) {
            try generateProc(code_builder, null, allocator, class_name, "deinit", "void", .Destructor);
        }
    }
}

fn generateMethod(class_node: anytype, code_builder: anytype, allocator: mem.Allocator, comptime is_builtin_class: bool, generated_method_map: *StringVoidMap) !void {
    const class_name = correctName(class_node.name);
    const enum_type_name = getVariantTypeName(class_name);

    const proc_type = if (is_builtin_class) ProcType.BuiltinClassMethod else ProcType.EngineClassMethod;

    var vf_builder = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    defer vf_builder.deinit();

    if (class_node.methods) |ms| {
        for (ms) |m| {
            const func_name = m.name;

            const zig_func_name = getZigFuncName(allocator, func_name);

            if (@hasField(@TypeOf(m), "is_virtual") and m.is_virtual) {
                if (m.arguments) |as| {
                    for (as) |a| {
                        const arg_type = correctType(a.type, "");
                        if (isEngineClass(arg_type) or isRefCounted(arg_type)) {
                            //std.debug.print("engine class arg type:  {s}::{s}({s})\n", .{ class_name, m.name, arg_type });
                        }
                    }
                }

                const casecmp_to_func_name = getZigFuncName(allocator, "casecmp_to");

                try vf_builder.printLine(1, "if (@as(*StringName, @ptrCast(@constCast(p_name))).{1s}(\"{0s}\") == 0 and @hasDecl(T, \"{0s}\")) {{", .{
                    func_name,
                    casecmp_to_func_name,
                });

                try vf_builder.writeLine(2, "const MethodBinder = struct {");

                try vf_builder.printLine(3, "pub fn {s}(p_instance: godot.GDExtensionClassInstancePtr, p_args: [*c]const godot.GDExtensionConstTypePtr, p_ret: godot.GDExtensionTypePtr) callconv(.C) void {{", .{
                    func_name,
                });
                try vf_builder.printLine(4, "const MethodBinder = godot.MethodBinderT(@TypeOf(T.{s}));", .{
                    func_name,
                });
                try vf_builder.printLine(4, "MethodBinder.bindPtrcall(@ptrCast(@constCast(&T.{s})), p_instance, p_args, p_ret);", .{
                    func_name,
                });
                try vf_builder.writeLine(3, "}");
                try vf_builder.writeLine(2, "};");

                try vf_builder.printLine(2, "return MethodBinder.{s};", .{func_name});
                try vf_builder.writeLine(1, "}");
                continue;
            } else {
                const return_type = blk: {
                    if (is_builtin_class) {
                        break :blk correctType(m.return_type, "");
                    } else if (m.return_value) |ret| {
                        break :blk correctType(ret.type, ret.meta);
                    } else {
                        break :blk "void";
                    }
                };

                if (!generated_method_map.contains(zig_func_name)) {
                    try generated_method_map.putNoClobber(zig_func_name, {});
                    try generateProc(code_builder, m, allocator, class_name, func_name, return_type, proc_type);
                }
            }
        }
    }
    if (!is_builtin_class) {
        const temp_virtual_func_name = try std.fmt.allocPrint(allocator, "get_virtual_{s}", .{class_name});
        const virtual_func_name = getZigFuncName(allocator, temp_virtual_func_name);

        try code_builder.printLine(0, "pub fn {s}(comptime T:type, p_userdata: ?*anyopaque, p_name: godot.GDExtensionConstStringNamePtr) godot.GDExtensionClassCallVirtual {{", .{virtual_func_name});
        try code_builder.writeLine(0, vf_builder.getWritten());
        if (class_node.inherits.len > 0) {
            const temp_virtual_inherits_func_name = try std.fmt.allocPrint(allocator, "get_virtual_{s}", .{class_node.inherits});
            const virtual_inherits_func_name = getZigFuncName(allocator, temp_virtual_inherits_func_name);

            try code_builder.printLine(1, "return godot.{s}.{s}(T, p_userdata, p_name);", .{ class_node.inherits, virtual_inherits_func_name });
        } else {
            try code_builder.writeLine(1, "_ = T;");
            try code_builder.writeLine(1, "_ = p_userdata;");
            try code_builder.writeLine(1, "_ = p_name;");
            try code_builder.writeLine(1, "return null;");
        }
        try code_builder.writeLine(0, "}");
    }
    if (@hasField(@TypeOf(class_node), "members")) {
        if (class_node.members) |ms| {
            for (ms) |m| {
                const member_type = correctType(m.type, "");
                //getter
                const temp_getter_name = try temp_buf.bufPrint("get_{s}", .{m.name});
                const getter_name = getZigFuncName(allocator, temp_getter_name);

                if (!generated_method_map.contains(getter_name)) {
                    try generated_method_map.putNoClobber(getter_name, {});

                    try code_builder.printLine(0, "pub fn {s}(self: Self) {s} {{", .{ getter_name, member_type });
                    try code_builder.printLine(1, "var result:{s} = undefined;", .{member_type});

                    try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrGetter = null; };");
                    try code_builder.writeLine(1, "if( Binding.method == null ) {");
                    try code_builder.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{m.name});
                    try code_builder.printLine(2, "Binding.method = godot.variantGetPtrGetter({s}, @ptrCast(&func_name));", .{enum_type_name});
                    try code_builder.writeLine(1, "}");

                    try code_builder.writeLine(1, "Binding.method.?(@ptrCast(&self.value), @ptrCast(&result));");
                    try code_builder.writeLine(1, "return result;");
                    try code_builder.writeLine(0, "}");
                }

                //setter
                const temp_setter_name = try temp_buf.bufPrint("set_{s}", .{m.name});
                const setter_name = getZigFuncName(allocator, temp_setter_name);

                if (!generated_method_map.contains(setter_name)) {
                    try generated_method_map.putNoClobber(setter_name, {});

                    try code_builder.printLine(0, "pub fn {s}(self: *Self, v: {s}) void {{", .{ setter_name, member_type });

                    try code_builder.writeLine(1, "const Binding = struct{ pub var method:godot.GDExtensionPtrSetter = null; };");
                    try code_builder.writeLine(1, "if( Binding.method == null ) {");
                    try code_builder.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{m.name});
                    try code_builder.printLine(2, "Binding.method = godot.variantGetPtrSetter({s}, @ptrCast(&func_name));", .{enum_type_name});
                    try code_builder.writeLine(1, "}");

                    try code_builder.writeLine(1, "Binding.method.?(@ptrCast(&self.value), @ptrCast(&v));");
                    try code_builder.writeLine(0, "}");
                }
            }
        }
    }
    // if "members" in clsNode:
    //     for m in clsNode["members"]:
    //         var typeStr = m["type"].getStr
    //         var origName = m["name"].getStr
    //         var mname = correctName(origName)
    //         if typeStr in ["bool", "int", "float"]:
    //             result.add "proc " & mname & "*(this:" & className & "):" &
    //                     typeStr & "=\n"
    //             result.add fmt"""  methodBindings{className}.member_{origName}_getter(this.opaque.addr, result.addr){'\n'}"""
    //             result.add "proc `" & origName & "=`*(this:var " & className &
    //                     ", v:" & typeStr & ")=\n"
    //             result.add fmt"""  methodBindings{className}.member_{origName}_setter(this.opaque.addr, v.addr){'\n'}"""
    //         else:
    //             result.add "proc " & mname & "*(this:" & className & "):" &
    //                     typeStr & "=\n"
    //             result.add fmt"""  methodBindings{className}.member_{origName}_getter(this.opaque.addr, result.opaque.addr){'\n'}"""
    //             result.add "proc `" & origName & "=`*(this:var " & className &
    //                     ", v:" & typeStr & ")=\n"
    //             result.add fmt"""  methodBindings{className}.member_{origName}_setter(this.opaque.addr, v.opaque.addr){'\n'}"""
}

fn addImports(class_name: []const u8, code_builder: anytype, allocator: std.mem.Allocator) ![]const u8 {
    //handle imports
    var imp_builder = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    defer imp_builder.deinit();
    var imported_class_map = StringBoolMap.init(allocator);
    defer imported_class_map.deinit();

    //filter types which are no need to be imported
    try imported_class_map.put("Self", true);
    try imported_class_map.put("void", true);
    try imported_class_map.put("String", true);
    try imported_class_map.put("StringName", true);

    try imp_builder.writeLine(0, "const godot = @import(\"godot\");");
    try imp_builder.writeLine(0, "const c = godot.c;");

    if (!mem.eql(u8, class_name, "String")) {
        try imp_builder.writeLine(0, "const String = godot.String;");
    }

    if (!mem.eql(u8, class_name, "StringName")) {
        try imp_builder.writeLine(0, "const StringName = godot.StringName;");
    }

    for (depends.items) |d| {
        if (mem.eql(u8, d, class_name)) continue;
        if (imported_class_map.contains(d)) continue;
        if (builtin_type_map.has(d)) continue;
        try imp_builder.printLine(0, "const {0s} = godot.{0s};", .{d});
        try imported_class_map.put(d, true);
    }

    try imp_builder.writer.writeAll(code_builder.getWritten());
    return allocator.dupe(u8, imp_builder.getWritten());
}

fn generateUtilityFunctions(api: GdExtensionApi, allocator: std.mem.Allocator) !void {
    var code_builder = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    defer code_builder.deinit();
    depends.clearRetainingCapacity();

    for (api.utility_functions) |f| {
        const return_type = correctType(f.return_type, "");
        try generateProc(code_builder, f, allocator, "", f.name, return_type, .UtilityFunction);
    }

    const code = try addImports("", code_builder, allocator);
    defer allocator.free(code);

    const file_name = try std.mem.concat(allocator, u8, &.{ outpath, "/util.zig" });
    defer allocator.free(file_name);
    try cwd.writeFile(.{ .sub_path = file_name, .data = code });
}

const ClassType = enum {
    class,
    builtinClass,
};

fn generateClasses(api: GdExtensionApi, allocator: std.mem.Allocator, comptime of_type: ClassType) !void {
    const class_defs = if (of_type == .builtinClass) api.builtin_classes else api.classes;
    var code_builder = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    defer code_builder.deinit();

    if (of_type != .builtinClass) {
        try parseEngineClasses(api);
    }

    for (class_defs) |bc| {
        if (std.mem.eql(u8, bc.name, "bool") or
            std.mem.eql(u8, bc.name, "Nil") or
            std.mem.eql(u8, bc.name, "int") or
            std.mem.eql(u8, bc.name, "float"))
        {
            continue;
        }

        if (native_type_map.has(bc.name)) {
            continue;
        }

        const class_name = bc.name;
        try all_classes.append(class_name);
        if (of_type != .builtinClass) {
            try all_engine_classes.append(class_name);
        }

        if (packed_array.regex.isMatch(bc.name) and of_type == .builtinClass) {
            // TODO: generate packed array struct
            try packed_array.generate(bc, mode, code_builder);
        }

        code_builder.reset();
        depends.clearRetainingCapacity();
        try code_builder.printLine(0, "pub const {s} = extern struct {{", .{class_name});

        if (of_type == .builtinClass) {
            try code_builder.printLine(0, "value:[{d}]u8,", .{class_size_map.get(class_name).?});
        } else {
            try code_builder.writeLine(0, "godot_object: ?*anyopaque,\n");
        }
        try code_builder.writeLine(0, "pub const Self = @This();");

        if (of_type != .builtinClass) {
            if (bc.inherits.len > 0) {
                try code_builder.printLine(0, "pub usingnamespace godot.{s};", .{bc.inherits});
            }
        }

        if (bc.enums) |es| {
            for (es) |e| {
                try code_builder.printLine(0, "pub const {s} = c_int;", .{e.name});
                for (e.values) |v| {
                    try code_builder.printLine(0, "pub const {s}:c_int = {d};", .{ v.name, v.value });
                }
            }
        }
        if (bc.constants) |cs| {
            for (cs) |c| {
                if (of_type == .builtinClass) {
                    //todo:parse value string
                    //try code_builder.printLine(0, "pub const {s}:{s} = {s};", .{ c.name, correctType(c.type, ""), c.value });
                } else {
                    try code_builder.printLine(0, "pub const {s}:c_int = {d};", .{ c.name, c.value });
                }
            }
        }

        var generated_method_map = StringVoidMap.init(allocator);

        if (isSingleton(class_name)) {
            const singleton_code =
                \\var instance: ?{0s} = null;
                \\pub fn getSingleton() {0s} {{
                \\    if(instance == null ) {{
                \\        const obj = godot.globalGetSingleton(@ptrCast(godot.getClassName({0s})));
                \\        instance = .{{ .godot_object = obj }};
                \\    }}
                \\    return instance.?;
                \\}}
            ;
            try code_builder.printLine(0, singleton_code, .{class_name});
            try generated_method_map.putNoClobber("getSingleton", {});
        }

        if (hasAnyMethod(bc)) {
            try generateConstructor(bc, code_builder, allocator);
            try generateMethod(bc, code_builder, allocator, of_type == .builtinClass, &generated_method_map);
        }

        if (false) {
            const callbacks_code =
                \\pub var callbacks_{0s} = godot.GDExtensionInstanceBindingCallbacks{{ .create_callback = instanceBindingCreateCallback, .free_callback = instanceBindingFreeCallback, .reference_callback = instanceBindingReferenceCallback }};
                \\fn instanceBindingCreateCallback(p_token: ?*anyopaque, p_instance: ?*anyopaque) callconv(.C) ?*anyopaque {{
                \\    _ = p_token;
                \\    var self = @as(*{0s}, @ptrCast(@alignCast(godot.memAlloc(@sizeOf({0s})))));
                \\    //var self = godot.general_allocator.create({0s}) catch unreachable;
                \\    self.godot_object = @ptrCast(p_instance);
                \\    return @ptrCast(self);
                \\}}
                \\fn instanceBindingFreeCallback(p_token: ?*anyopaque, p_instance: ?*anyopaque, p_binding: ?*anyopaque) callconv(.C) void {{
                \\    //godot.general_allocator.destroy(@as(*{0s}, @ptrCast(@alignCast(p_binding.?))));
                \\    godot.memFree(p_binding.?);
                \\    _ = p_instance;
                \\    _ = p_token;
                \\}}
                \\fn instanceBindingReferenceCallback(p_token: ?*anyopaque, p_binding: ?*anyopaque, p_reference: godot.GDExtensionBool) callconv(.C) godot.GDExtensionBool {{
                \\    _ = p_reference;
                \\    _ = p_binding;
                \\    _ = p_token;
                \\    return 1;
                \\}}
            ;
            try code_builder.printLine(0, callbacks_code, .{class_name});
        }

        try code_builder.printLine(0, "}};", .{});

        const code = try addImports(class_name, code_builder, allocator);
        defer allocator.free(code);

        const file_name = try std.mem.concat(allocator, u8, &.{ outpath, "/", class_name, ".zig" });
        defer allocator.free(file_name);
        try cwd.writeFile(.{ .sub_path = file_name, .data = code });
    }
}

fn generateGodotCore(allocator: std.mem.Allocator, fp_map: *const std.StringHashMapUnmanaged([]const u8)) !void {
    var code_builder = try StreamBuilder(u8, 10 * 1024 * 1024).init(allocator);
    defer code_builder.deinit();

    var loader_builder = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    defer loader_builder.deinit();

    try code_builder.writeLine(0, "const std = @import(\"std\");");
    try code_builder.writeLine(0, "const godot = @import(\"godot\");");
    try code_builder.writeLine(0, "pub const util = @import(\"util.zig\");");
    try code_builder.writeLine(0, "pub const c = @import(\"gdextension\");");

    for (all_classes.items) |cls| {
        if (mem.eql(u8, cls, "global")) {
            try code_builder.printLine(0, "pub const {0s} = @import(\"{0s}.zig\");", .{cls});
        } else {
            try code_builder.printLine(0, "pub const {0s} = @import(\"{0s}.zig\").{0s};", .{cls});
        }
    }

    try code_builder.writeLine(0, "pub var p_library: godot.GDExtensionClassLibraryPtr = null;");
    try loader_builder.writeLine(0, "pub fn initCore(getProcAddress:std.meta.Child(godot.GDExtensionInterfaceGetProcAddress), library: godot.GDExtensionClassLibraryPtr) !void {");
    try loader_builder.writeLine(1, "p_library = library;");

    const callback_decl_code =
        \\const BindingCallbackMap = std.AutoHashMap(StringName, *godot.GDExtensionInstanceBindingCallbacks);
    ;
    try code_builder.writeLine(0, callback_decl_code);

    for (comptime std.meta.declarations(C)) |decl| {
        if (std.mem.startsWith(u8, decl.name, "GDExtensionInterface")) {
            const type_suffix = try std.mem.replaceOwned(u8, allocator, decl.name, "GDExtensionInterface", "");
            defer allocator.free(type_suffix);
            if (std.mem.eql(u8, type_suffix, "FunctionPtr") or std.mem.eql(u8, type_suffix, "GetProcAddress")) {
                continue;
            }

            const res2 = try std.mem.replaceOwned(u8, allocator, type_suffix, "PlaceHolder", "Placeholder");
            defer allocator.free(res2);
            var res = try std.mem.replaceOwned(u8, allocator, res2, "CallableCustomGetUserData", "CallableCustomGetUserdata");
            defer allocator.free(res);

            const fn_name = fp_map.get(decl.name).?;

            res[0] = std.ascii.toLower(res[0]);
            try code_builder.printLine(0, "pub var {s}:std.meta.Child(godot.{s}) = undefined;", .{ res, decl.name });
            try loader_builder.printLine(1, "{s} = @ptrCast(getProcAddress(\"{s}\"));", .{ res, fn_name });
        }
    }

    try loader_builder.writeLine(1, "godot.Variant.initBindings();");

    for (all_engine_classes.items) |cls| {
        try loader_builder.printLine(1, "godot.getClassName({0s}).* = StringName.initFromLatin1Chars(\"{0s}\");", .{cls});
    }

    try loader_builder.writeLine(0, "}");
    try loader_builder.writeLine(0, "pub fn deinitCore() void {");
    for (all_engine_classes.items) |cls| {
        try loader_builder.printLine(1, "godot.getClassName({0s}).deinit();", .{cls});
    }

    try loader_builder.writeLine(0, "}");
    for (all_engine_classes.items) |cls| {
        const constructor_code =
            \\pub fn init{0s}() {0s} {{
            \\    return .{{
            \\        .godot_object = godot.classdbConstructObject(@ptrCast(godot.getClassName({0s})))
            \\    }};
            \\}}
        ;
        if (!isSingleton(cls)) {
            try loader_builder.printLine(0, constructor_code, .{cls});
        }
    }

    try code_builder.writeLine(0, loader_builder.getWritten());

    const file_name = try std.mem.concat(allocator, u8, &.{ outpath, "/core.zig" });
    defer allocator.free(file_name);
    try cwd.writeFile(.{ .sub_path = file_name, .data = code_builder.getWritten() });
}

fn getZigFuncName(allocator: Allocator, godot_func_name: []const u8) []const u8 {
    const result = func_name_map.getOrPut(godot_func_name) catch unreachable;

    if (!result.found_existing) {
        result.value_ptr.* = correctName(case.allocTo(allocator, func_case, godot_func_name) catch unreachable);
    }

    return result.value_ptr.*;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 5) {
        std.debug.print("Usage: binding_generator export_path generated_path precision arch verbose\n", .{});
        return;
    }

    outpath = args[2];
    mode = std.meta.stringToEnum(Mode, args[5]) orelse mode;

    class_size_map = StringSizeMap.init(allocator);
    engine_class_map = StringBoolMap.init(allocator);
    singletons_map = StringStringMap.init(allocator);
    depends = std.ArrayList(string).init(allocator);
    all_classes = std.ArrayList(string).init(allocator);
    temp_buf = try StreamBuilder(u8, 1024 * 1024).init(allocator);
    all_engine_classes = std.ArrayList(string).init(allocator);
    func_name_map = StringStringMap.init(allocator);

    cwd = std.fs.cwd();

    const gdextension_h_path = try std.fs.path.resolve(allocator, &.{ args[1], "gdextension_interface.h" });
    const extension_api_json_path = try std.fs.path.resolve(allocator, &.{ args[1], "extension_api.json" });

    const contents = try cwd.readFileAlloc(allocator, extension_api_json_path, 10 * 1024 * 1024); //"./src/api/extension_api.json", 10 * 1024 * 1024);

    const api = try std.json.parseFromSlice(GdExtensionApi, allocator, contents, .{ .ignore_unknown_fields = false });
    const gdapi = api.value;

    try cwd.deleteTree(outpath);
    try cwd.makePath(outpath);

    const conf = try temp_buf.bufPrint("{s}_{s}", .{ args[3], args[4] });
    try parseClassSizes(gdapi, conf);
    try parseSingletons(gdapi);
    const fp_map = try parseFunctionPointers(allocator, gdextension_h_path);

    try generateGlobalEnums(gdapi, allocator);
    try generateUtilityFunctions(gdapi, allocator);
    try generateClasses(gdapi, allocator, .builtinClass);
    try generateClasses(gdapi, allocator, .class);
    try generateGodotCore(allocator, &fp_map);

    // Disabled this log because it is causing issues with the zig build system
    //std.log.info("zig bindings with configuration {s} for {s} have been successfully generated, have fun!", .{ conf, api.value.header.version_full_name });

    if (mode == .verbose) {
        std.debug.print("Output path: {s}\n", .{outpath});
        std.debug.print("API JSON: {s}\n", .{extension_api_json_path});
    }
}
