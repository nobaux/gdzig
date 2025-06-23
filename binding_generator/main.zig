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

    // Assemble the bindgen configuration
    var config: Config = blk: {
        const cwd = std.fs.cwd();

        var vendor = try cwd.openDir(args[1], .{});
        defer vendor.close();

        try cwd.deleteTree(args[2]);

        const build_target = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ args[3], args[4] });
        const extension_api = try vendor.openFile("extension_api.json", .{});
        const gdextension_interface = try vendor.openFile("gdextension_interface.h", .{});
        const output = try std.fs.cwd().makeOpenPath(args[2], .{});
        const verbosity = std.meta.stringToEnum(Config.Verbosity, args[5]) orelse .quiet;

        break :blk .{
            .build_target = build_target,
            .extension_api = extension_api,
            .gdextension_interface = gdextension_interface,
            .output = output,
            .verbosity = verbosity,
        };
    };
    defer config.deinit(allocator);

    // Parse the extension_api.json
    var parser = zimdjson.ondemand.FullParser(.default).init;
    defer parser.deinit(allocator);
    var document = try parser.parseFromReader(allocator, config.extension_api.reader().any());
    const godot_api = try document.asLeaky(GodotApi, allocator, .{});

    // Build the codegen context
    var ctx = try Context.build(allocator, godot_api, config);

    // Generate the code
    try codegen.generate(&ctx);

    // Format the code
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .cwd_dir = config.output,
        .argv = &.{ "zig", "fmt" },
        .max_output_bytes = 1024 * 1024,
    });

    if (config.verbosity == .verbose) {
        std.debug.print("Output path: {s}\n", .{args[2]});
        std.debug.print("API JSON: {s}/extension_api.json\n", .{args[1]});
    }
}

const std = @import("std");

const zimdjson = @import("zimdjson");

const codegen = @import("codegen.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const GodotApi = @import("GodotApi.zig");
