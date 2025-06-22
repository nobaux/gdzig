const std = @import("std");
const godot = @import("root.zig");

pub const GodotMethodBind = struct {
    name: []const u8,
    hash: u64,
};

pub inline fn bindMethod(
    comptime Method: type,
    comptime func_name: []const u8,
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
        var string_name = godot.StringName.initFromLatin1Chars(@ptrCast(func_name));
        defer string_name.deinit();

        Binding.method = S.init(string_name);
    }

    return Binding.method.?;
}

pub inline fn bindMethodUtilityFunction(comptime Method: type, comptime name: []const u8, comptime hash: comptime_int) Method {
    const S = struct {
        fn init(string_name: godot.StringName) Method {
            return godot.variantGetPtrUtilityFunction(@ptrCast(@constCast(&string_name)), hash);
        }
    };

    return bindMethod(Method, name, S);
}

pub inline fn bindEngineClassMethod(comptime Method: type, comptime ClassType: type, comptime name: []const u8, hash: comptime_int) Method {
    const S = struct {
        pub fn init(string_name: godot.StringName) Method {
            const class_name = godot.getClassName(ClassType);
            return godot.classdbGetMethodBind(@ptrCast(class_name), @ptrCast(@constCast(&string_name)), hash);
        }
    };

    return bindMethod(Method, name, S);
}
