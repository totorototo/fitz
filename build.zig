const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // As of Zig ~0.14+, compile steps take a `root_module` built via
    // `b.createModule(...)` rather than root_source_file/target/optimize
    // passed directly to addExecutable/addLibrary/addTest.
    const fitz_mod = b.addModule("fitz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "fitz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "fitz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fitz", .module = fitz_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the fitz CLI (pass a .fit path with -- <path>)");
    run_step.dependOn(&run_cmd.step);

    // Library tests start at root.zig so the public re-exports are compiled too; CLI tests run
    // against main.zig so any tests added there are picked up.
    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{ .root_module = fitz_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
