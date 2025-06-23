pub const ProcType = enum {
    UtilityFunction,
    BuiltinMethod,
    ClassMethod,
    Constructor,
    Destructor,
};

pub const Mode = enum {
    quiet,
    verbose,
};
