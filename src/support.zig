const godot = @import("root.zig");

pub const GodotMethodBind = struct {
    name: []const u8,
    hash: u64,
};

pub inline fn bindMethod(
    comptime Method: type,
    comptime func_name: ?[]const u8,
    comptime S: anytype,
) Method {
    // building all elements into the struct ensures that the binding is generated
    // for every unique type
    const Binding = struct {
        var method_name = func_name;
        var s: S = undefined;
        var method: ?Method = null;
    };

    if (Binding.method == null) {
        var string_name: ?godot.core.StringName = null;

        if (func_name) |fn_name| {
            string_name = godot.core.StringName.initFromLatin1Chars(@ptrCast(fn_name));
        }

        Binding.method = S.init(string_name);

        if (string_name) |*sn| {
            sn.deinit();
        }
    }

    return Binding.method.?;
}

pub inline fn bindMethodUtilityFunction(comptime name: []const u8, comptime hash: comptime_int) godot.c.GDExtensionPtrUtilityFunction {
    const S = struct {
        fn init(string_name: ?godot.core.StringName) godot.c.GDExtensionPtrUtilityFunction {
            return godot.core.variantGetPtrUtilityFunction(@ptrCast(@constCast(&string_name.?)), hash);
        }
    };

    return bindMethod(godot.c.GDExtensionPtrUtilityFunction, name, S);
}

pub inline fn bindEngineClassMethod(comptime ClassType: type, comptime name: []const u8, hash: comptime_int) godot.c.GDExtensionMethodBindPtr {
    const S = struct {
        pub fn init(string_name: ?godot.core.StringName) godot.c.GDExtensionMethodBindPtr {
            const class_name = godot.getClassName(ClassType);
            return godot.core.classdbGetMethodBind(@ptrCast(class_name), @ptrCast(@constCast(&string_name.?)), hash);
        }
    };

    return bindMethod(godot.c.GDExtensionMethodBindPtr, name, S);
}

const ConstructorMethod = @typeInfo(godot.c.GDExtensionPtrConstructor).optional.child;

pub inline fn bindConstructorMethod(variant_type: comptime_int, index: comptime_int) ConstructorMethod {
    const S = struct {
        fn init(_: ?godot.core.StringName) ConstructorMethod {
            return godot.core.variantGetPtrConstructor(variant_type, index).?;
        }
    };

    return bindMethod(ConstructorMethod, null, S);
}

const BuiltInClassMethod = @typeInfo(godot.c.GDExtensionPtrBuiltInMethod).optional.child;

pub inline fn bindBuiltinClassMethod(variant_type: ?comptime_int, comptime name: []const u8, hash: comptime_int) BuiltInClassMethod {
    const S = struct {
        fn init(string_name: ?godot.core.StringName) BuiltInClassMethod {
            if (variant_type) |vt| {
                return godot.core.variantGetPtrBuiltinMethod(vt, @ptrCast(&string_name.?.value), hash).?;
            } else {
                return godot.core.variantGetPtrBuiltinMethod(null, @ptrCast(&string_name.?.value), hash).?;
            }
        }
    };

    return bindMethod(BuiltInClassMethod, name, S);
}

const DestructorMethod = @typeInfo(godot.c.GDExtensionPtrDestructor).optional.child;

pub inline fn bindDestructorMethod(variant_type: comptime_int) DestructorMethod {
    const S = struct {
        pub fn init(_: ?godot.core.StringName) DestructorMethod {
            return godot.core.variantGetPtrDestructor(variant_type).?;
        }
    };

    return bindMethod(DestructorMethod, null, S);
}
