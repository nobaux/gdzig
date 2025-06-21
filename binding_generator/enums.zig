pub const ProcType = enum {
    UtilityFunction,
    BuiltinClassMethod,
    EngineClassMethod,
    Constructor,
    Destructor,
};

pub const Mode = enum {
    quiet,
    verbose,
};
