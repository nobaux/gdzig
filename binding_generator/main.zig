const std = @import("std");
const enums = @import("enums.zig");
const codegen = @import("codegen.zig");

const GdExtensionApi = @import("extension_api.zig");
const StreamBuilder = @import("stream_builder.zig").DefaultStreamBuilder;
const Mode = enums.Mode;

var outpath: []const u8 = undefined;
var mode: Mode = .quiet;
var cwd: std.fs.Dir = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len < 5) {
        std.debug.print("Usage: binding_generator export_path generated_path precision arch verbose\n", .{});
        return;
    }

    outpath = args[2];
    mode = std.meta.stringToEnum(Mode, args[5]) orelse mode;

    cwd = std.fs.cwd();

    const gdextension_h_path = try std.fs.path.resolve(allocator, &.{ args[1], "gdextension_interface.h" });
    const extension_api_json_path = try std.fs.path.resolve(allocator, &.{ args[1], "extension_api.json" });

    const contents = try cwd.readFileAlloc(allocator, extension_api_json_path, 10 * 1024 * 1024); //"./src/api/extension_api.json", 10 * 1024 * 1024);

    const api = try std.json.parseFromSlice(GdExtensionApi, allocator, contents, .{ .ignore_unknown_fields = false });
    const gdapi = api.value;

    try cwd.deleteTree(outpath);
    try cwd.makePath(outpath);

    var temp_buf = try StreamBuilder.init(allocator);
    defer temp_buf.deinit();
    const conf = try temp_buf.bufPrint("{s}_{s}", .{ args[3], args[4] });

    try codegen.generate(allocator, gdapi, .{
        .conf = conf,
        .gdextension_h_path = gdextension_h_path,
        .mode = mode,
        .output = outpath,
    });

    if (mode == .verbose) {
        std.debug.print("Output path: {s}\n", .{outpath});
        std.debug.print("API JSON: {s}\n", .{extension_api_json_path});
    }
}
