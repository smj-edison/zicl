const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // options
    const use_utf8 = b.option(bool, "use-utf8", "UTF-8 support") orelse true;
    const use_llvm = b.option(bool, "use-llvm", "Force building with llvm") orelse false;
    const trace_mem = b.option(bool, "trace-mem", "Trace object memory operations") orelse (optimize == .Debug);
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};
    const token_debugging = b.option(bool, "token-debugging", "Whether to print tokens when they're parsed") orelse false;
    const threading = b.option(bool, "threading", "Whether threading is enabled") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "use_utf8", use_utf8);
    options.addOption(bool, "token_debugging", token_debugging);
    options.addOption(bool, "threading", threading);
    options.addOption(bool, "trace_mem", trace_mem);

    const options_mod = options.createModule();

    // deps
    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "simple_uppercase_mapping",
            "simple_lowercase_mapping",
            "simple_titlecase_mapping",
        }),
    });

    // steps
    const run_step = b.step("run", "Run the application");
    const test_step = b.step("test", "Run all tests");

    // main entry
    const root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    root.addImport("uucode", uucode_dep.module("uucode"));
    root.addImport("options", options_mod);

    // executable
    const exe = b.addExecutable(.{
        .name = "zicl",
        .root_module = root,
        .use_llvm = use_llvm,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);

    // tests
    const tests = b.addTest(.{
        .name = "zicl-test",
        .filters = test_filters,
        .root_module = root,
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const test_asm = tests.getEmittedAsm();
    const write_asm = b.addInstallFile(test_asm, "main.s");
    test_step.dependOn(&write_asm.step);
}
