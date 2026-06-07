const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stack_size = b.option(u64, "stack-size", "Executable stack size in bytes") orelse 16 * 1024 * 1024;

    const exe = b.addExecutable(.{
        .name = "Shellowo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.stack_size = stack_size;

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe.root_module.addAnonymousImport("shellowo-zed-font", .{
        .root_source_file = b.path("assets/fonts/zed-mono-extended.ttf"),
    });
    exe.root_module.addAnonymousImport("shellowo-cjk-font", .{
        .root_source_file = b.path("assets/fonts/NotoSansCJKsc-Medium.otf"),
    });
    exe.root_module.addAnonymousImport("shellowo-server-icon", .{
        .root_source_file = b.path("assets/server.png"),
    });
    exe.root_module.addAnonymousImport("shellowo-settings-icon", .{
        .root_source_file = b.path("assets/settings.png"),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tests = b.addTest(.{
        .name = "shellow-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
