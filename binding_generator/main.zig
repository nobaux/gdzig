var outpath: []const u8 = undefined;
var mode: Mode = .quiet;
var cwd: std.fs.Dir = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: binding_generator export_path generated_path precision arch verbose\n", .{});
        return;
    }

    outpath = args[2];
    mode = std.meta.stringToEnum(Mode, args[5]) orelse mode;

    cwd = std.fs.cwd();

    const gdextension_h_path = try std.fs.path.resolve(allocator, &.{ args[1], "gdextension_interface.h" });
    const extension_api_json_path = try std.fs.path.resolve(allocator, &.{ args[1], "extension_api.json" });

    const extension_api_json_file = try cwd.openFile(extension_api_json_path, .{});
    defer extension_api_json_file.close();

    var parser = zimdjson.ondemand.FullParser(.default).init;
    defer parser.deinit(allocator);

    var document = try parser.parseFromReader(allocator, extension_api_json_file.reader().any());

    const gdapi = try document.asLeaky(GodotApi, allocator, .{});

    try cwd.deleteTree(outpath);
    try cwd.makePath(outpath);

    const conf = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ args[3], args[4] });
    defer allocator.free(conf);

    const config = CodegenConfig{
        .conf = conf,
        .gdextension_h_path = gdextension_h_path,
        .mode = mode,
        .output = outpath,
    };

    var ctx = try Context.build(allocator, gdapi, config);

    try codegen.generate(&ctx);

    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "fmt", outpath },
        .max_output_bytes = 1024 * 1024,
    });

    if (mode == .verbose) {
        std.debug.print("Output path: {s}\n", .{outpath});
        std.debug.print("API JSON: {s}\n", .{extension_api_json_path});
    }
}

const std = @import("std");

const zimdjson = @import("zimdjson");

const codegen = @import("codegen.zig");
const CodegenConfig = @import("types.zig").CodegenConfig;
const Context = @import("Context.zig");
const enums = @import("enums.zig");
const Mode = enums.Mode;
const GodotApi = @import("GodotApi.zig");
