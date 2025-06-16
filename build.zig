const std = @import("std");
const path = std.fs.path;

const BINDGEN_INSTALL_RELPATH = "bindgen";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const godot_path = b.option([]const u8, "godot", "Path to Godot engine binary [default: `godot`]") orelse "godot";
    const precision = b.option([]const u8, "precision", "Floating point precision, either `float` or `double` [default: `float`]") orelse "float";
    const arch = b.option([]const u8, "arch", "32") orelse "64";
    const headers = b.option(
        []const u8,
        "headers",
        "Where to source Godot header files. [options: GENERATED, VENDORED, DEPENDENCY, <dir_path>] [default: GENERATED]",
    );

    const headers_source = parseHeadersOption(b, headers);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "precision", precision);
    build_options.addOption([]const u8, "headers", switch (headers_source) {
        .dependency => "DEPENDENCY",
        .vendored => "VENDORED",
        .generated => "GENERATED",
        .custom => headers.?,
    });

    const gdextension = buildGdExtension(b, godot_path, headers_source);

    const binding_generator_step = b.step("binding_generator", "Build the binding_generator program");
    const binding_generator = b.addExecutable(.{
        .name = "binding_generator",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(b.pathJoin(&.{ "binding_generator", "main.zig" })),
        .link_libc = true,
    });
    binding_generator.step.dependOn(gdextension.step);
    binding_generator.addIncludePath(gdextension.iface_headers.dirname());
    binding_generator_step.dependOn(&binding_generator.step);
    b.installArtifact(binding_generator);

    const lib_case = b.dependency("case", .{});
    binding_generator.root_module.addImport("case", lib_case.module("case"));

    const bindgen = build_bindgen(b, gdextension.iface_headers.dirname(), binding_generator, precision, arch);

    const godot_module = b.addModule("godot", .{
        .root_source_file = b.path(b.pathJoin(&.{ "src", "api", "Godot.zig" })),
        .target = target,
        .optimize = optimize,
    });
    godot_module.addOptions("build_options", build_options);
    godot_module.addIncludePath(bindgen.output_path);
    godot_module.addIncludePath(gdextension.iface_headers.dirname());

    const lib_vector = b.dependency("vector_z", .{
        .precision = precision,
    });
    godot_module.addImport("vector", lib_vector.module("vector_z"));

    const godot_core_module = b.addModule("GodotCore", .{
        .root_source_file = bindgen.godot_core_path,
        .target = target,
        .optimize = optimize,
    });
    godot_core_module.addIncludePath(gdextension.iface_headers.dirname());
    godot_core_module.addImport("godot", godot_module);

    godot_module.addImport("GodotCore", godot_core_module);
}

const BindgenOutput = struct {
    step: *std.Build.Step,
    godot_core_path: std.Build.LazyPath,
    output_path: std.Build.LazyPath,
};

/// Build the zig bindings using the binding_generator program,
fn build_bindgen(
    b: *std.Build,
    godot_headers_path: std.Build.LazyPath,
    binding_generator: *std.Build.Step.Compile,
    precision: []const u8,
    arch: []const u8,
) BindgenOutput {
    const bind_step = b.step("bindgen", "Generate godot bindings");
    const run_binding_generator = std.Build.Step.Run.create(b, "run_binding_generator");

    const output_path = makeTempPathRelative(b) catch unreachable;
    defer b.allocator.free(output_path);

    const mode = if (b.verbose) "verbose" else "quiet";

    run_binding_generator.addArtifactArg(binding_generator);
    run_binding_generator.addDirectoryArg(godot_headers_path);
    const output_lazypath = run_binding_generator.addOutputDirectoryArg(output_path);
    run_binding_generator.addArgs(&.{ precision, arch, mode });
    const install_bindgen = b.addInstallDirectory(.{
        .source_dir = output_lazypath,
        .install_dir = .prefix,
        .install_subdir = BINDGEN_INSTALL_RELPATH,
    });
    bind_step.dependOn(&install_bindgen.step);
    return .{
        .step = bind_step,
        .output_path = output_lazypath,
        .godot_core_path = output_lazypath.path(b, "GodotCore.zig"),
    };
}

const GDExtensionOutput = struct {
    step: *std.Build.Step,
    api_json: std.Build.LazyPath,
    iface_headers: std.Build.LazyPath,
};

const HeadersOption = enum {
    dependency,
    vendored,
    generated,
    custom,
};

const HeadersSource = union(HeadersOption) {
    dependency: void,
    vendored: void,
    generated: void,
    custom: std.Build.LazyPath,
};

fn parseHeadersOption(b: *std.Build, headers_option: ?[]const u8) HeadersSource {
    if (headers_option == null or headers_option.?.len == 0) {
        return .generated;
    }

    const headers_option_lower = std.ascii.allocLowerString(b.allocator, headers_option.?) catch @panic("OOM");
    const header_option = std.meta.stringToEnum(HeadersOption, headers_option_lower);

    if (header_option) |opt| switch (opt) {
        .dependency => return .dependency,
        .generated => return .generated,
        .vendored => return .vendored,
        else => {},
    };

    return .{
        .custom = .{
            .cwd_relative = headers_option.?,
        },
    };
}

/// Dump the Godot headers and interface files to the bindgen_path.
fn buildGdExtension(
    b: *std.Build,
    godot_path: []const u8,
    headers_source: HeadersSource,
) GDExtensionOutput {
    const dump_step = b.step("dump", "dump godot headers");
    var iface_headers: std.Build.LazyPath = undefined;
    var api_json: std.Build.LazyPath = undefined;

    switch (headers_source) {
        .dependency => {
            const godot_cpp = b.dependency("godot_cpp", .{});
            const gdextension_interface_h = godot_cpp.builder.path("gdextension/gdextension_interface.h");
            const extension_api_json = godot_cpp.builder.path("gdextension/extension_api.json");
            iface_headers = gdextension_interface_h;
            api_json = extension_api_json;

            gdextension_interface_h.addStepDependencies(dump_step);
            extension_api_json.addStepDependencies(dump_step);
        },
        .generated => {
            const tmpdir = b.makeTempPath();
            const dump_cmd = b.addSystemCommand(&.{
                godot_path, "--dump-extension-api", "--dump-gdextension-interface", "--headless",
            });
            dump_cmd.setCwd(.{ .cwd_relative = tmpdir });
            const output_dir = b.addInstallDirectory(.{
                .source_dir = .{ .cwd_relative = tmpdir },
                .install_dir = .prefix,
                .install_subdir = BINDGEN_INSTALL_RELPATH,
            });
            output_dir.step.dependOn(&dump_cmd.step);
            dump_step.dependOn(&output_dir.step);
            iface_headers = output_dir.options.source_dir.path(b, "gdextension_interface.h");
            api_json = output_dir.options.source_dir.path(b, "extension_api.json");
        },
        .vendored => {
            const vendor_path = b.path("vendor");
            const vendor_json = b.addInstallFile(vendor_path.path(b, "extension_api.json"), "extension_api.json");
            const vendor_h = b.addInstallFile(vendor_path.path(b, "gdextension_interface.h"), "gdextension_interface.h");
            iface_headers = vendor_h.source;
            api_json = vendor_json.source;
            dump_step.dependOn(&vendor_h.step);
            dump_step.dependOn(&vendor_json.step);
        },
        .custom => |custom_path| {
            const custom_json = custom_path.path(b, "extension_api.json");
            const custom_h = custom_path.path(b, "gdextension_interface.h");
            const install_iface_headers = b.addInstallFile(
                custom_json,
                b.pathJoin(&.{ BINDGEN_INSTALL_RELPATH, "extension_api.json" }),
            );
            dump_step.dependOn(&install_iface_headers.step);
            iface_headers = install_iface_headers.source;
            const install_api_json = b.addInstallFile(
                custom_h,
                b.pathJoin(&.{ BINDGEN_INSTALL_RELPATH, "gdextension_interface.h" }),
            );
            dump_step.dependOn(&install_api_json.step);
            api_json = install_api_json.source;
        },
    }

    return GDExtensionOutput{
        .step = dump_step,
        .api_json = api_json,
        .iface_headers = iface_headers,
    };
}

fn makeTempPathRelative(b: *std.Build) ![]const u8 {
    return try path.relative(b.allocator, b.build_root.path.?, b.makeTempPath());
}
