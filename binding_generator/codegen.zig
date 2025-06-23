pub fn generate(ctx: *Context) !void {
    try generateGlobalEnums(ctx);
    try generateUtilityFunctions(ctx);
    try generateBuiltins(ctx);
    try generateClasses(ctx);
    try generateCore(ctx);
}

fn generateGlobalEnums(ctx: *Context) !void {
    var b = StreamBuilder.init(ctx.allocator);
    defer b.deinit();

    for (ctx.api.global_enums) |@"enum"| {
        if (std.mem.startsWith(u8, @"enum".name, "Variant.")) continue;
        try generateGlobalEnum(&b, @"enum");
    }

    try ctx.all_classes.append(ctx.allocator, "global");

    try ctx.config.output.writeFile(.{ .sub_path = "global.zig", .data = b.getWritten() });
}

fn generateGlobalEnum(b: *StreamBuilder, @"enum": GodotApi.GlobalEnum) !void {
    try b.printLine(0, "pub const {s} = i64;", .{@"enum".name});
    for (@"enum".values) |value| {
        try b.printLine(0, "pub const {s}: i64 = {d};", .{ value.name, value.value });
    }
}

fn generateTypeStart(b: *StreamBuilder, name: []const u8, description: ?[]const u8, ctx: *Context) !void {
    b.reset();
    ctx.depends.clearRetainingCapacity();

    if (description) |desc| try b.writeComments(desc);
    try b.printLine(0, "pub const {s} = extern struct {{", .{name});
    try b.writeLine(4, "pub const Self = @This();");
}

fn generateTypeEnd(b: *StreamBuilder, name: []const u8, ctx: *Context) !void {
    try b.printLine(0, "}};", .{});

    const code = try generateImports(b, name, ctx);
    defer ctx.allocator.free(code);

    const file_name = try std.mem.concat(ctx.allocator, u8, &.{ name, ".zig" });
    defer ctx.allocator.free(file_name);

    try ctx.config.output.writeFile(.{ .sub_path = file_name, .data = code });
}

fn generateBuiltins(ctx: *Context) !void {
    var b = StreamBuilder.init(ctx.allocator);
    defer b.deinit();

    for (ctx.api.builtin_classes) |builtin| {
        if (util.shouldSkipClass(builtin.name)) {
            continue;
        }
        try generateBuiltin(&b, builtin, ctx);
    }
}

fn generateBuiltin(b: *StreamBuilder, builtin: GodotApi.Builtin, ctx: *Context) !void {
    try ctx.all_classes.append(ctx.allocator, builtin.name);

    try generateTypeStart(b, builtin.name, builtin.description orelse builtin.brief_description, ctx);
    if (util.isPackedArray(builtin)) {
        try generateBuiltinPackedArray(b, builtin, ctx);
    } else {
        try generateBuiltinField(b, builtin.name, ctx);
    }
    try generateBuiltinEnums(b, builtin);
    try generateBuiltinConstants(b, builtin);
    try generateBuiltinConstructors(b, builtin, ctx);
    try generateBuiltinMethods(b, builtin, ctx);
    try generateTypeEnd(b, builtin.name, ctx);
}

fn generateBuiltinEnums(b: *StreamBuilder, builtin: GodotApi.Builtin) !void {
    if (builtin.enums) |enums| {
        for (enums) |@"enum"| {
            try b.printLine(0, "pub const {s} = c_int;", .{@"enum".name});
            for (@"enum".values) |value| {
                try b.printLine(0, "pub const {s}:c_int = {d};", .{ value.name, value.value });
            }
        }
    }
}

fn generateBuiltinConstants(b: *StreamBuilder, builtin: GodotApi.Builtin) !void {
    _ = b; // TODO: implement builtin constants generation
    if (builtin.constants) |cs| {
        for (cs) |c| {
            _ = c; // TODO: parse value string
            //try code_builder.printLine(0, "pub const {s}:{s} = {s};", .{ c.name, ctx.correctType(c.type, ""), c.value });
        }
    }
}

fn generateBuiltinConstructors(b: *StreamBuilder, builtin: GodotApi.Builtin, ctx: *Context) !void {
    const name = ctx.correctName(builtin.name);

    const string_class_extra_constructors_code =
        \\pub fn initFromLatin1Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNewWithLatin1CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf8Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNewWithUtf8CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf16Chars(chars:[]const godot.char16_t) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNewWithUtf16CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromUtf32Chars(chars:[]const godot.char32_t) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNewWithUtf32CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
        \\pub fn initFromWideChars(chars:[]const godot.wchar_t) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNewWithWideCharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
    ;

    const string_name_class_extra_constructors_code =
        \\pub fn initStaticFromLatin1Chars(chars:[:0]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNameNewWithLatin1Chars(@ptrCast(&self.value), chars.ptr, 1);
        \\    return self;
        \\}
        \\pub fn initFromLatin1Chars(chars:[:0]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNameNewWithLatin1Chars(@ptrCast(&self.value), chars.ptr, 0);
        \\    return self;
        \\}
        \\pub fn initFromUtf8Chars(chars:[]const u8) Self{
        \\    var self: Self = undefined;
        \\    godot.core.stringNameNewWithUtf8CharsAndLen(@ptrCast(&self.value), chars.ptr, @intCast(chars.len));
        \\    return self;
        \\}
    ;

    if (@hasField(@TypeOf(builtin), "constructors")) {
        if (std.mem.eql(u8, name, "String")) {
            try b.writeLine(0, string_class_extra_constructors_code);
        }
        if (std.mem.eql(u8, name, "StringName")) {
            try b.writeLine(0, string_name_class_extra_constructors_code);
        }

        for (builtin.constructors) |c| {
            try generateProc(b, c, name, "init", "Self", .Constructor, ctx);
        }

        if (builtin.has_destructor) {
            try generateProc(b, null, name, "deinit", "void", .Destructor, ctx);
        }
    }
}

fn generateBuiltinMethods(b: *StreamBuilder, builtin: GodotApi.Builtin, ctx: *Context) !void {
    var generated_method_map: StringHashMap(void) = .empty;
    defer generated_method_map.deinit(ctx.allocator);

    try generateMethods(b, builtin, &generated_method_map, ctx);
}

fn generateBuiltinField(code_builder: *StreamBuilder, class_name: []const u8, ctx: *Context) !void {
    try code_builder.printLine(0, "value: [{d}]u8,", .{
        ctx.class_sizes.get(class_name) orelse std.debug.panic("Could not get class size for {x}", .{class_name}),
    });
}

fn generateBuiltinPackedArray(b: *StreamBuilder, builtin: GodotApi.Builtin, ctx: *Context) !void {
    try b.printLine(1, "value: [{d}]u8,", .{ctx.class_sizes.get(builtin.name).?});
}

fn generateClasses(ctx: *Context) !void {
    var b = StreamBuilder.init(ctx.allocator);
    defer b.deinit();

    for (ctx.api.classes) |class| {
        if (util.shouldSkipClass(class.name)) {
            continue;
        }
        try generateClass(&b, class, ctx);
    }
}

fn generateClass(b: *StreamBuilder, class: GodotApi.Class, ctx: *Context) !void {
    try ctx.all_classes.append(ctx.allocator, class.name);
    try ctx.all_engine_classes.append(ctx.allocator, class.name);

    try generateTypeStart(b, class.name, class.description orelse class.brief_description, ctx);
    try generateClassField(b);
    try generateClassEnums(b, class);
    try generateClassConstants(b, class);
    if (class.findMethod("init") == null) {
        try generateClassInit(b, class.name);
    }
    try generateClassMethods(b, class, class.name, ctx);
    try generateTypeEnd(b, class.name, ctx);
}

fn generateClassField(b: *StreamBuilder) !void {
    try b.writeLine(0,
        \\godot_object: ?*anyopaque,
        \\
    );
}

fn generateClassEnums(b: *StreamBuilder, class: GodotApi.Class) !void {
    if (class.enums) |enums| {
        for (enums) |@"enum"| {
            try b.printLine(0, "pub const {s} = c_int;", .{@"enum".name});
            for (@"enum".values) |value| {
                try b.printLine(0, "pub const {s}:c_int = {d};", .{ value.name, value.value });
            }
        }
    }
}

fn generateClassConstants(b: *StreamBuilder, class: GodotApi.Class) !void {
    if (class.constants) |constants| {
        for (constants) |constant| {
            try b.printLine(0, "pub const {s}: c_int = {d};", .{ constant.name, constant.value });
        }
    }
}

fn generateClassInit(b: *StreamBuilder, class_name: []const u8) !void {
    try b.printLine(1,
        \\pub fn init() {0s} {{
        \\    return godot.core.init{0s}();
        \\}}
    , .{class_name});
}

fn generateClassMethods(b: *StreamBuilder, class: GodotApi.Class, class_name: []const u8, ctx: *Context) !void {
    var generated_method_map: StringHashMap(void) = .empty;
    defer generated_method_map.deinit(ctx.allocator);

    try generateClassSingleton(b, class_name, &generated_method_map, ctx);
    try generateMethods(b, class, &generated_method_map, ctx);
}

fn generateClassSingleton(b: *StreamBuilder, name: []const u8, generated_method_map: *StringHashMap(void), ctx: *Context) !void {
    if (ctx.isSingleton(name)) {
        try b.printLine(0,
            \\var instance: ?{0s} = null;
            \\pub fn getSingleton() {0s} {{
            \\    if (instance == null) {{
            \\        const obj = godot.core.globalGetSingleton(@ptrCast(godot.getClassName({0s})));
            \\        instance = .{{ .godot_object = obj }};
            \\    }}
            \\    return instance.?;
            \\}}
        , .{name});
        try generated_method_map.putNoClobber(ctx.allocator, "getSingleton", {});
    }
}

fn generateMethods(b: *StreamBuilder, @"type": anytype, generated_method_map: *StringHashMap(void), ctx: *Context) !void {
    const class_name = ctx.correctName(@"type".name);
    const enum_type_name = ctx.getVariantTypeName(class_name);
    const is_builtin_class = @TypeOf(@"type") == GodotApi.Builtin;
    const proc_type = if (is_builtin_class) ProcType.BuiltinMethod else ProcType.ClassMethod;

    var vf_builder = StreamBuilder.init(ctx.allocator);
    defer vf_builder.deinit();

    if (@"type".methods) |ms| {
        for (ms) |m| {
            const func_name = m.name;

            const zig_func_name = ctx.getZigFuncName(func_name);

            if (@hasField(@TypeOf(m), "is_virtual") and m.is_virtual) {
                if (m.arguments) |as| {
                    for (as) |a| {
                        const arg_type = ctx.correctType(a.type, "");
                        if (ctx.isEngineClass(arg_type) or ctx.isRefCounted(arg_type)) {
                            //std.debug.print("engine class arg type:  {s}::{s}({s})\n", .{ class_name, m.name, arg_type });
                        }
                    }
                }

                const casecmp_to_func_name = ctx.getZigFuncName("casecmp_to");

                try vf_builder.printLine(1, "if (@as(*StringName, @ptrCast(@constCast(p_name))).{1s}(\"{0s}\") == 0 and @hasDecl(T, \"{0s}\")) {{", .{
                    func_name,
                    casecmp_to_func_name,
                });

                try vf_builder.writeLine(2, "const MethodBinder = struct {");

                try vf_builder.printLine(3, "pub fn {s}(p_instance: godot.c.GDExtensionClassInstancePtr, p_args: [*c]const godot.c.GDExtensionConstTypePtr, p_ret: godot.c.GDExtensionTypePtr) callconv(.C) void {{", .{
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
                        break :blk ctx.correctType(m.return_type, "");
                    } else if (m.return_value) |ret| {
                        break :blk ctx.correctType(ret.type, ret.meta);
                    } else {
                        break :blk "void";
                    }
                };

                if (!generated_method_map.contains(zig_func_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, zig_func_name, {});
                    try generateProc(b, m, class_name, func_name, return_type, proc_type, ctx);
                }
            }
        }
    }

    if (!is_builtin_class) {
        var class_inherits = try ctx.api.findInherits(ctx.allocator, @"type");
        defer class_inherits.deinit(ctx.allocator);

        for (class_inherits.items) |inherits| {
            try generateVirtualMethods(b, inherits, ctx);
        }

        try b.writeLine(0, "pub fn getVirtualDispatch(comptime T:type, p_userdata: ?*anyopaque, p_name: godot.c.GDExtensionConstStringNamePtr) godot.c.GDExtensionClassCallVirtual {");
        try b.writeLine(0, vf_builder.getWritten());
        if (@"type".inherits.len > 0) {
            try b.printLine(1, "return godot.core.{s}.getVirtualDispatch(T, p_userdata, p_name);", .{@"type".inherits});
        } else {
            try b.writeLine(1, "_ = T;");
            try b.writeLine(1, "_ = p_userdata;");
            try b.writeLine(1, "_ = p_name;");
            try b.writeLine(1, "return null;");
        }
        try b.writeLine(0, "}");
    }

    if (@hasField(@TypeOf(@"type"), "members")) {
        if (@"type".members) |ms| {
            for (ms) |m| {
                const member_type = ctx.correctType(m.type, "");
                //getter
                const temp_getter_name = try std.fmt.allocPrint(ctx.allocator, "get_{s}", .{m.name});
                const getter_name = ctx.getZigFuncName(temp_getter_name);

                if (!generated_method_map.contains(getter_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, getter_name, {});

                    try b.printLine(0, "pub fn {s}(self: Self) {s} {{", .{ getter_name, member_type });
                    try b.printLine(1, "var result:{s} = undefined;", .{member_type});

                    try b.writeLine(1, "const Binding = struct{ pub var method:godot.c.GDExtensionPtrGetter = null; };");
                    try b.writeLine(1, "if( Binding.method == null ) {");
                    try b.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{m.name});
                    try b.printLine(2, "Binding.method = godot.core.variantGetPtrGetter({s}, @ptrCast(&func_name));", .{enum_type_name});
                    try b.writeLine(1, "}");

                    try b.writeLine(1, "Binding.method.?(@ptrCast(&self.value), @ptrCast(&result));");
                    try b.writeLine(1, "return result;");
                    try b.writeLine(0, "}");
                }

                //setter
                const temp_setter_name = try std.fmt.allocPrint(ctx.allocator, "set_{s}", .{m.name});
                const setter_name = ctx.getZigFuncName(temp_setter_name);

                if (!generated_method_map.contains(setter_name)) {
                    try generated_method_map.putNoClobber(ctx.allocator, setter_name, {});

                    try b.printLine(0, "pub fn {s}(self: *Self, v: {s}) void {{", .{ setter_name, member_type });

                    try b.writeLine(1, "const Binding = struct{ pub var method:godot.c.GDExtensionPtrSetter = null; };");
                    try b.writeLine(1, "if( Binding.method == null ) {");
                    try b.printLine(2, "const func_name = StringName.initFromLatin1Chars(\"{s}\");", .{m.name});
                    try b.printLine(2, "Binding.method = godot.core.variantGetPtrSetter({s}, @ptrCast(&func_name));", .{enum_type_name});
                    try b.writeLine(1, "}");

                    try b.writeLine(1, "Binding.method.?(@ptrCast(&self.value), @ptrCast(&v));");
                    try b.writeLine(0, "}");
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

fn generateVirtualMethods(b: *StreamBuilder, @"type": GodotApi.Type, ctx: *Context) !void {
    const name = try std.fmt.allocPrint(ctx.allocator, "godot.core.{s}", .{@"type".getClassName()});
    defer ctx.allocator.free(name);

    switch (@"type") {
        .builtin => |builtin| {
            if (builtin.methods) |methods| {
                for (methods) |method| {
                    if (method.isPrivate()) continue;

                    const return_type = ctx.getReturnType(.{ .builtin = method });
                    try b.printLine(1, "/// {s} builtin method: {s}", .{ builtin.name, method.name });
                    try generateProc(b, method, name, method.name, return_type, .BuiltinMethod, ctx);
                }
            }
        },
        .class => |class| {
            if (class.methods) |methods| {
                for (methods) |method| {
                    if (method.isPrivate()) continue;

                    const return_type = ctx.getReturnType(.{ .class = method });
                    try b.printLine(1, "/// {s} class method: {s}", .{ class.name, method.name });
                    try generateProc(b, method, name, method.name, return_type, .ClassMethod, ctx);
                }
            }
        },
    }
}

fn generateProc(b: *StreamBuilder, fn_node: anytype, class_name: []const u8, func_name: []const u8, return_type_orig: []const u8, comptime proc_type: ProcType, ctx: *Context) !void {
    const zig_func_name = ctx.getZigFuncName(func_name);

    const return_type: []const u8 = blk: {
        if (std.mem.startsWith(u8, return_type_orig, "*")) {
            break :blk try std.fmt.allocPrint(ctx.allocator, "?{s}", .{return_type_orig});
        } else {
            break :blk return_type_orig;
        }
    };

    if (@typeInfo(@TypeOf(fn_node)) != .null) {
        const description: ?[]const u8 = fn_node.description;
        if (description) |desc| {
            try b.writeComments(desc);
        }
    }

    if (proc_type == .Constructor) {
        var buf: [256]u8 = undefined;
        const atypes = ctx.getArgumentsTypes(fn_node, &buf);
        if (atypes.len > 0) {
            const temp_atypes_func_name = try std.fmt.allocPrint(ctx.allocator, "{s}_from_{s}", .{ func_name, atypes });
            const atypes_func_name = ctx.getZigFuncName(temp_atypes_func_name);

            try b.print(0, "pub fn {s}(", .{atypes_func_name});
        } else {
            try b.print(0, "pub fn {s}(", .{zig_func_name});
        }
    } else {
        try b.print(0, "pub fn {s}(", .{zig_func_name});
    }

    const is_const = (proc_type == .BuiltinMethod or proc_type == .ClassMethod) and fn_node.is_const;
    const is_static = (proc_type == .BuiltinMethod or proc_type == .ClassMethod) and fn_node.is_static;
    const is_vararg = proc_type != .Constructor and proc_type != .Destructor and fn_node.is_vararg;

    var args = std.ArrayList([]const u8).init(ctx.allocator);
    defer args.deinit();
    var arg_types = std.ArrayList([]const u8).init(ctx.allocator);
    defer arg_types.deinit();
    const need_return = !std.mem.eql(u8, return_type, "void");
    var is_first_arg = true;
    if (!is_static) {
        if (proc_type == .BuiltinMethod or proc_type == .Destructor) {
            if (is_const) {
                _ = try b.write(0, "self: Self");
            } else {
                _ = try b.write(0, "self: *Self");
            }

            is_first_arg = false;
        } else if (proc_type == .ClassMethod) {
            _ = try b.write(0, "self: anytype");
            is_first_arg = false;
        }
    }
    const arg_name_postfix = "_"; //to avoid shadowing member function, which is not allowed in Zig

    if (proc_type != .Destructor) {
        if (fn_node.arguments) |as| {
            for (as, 0..) |a, i| {
                _ = i;
                const arg_type = ctx.correctType(a.type, "");
                const arg_name = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ a.name, arg_name_postfix });
                // //constructors use Variant to store each argument, which use double/int64_t for float/int internally
                // if (proc_type == .Constructor) {
                //     if (std.mem.eql(u8, arg_type, "f32")) {}
                // }
                try ctx.addDependType(arg_type);
                if (!is_first_arg) {
                    try b.write(0, ", ");
                }
                is_first_arg = false;
                if (ctx.isEngineClass(arg_type)) {
                    try b.print(0, "{s}: anytype", .{arg_name});
                } else {
                    if ((proc_type != .Constructor or !util.isStringType(class_name)) and (util.isStringType(arg_type))) {
                        try b.print(0, "{s}: anytype", .{arg_name});
                    } else {
                        try b.print(0, "{s}: {s}", .{ arg_name, arg_type });
                    }
                }

                try args.append(arg_name);
                try arg_types.append(arg_type);
            }
        }

        if (is_vararg) {
            if (!is_first_arg) {
                _ = try b.write(0, ", ");
            }
            const arg_name = "varargs";
            try b.print(0, "{s}: anytype", .{arg_name});
            try args.append(arg_name);
            try arg_types.append("anytype");
        }
    }

    try b.printLine(0, ") {s} {{", .{return_type});
    if (need_return) {
        try ctx.addDependType(return_type);
        if (return_type[0] == '?') {
            try b.printLine(1, "var result:{s} = null;", .{return_type});
        } else {
            try b.printLine(1, "var result:{0s} = undefined;", .{return_type});
        }
    }

    var arg_array: []const u8 = "null";
    var arg_count: []const u8 = "0";

    if (is_vararg) {
        try b.writeLine(1, "const fields = @import(\"std\").meta.fields(@TypeOf(varargs));");
        try b.printLine(1, "var args:[fields.len + {d}]*const godot.Variant = undefined;", .{args.items.len - 1});
        for (0..args.items.len - 1) |i| {
            if (util.isStringType(arg_types.items[i])) {
                try b.printLine(1, "args[{d}] = &godot.Variant.initFrom(godot.core.String.initFromLatin1Chars({s}));", .{ i, args.items[i] });
            } else {
                try b.printLine(1, "args[{d}] = &godot.Variant.initFrom({s});", .{ i, args.items[i] });
            }
        }
        try b.writeLine(1, "inline for(fields, 0..)|f, i|{");
        try b.printLine(2, "args[{d}+i] = &godot.Variant.initFrom(@field(varargs, f.name));", .{args.items.len - 1});
        try b.writeLine(1, "}");

        arg_array = "@ptrCast(&args)";
        arg_count = "args.len";
    } else if (args.items.len > 0) {
        try b.printLine(1, "var args:[{d}]godot.c.GDExtensionConstTypePtr = undefined;", .{args.items.len});
        for (args.items, arg_types.items, 0..) |arg, arg_type, i| {
            if (ctx.isEngineClass(arg_types.items[i])) {
                try b.printLine(1, "if(@typeInfo(@TypeOf({1s})) == .@\"struct\") {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr(&{1s})); }}", .{ i, arg });
                try b.printLine(1, "else if(@typeInfo(@TypeOf({1s})) == .optional) {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr(&{1s}.?)); }}", .{ i, arg });
                try b.printLine(1, "else if(@typeInfo(@TypeOf({1s})) == .pointer) {{ args[{0d}] = @ptrCast(godot.getGodotObjectPtr({1s})); }}", .{ i, arg });
                try b.printLine(1, "else {{ args[{0d}] = null; }}", .{i});
            } else {
                if ((proc_type != .Constructor or !util.isStringType(class_name)) and (util.isStringType(arg_type))) {
                    try b.printLine(1, "if(@TypeOf({2s}) == {1s}) {{ args[{0d}] = @ptrCast(&{2s}); }} else {{ args[{0d}] = @ptrCast(&{1s}.initFromLatin1Chars({2s})); }}", .{ i, arg_type, arg });
                } else {
                    try b.printLine(1, "args[{d}] = @ptrCast(&{s});", .{ i, arg });
                }
            }
        }
        arg_array = "@ptrCast(&args)";
        arg_count = "args.len";
    }

    const enum_type_name = ctx.getVariantTypeName(class_name);
    const result_string = if (need_return) "@ptrCast(&result)" else "null";

    switch (proc_type) {
        .UtilityFunction => {
            try b.printLine(1, "const method = support.bindUtilityFunction(\"{s}\", {d});", .{
                func_name,
                fn_node.hash,
            });
            try b.printLine(1, "method({s}, {s}, {s});", .{
                result_string,
                arg_array,
                arg_count,
            });
        },
        .ClassMethod => {
            const self_ptr = if (is_static) "null" else "@ptrCast(godot.getGodotObjectPtr(self).*)";

            try b.printLine(1, "const method = support.bindEngineClassMethod({s}, \"{s}\", {d});", .{
                class_name,
                func_name,
                fn_node.hash,
            });
            if (is_vararg) {
                try b.writeLine(1, "var err:godot.c.GDExtensionCallError = undefined;");
                if (std.mem.eql(u8, return_type, "Variant")) {
                    try b.printLine(1, "godot.core.objectMethodBindCall(method, {s}, @ptrCast(@alignCast(&args[0])), args.len, &result, &err);", .{self_ptr});
                } else {
                    try b.writeLine(1, "var ret:Variant = Variant.init();");
                    try b.printLine(1, "godot.core.objectMethodBindCall(method, {s}, @ptrCast(@alignCast(&args[0])), args.len, &ret, &err);", .{self_ptr});
                    if (need_return) {
                        try b.printLine(1, "result = ret.as({s});", .{return_type});
                    }
                }
            } else {
                if (ctx.isEngineClass(return_type)) {
                    try b.writeLine(1, "var godot_object:?*anyopaque = null;");
                    try b.printLine(1, "godot.core.objectMethodBindPtrcall(method, {s}, {s}, @ptrCast(&godot_object));", .{ self_ptr, arg_array });
                    try b.printLine(1, "result = {s}{{ .godot_object = godot_object }};", .{util.childType(return_type)});
                } else {
                    try b.printLine(1, "godot.core.objectMethodBindPtrcall(method, {s}, {s}, {s});", .{ self_ptr, arg_array, result_string });
                }
            }
        },
        .BuiltinMethod => {
            try b.printLine(1, "const method = support.bindBuiltinClassMethod({s}, \"{s}\", {d});", .{ enum_type_name, func_name, fn_node.hash });
            if (is_static) {
                try b.printLine(1, "method(null, {s}, {s}, {s});", .{ arg_array, result_string, arg_count });
            } else {
                try b.printLine(1, "method(@ptrCast(@constCast(&self.value)), {s}, {s}, {s});", .{ arg_array, result_string, arg_count });
            }
        },
        .Constructor => {
            try b.printLine(2, "const method = support.bindConstructorMethod({s}, {d});", .{ enum_type_name, fn_node.index });
            try b.printLine(1, "method(@ptrCast(&result), {s});", .{arg_array});
        },
        .Destructor => {
            try b.printLine(1, "const method = support.bindDestructorMethod({s});", .{enum_type_name});
            try b.writeLine(1, "method(@ptrCast(&self.value));");
        },
    }

    if (need_return) {
        try b.writeLine(1, "return result;");
    }
    try b.writeLine(0, "}");
}

fn generateCore(ctx: *Context) !void {
    const fp_map = ctx.func_pointers;

    var cb = StreamBuilder.init(ctx.allocator);
    defer cb.deinit();

    var lb = StreamBuilder.init(ctx.allocator);
    defer lb.deinit();

    try cb.writeLine(0, "const std = @import(\"std\");");
    try cb.writeLine(0, "const godot = @import(\"godot\");");
    try cb.writeLine(0, "pub const util = @import(\"util.zig\");");
    try cb.writeLine(0, "pub const c = @import(\"gdextension\");");

    for (ctx.all_classes.items) |cls| {
        if (std.mem.eql(u8, cls, "global")) {
            try cb.printLine(0, "pub const {0s} = @import(\"{0s}.zig\");", .{cls});
        } else {
            try cb.printLine(0, "pub const {0s} = @import(\"{0s}.zig\").{0s};", .{cls});
        }
    }

    try cb.writeLine(0, "pub var p_library: godot.c.GDExtensionClassLibraryPtr = null;");

    try lb.writeLine(0, "pub fn initCore(getProcAddress:std.meta.Child(godot.c.GDExtensionInterfaceGetProcAddress), library: godot.c.GDExtensionClassLibraryPtr) !void {");
    try lb.writeLine(1, "p_library = library;");

    const callback_decl_code =
        \\const BindingCallbackMap = std.AutoHashMap(StringName, *godot.c.GDExtensionInstanceBindingCallbacks);
    ;
    try cb.writeLine(0, callback_decl_code);

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
            const fn_docs = ctx.func_docs.get(decl.name).?;

            res[0] = std.ascii.toLower(res[0]);
            try cb.write(0, fn_docs);
            try cb.printLine(0, "pub var {s}:std.meta.Child(godot.c.{s}) = undefined;", .{ res, decl.name });
            try lb.printLine(1, "{s} = @ptrCast(getProcAddress(\"{s}\"));", .{ res, fn_name });
        }
    }

    try lb.writeLine(1, "godot.Variant.initBindings();");

    for (ctx.all_engine_classes.items) |cls| {
        try lb.printLine(1, "godot.getClassName({0s}).* = StringName.initFromLatin1Chars(\"{0s}\");", .{cls});
    }

    try lb.writeLine(0, "}");
    try lb.writeLine(0, "pub fn deinitCore() void {");
    for (ctx.all_engine_classes.items) |cls| {
        try lb.printLine(1, "godot.getClassName({0s}).deinit();", .{cls});
    }

    try lb.writeLine(0, "}");
    for (ctx.all_engine_classes.items) |cls| {
        const constructor_code =
            \\pub fn init{0s}() {0s} {{
            \\    return .{{
            \\        .godot_object = godot.core.classdbConstructObject(@ptrCast(godot.getClassName({0s})))
            \\    }};
            \\}}
        ;
        if (!ctx.isSingleton(cls)) {
            try lb.printLine(0, constructor_code, .{cls});
        }
    }

    try cb.writeLine(0, lb.getWritten());

    try ctx.config.output.writeFile(.{ .sub_path = "core.zig", .data = cb.getWritten() });
}

fn generateImports(b: *StreamBuilder, class_name: []const u8, ctx: *Context) ![]const u8 {
    //handle imports
    var imp_builder = StreamBuilder.init(ctx.allocator);
    defer imp_builder.deinit();
    var imported_class_map: StringHashMap(bool) = .empty;
    defer imported_class_map.deinit(ctx.allocator);

    //filter types which are no need to be imported
    try imported_class_map.put(ctx.allocator, "Self", true);
    try imported_class_map.put(ctx.allocator, "void", true);
    try imported_class_map.put(ctx.allocator, "String", true);
    try imported_class_map.put(ctx.allocator, "StringName", true);

    try imp_builder.writeLine(0, "const godot = @import(\"godot\");");
    try imp_builder.writeLine(0, "const support = godot.support;");
    try imp_builder.writeLine(0, "const c = godot.c;");
    try imp_builder.writeLine(0, "const vector = @import(\"vector\");");

    if (!std.mem.eql(u8, class_name, "String")) {
        try imp_builder.writeLine(0, "const String = godot.core.String;");
    }

    if (!std.mem.eql(u8, class_name, "StringName")) {
        try imp_builder.writeLine(0, "const StringName = godot.core.StringName;");
    }

    for (ctx.depends.items) |d| {
        if (std.mem.eql(u8, d, class_name)) continue;
        if (imported_class_map.contains(d)) continue;
        if (util.isBuiltinType(d)) continue;
        try imported_class_map.putNoClobber(ctx.allocator, d, true);
        if (std.mem.startsWith(u8, d, "Vector")) {
            try imp_builder.printLine(0, "const {0s} = godot.{0s};", .{d});
        } else if (std.mem.eql(u8, d, "Variant")) {
            try imp_builder.printLine(0, "const {0s} = godot.{0s};", .{d});
        } else if (std.mem.eql(u8, d, "global")) {
            try imp_builder.printLine(0, "const {0s} = godot.{0s};", .{d});
        } else {
            try imp_builder.printLine(0, "const {0s} = godot.core.{0s};", .{d});
        }
    }

    try imp_builder.write(0, b.getWritten());
    return ctx.allocator.dupe(u8, imp_builder.getWritten());
}

fn generateUtilityFunctions(ctx: *Context) !void {
    var b = StreamBuilder.init(ctx.allocator);
    defer b.deinit();

    ctx.depends.clearRetainingCapacity();

    for (ctx.api.utility_functions) |function| {
        const return_type = ctx.correctType(function.return_type, "");
        try generateProc(&b, function, "", function.name, return_type, .UtilityFunction, ctx);
    }

    const code = try generateImports(&b, "", ctx);
    defer ctx.allocator.free(code);

    try ctx.config.output.writeFile(.{ .sub_path = "util.zig", .data = code });
}

pub const ProcType = enum {
    UtilityFunction,
    BuiltinMethod,
    ClassMethod,
    Constructor,
    Destructor,
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const StringHashMap = std.StringHashMapUnmanaged;

const case = @import("case");
const gdextension = @import("gdextension");

const Context = @import("Context.zig");
const GodotApi = @import("GodotApi.zig");
const packed_array = @import("packed_array.zig");
const StreamBuilder = @import("stream_builder.zig").DefaultStreamBuilder;
const Config = @import("Config.zig");
const util = @import("util.zig");
