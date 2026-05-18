const std = @import("std");
const CombineArchivesStep = @import("src/build/CombineArchivesStep.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // options
    const static_link = b.option(bool, "static-link", "Whether to statically link libc") orelse true;
    const use_utf8 = b.option(bool, "use-utf8", "UTF-8 support") orelse true;
    const use_llvm = b.option(bool, "use-llvm", "Force building with llvm") orelse !static_link;
    const trace_mem = b.option(bool, "trace-mem", "Trace object memory operations") orelse (optimize == .Debug);
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};
    const token_debugging = b.option(bool, "token-debugging", "Whether to print tokens when they're parsed") orelse false;
    const threading = b.option(bool, "threading", "Whether threading is enabled") orelse true;

    const target = b.standardTargetOptions(.{
        .default_target = if (static_link) .{ .abi = .musl } else .{},
    });

    const options = b.addOptions();
    options.addOption(bool, "use_utf8", use_utf8);
    options.addOption(bool, "token_debugging", token_debugging);
    options.addOption(bool, "threading", threading);
    options.addOption(bool, "trace_mem", trace_mem);
    const options_mod = options.createModule();

    // deps
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "simple_uppercase_mapping",
            "simple_lowercase_mapping",
            "simple_titlecase_mapping",
        }),
    });

    const pcre2 = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });

    const pcre2_config = b.addWriteFiles().add("pcre2_config.h",
        \\#define PCRE2_CODE_UNIT_WIDTH 8
        \\#include "pcre2.h"
    );
    const pcre2_translated = b.addTranslateC(.{
        .root_source_file = pcre2_config,
        .target = target,
        .optimize = optimize,
    });
    pcre2_translated.addIncludePath(pcre2.namedLazyPath("pcre2.h").dirname());
    const pcre2_mod = pcre2_translated.createModule();

    // steps
    const run_step = b.step("run", "Run the application");
    const test_step = b.step("test", "Run all tests");

    // main entry
    const root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    root.addImport("uucode", uucode.module("uucode"));
    root.addImport("options", options_mod);
    root.addImport("pcre2", pcre2_mod);
    root.linkLibrary(pcre2.artifact("pcre2-8"));

    // executable
    const exe = b.addExecutable(.{
        .name = "zicl",
        .root_module = root,
        .use_llvm = use_llvm,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);

    // libzicl
    const lz_mod = b.createModule(.{
        .root_source_file = b.path("src/libzicl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lz_mod.addImport("uucode", uucode.module("uucode"));
    lz_mod.addImport("options", options_mod);
    lz_mod.addImport("pcre2", pcre2_mod);
    lz_mod.linkLibrary(pcre2.artifact("pcre2-8"));

    const lz = b.addLibrary(.{
        .name = "zicl",
        .linkage = .static,
        .root_module = lz_mod,
        .use_llvm = use_llvm,
    });
    lz.bundle_compiler_rt = true;
    const install_header = b.addInstallFile(b.path("include/libzicl.h"), "include/libzicl.h");
    b.getInstallStep().dependOn(&install_header.step);

    // Combine pcre2 into libzicl.a so downstream consumers only need
    // to link one library. Zig skips transitive static lib deps by design.
    const lib_list = b.allocator.alloc(std.Build.LazyPath, 2) catch @panic("OOM");
    lib_list[0] = pcre2.artifact("pcre2-8").getEmittedBin();
    lib_list[1] = lz.getEmittedBin();
    const combined = CombineArchivesStep.create(b, target, "zicl", lib_list);
    combined.step.dependOn(&lz.step);

    const install_lib = b.addInstallLibFile(combined.output, "libzicl.a");
    b.getInstallStep().dependOn(&install_lib.step);

    // tests
    const tests = b.addTest(.{
        .name = "zicl-test",
        .filters = test_filters,
        .root_module = root,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .server },
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
