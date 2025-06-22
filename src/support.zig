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
        var string_name: ?godot.StringName = null;

        if (func_name) |fn_name| {
            string_name = godot.StringName.initFromLatin1Chars(@ptrCast(fn_name));
        }

        Binding.method = S.init(string_name);

        if (string_name) |*sn| {
            sn.deinit();
        }
    }

    return Binding.method.?;
}

pub inline fn bindMethodUtilityFunction(comptime name: []const u8, comptime hash: comptime_int) godot.GDExtensionPtrUtilityFunction {
    const S = struct {
        fn init(string_name: ?godot.StringName) godot.GDExtensionPtrUtilityFunction {
            return godot.variantGetPtrUtilityFunction(@ptrCast(@constCast(&string_name.?)), hash);
        }
    };

    return bindMethod(godot.GDExtensionPtrUtilityFunction, name, S);
}

pub inline fn bindEngineClassMethod(comptime ClassType: type, comptime name: []const u8, hash: comptime_int) godot.GDExtensionMethodBindPtr {
    const S = struct {
        pub fn init(string_name: ?godot.StringName) godot.GDExtensionMethodBindPtr {
            const class_name = godot.getClassName(ClassType);
            return godot.classdbGetMethodBind(@ptrCast(class_name), @ptrCast(@constCast(&string_name.?)), hash);
        }
    };

    return bindMethod(godot.GDExtensionMethodBindPtr, name, S);
}

const ConstructorMethod = @typeInfo(godot.GDExtensionPtrConstructor).optional.child;

pub inline fn bindConstructorMethod(variant_type: comptime_int, index: comptime_int) ConstructorMethod {
    const S = struct {
        fn init(_: ?godot.StringName) ConstructorMethod {
            return godot.variantGetPtrConstructor(variant_type, index).?;
        }
    };

    return bindMethod(ConstructorMethod, null, S);
}

const BuiltInClassMethod = @typeInfo(godot.GDExtensionPtrBuiltInMethod).optional.child;

pub inline fn bindBuiltinClassMethod(variant_type: ?comptime_int, comptime name: []const u8, hash: comptime_int) BuiltInClassMethod {
    const S = struct {
        fn init(string_name: ?godot.StringName) BuiltInClassMethod {
            if (variant_type) |vt| {
                return godot.variantGetPtrBuiltinMethod(vt, @ptrCast(&string_name.?.value), hash).?;
            } else {
                return godot.variantGetPtrBuiltinMethod(null, @ptrCast(&string_name.?.value), hash).?;
            }
        }
    };

    return bindMethod(BuiltInClassMethod, name, S);
}

const DestructorMethod = @typeInfo(godot.GDExtensionPtrDestructor).optional.child;

pub inline fn bindDestructorMethod(variant_type: comptime_int) DestructorMethod {
    const S = struct {
        pub fn init(_: ?godot.StringName) DestructorMethod {
            return godot.variantGetPtrDestructor(variant_type).?;
        }
    };

    return bindMethod(DestructorMethod, null, S);
}
