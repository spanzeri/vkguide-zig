const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vkguide-zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vk_lib_name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";

    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary(vk_lib_name);
    exe.addLibraryPath(.{ .cwd_relative = "thirdparty/sdl3/lib" });
    exe.addIncludePath(.{ .cwd_relative = "thirdparty/sdl3/include" });
    const env_map = try std.process.getEnvMap(b.allocator);
    if (env_map.get("VK_SDK_PATH")) |path| {
        exe.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{ path }) catch @panic("OOM") });
        exe.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{ path }) catch @panic("OOM") });
    }
    exe.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp"), .flags = &.{ "" } });
    exe.addIncludePath(b.path("thirdparty/vma/"));
    exe.addIncludePath(b.path("thirdparty/stb/"));
    exe.addIncludePath(b.path("thirdparty/imgui/"));
    exe.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{ "" } });

    exe.linkLibCpp();

    compile_all_shaders(b, exe);

    b.installArtifact(exe);
    if (target.result.os.tag == .windows) {
        b.installBinFile("thirdparty/sdl3/lib/SDL3.dll", "SDL3.dll");
    } else {
        b.installBinFile("thirdparty/sdl3/lib/libSDL3.so", "libSDL3.so.0");
        exe.root_module.addRPathSpecial("$ORIGIN");
    }

    // Imgui (with cimgui and vulkan + sdl3 backends)
    const imgui_lib = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    imgui_lib.addIncludePath(b.path("thirdparty/imgui/"));
    imgui_lib.addIncludePath(b.path("thirdparty/sdl3/include/"));
    imgui_lib.linkLibCpp();
    imgui_lib.addCSourceFiles(.{
        .files = &.{
            "thirdparty/imgui/imgui.cpp",
            "thirdparty/imgui/imgui_demo.cpp",
            "thirdparty/imgui/imgui_draw.cpp",
            "thirdparty/imgui/imgui_tables.cpp",
            "thirdparty/imgui/imgui_widgets.cpp",
            "thirdparty/imgui/imgui_impl_sdl3.cpp",
            "thirdparty/imgui/imgui_impl_vulkan.cpp",
            "thirdparty/imgui/cimgui.cpp",
            "thirdparty/imgui/cimgui_impl_sdl3.cpp",
            "thirdparty/imgui/cimgui_impl_vulkan.cpp",
        },
    });
    exe.linkLibrary(imgui_lib);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn compile_all_shaders(b: *std.Build, exe: *std.Build.Step.Compile) void {
    // This is a fix for a change between zig 0.11 and 0.12

    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir("shaders", .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0..basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                add_shader(b, exe, name);
            }
        }
    }
}

fn add_shader(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{ "glslangValidator" });
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    exe.root_module.addAnonymousImport(name, .{ .root_source_file = output });
}
