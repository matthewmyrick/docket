const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ical-calendar-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    // Test fixtures live outside src/, so @embedFile reaches them as imports.
    exe.root_module.addAnonymousImport("ical-list-sample.json", .{
        .root_source_file = b.path("testdata/ical-list-sample.json"),
    });
    exe.root_module.addAnonymousImport("ical-calendars-sample.json", .{
        .root_source_file = b.path("testdata/ical-calendars-sample.json"),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the TUI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests (leak-checked)");
    test_step.dependOn(&run_exe_tests.step);
}
