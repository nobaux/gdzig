pub fn PackedArray(T: type) type {
    return struct {
        pub const Slice = []const T;
    };
}
