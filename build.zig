const std = @import("std");
const path = std.fs.path;

const BINDGEN_INSTALL_RELPATH = "bindgen";

const DependencyModules = struct {
    modules: std.StringHashMap(*std.Build.Module),
    godot_cpp_dep: *std.Build.Dependency,
};

fn getDependencyModules(b: *std.Build, precision: []const u8) DependencyModules {
    var modules = std.StringHashMap(*std.Build.Module).init(b.allocator);

    const lib_case = b.dependency("case", .{});
    modules.put("case", lib_case.module("case")) catch @panic("Failed to add case module");

    const lib_vector = b.dependency("vector_z", .{
        .precision = precision,
    });
    modules.put("vector_z", lib_vector.module("vector_z")) catch @panic("Failed to add vector_z module");

    const godot_cpp = b.dependency("godot_cpp", .{});

    const mvzr = b.dependency("mvzr", .{});
    modules.put("mvzr", mvzr.module("mvzr")) catch @panic("Failed to add mvzr module");

    return DependencyModules{
        .modules = modules,
        .godot_cpp_dep = godot_cpp,
    };
}

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
    const dep_modules = getDependencyModules(b, precision);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "precision", precision);
    build_options.addOption([]const u8, "headers", switch (headers_source) {
        .dependency => "DEPENDENCY",
        .vendored => "VENDORED",
        .generated => "GENERATED",
        .custom => headers.?,
    });

    const gdextension = buildGdExtension(b, godot_path, headers_source, dep_modules.godot_cpp_dep);

    const gdextension_c = b.addTranslateC(.{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = gdextension.iface_headers,
    });
    gdextension_c.step.dependOn(gdextension.step);

    const gdextension_mod = b.createModule(.{
        .root_source_file = gdextension_c.getOutput(),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const binding_generator = b.addExecutable(.{
        .name = "binding_generator",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("binding_generator/main.zig"),
        .link_libc = true,
    });
    binding_generator.root_module.addImport("gdextension", gdextension_mod);
    b.installArtifact(binding_generator);

    const binding_generator_step = b.step("binding_generator", "Build the binding_generator program");
    binding_generator_step.dependOn(&binding_generator.step);

    binding_generator.root_module.addImport("case", dep_modules.modules.get("case").?);
    binding_generator.root_module.addImport("mvzr", dep_modules.modules.get("mvzr").?);

    const bindgen = buildBindgen(b, gdextension.iface_headers.dirname(), binding_generator, precision, arch);

    const bindgen_fmt = b.addSystemCommand(&.{
        "zig",
        "fmt",
    });
    bindgen_fmt.addDirectoryArg(bindgen.output_path);
    _ = bindgen_fmt.captureStdOut();

    const godot_module = b.addModule("godot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    godot_module.addOptions("build_options", build_options);
    godot_module.addIncludePath(bindgen.output_path);

    godot_module.addImport("vector", dep_modules.modules.get("vector_z").?);

    const godot_core_module = b.addModule("godot_core", .{
        .root_source_file = bindgen.godot_core_path,
        .target = target,
        .optimize = optimize,
    });
    godot_core_module.addImport("godot", godot_module);
    godot_core_module.addImport("gdextension", gdextension_mod);

    godot_module.addImport("godot_core", godot_core_module);

    const lib = b.addSharedLibrary(.{
        .name = "godot",
        .root_module = godot_module,
    });
    lib.step.dependOn(&bindgen_fmt.step);

    b.installArtifact(lib);
}

const BindgenOutput = struct {
    step: *std.Build.Step,
    godot_core_path: std.Build.LazyPath,
    output_path: std.Build.LazyPath,
};

/// Build the zig bindings using the binding_generator program,
fn buildBindgen(
    b: *std.Build,
    godot_headers_path: std.Build.LazyPath,
    binding_generator: *std.Build.Step.Compile,
    precision: []const u8,
    arch: []const u8,
) BindgenOutput {
    const bind_step = b.step("bindgen", "Generate godot bindings");
    const run_binding_generator = std.Build.Step.Run.create(b, "run_binding_generator");
    run_binding_generator.step.dependOn(&binding_generator.step);

    const mode = if (b.verbose) "verbose" else "quiet";

    run_binding_generator.addArtifactArg(binding_generator);
    run_binding_generator.addDirectoryArg(godot_headers_path);
    const output_lazypath = run_binding_generator.addOutputDirectoryArg("bindgen_cache");
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
        .godot_core_path = output_lazypath.path(b, "core.zig"),
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
    godot_cpp_dep: *std.Build.Dependency,
) GDExtensionOutput {
    const dump_step = b.step("dump", "dump godot headers");
    var iface_headers: std.Build.LazyPath = undefined;
    var api_json: std.Build.LazyPath = undefined;

    switch (headers_source) {
        .dependency => {
            const gdextension_interface_h = godot_cpp_dep.builder.path("gdextension/gdextension_interface.h");
            const extension_api_json = godot_cpp_dep.builder.path("gdextension/extension_api.json");
            iface_headers = gdextension_interface_h;
            api_json = extension_api_json;

            gdextension_interface_h.addStepDependencies(dump_step);
            extension_api_json.addStepDependencies(dump_step);
        },
        .generated => {
            const write_files = b.addWriteFiles();
            const tmpdir = write_files.getDirectory();

            const dump_cmd = b.addSystemCommand(&.{
                godot_path,
                "--dump-extension-api",
                "--dump-gdextension-interface",
                "--headless",
            });
            dump_cmd.setCwd(tmpdir);

            _ = dump_cmd.captureStdOut();
            _ = dump_cmd.captureStdErr();

            iface_headers = tmpdir.path(b, "gdextension_interface.h");
            api_json = tmpdir.path(b, "extension_api.json");

            dump_step.dependOn(&dump_cmd.step);
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
