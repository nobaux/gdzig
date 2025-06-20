const std = @import("std");
const case = @import("case");
const types = @import("types.zig");
const enums = @import("enums.zig");
const packed_array = @import("packed_array.zig");
const gdextension = @import("gdextension");

const Allocator = std.mem.Allocator;
const GdExtensionApi = @import("extension_api.zig");
const string = []const u8;
const StreamBuilder = @import("stream_builder.zig").DefaultStreamBuilder;
const CodegenConfig = types.CodegenConfig;
const CodegenContext = types.CodegenContext;
const ProcType = enums.ProcType;

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

const func_case: case.Case = .camel;

pub fn generate(allocator: Allocator, gdapi: GdExtensionApi, config: CodegenConfig) !void {
    var ctx = try CodegenContext.init(allocator);
    defer ctx.deinit();

    try parseGdExtensionHeaders(config, &ctx);
    try parseClassSizes(gdapi, config, &ctx);
    try parseSingletons(gdapi, config, &ctx);

    try generateGlobalEnums(gdapi, config, &ctx);
    try generateUtilityFunctions(gdapi, config, &ctx);
    try generateClasses(gdapi, .builtinClass, config, &ctx);
    try generateClasses(gdapi, .class, config, &ctx);
    try generateGodotCore(config, &ctx);
}

pub fn generateProc(code_builder: *StreamBuilder, fn_node: anytype, class_name: string, func_name: string, return_type_orig: string, comptime proc_type: ProcType, ctx: *CodegenContext) !void {
    const zig_func_name = getZigFuncName(func_name, ctx);

    const return_type: string = blk: {
        if (std.mem.startsWith(u8, return_type_orig, "*")) {
            break :blk try std.fmt.allocPrint(ctx.allocator, "?{s}", .{return_type_orig});
        } else {
            break :blk return_type_orig;
        }
    };

    if (proc_type == .Constructor) {
        var buf: [256]u8 = undefined;
        const atypes = getArgumentsTypes(fn_node, &buf, ctx);
        if (atypes.len > 0) {
            const temp_atypes_func_name = try std.fmt.allocPrint(ctx.allocator, "{s}_from_{s}", .{ func_name, atypes });
            const atypes_func_name = getZigFuncName(temp_atypes_func_name, ctx);

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

    var args = std.ArrayList(string).init(ctx.allocator);
    defer args.deinit();
    var arg_types = std.ArrayList(string).init(ctx.allocator);
    defer arg_types.deinit();
    const need_return = !std.mem.eql(u8, return_type, "void");
    var is_first_arg = true;
    if (!is_static) {
        if (proc_type == .BuiltinClassMethod or proc_type == .Destructor) {
            if (is_const) {
                _ = try code_builder.write(0, "self: Self");
            } else {
                _ = try code_builder.write(0, "self: *Self");
            }

            is_first_arg = false;
        } else if (proc_type == .EngineClassMethod) {
            _ = try code_builder.write(0, "self: anytype");
            is_first_arg = false;
        }
    }
    const arg_name_postfix = "_"; //to avoid shadowing member function, which is not allowed in Zig

    if (proc_type != .Destructor) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = correctType(a.type, "", ctx);
                const arg_name = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ a.name, arg_name_postfix });
                // //constructors use Variant to store each argument, which use double/int64_t for float/int internally
                // if (proc_type == .Constructor) {
                //     if (std.mem.eql(u8, arg_type, "f32")) {}
                // }
                try addDependType(arg_type, ctx);
                if (!is_first_arg) {
                    try code_builder.write(0, ", ");
                }
                is_first_arg = false;
                if (isEngineClass(arg_type, ctx)) {
                    try code_builder.print(0, "{s}: anytype", .{arg_name});
                } else {
                    if ((proc_type != .Constructor or !isStringType(class_name)) and (isStringType(arg_type))) {
                        try code_builder.print(0, "{s}: anytype", .{arg_name});
                    } else {
                        try code_builder.print(0, "{s}: {s}", .{ arg_name, arg_type });
                    }
                }

                try args.append(arg_name);
                try arg_types.append(arg_type);
            }
        }

        if (is_vararg) {
            if (!is_first_arg) {
                _ = try code_builder.write(0, ", ");
            }
            const arg_name = "varargs";
            try code_builder.print(0, "{s}: anytype", .{arg_name});
            try args.append(arg_name);
            try arg_types.append("anytype");
        }
    }

    try code_builder.printLine(0, ") {s} {{", .{return_type});
    if (need_return) {
        try addDependType(return_type, ctx);
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
            if (isEngineClass(arg_types.items[i], ctx)) {
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

    const enum_type_name = getVariantTypeName(class_name, ctx);
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
                if (isEngineClass(return_type, ctx)) {
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
            try code_builder.printLine(2, "const method: godot.GDExtensionPtrConstructor = godot.variantGetPtrConstructor({s}, {d}) orelse @panic(\"Constructor not found\");", .{ enum_type_name, fn_node.index });
            try code_builder.printLine(1, "method(@ptrCast(&result), {s});", .{arg_array});
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

pub fn generateConstructor(class_node: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder, ctx: *CodegenContext) !void {
    const class_name = correctName(class_node.name, ctx);

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
        if (std.mem.eql(u8, class_name, "String")) {
            try code_builder.writeLine(0, string_class_extra_constructors_code);
        }
        if (std.mem.eql(u8, class_name, "StringName")) {
            try code_builder.writeLine(0, string_name_class_extra_constructors_code);
        }

        for (class_node.constructors) |c| {
            try generateProc(code_builder, c, class_name, "init", "Self", .Constructor, ctx);
        }

        if (class_node.has_destructor) {
            try generateProc(code_builder, null, class_name, "deinit", "void", .Destructor, ctx);
        }
    }
}

pub fn generateMethods(class_node: anytype, code_builder: *StreamBuilder, comptime is_builtin_class: bool, generated_method_map: *types.StringVoidMap, ctx: *CodegenContext) !void {
    const class_name = correctName(class_node.name, ctx);
    const enum_type_name = getVariantTypeName(class_name, ctx);

    const proc_type = if (is_builtin_class) ProcType.BuiltinClassMethod else ProcType.EngineClassMethod;

    var vf_builder = StreamBuilder.init(ctx.allocator);
    defer vf_builder.deinit();

    if (class_node.methods) |ms| {
        for (ms) |m| {
            const func_name = m.name;

            const zig_func_name = getZigFuncName(func_name, ctx);

            if (@hasField(@TypeOf(m), "is_virtual") and m.is_virtual) {
                if (m.arguments) |as| {
                    for (as) |a| {
                        const arg_type = correctType(a.type, "", ctx);
                        if (isEngineClass(arg_type, ctx) or isRefCounted(arg_type, ctx)) {
                            //std.debug.print("engine class arg type:  {s}::{s}({s})\n", .{ class_name, m.name, arg_type });
                        }
                    }
                }

                const casecmp_to_func_name = getZigFuncName("casecmp_to", ctx);

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
                        break :blk correctType(m.return_type, "", ctx);
                    } else if (m.return_value) |ret| {
                        break :blk correctType(ret.type, ret.meta, ctx);
                    } else {
                        break :blk "void";
                    }
                };

                if (!generated_method_map.contains(zig_func_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, zig_func_name, {});
                    try generateProc(code_builder, m, class_name, func_name, return_type, proc_type, ctx);
                }
            }
        }
    }
    if (!is_builtin_class) {
        const temp_virtual_func_name = try std.fmt.allocPrint(ctx.allocator, "get_virtual_{s}", .{class_name});
        const virtual_func_name = getZigFuncName(temp_virtual_func_name, ctx);

        try code_builder.printLine(0, "pub fn {s}(comptime T:type, p_userdata: ?*anyopaque, p_name: godot.GDExtensionConstStringNamePtr) godot.GDExtensionClassCallVirtual {{", .{virtual_func_name});
        try code_builder.writeLine(0, vf_builder.getWritten());
        if (class_node.inherits.len > 0) {
            const temp_virtual_inherits_func_name = try std.fmt.allocPrint(ctx.allocator, "get_virtual_{s}", .{class_node.inherits});
            const virtual_inherits_func_name = getZigFuncName(temp_virtual_inherits_func_name, ctx);

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
                const member_type = correctType(m.type, "", ctx);
                //getter
                const temp_getter_name = try std.fmt.allocPrint(ctx.allocator, "get_{s}", .{m.name});
                const getter_name = getZigFuncName(temp_getter_name, ctx);

                if (!generated_method_map.contains(getter_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, getter_name, {});

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
                const temp_setter_name = try std.fmt.allocPrint(ctx.allocator, "set_{s}", .{m.name});
                const setter_name = getZigFuncName(temp_setter_name, ctx);

                if (!generated_method_map.contains(setter_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, setter_name, {});

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

fn generateGlobalEnums(api: GdExtensionApi, config: CodegenConfig, ctx: *CodegenContext) !void {
    var code_builder = StreamBuilder.init(ctx.allocator);
    defer code_builder.deinit();

    for (api.global_enums) |ge| {
        if (std.mem.startsWith(u8, ge.name, "Variant.")) continue;

        try code_builder.printLine(0, "pub const {s} = i64;", .{ge.name});
        for (ge.values) |v| {
            try code_builder.printLine(0, "pub const {s}:i64 = {d};", .{ v.name, v.value });
        }
    }

    try ctx.appendClass("global");
    const file_name = try std.mem.concat(ctx.allocator, u8, &.{ config.output, "/global.zig" });
    defer ctx.allocator.free(file_name);
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = file_name, .data = code_builder.getWritten() });
}

fn parseEngineClasses(api: GdExtensionApi, ctx: *CodegenContext) !void {
    for (api.classes) |bc| {
        // TODO: why?
        if (std.mem.eql(u8, bc.name, "ClassDB")) {
            continue;
        }

        try ctx.putEngineClass(bc.name, bc.is_refcounted);
    }

    for (api.native_structures) |ns| {
        try ctx.putEngineClass(ns.name, false);
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

fn getArgumentsTypes(fn_node: anytype, buf: []u8, ctx: *CodegenContext) string {
    var pos: usize = 0;
    if (@hasField(@TypeOf(fn_node), "arguments")) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = correctType(a.type, "", ctx);
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

fn generateSingletonMethods(class_name: []const u8, code_builder: *StreamBuilder, generated_method_map: *types.StringVoidMap, ctx: *CodegenContext) !void {
    if (isSingleton(class_name, ctx)) {
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
        try generated_method_map.putNoClobber(ctx.allocator, "getSingleton", {});
    }
}

fn initializeClassGeneration(class_name: []const u8, code_builder: *StreamBuilder, ctx: *CodegenContext) !void {
    code_builder.reset();
    ctx.clearDependencies();
    try code_builder.printLine(0, "pub const {s} = struct {{", .{class_name});
    try code_builder.writeLine(4, "pub const Self = @This();");
}

fn finalizeClassGeneration(class_name: []const u8, code_builder: *StreamBuilder, config: CodegenConfig, ctx: *CodegenContext) !void {
    try code_builder.printLine(0, "}};", .{});

    const code = try addImports(class_name, code_builder, ctx);
    defer ctx.allocator.free(code);

    const file_name = try std.mem.concat(ctx.allocator, u8, &.{ config.output, "/", class_name, ".zig" });
    defer ctx.allocator.free(file_name);
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = file_name, .data = code });
}

pub fn generateBuiltinClassMethods(bc: GdExtensionApi.BuiltinClass, class_name: []const u8, code_builder: *StreamBuilder, ctx: *CodegenContext) !void {
    var generated_method_map: types.StringVoidMap = .empty;
    defer generated_method_map.deinit(ctx.allocator);

    try generateSingletonMethods(class_name, code_builder, &generated_method_map, ctx);

    if (hasAnyMethod(bc)) {
        try generateConstructor(bc, code_builder, ctx);
        try generateMethods(bc, code_builder, true, &generated_method_map, ctx);
    }
}

fn generateEngineClassMethods(bc: GdExtensionApi.Class, class_name: []const u8, code_builder: *StreamBuilder, ctx: *CodegenContext) !void {
    var generated_method_map: types.StringVoidMap = .empty;
    defer generated_method_map.deinit(ctx.allocator);

    try generateSingletonMethods(class_name, code_builder, &generated_method_map, ctx);

    if (hasAnyMethod(bc)) {
        try generateMethods(bc, code_builder, false, &generated_method_map, ctx);
    }
}

fn generateBuiltinClass(bc: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder, config: CodegenConfig, ctx: *CodegenContext) !void {
    const class_name = bc.name;

    if (shouldSkipClass(class_name)) {
        return;
    }

    try ctx.appendClass(class_name);

    try initializeClassGeneration(class_name, code_builder, ctx);

    if (isPackedArray(bc)) {
        try packed_array.generate(bc, code_builder, config, ctx);
    } else {
        try generateBuiltinClassField(class_name, code_builder, ctx);
    }

    try generateBuiltinEnums(bc, code_builder);
    try generateBuiltinConstants(bc, code_builder);
    try generateBuiltinClassMethods(bc, class_name, code_builder, ctx);

    try finalizeClassGeneration(class_name, code_builder, config, ctx);
}

fn isPackedArray(bc: GdExtensionApi.BuiltinClass) bool {
    return packed_array.regex.isMatch(bc.name);
}

fn generateBuiltinClassField(class_name: []const u8, code_builder: *StreamBuilder, ctx: *CodegenContext) !void {
    try code_builder.printLine(0, "value:[{d}]u8,", .{ctx.getClassSize(class_name).?});
}

fn generateEngineClassField(bc: GdExtensionApi.Class, code_builder: *StreamBuilder) !void {
    try code_builder.writeLine(0, "godot_object: ?*anyopaque,\n");

    // Handle inheritance
    if (bc.inherits.len > 0) {
        try code_builder.printLine(0, "pub usingnamespace godot.{s};", .{bc.inherits});
    }
}

fn generateInstanceBindingCallbacks(class_name: []const u8, code_builder: *StreamBuilder) !void {
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

pub fn generateClass(bc: GdExtensionApi.Class, code_builder: *StreamBuilder, config: CodegenConfig, ctx: *CodegenContext) !void {
    const class_name = bc.name;

    if (shouldSkipClass(class_name)) {
        return;
    }

    try ctx.appendClass(class_name);
    try ctx.appendEngineClass(class_name);

    try initializeClassGeneration(class_name, code_builder, ctx);
    try generateEngineClassField(bc, code_builder);
    try generateEngineEnums(bc, code_builder);
    try generateEngineConstants(bc, code_builder);

    try generateEngineClassMethods(bc, class_name, code_builder, ctx);

    if (false) {
        try generateInstanceBindingCallbacks(class_name, code_builder);
    }

    try finalizeClassGeneration(class_name, code_builder, config, ctx);
}

fn generateClasses(api: GdExtensionApi, comptime of_type: ClassType, config: CodegenConfig, ctx: *CodegenContext) !void {
    const class_defs = if (of_type == .builtinClass) api.builtin_classes else api.classes;
    var code_builder = StreamBuilder.init(ctx.allocator);
    defer code_builder.deinit();

    if (of_type != .builtinClass) {
        try parseEngineClasses(api, ctx);
    }

    for (class_defs) |bc| {
        if (of_type == .builtinClass) {
            try generateBuiltinClass(bc, &code_builder, config, ctx);
        } else {
            try generateClass(bc, &code_builder, config, ctx);
        }
    }
}

fn generateGodotCore(config: CodegenConfig, ctx: *CodegenContext) !void {
    const fp_map = ctx.func_pointers_map;

    var code_builder = StreamBuilder.init(ctx.allocator);
    defer code_builder.deinit();

    var loader_builder = StreamBuilder.init(ctx.allocator);
    defer loader_builder.deinit();

    try code_builder.writeLine(0, "const std = @import(\"std\");");
    try code_builder.writeLine(0, "const godot = @import(\"godot\");");
    try code_builder.writeLine(0, "pub const util = @import(\"util.zig\");");
    try code_builder.writeLine(0, "pub const c = @import(\"gdextension\");");

    for (ctx.all_classes.items) |cls| {
        if (std.mem.eql(u8, cls, "global")) {
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

    for (comptime std.meta.declarations(gdextension)) |decl| {
        if (std.mem.startsWith(u8, decl.name, "GDExtensionInterface")) {
            const type_suffix = try std.mem.replaceOwned(u8, ctx.allocator, decl.name, "GDExtensionInterface", "");
            defer ctx.allocator.free(type_suffix);
            if (std.mem.eql(u8, type_suffix, "FunctionPtr") or std.mem.eql(u8, type_suffix, "GetProcAddress")) {
                continue;
            }

            const res2 = try std.mem.replaceOwned(u8, ctx.allocator, type_suffix, "PlaceHolder", "Placeholder");
            defer ctx.allocator.free(res2);
            var res = try std.mem.replaceOwned(u8, ctx.allocator, res2, "CallableCustomGetUserData", "CallableCustomGetUserdata");
            defer ctx.allocator.free(res);

            const fn_name = fp_map.get(decl.name).?;
            const fn_docs = ctx.func_docs_map.get(decl.name).?;

            res[0] = std.ascii.toLower(res[0]);
            try code_builder.write(0, fn_docs);
            try code_builder.printLine(0, "pub var {s}:std.meta.Child(godot.{s}) = undefined;", .{ res, decl.name });
            try loader_builder.printLine(1, "{s} = @ptrCast(getProcAddress(\"{s}\"));", .{ res, fn_name });
        }
    }

    try loader_builder.writeLine(1, "godot.Variant.initBindings();");

    for (ctx.all_engine_classes.items) |cls| {
        try loader_builder.printLine(1, "godot.getClassName({0s}).* = StringName.initFromLatin1Chars(\"{0s}\");", .{cls});
    }

    try loader_builder.writeLine(0, "}");
    try loader_builder.writeLine(0, "pub fn deinitCore() void {");
    for (ctx.all_engine_classes.items) |cls| {
        try loader_builder.printLine(1, "godot.getClassName({0s}).deinit();", .{cls});
    }

    try loader_builder.writeLine(0, "}");
    for (ctx.all_engine_classes.items) |cls| {
        const constructor_code =
            \\pub fn init{0s}() {0s} {{
            \\    return .{{
            \\        .godot_object = godot.classdbConstructObject(@ptrCast(godot.getClassName({0s})))
            \\    }};
            \\}}
        ;
        if (!isSingleton(cls, ctx)) {
            try loader_builder.printLine(0, constructor_code, .{cls});
        }
    }

    try code_builder.writeLine(0, loader_builder.getWritten());

    const file_name = try std.mem.concat(ctx.allocator, u8, &.{ config.output, "/core.zig" });
    defer ctx.allocator.free(file_name);
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = file_name, .data = code_builder.getWritten() });
}

fn getZigFuncName(godot_func_name: []const u8, ctx: *CodegenContext) []const u8 {
    const result = ctx.getOrPutFuncName(godot_func_name) catch unreachable;

    if (!result.found_existing) {
        result.value_ptr.* = correctName(case.allocTo(ctx.allocator, func_case, godot_func_name) catch unreachable, ctx);
    }

    return result.value_ptr.*;
}

fn isStringType(type_name: string) bool {
    return std.mem.eql(u8, type_name, "String") or std.mem.eql(u8, type_name, "StringName");
}

fn childType(type_name: string) string {
    var child_type = type_name;
    while (child_type[0] == '?' or child_type[0] == '*') {
        child_type = child_type[1..];
    }
    return child_type;
}

fn isRefCounted(type_name: string, ctx: *CodegenContext) bool {
    const real_type = childType(type_name);
    if (ctx.getEngineClass(real_type)) |v| {
        return v;
    }
    return false;
}

fn isEngineClass(type_name: string, ctx: *CodegenContext) bool {
    const real_type = childType(type_name);
    return std.mem.eql(u8, real_type, "Object") or ctx.containsEngineClass(real_type);
}

fn isSingleton(class_name: string, ctx: *CodegenContext) bool {
    return ctx.containsSingleton(class_name);
}

fn isBitfield(type_name: string) bool {
    return std.mem.startsWith(u8, type_name, "bitfield::");
}

fn isEnum(type_name: string) bool {
    return std.mem.startsWith(u8, type_name, "enum::") or isBitfield(type_name);
}

fn getEnumClass(type_name: string) string {
    const pos = std.mem.lastIndexOf(u8, type_name, ".");
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
    const pos = std.mem.lastIndexOf(u8, type_name, ":");
    if (pos) |p| {
        return type_name[p + 1 ..];
    } else {
        return type_name;
    }
}

fn getVariantTypeName(class_name: string, ctx: *CodegenContext) string {
    var buf: [256]u8 = undefined;
    const nnn = toSnakeCase(class_name, &buf);
    return std.fmt.allocPrint(ctx.allocator, "godot.GDEXTENSION_VARIANT_TYPE_{s}", .{std.ascii.upperString(&buf, nnn)}) catch unreachable;
}

fn addDependType(type_name: string, ctx: *CodegenContext) !void {
    var depend_type = childType(type_name);

    if (std.mem.startsWith(u8, depend_type, "TypedArray")) {
        depend_type = depend_type[11 .. depend_type.len - 1];
        try ctx.appendDependency("Array");
    }

    if (std.mem.startsWith(u8, depend_type, "Ref(")) {
        depend_type = depend_type[4 .. depend_type.len - 1];
        try ctx.appendDependency("Ref");
    }

    const pos = std.mem.indexOf(u8, depend_type, ".");
    if (pos) |p| {
        try ctx.appendDependency(depend_type[0..p]);
    } else {
        try ctx.appendDependency(depend_type);
    }
}

fn correctType(type_name: string, meta: string, ctx: *CodegenContext) string {
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
    } else if (isEnum(correct_type)) {
        const cls = getEnumClass(correct_type);
        if (std.mem.eql(u8, cls, "GlobalConstants")) {
            return std.fmt.allocPrint(ctx.allocator, "global.{s}", .{getEnumName(correct_type)}) catch unreachable;
        } else {
            return getEnumName(correct_type);
        }
    }

    if (std.mem.startsWith(u8, correct_type, "const ")) {
        correct_type = correct_type[6..];
    }

    if (isRefCounted(correct_type, ctx)) {
        return std.fmt.allocPrint(ctx.allocator, "?{s}", .{correct_type}) catch unreachable;
    } else if (isEngineClass(correct_type, ctx)) {
        return std.fmt.allocPrint(ctx.allocator, "?{s}", .{correct_type}) catch unreachable;
    } else if (correct_type[correct_type.len - 1] == '*') {
        return std.fmt.allocPrint(ctx.allocator, "?*{s}", .{correct_type[0 .. correct_type.len - 1]}) catch unreachable;
    }
    return correct_type;
}

fn correctName(name: string, ctx: *CodegenContext) string {
    if (keywords.has(name)) {
        return std.fmt.allocPrint(ctx.allocator, "@\"{s}\"", .{name}) catch unreachable;
    }

    return name;
}

fn addImports(class_name: []const u8, code_builder: *StreamBuilder, ctx: *CodegenContext) ![]const u8 {
    //handle imports
    var imp_builder = StreamBuilder.init(ctx.allocator);
    defer imp_builder.deinit();
    var imported_class_map: types.StringBoolMap = .empty;
    defer imported_class_map.deinit(ctx.allocator);

    //filter types which are no need to be imported
    try imported_class_map.put(ctx.allocator, "Self", true);
    try imported_class_map.put(ctx.allocator, "void", true);
    try imported_class_map.put(ctx.allocator, "String", true);
    try imported_class_map.put(ctx.allocator, "StringName", true);

    try imp_builder.writeLine(0, "const godot = @import(\"godot\");");
    try imp_builder.writeLine(0, "const c = godot.c;");
    try imp_builder.writeLine(0, "const vector = @import(\"vector\");");

    if (!std.mem.eql(u8, class_name, "String")) {
        try imp_builder.writeLine(0, "const String = godot.String;");
    }

    if (!std.mem.eql(u8, class_name, "StringName")) {
        try imp_builder.writeLine(0, "const StringName = godot.StringName;");
    }

    for (ctx.depends.items) |d| {
        if (std.mem.eql(u8, d, class_name)) continue;
        if (imported_class_map.contains(d)) continue;
        if (builtin_type_map.has(d)) continue;
        try imported_class_map.putNoClobber(ctx.allocator, d, true);
        try imp_builder.printLine(0, "const {0s} = godot.{0s};", .{d});
    }

    try imp_builder.write(0, code_builder.getWritten());
    return ctx.allocator.dupe(u8, imp_builder.getWritten());
}

fn generateUtilityFunctions(api: GdExtensionApi, config: CodegenConfig, ctx: *CodegenContext) !void {
    var code_builder = StreamBuilder.init(ctx.allocator);
    defer code_builder.deinit();
    ctx.clearDependencies();

    for (api.utility_functions) |f| {
        const return_type = correctType(f.return_type, "", ctx);
        try generateProc(&code_builder, f, "", f.name, return_type, .UtilityFunction, ctx);
    }

    const code = try addImports("", &code_builder, ctx);
    defer ctx.allocator.free(code);

    const file_name = try std.mem.concat(ctx.allocator, u8, &.{ config.output, "/util.zig" });
    defer ctx.allocator.free(file_name);
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = file_name, .data = code });
}

const ClassType = enum {
    class,
    builtinClass,
};

fn shouldSkipClass(class_name: []const u8) bool {
    return std.mem.eql(u8, class_name, "bool") or
        std.mem.eql(u8, class_name, "Nil") or
        std.mem.eql(u8, class_name, "int") or
        std.mem.eql(u8, class_name, "float") or
        native_type_map.has(class_name);
}

fn generateBuiltinEnums(bc: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder) !void {
    if (bc.enums) |es| {
        for (es) |e| {
            try code_builder.printLine(0, "pub const {s} = c_int;", .{e.name});
            for (e.values) |v| {
                try code_builder.printLine(0, "pub const {s}:c_int = {d};", .{ v.name, v.value });
            }
        }
    }
}

fn generateEngineEnums(bc: GdExtensionApi.Class, code_builder: *StreamBuilder) !void {
    if (bc.enums) |es| {
        for (es) |e| {
            try code_builder.printLine(0, "pub const {s} = c_int;", .{e.name});
            for (e.values) |v| {
                try code_builder.printLine(0, "pub const {s}:c_int = {d};", .{ v.name, v.value });
            }
        }
    }
}

fn generateBuiltinConstants(bc: GdExtensionApi.BuiltinClass, code_builder: *StreamBuilder) !void {
    _ = code_builder; // TODO: implement builtin constants generation
    if (bc.constants) |cs| {
        for (cs) |c| {
            _ = c; // TODO: parse value string
            //try code_builder.printLine(0, "pub const {s}:{s} = {s};", .{ c.name, correctType(c.type, ""), c.value });
        }
    }
}

fn generateEngineConstants(bc: GdExtensionApi.Class, code_builder: *StreamBuilder) !void {
    if (bc.constants) |cs| {
        for (cs) |c| {
            try code_builder.printLine(0, "pub const {s}:c_int = {d};", .{ c.name, c.value });
        }
    }
}

fn parseClassSizes(api: GdExtensionApi, config: CodegenConfig, ctx: *CodegenContext) !void {
    for (api.builtin_class_sizes) |bcs| {
        if (!std.mem.eql(u8, bcs.build_configuration, config.conf)) {
            continue;
        }

        for (bcs.sizes) |sz| {
            try ctx.putClassSize(sz.name, sz.size);
        }
    }
}

fn parseSingletons(api: GdExtensionApi, config: CodegenConfig, ctx: *CodegenContext) !void {
    _ = config;
    for (api.singletons) |sg| {
        try ctx.putSingleton(sg.name, sg.type);
    }
}

fn parseGdExtensionHeaders(config: CodegenConfig, ctx: *CodegenContext) !void {
    const header_file = try std.fs.openFileAbsolute(config.gdextension_h_path, .{});
    var buffered_reader = std.io.bufferedReader(header_file.reader());
    const reader = buffered_reader.reader();

    const name_doc = "@name";

    var buf: [1024]u8 = undefined;
    var fn_name: ?[]const u8 = null;
    var fp_type: ?[]const u8 = null;
    const safe_ident_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";

    var doc_stream: std.ArrayListUnmanaged(u8) = .empty;
    const doc_writer: std.ArrayListUnmanaged(u8).Writer = doc_stream.writer(ctx.allocator);

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
                    try doc_writer.writeAll(try ctx.allocator.dupe(u8, doc_line));
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
            fn_name = try ctx.allocator.dupe(u8, line[start..]);
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
            fp_type = try ctx.allocator.dupe(u8, fp_type_slice[start..(end + start)]);
        }

        if (fn_name) |_| if (fp_type) |_| {
            try ctx.putFuncPointer(fp_type.?, fn_name.?);

            if (doc_start) |start_index| if (doc_end) |end_index| {
                const doc_text = try ctx.allocator.dupe(u8, doc_stream.items[start_index..end_index]);
                try ctx.putFuncDoc(fp_type.?, doc_text);
            };

            fn_name = null;
            fp_type = null;
            doc_start = null;
            doc_end = null;
        };
    }
}

pub fn toSnakeCase(in: []const u8, buf: []u8) []const u8 {
    return case.bufTo(buf, .snake, in) catch @panic("toSnakeCase failed");
}
