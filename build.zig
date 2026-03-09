const std = @import("std");
const ziglint = @import("ziglint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigdoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Generate README.md as part of the default build
    const readme_run = b.addRunArtifact(exe);
    readme_run.addArg("--help");
    const help_output = readme_run.captureStdOut();

    const gen_readme = b.addExecutable(.{
        .name = "gen_readme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_readme.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run_gen = b.addRunArtifact(gen_readme);
    run_gen.addFileArg(help_output);
    const readme_file = run_gen.addOutputFileArg("README.md");

    const install_readme = b.addInstallFile(readme_file, "../README.md");
    b.getInstallStep().dependOn(&install_readme.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon", "build_readme.zig" },
        .check = true,
    });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);

    const lint_step = b.step("lint", "Run ziglint");
    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    lint_step.dependOn(ziglint.addLint(
        b,
        ziglint_dep,
        &.{ b.path("src"), b.path("build.zig"), b.path("build_readme.zig") },
    ));
    test_step.dependOn(lint_step);
}
