const std = @import("std");

const string = []const u8;
const int = i64;

pub const Header = struct {
    version_major: int,
    version_minor: int,
    version_patch: int,
    version_status: string,
    version_build: string,
    version_full_name: string,
};

pub const SizeInfo = struct {
    name: string,
    size: int,
};

pub const BuiltinClassSize = struct {
    build_configuration: string,
    sizes: []SizeInfo,
};

pub const MemberOffset = struct {
    member: string,
    offset: int,
    meta: string,
};

pub const ClassMemberOffsets = struct {
    name: string,
    members: []MemberOffset,
};

pub const BuiltinClassMemberOffset = struct {
    build_configuration: string,
    classes: []ClassMemberOffsets,
};

pub const GlobalEnum = struct {
    name: string,
    is_bitfield: bool,
    values: []Value,

    pub const Value = struct {
        name: string,
        value: int,
        description: ?[]const u8 = null,
    };
};

pub const GlobalConstant = struct {
    name: string,
    value: string,
};

pub const UtilityFunction = struct {
    name: string,
    return_type: string = "",
    category: string,
    is_vararg: bool,
    hash: u64,
    arguments: ?[]Argument = null,
    description: ?[]const u8 = null,

    pub const Argument = struct {
        name: string,
        type: string,
    };
};

pub const Builtin = struct {
    name: string,
    indexing_return_type: string = "",
    is_keyed: bool,
    members: ?[]Member = null,
    constants: ?[]Constant = null,
    enums: ?[]Enum = null,
    operators: []Operator,
    methods: ?[]Method = null,
    constructors: []Constructor,
    has_destructor: bool,
    brief_description: ?[]const u8 = null,
    description: ?[]const u8 = null,

    pub const Constructor = struct {
        index: int,
        arguments: ?[]Argument = null,
        description: ?[]const u8 = null,

        pub const Argument = struct {
            name: string,
            type: string,
        };
    };

    pub const Method = struct {
        name: string,
        return_type: string = "void",
        is_vararg: bool,
        is_const: bool,
        is_static: bool,
        hash: u64,
        arguments: ?[]Argument = null,
        description: ?[]const u8 = null,

        pub fn isPrivate(self: Method) bool {
            return std.mem.startsWith(u8, self.name, "_");
        }

        pub fn isPublic(self: Method) bool {
            return !self.isPrivate();
        }

        pub const Argument = struct {
            name: string,
            type: string,
            default_value: string = "",
        };
    };

    pub const Operator = struct {
        name: string,
        right_type: string = "",
        return_type: string,
        description: ?[]const u8 = null,
    };

    pub const Enum = struct {
        name: string,
        values: []Value,

        pub const Value = struct {
            name: string,
            value: int,
            description: ?[]const u8 = null,
        };
    };

    pub const Constant = struct {
        name: string,
        type: string,
        value: string,
    };

    pub const Member = struct {
        name: string,
        type: string,
        description: ?[]const u8 = null,
    };
};

pub const Signal = struct {
    name: string,
    arguments: ?[]Argument = null,

    pub const Argument = struct {
        name: string,
        type: string,
    };
};

pub const Class = struct {
    name: string,
    is_refcounted: bool,
    is_instantiable: bool,
    inherits: string = "",
    api_type: string,
    constants: ?[]Constant = null,
    enums: ?[]Enum = null,
    methods: ?[]Method = null,
    signals: ?[]Signal = null,
    properties: ?[]Property = null,
    brief_description: ?[]const u8,
    description: ?[]const u8,

    pub fn findMethod(self: Class, name: []const u8) ?Method {
        if (self.methods) |methods| {
            for (methods) |method| {
                if (std.mem.eql(u8, method.name, name)) {
                    return method;
                }
            }
        }
        return null;
    }

    pub const Property = struct {
        type: string,
        name: string,
        setter: string = "",
        getter: string,
        index: int = -1,
    };

    pub const Constant = struct {
        name: string,
        value: int,
    };

    pub const Enum = struct {
        name: string,
        is_bitfield: bool,
        values: []Value,

        pub const Value = struct {
            name: string,
            value: int,
            description: ?[]const u8 = null,
        };
    };

    pub const Method = struct {
        name: string,
        is_const: bool,
        is_static: bool,
        is_required: bool = false,
        is_vararg: bool,
        is_virtual: bool,
        hash: u64 = 0,
        hash_compatibility: ?[]u64 = null,
        return_value: ?ReturnValue = null,
        arguments: ?[]Argument = null,
        description: ?[]const u8 = null,

        pub fn isPrivate(self: Method) bool {
            return std.mem.startsWith(u8, self.name, "_");
        }

        pub fn isPublic(self: Method) bool {
            return !self.isPrivate();
        }

        pub const Argument = struct {
            name: string,
            type: string,
            meta: string = "",
            default_value: string = "",
        };

        pub const ReturnValue = struct {
            type: string,
            meta: string = "",
            default_value: string = "",
        };
    };
};

pub const Singleton = struct {
    name: string,
    type: string,
};

pub const NativeStructure = struct {
    name: string,
    format: string,
};

header: Header,
builtin_class_sizes: []BuiltinClassSize,
builtin_class_member_offsets: []BuiltinClassMemberOffset,
global_constants: []GlobalConstant,
global_enums: []GlobalEnum,
utility_functions: []UtilityFunction,
builtin_classes: []Builtin,
classes: []Class,
singletons: []Singleton,
native_structures: []NativeStructure,

pub fn findClass(self: @This(), name: []const u8) ?Class {
    for (self.classes) |class| {
        if (std.mem.eql(u8, class.name, name)) {
            return class;
        }
    }

    return null;
}

pub fn findBuiltinClass(self: @This(), name: []const u8) ?Builtin {
    for (self.builtin_classes) |class| {
        if (std.mem.eql(u8, class.name, name)) {
            return class;
        }
    }

    return null;
}

pub const GdClassType = enum {
    class,
    builtinClass,
};

pub const GdMethodType = enum {
    class,
    builtinClass,
};

pub const GdMethod = union(GdMethodType) {
    class: Class.Method,
    builtinClass: Builtin.Method,
};

pub const GdClass = union(GdClassType) {
    class: Class,
    builtinClass: Builtin,

    pub fn getClassName(self: @This()) []const u8 {
        switch (self) {
            inline else => |class| return class.name,
        }
    }
};

pub fn findInherits(self: @This(), allocator: std.mem.Allocator, class: Class) !std.ArrayListUnmanaged(GdClass) {
    var inherits: std.ArrayListUnmanaged(GdClass) = .empty;
    try self.findInheritsRecursive(allocator, class, &inherits);
    return inherits;
}

fn findInheritsRecursive(self: @This(), allocator: std.mem.Allocator, class: Class, inherits: *std.ArrayListUnmanaged(GdClass)) !void {
    if (class.inherits.len == 0) {
        return;
    }

    if (self.findClass(class.inherits)) |parent| {
        try inherits.append(allocator, .{ .class = parent });
        try self.findInheritsRecursive(allocator, parent, inherits);
    }

    if (self.findBuiltinClass(class.inherits)) |parent| {
        try inherits.append(allocator, .{ .builtinClass = parent });
    }
}
