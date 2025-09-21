pub fn generate(ctx: *Context) !void {
    try writeBuiltins(ctx);
    try writeClasses(ctx);
    try writeGlobals(ctx);
    try writeInterface(ctx);
    try writeModules(ctx);
}

fn writeBuiltins(ctx: *const Context) !void {
    // builtin.zig
    {
        const file = try ctx.config.output.createFile("builtin.zig", .{});
        defer file.close();

        var buf = file.writer();
        var w = CodeWriter.init(buf.interface);

        // Variant is a special case, since it is not a generated file.
        try w.writeLine(
            \\pub const Variant = @import("builtin/variant.zig").Variant;
            \\
        );
        for (ctx.builtins.values()) |builtin| {
            try w.printLine(
                \\pub const {1s} = @import("builtin/{0s}.zig").{1s};
            , .{ builtin.module, builtin.name });
        }

        try buf.flush();
    }

    // builtin/[name].zig
    try ctx.config.output.makePath("builtin");
    for (ctx.builtins.values()) |*builtin| {
        const filename = try std.fmt.allocPrint(ctx.arena.allocator(), "builtin/{s}.zig", .{builtin.module});
        const file = try ctx.config.output.createFile(filename, .{});
        defer file.close();

        var buf = file.writer();
        var writer = CodeWriter.init(buf.interface);

        try writeBuiltin(&writer, builtin, ctx);

        try buf.flush();
    }
}

fn writeBuiltin(w: *CodeWriter, builtin: *const Context.Builtin, ctx: *const Context) !void {
    try writeDocBlock(w, builtin.doc);

    // Declaration start
    try w.printLine(
        \\pub const {0s} = extern struct {{
    , .{builtin.name});
    w.indent += 1;

    // Memory layout assertions
    try w.printLine(
        \\comptime {{
        \\    if (@sizeOf({0s}) != {1d}) @compileError("expected {0s} to be {1d} bytes");
    , .{ builtin.name, builtin.size });
    w.indent += 1;
    for (builtin.fields.values()) |*field| {
        if (field.offset) |offset| {
            try w.printLine(
                \\if (@offsetOf({1s}, "{0s}") != {2d}) @compileError("expected the offset of '{0s}' on '{1s}' to be {2d}");
            , .{ field.name, builtin.name, offset });
        }
    }
    w.indent -= 1;
    try w.writeLine(
        \\}
        \\
    );

    // Fields
    if (builtin.fields.count() == 0) {
        try w.printLine(
            \\/// {0s} is an opaque data structure; these bytes are not meant to be accessed directly.
            \\_: [{1d}]u8,
            \\
        , .{ builtin.name, builtin.size });
    } else if (builtin.fields.count() > 0) {
        for (builtin.fields.values()) |*field| {
            if (field.offset != null) {
                try writeField(w, field);
            }
        }
    }

    // Constants
    for (builtin.constants.values()) |*constant| {
        try writeConstant(w, constant);
    }
    if (builtin.constants.count() > 0) {
        try w.writeLine("");
    }

    // Constructors
    for (builtin.constructors.items) |*constructor| {
        try writeBuiltinConstructor(w, builtin.name, constructor);
        try w.writeLine("");
    }

    // Destructor
    if (builtin.has_destructor) {
        try writeBuiltinDestructor(w, builtin);
        try w.writeLine("");
    }

    // Methods
    for (builtin.methods.values()) |*method| {
        try writeBuiltinMethod(w, builtin.name, method);
        try w.writeLine("");
    }

    // Operators
    for (builtin.operators.items) |*operator| {
        try writeBuiltinOperator(w, builtin.name, operator);
        try w.writeLine("");
    }

    // Enums
    for (builtin.enums.values()) |*@"enum"| {
        try writeEnum(w, @"enum", ctx);
        try w.writeLine("");
    }

    // Helpers
    try w.printLine(
        \\/// Returns an opaque pointer to the {0s}.
        \\pub fn ptr(self: *{0s}) *anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
        \\/// Returns a constant opaque pointer to the {0s}.
        \\pub fn constPtr(self: *const {0s}) *const anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
    , .{builtin.name});

    // Mixin
    try writeMixin(w, "builtin/{s}.mixin.zig", .{builtin.name}, ctx);

    // Declaration end
    w.indent -= 1;
    try w.writeLine("};");

    // Imports
    try w.writeAll(
        \\const oopz = @import("oopz");
        \\
    );
    try writeImports(w, "..", &builtin.imports, ctx);
}

fn writeBuiltinConstructor(w: *CodeWriter, builtin_name: []const u8, constructor: *const Context.Function) !void {
    try writeFunctionHeader(w, constructor);
    if (constructor.can_init_directly) {
        for (constructor.parameters.values()) |param| {
            try w.printLine(
                \\result.{0s} = blk: {{
                \\    switch (@typeInfo(@TypeOf({1s}))) {{
                \\        .int => break :blk @intCast({1s}),
                \\        .float => break :blk @floatCast({1s}),
                \\        else => break :blk {1s},
                \\    }}
                \\}};
            , .{ param.field_name.?, param.name });
        }
    } else {
        try w.printLine(
            \\if ({0s}_ptr == null) {{
            \\    {0s}_ptr = raw.variantGetPtrConstructor(@intFromEnum(Variant.Tag.forType({2s})), {1d});
            \\}}
            \\{0s}_ptr.?(@ptrCast(&result), @ptrCast(&args));
        , .{
            constructor.name,
            constructor.index.?,
            builtin_name,
        });
    }
    try writeFunctionFooter(w, constructor);
    if (!constructor.can_init_directly) {
        try w.printLine(
            \\var {0s}_ptr: c.GDExtensionPtrConstructor = null;
        , .{constructor.name});
    }
}

fn writeBuiltinDestructor(w: *CodeWriter, builtin: *const Context.Builtin) !void {
    try w.printLine(
        \\pub fn deinit(self: *{0s}) void {{
        \\    if (deinit_ptr == null) {{
        \\        deinit_ptr = raw.variantGetPtrDestructor(@intFromEnum(Variant.Tag.forType({0s}))).?;
        \\    }}
        \\    deinit_ptr.?(@ptrCast(self));
        \\}}
        \\var deinit_ptr: c.GDExtensionPtrDestructor = null;
        \\
    , .{
        builtin.name,
    });
}

fn writeBuiltinMethod(w: *CodeWriter, builtin_name: []const u8, method: *const Context.Function) !void {
    try writeFunctionHeader(w, method);
    try w.printLine(
        \\if ({0s}_ptr == null) {{
        \\    {0s}_ptr = raw.variantGetPtrBuiltinMethod(@intFromEnum(Variant.Tag.forType({3s})), @ptrCast(&StringName.fromComptimeLatin1("{1s}")), {2d}).?;
        \\}}
        \\{0s}_ptr.?({4s}, @ptrCast(&args), @ptrCast(&result), args.len);
    , .{
        method.name,
        method.name_api,
        method.hash.?,
        builtin_name,
        switch (method.self) {
            .static => "null",
            .singleton => @panic("singleton builtins not supported"),
            .constant => "@ptrCast(@constCast(self))",
            .mutable => "@ptrCast(self)",
            .value => "@ptrCast(@constCast(&self))",
        },
    });
    try writeFunctionFooter(w, method);
    try w.printLine(
        \\var {0s}_ptr: c.GDExtensionPtrBuiltInMethod = null;
    , .{method.name});
}

fn writeBuiltinOperator(w: *CodeWriter, builtin_name: []const u8, operator: *const Context.Function) !void {
    try writeFunctionHeader(w, operator);

    // Lookup the method
    try w.print(
        \\if ({0s}_ptr == null) {{
        \\    {0s}_ptr = raw.variantGetPtrOperatorEvaluator(@intFromEnum(Variant.Operator.{1s}), @intFromEnum(Variant.Tag.forType({2s})),
    , .{ operator.name, operator.operator_name.?, builtin_name });
    w.indent += 1;
    if (operator.parameters.getPtr("rhs")) |rhs| {
        try w.writeAll(" @intFromEnum(Variant.Tag.forType(");
        try writeTypeAtField(w, &rhs.type);
        try w.writeAll("))");
    } else {
        try w.writeAll(" null");
    }
    w.indent -= 1;
    try w.writeLine(
        \\);
        \\}
    );

    // Call the method
    try w.print("{0s}_ptr.?(", .{operator.name});
    w.indent += 1;
    try w.writeAll("@ptrCast(self), ");
    if (operator.parameters.getPtr("rhs")) |_| {
        try w.writeAll("@ptrCast(&rhs), ");
    } else {
        try w.writeAll("null, ");
    }
    try w.writeAll("@ptrCast(&result)");
    w.indent -= 1;
    try w.writeLine(");");

    try writeFunctionFooter(w, operator);
    try w.printLine(
        \\var {0s}_ptr: c.GDExtensionPtrOperatorEvaluator = null;
    , .{operator.name});
}

fn writeClasses(ctx: *const Context) !void {
    // class.zig
    {
        const file = try ctx.config.output.createFile("class.zig", .{});
        defer file.close();

        var buf = file.writer();
        var w = CodeWriter.init(buf.interface);

        for (ctx.classes.values()) |class| {
            try w.printLine(
                \\pub const {1s} = @import("class/{0s}.zig").{1s};
            , .{ class.module, class.name });
        }

        try buf.flush();
    }

    // class/[name].zig
    try ctx.config.output.makePath("class");
    for (ctx.classes.values()) |*class| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "class/{s}.zig", .{class.module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(filename, .{});
        defer file.close();

        var buf = file.writer();
        var writer = CodeWriter.init(buf.interface);

        try writeClass(&writer, class, ctx);

        try buf.flush();
    }
}

fn writeClass(w: *CodeWriter, class: *const Context.Class, ctx: *const Context) !void {
    try writeDocBlock(w, class.doc);

    // Declaration start
    try w.printLine(
        \\pub const {0s} = opaque {{
    , .{class.name});
    w.indent += 1;

    // Base class
    if (class.base) |base| {
        try w.printLine(
            \\pub const Base = {0s};
            \\
        , .{base});
    } else {
        try w.writeLine(
            \\pub const Base = void;
            \\
        );
    }

    // Singleton storage
    if (class.is_singleton) {
        try w.printLine(
            \\pub var instance: ?*{0s} = null;
        , .{class.name});
    }

    // Constants
    for (class.constants.values()) |*constant| {
        try writeConstant(w, constant);
    }
    if (class.constants.count() > 0) {
        try w.writeLine("");
    }

    // Signals
    for (class.signals.values()) |*signal| {
        try writeSignal(w, signal);
        try w.writeLine("");
    }

    // Constructor
    if (class.is_instantiable) {
        if (class.base) |_| {
            try w.printLine(
                \\/// Allocates an empty {0s}.
                \\pub fn init() *{0s} {{
                \\    return @ptrCast(raw.classdbConstructObject(@ptrCast(typeName({0s}))).?);
                \\}}
                \\
            , .{class.name});
        } else {
            try w.printLine(
                \\/// Allocates an empty {0s}.
                \\pub fn init() {0s} {{
                \\    return @ptrCast(raw.classdbConstructObject(@ptrCast(typeName({0s}))).?);
                \\}}
                \\
            , .{class.name});
        }
    }

    // Functions
    for (class.functions.values()) |*function| {
        if (function.mode != .final) continue;
        try writeClassFunction(w, class, function, ctx);
        try w.writeLine("");
    }

    // TODO: write properties and signals

    // Properties
    // for (class.properties.values()) |*property| {
    //     try writeClassProperty(w, class.name, property);
    // }

    // Cast helper
    try w.printLine(
        \\/// Upcasts a child type to a `{0s}`.
        \\///
        \\/// This is a zero cost, compile time operation.
        \\pub fn upcast(value: anytype) *{0s} {{
        \\    return oopz.upcast(*{0s}, value);
        \\}}
        \\
        \\/// Downcasts a parent type to a `{0s}`.
        \\///
        \\/// This operation will fail at compile time if {0s} does not inherit from `@TypeOf(value)`. However,
        \\/// since there is no guarantee that `value` is a `{0s}` at runtime, this function has a runtime cost
        \\/// and may return `null`.
        \\pub fn downcast(value: anytype) ?*{0s} {{
        \\    const T = comptime sw: switch (@typeInfo(@TypeOf(value))) {{
        \\        .optional => |info| continue :sw @typeInfo(info.child),
        \\        .pointer => |info| break :sw info.child,
        \\        else => @compileError("downcasted value should be a pointer, found '" ++ @typeName(@TypeOf(value)) ++ "'"),
        \\    }};
        \\    comptime oopz.assertIsA(T, {0s});
        \\    const tag = raw.classdbGetClassTag(@ptrCast(&StringName.fromComptimeLatin1("{1s}")));
        \\    const result = raw.objectCastTo(@ptrCast(value), tag);
        \\    if (result) |p| {{
        \\        if (oopz.isOpaqueClass(T)) {{
        \\            return @ptrCast(@alignCast(p));
        \\        }} else {{
        \\            const object: *anyopaque = raw.objectGetInstanceBinding(p, raw.library, null) orelse return null;
        \\            return @ptrCast(@alignCast(object));
        \\        }}
        \\    }} else {{
        \\        return null;
        \\    }}
        \\}}
        \\
    , .{
        class.name,
        class.name_api,
    });

    // Virtual dispatch
    try writeClassVirtualDispatch(w, class, ctx);
    try w.writeLine("");

    // Enums
    for (class.enums.values()) |*@"enum"| {
        try writeEnum(w, @"enum", ctx);
        try w.writeLine("");
    }

    // Flags
    for (class.flags.values()) |*flag| {
        try writeFlag(w, flag, ctx);
        try w.writeLine("");
    }

    // Helpers
    try w.printLine(
        \\/// Returns an opaque pointer to the {0s}.
        \\pub fn ptr(self: *{0s}) *anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
        \\/// Returns a constant opaque pointer to the {0s}.
        \\pub fn constPtr(self: *const {0s}) *const anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
    , .{class.name});

    // Mixin
    try writeMixin(w, "class/{s}.mixin.zig", .{class.name}, ctx);

    // Declaration end
    w.indent -= 1;
    try w.writeLine("};");

    // Imports
    try w.writeLine(
        \\const oopz = @import("oopz");
        \\const typeName = @import("../gdzig.zig").typeName;
    );
    try writeImports(w, "..", &class.imports, ctx);
}

fn writeSignal(w: *CodeWriter, signal: *const Context.Signal) !void {
    try writeDocBlock(w, signal.doc);
    try w.print("pub const {s} = struct {{", .{signal.struct_name});

    if (signal.parameters.count() > 0) {
        try w.writeLine("");
        var is_first = true;
        for (signal.parameters.values()) |param| {
            if (!is_first) {
                try w.writeAll(", ");
            }
            try w.print("{s}: ", .{param.name});
            try w.writeAll("?");
            try writeTypeAtOptionalParameterField(w, &param.type);
            try w.writeAll(" = null");
            is_first = false;
        }
    }
    try w.writeLine("};");
}

fn writeClassFunction(w: *CodeWriter, class: *const Context.Class, function: *const Context.Function, ctx: *const Context) !void {
    try writeFunctionHeader(w, function);

    if (class.is_singleton) {
        try w.printLine(
            \\if (instance == null) {{
            \\    instance = @ptrCast(raw.globalGetSingleton(@ptrCast(typeName({0s}))).?);
            \\}}
        , .{class.name});
    }

    if (function.is_vararg) {
        try w.writeLine("var err: c.GDExtensionCallError = undefined;");
    }

    try w.printLine(
        \\if ({0s}_ptr == null) {{
        \\    {0s}_ptr = raw.classdbGetMethodBind(@ptrCast(typeName({2s})), @ptrCast(&StringName.fromComptimeLatin1("{1s}")), {3d});
        \\}}
    , .{
        function.name,
        function.name_api,
        function.base.?,
        function.hash.?,
    });

    if (function.is_vararg) {
        try w.print("raw.objectMethodBindCall({0s}_ptr, ", .{function.name});
        try writeClassFunctionObjectPtr(w, class, function, ctx);
        try w.printLine(", @ptrCast(@alignCast(&args[0])), args.len, {s}, &err);", .{
            if (function.return_type != .void)
                "@ptrCast(&result)"
            else
                "null",
        });
    } else {
        try w.print("raw.objectMethodBindPtrcall({0s}_ptr, ", .{function.name});
        try writeClassFunctionObjectPtr(w, class, function, ctx);
        try w.printLine(", @ptrCast(&args), {s});", .{
            if (function.return_type != .void)
                "@ptrCast(&result)"
            else
                "null",
        });
    }

    try writeFunctionFooter(w, function);
    try w.printLine(
        \\var {0s}_ptr: c.GDExtensionMethodBindPtr = null;
    , .{function.name});
}

fn writeClassFunctionObjectPtr(w: *CodeWriter, class: *const Context.Class, function: *const Context.Function, ctx: *const Context) !void {
    if (function.self == .static) {
        try w.writeAll("null");
    } else if (class.getNearestSingleton(ctx)) |singleton| {
        if (class.is_singleton) {
            try w.writeAll("@ptrCast(instance)");
        } else {
            try w.print("@ptrCast({s}.instance)", .{singleton.name});
        }
    } else if (function.self == .constant) {
        try w.writeAll("@ptrCast(@constCast(self))");
    } else {
        try w.writeAll("@ptrCast(self)");
    }
}

fn writeClassVirtualDispatch(w: *CodeWriter, class: *const Context.Class, ctx: *const Context) !void {
    try w.writeLine(
        \\pub fn getVirtualDispatch(comptime T: type, p_userdata: ?*anyopaque, p_name: c.GDExtensionConstStringNamePtr) c.GDExtensionClassCallVirtual {
    );
    w.indent += 1;

    // Inherited virtual/abstract functions
    var cur: ?*const Context.Class = class;
    while (cur) |base| : (cur = base.getBasePtr(ctx)) {
        for (base.functions.values()) |*function| {
            if (function.mode == .final) continue;
            try w.printLine(
                \\if (@hasDecl(T, "{0s}") and @import("std").meta.eql(@as(*StringName, @ptrCast(@constCast(p_name))).*, StringName.fromComptimeLatin1("{1s}"))) {{
                \\    return &struct {{
                \\        fn call(p_instance: c.GDExtensionClassInstancePtr, p_args: [*c]const c.GDExtensionConstTypePtr, p_return: c.GDExtensionTypePtr) callconv(.C) void {{
                \\            const Fn = @TypeOf(T.{0s});
                \\            const info = @typeInfo(Fn).@"fn";
                \\            const method: *Fn = @ptrCast(@constCast(&T.{0s}));
                \\            var args: std.meta.ArgsTuple(Fn) = undefined;
                \\            if (info.params.len > 0) {{
                \\                args[0] = @ptrCast(@alignCast(p_instance));
                \\                inline for (1..info.params.len, 0..) |i, j| {{
                \\                    const Arg = @TypeOf(args[i]);
                \\                    if (comptime oopz.isA(RefCounted, Arg)) {{
                \\                        const obj = raw.refGetObject(p_args[j]);
                \\                        args[i] = @ptrCast(obj.?);
                \\                    }} else if (comptime oopz.isOpaqueClassPtr(Arg)) {{
                \\                        args[i] = @ptrCast(@constCast(p_args[j].?));
                \\                    }} else {{
                \\                        args[i] = @as(*Arg, @ptrCast(@constCast(@alignCast(p_args[j])))).*;
                \\                    }}
                \\                }}
                \\            }}
                \\            if (info.return_type == void or info.return_type == null) {{
                \\                @call(.auto, method, args);
                \\            }} else {{
                \\                @as(*info.return_type.?, @ptrCast(@alignCast(p_return))).* = @call(.auto, method, args);
                \\            }}
                \\        }}
                \\    }}.call;
                \\}}
            , .{ function.name, function.name_api });
        }
    }

    if (class.base) |base| {
        try w.printLine(
            \\return {s}.getVirtualDispatch(T, p_userdata, p_name);
        , .{base});
    } else {
        try w.writeLine(
            \\_ = T;
            \\_ = p_userdata;
            \\_ = p_name;
            \\return null;
        );
    }

    w.indent -= 1;
    try w.writeLine(
        \\}
    );
}

fn writeConstant(w: *CodeWriter, constant: *const Context.Constant) !void {
    try writeDocBlock(w, constant.doc);
    try w.print("pub const {s}: ", .{constant.name});
    try writeTypeAtField(w, &constant.type);
    try w.printLine(" = {s};", .{constant.value});
}

fn writeDocBlock(w: *CodeWriter, docs: ?[]const u8) !void {
    if (docs) |d| {
        w.comment = .doc;
        try w.writeLine(d);
        w.comment = .off;
    }
}

fn writeGlobals(ctx: *const Context) !void {
    // global.zig
    {
        const file = try ctx.config.output.createFile("global.zig", .{});
        defer file.close();

        var buf = file.writer();
        var w = CodeWriter.init(buf.interface);

        for (ctx.enums.values()) |@"enum"| {
            try w.printLine(
                \\pub const {1s} = @import("global/{0s}.zig").{1s};
            , .{ @"enum".module, @"enum".name });
        }

        try w.writeLine("");

        for (ctx.flags.values()) |flag| {
            try w.printLine(
                \\pub const {1s} = @import("global/{0s}.zig").{1s};
            , .{ flag.module, flag.name });
        }

        try buf.flush();
    }

    // global/[name].zig
    try ctx.config.output.makePath("global");
    for (ctx.enums.values()) |*@"enum"| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "global/{s}.zig", .{@"enum".module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(filename, .{});
        defer file.close();

        var buf = file.writer();
        var writer = CodeWriter.init(buf.interface);

        try writeEnum(&writer, @"enum", ctx);

        try buf.flush();
    }

    for (ctx.flags.values()) |*flag| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "global/{s}.zig", .{flag.module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(filename, .{});
        defer file.close();

        var buf = file.writer();
        var writer = CodeWriter.init(buf.interface);

        try writeFlag(&writer, flag, ctx);

        try buf.flush();
    }
}

fn writeEnum(w: *CodeWriter, @"enum": *const Context.Enum, ctx: *const Context) !void {
    try writeDocBlock(w, @"enum".doc);
    try w.printLine("pub const {s} = enum(i32) {{", .{@"enum".name});
    w.indent += 1;
    var values = @"enum".values.valueIterator();
    while (values.next()) |value| {
        try writeDocBlock(w, value.doc);
        try w.printLine("{s} = {d},", .{ value.name, value.value });
    }
    try writeMixin(w, "global/{s}.mixin.zig", .{@"enum".name}, ctx);
    w.indent -= 1;
    try w.writeLine("};");
}

fn writeField(w: *CodeWriter, field: *const Context.Field) !void {
    try writeDocBlock(w, field.doc);
    try w.print("{s}: ", .{field.name});
    try writeTypeAtField(w, &field.type);
    try w.writeLine(
        \\,
        \\
    );
}

fn writeFlag(w: *CodeWriter, flag: *const Context.Flag, ctx: *const Context) !void {
    try writeDocBlock(w, flag.doc);
    try w.printLine("pub const {s} = packed struct({s}) {{", .{
        flag.name, switch (flag.representation) {
            .u32 => "u32",
            .u64 => "u64",
        },
    });
    w.indent += 1;
    for (flag.fields.values()) |field| {
        try writeDocBlock(w, field.doc);
        try w.printLine("{s}: bool = {s},", .{ field.name, if (field.default) "true" else "false" });
    }
    if (flag.padding > 0) {
        try w.printLine("_: u{d} = 0,", .{flag.padding});
    }
    for (flag.consts.values()) |@"const"| {
        try writeDocBlock(w, @"const".doc);
        try w.printLine("pub const {s}: {s} = @bitCast(@as({s}, {d}));", .{ @"const".name, flag.name, switch (flag.representation) {
            .u32 => "u32",
            .u64 => "u64",
        }, @"const".value });
    }
    try writeMixin(w, "global/{s}.mixin.zig", .{flag.module}, ctx);
    w.indent -= 1;
    try w.writeLine("};");
}

fn writeFunctionHeader(w: *CodeWriter, function: *const Context.Function) !void {
    try writeDocBlock(w, function.doc);

    // Declaration
    try w.writeAll("");
    if (std.zig.Token.keywords.has(function.name)) {
        try w.print("pub fn @\"{s}\"(", .{function.name});
    } else {
        try w.print("pub fn {s}(", .{function.name});
    }

    var is_first = true;

    // Self parameter
    switch (function.self) {
        .static, .singleton => {},
        .constant => |self| {
            try w.print("self: *const {0s}", .{self});
            is_first = false;
        },
        .mutable => |self| {
            try w.print("self: *{0s}", .{self});
            is_first = false;
        },
        .value => |self| {
            try w.print("self: {0s}", .{self});
            is_first = false;
        },
    }

    // Positional parameters
    var opt: usize = function.parameters.count();
    for (function.parameters.values(), 0..) |param, i| {
        if (param.default != null) {
            opt = i;
            break;
        }
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.print("{s}: ", .{param.name});
        try writeTypeAtParameter(w, &param.type);
        is_first = false;
    }

    // Variadic parameters
    if (function.is_vararg) {
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.print("@\"...\": anytype", .{});
        is_first = false;
    }

    // Optional parameters
    if (opt < function.parameters.count()) {
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.writeAll("opt: struct { ");
        is_first = true;
        for (function.parameters.values()[opt..]) |param| {
            if (!is_first) {
                try w.writeAll(", ");
            }
            try w.print("{s}: ", .{param.name});
            if (std.mem.eql(u8, "null", param.default.?)) {
                try w.writeAll("?");
            }
            try writeTypeAtOptionalParameterField(w, &param.type);
            try w.print(" = {s}", .{param.default.?});
            is_first = false;
        }
        try w.writeAll(" }");
        is_first = false;
    }

    // Return type
    try w.writeAll(") ");
    try writeTypeAtReturn(w, &function.return_type);
    try w.writeLine(" {");
    w.indent += 1;

    // Parameter comptime type checking
    for (function.parameters.values()) |_| {
        // try generateFunctionParameterTypeCheck(w, param);
    }

    // Fixed argument slice variable
    if (!function.is_vararg and function.operator_name == null and !function.can_init_directly) {
        try w.printLine("var args: [{d}]c.GDExtensionConstTypePtr = undefined;", .{function.parameters.count()});
        for (function.parameters.values()[0..opt], 0..) |param, i| {
            try w.printLine("args[{d}] = @ptrCast(&{s});", .{ i, param.name });
        }
        for (function.parameters.values()[opt..], opt..) |param, i| {
            try w.printLine("args[{d}] = @ptrCast(&opt.{s});", .{ i, param.name });
        }
    }

    // Variadic argument slice variable
    if (function.is_vararg and function.operator_name == null) {
        try w.printLine("var args: [@\"...\".len + {d}]c.GDExtensionConstTypePtr = undefined;", .{function.parameters.count()});
        for (function.parameters.values()[0..opt], 0..) |param, i| {
            try w.printLine("args[{d}] = &Variant.init(&{s});", .{ i, param.name });
        }
        for (function.parameters.values()[opt..], opt..) |param, i| {
            try w.printLine("args[{d}] = &Variant.init(&opt.{s});", .{ i, param.name });
        }
        try w.printLine(
            \\inline for (0..@"...".len) |i| {{
            \\    args[{d} + i] = &Variant.init(@"..."[i]);
            \\}}
        , .{function.parameters.count()});
    }

    // Return variable
    if (function.return_type != .void) {
        if (function.is_vararg) {
            try w.writeLine("var result: Variant = .nil;");
        } else {
            try w.writeAll("var result: ");
            if (function.return_type == .class) {
                try w.writeLine("?*anyopaque = null;");
            } else {
                try writeTypeAtReturn(w, &function.return_type);
                if (function.can_init_directly) {
                    try w.writeLine(" = undefined;");
                } else {
                    try w.printLine(" = {s};", .{function.return_type_initializer orelse "undefined"});
                }
            }
        }
    }
}

fn writeFunctionFooter(w: *CodeWriter, function: *const Context.Function) !void {
    switch (function.return_type) {
        // Class functions need to cast an object pointer
        .class => {
            try w.writeLine(
                \\return @ptrCast(result);
            );
        },

        // Variant return types can always be returned directly, even in a vararg function.
        .variant => {
            try w.writeLine(
                \\return result;
            );
        },

        // Void does nothing.
        .void => {},

        // Vararg and operator functions cast to the return type, fixed arity return directly.
        else => if (function.is_vararg) {
            try w.writeAll("return result.as(");
            try writeTypeAtReturn(w, &function.return_type);
            try w.writeLine(").?;");
        } else {
            try w.writeLine(
                \\return result;
            );
        },
    }

    // End function
    w.indent -= 1;
    try w.writeLine("}");
}

fn writeImports(w: *CodeWriter, root: []const u8, imports: *const Context.Imports, ctx: *const Context) !void {
    try w.printLine(
        \\const std = @import("std");
        \\
        \\const c = @import("gdextension");
        \\
        \\const raw = &@import("{0s}/gdzig.zig").raw;
        \\
    , .{root});

    var iter = imports.iterator();
    while (iter.next()) |import| {
        if (util.isBuiltinType(import.*)) continue;

        if (std.mem.eql(u8, import.*, "Variant")) {
            try w.printLine("const Variant = @import(\"{0s}/builtin/variant.zig\").Variant;", .{root});
        } else if (ctx.builtins.contains(import.*)) {
            try w.printLine("const {1s} = @import(\"{0s}/builtin.zig\").{1s};", .{ root, import.* });
        } else if (ctx.classes.contains(import.*)) {
            try w.printLine("const {1s} = @import(\"{0s}/class.zig\").{1s};", .{ root, import.* });
        } else if (ctx.enums.contains(import.*)) {
            try w.printLine("const {1s} = @import(\"{0s}/global.zig\").{1s};", .{ root, import.* });
        } else if (ctx.flags.contains(import.*)) {
            try w.printLine("const {1s} = @import(\"{0s}/global.zig\").{1s};", .{ root, import.* });
        } else {
            // TODO: native structures?
        }
    }
}

fn writeMixin(w: *CodeWriter, comptime fmt: []const u8, args: anytype, ctx: *const Context) !void {
    const filename = try std.fmt.allocPrint(ctx.arena.allocator(), fmt, args);
    const file: ?std.fs.File = ctx.config.input.openFile(filename, .{}) catch null;
    if (file) |f| {
        defer f.close();
        const reader = f.reader();

        var buf: [1024]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            if (std.mem.startsWith(u8, line, "// @mixin stop")) {
                break;
            }

            try w.writeLine(line);
        }
    }
}

fn writeInterface(ctx: *Context) !void {
    const file = try ctx.config.output.createFile("Interface.zig", .{});
    defer file.close();

    var buf = file.writer();
    var w = CodeWriter.init(buf.interface);

    try w.writeLine(
        \\const Interface = @This();
        \\
    );
    try w.writeLine(
        \\library: Child(c.GDExtensionClassLibraryPtr),
        \\
    );

    for (ctx.interface.functions.items) |function| {
        try writeDocBlock(&w, function.docs);
        try w.printLine(
            \\{s}: Child(c.{s}),
            \\
        , .{ function.name, function.ptr_type });
    }

    try w.writeLine("pub fn init(getProcAddress: Child(c.GDExtensionInterfaceGetProcAddress), library: Child(c.GDExtensionClassLibraryPtr)) Interface {");
    w.indent += 1;

    try w.writeLine(
        \\const self: Interface = .{
        \\    .library = library,
    );
    w.indent += 1;

    for (ctx.interface.functions.items) |function| {
        try w.printLine(
            \\.{s} = @ptrCast(getProcAddress("{s}").?),
        , .{ function.name, function.api_name });
    }

    w.indent -= 1;
    try w.writeLine(
        \\};
        \\
    );

    // TODO: static string map
    // for (ctx.builtins.values()) |builtin| {
    //     try w.printLine(
    //         \\self.stringNameNewWithLatin1Chars(@ptrCast(typeName(builtin.{0s})), @ptrCast("{1s}"), 1);
    //     , .{ builtin.name, builtin.name_api });
    // }
    // for (ctx.classes.values()) |class| {
    //     try w.printLine(
    //         \\self.stringNameNewWithLatin1Chars(@ptrCast(typeName(class.{0s})), @ptrCast("{1s}"), 1);
    //     , .{ class.name, class.name_api });
    // }
    // for (ctx.enums.values()) |@"enum"| {
    //     try w.printLine(
    //         \\self.stringNameNewWithLatin1Chars(@ptrCast(typeName(global.{0s})), @ptrCast("{1s}"), 1);
    //     , .{ @"enum".name, @"enum".name_api });
    // }
    // for (ctx.flags.values()) |flag| {
    //     try w.printLine(
    //         \\self.stringNameNewWithLatin1Chars(@ptrCast(typeName(global.{0s})), @ptrCast("{1s}"), 1);
    //     , .{ flag.name, flag.name_api });
    // }

    w.indent -= 1;
    try w.writeLine(
        \\
        \\    return self;
        \\}
    );

    try w.writeLine(
        \\const std = @import("std");
        \\const Child = std.meta.Child;
        \\
        \\const c = @import("gdextension");
        \\
        \\const builtin = @import("builtin.zig");
        \\const class = @import("class.zig");
        \\const global = @import("global.zig");
        \\const typeName = @import("gdzig.zig").typeName;
    );

    try buf.flush();
    try file.sync();
}

fn writeModules(ctx: *const Context) !void {
    for (ctx.modules.values()) |*module| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "{s}.zig", .{module.name});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(filename, .{});
        defer file.close();

        var buf = file.writer();
        var writer = CodeWriter.init(buf.interface);

        try writeModule(&writer, module, ctx);

        try buf.flush();
    }
}

fn writeModule(w: *CodeWriter, module: *const Context.Module, ctx: *const Context) !void {
    for (module.functions) |*function| {
        try writeModuleFunction(w, function);
    }
    try writeImports(w, ".", &module.imports, ctx);
}

fn writeModuleFunction(w: *CodeWriter, function: *const Context.Function) !void {
    try writeFunctionHeader(w, function);

    try w.printLine(
        \\if ({0s}_ptr == null) {{
        \\    {0s}_ptr = raw.variantGetPtrUtilityFunction(@ptrCast(@constCast(&StringName.fromComptimeLatin1("{1s}"))), {2d});
        \\}}
        \\{0s}_ptr.?({3s}, @ptrCast(&args), args.len);
    , .{
        function.name,
        function.name_api,
        function.hash.?,
        if (function.return_type != .void) "@ptrCast(&result)" else "null",
    });
    try writeFunctionFooter(w, function);
    try w.printLine(
        \\var {0s}_ptr: c.GDExtensionPtrUtilityFunction = null;
        \\
    , .{function.name});
}

fn writeTypeAtField(w: *CodeWriter, @"type": *const Context.Type) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |name| try w.print("*{0s}", .{name}),
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union types in a struct field position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        inline else => |s| try w.writeAll(s),
    }
}

fn writeTypeAtReturn(w: *CodeWriter, @"type": *const Context.Type) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |name| try w.print("?*{0s}", .{name}),
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a return position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        inline else => |s| try w.writeAll(s),
    }
}

/// Writes out a Type for a function parameter. Used to provide `anytype` where we do comptime type
/// checks and coercions.
fn writeTypeAtParameter(w: *CodeWriter, @"type": *const Context.Type) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |name| try w.print("*{0s}", .{name}),
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a function parameter position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        inline else => |s| try w.writeAll(s),
    }
}

/// Writes out a Type for a function parameter. Used to provide `anytype` where we do comptime type
/// checks and coercions.
fn writeTypeAtOptionalParameterField(w: *CodeWriter, @"type": *const Context.Type) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |name| try w.print("*{0s}", .{name}),
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a function parameter position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        inline else => |s| try w.writeAll(s),
    }
}

const std = @import("std");

const CodeWriter = @import("CodeWriter.zig");
const Context = @import("Context.zig");
const util = @import("util.zig");
