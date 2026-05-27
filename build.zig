const std = @import("std");
const header_gen = @import("src/header.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
    const generated_header_dir = generatedHeaders(b);

    const module = b.addModule("interpose", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(generated_header_dir);
    linkDarwinRuntime(module, target);

    const static_lib = b.addLibrary(.{
        .name = "interpose",
        .root_module = module,
        .linkage = .static,
        .version = version,
    });
    b.installArtifact(static_lib);

    const dynamic_lib = b.addLibrary(.{
        .name = "interpose",
        .root_module = module,
        .linkage = .dynamic,
        .version = version,
    });
    b.installArtifact(dynamic_lib);

    b.getInstallStep().dependOn(&b.addInstallHeaderFile(generated_header_dir.path(b, "interpose.h"), "interpose.h").step);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("module.modulemap"), "module.modulemap").step);

    const runtime_tests = addZigTest(b, target, optimize, generated_header_dir, module, "runtime-tests", "tests/runtime_test.zig");
    const resolver_tests = addZigTest(b, target, optimize, generated_header_dir, module, "resolver-tests", "tests/resolver_test.zig");

    const header_gen_tests = b.addTest(.{
        .name = "header-gen-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/header.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_header_gen_tests = b.addRunArtifact(header_gen_tests);

    const test_step = b.step("test", "Run all validation");
    test_step.dependOn(&runtime_tests.step);
    test_step.dependOn(&resolver_tests.step);
    test_step.dependOn(&run_header_gen_tests.step);
    test_step.dependOn(&addHeaderFixture(b, target, optimize, generated_header_dir, "zi_header_c", "tests/header.c", .c, &.{
        "-std=c23",
        "-Wall",
        "-Wextra",
        "-Werror",
    }).step);
    test_step.dependOn(&addHeaderFixture(b, target, optimize, generated_header_dir, "zi_header_cpp", "tests/header.cpp", .cpp, &.{
        "-std=c++26",
        "-Wall",
        "-Wextra",
        "-Werror",
    }).step);
    test_step.dependOn(&addHeaderFixture(b, target, optimize, generated_header_dir, "zi_header_objc", "tests/header.m", .objective_c, &.{
        "-std=c23",
        "-Wall",
        "-Wextra",
        "-Werror",
    }).step);
    test_step.dependOn(&addHeaderFixture(b, target, optimize, generated_header_dir, "zi_header_objcpp", "tests/header.mm", .objective_cpp, &.{
        "-std=c++26",
        "-Wall",
        "-Wextra",
        "-Werror",
    }).step);
    if (target.result.os.tag.isDarwin()) {
        test_step.dependOn(&addHeaderFixture(b, target, optimize, generated_header_dir, "zi_darwin_integration_c", "tests/darwin.c", .c, &.{
            "-std=c23",
            "-Wall",
            "-Wextra",
            "-Werror",
        }).step);
    }

    b.getInstallStep().dependOn(test_step);

    const platform_tests = b.step("test-platforms", "Build platform capability matrix");
    addPlatformCompile(b, platform_tests, "zi_darwin_macos_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = semver(13, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_macos_x86_64", .{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
        .os_version_min = semver(13, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_ios_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .os_version_min = semver(16, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_tvos_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .tvos,
        .os_version_min = semver(16, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_watchos_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .watchos,
        .os_version_min = semver(9, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_visionos_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .visionos,
        .os_version_min = semver(1, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_maccatalyst_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .maccatalyst,
        .os_version_min = semver(16, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_darwin_maccatalyst_x86_64", .{
        .cpu_arch = .x86_64,
        .os_tag = .maccatalyst,
        .os_version_min = semver(16, 0, 0),
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_linux_x86_64", .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_windows_x86_64", .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    }, optimize);
    addPlatformCompile(b, platform_tests, "zi_android_arm64", .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    }, optimize);
}

fn addZigTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    generated_header_dir: std.Build.LazyPath,
    module: *std.Build.Module,
    name: []const u8,
    source_path: []const u8,
) *std.Build.Step.Run {
    const unit_tests = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("interpose", module);
    unit_tests.root_module.addIncludePath(generated_header_dir);
    if (target.result.os.tag.isDarwin()) {
        unit_tests.root_module.linkSystemLibrary("objc", .{ .needed = false, .weak = true });
    }
    return b.addRunArtifact(unit_tests);
}

fn generatedHeaders(b: *std.Build) std.Build.LazyPath {
    const write_files = b.addWriteFiles();
    const header = header_gen.generate(b.allocator, @embedFile("src/abi/header.zig")) catch |err| {
        std.debug.print("failed to generate interpose.h from src/abi/header.zig: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    _ = write_files.add("interpose.h", header);
    return write_files.getDirectory();
}

fn addHeaderFixture(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    generated_header_dir: std.Build.LazyPath,
    name: []const u8,
    path: []const u8,
    language: std.Build.Module.CSourceLanguage,
    flags: []const []const u8,
) *std.Build.Step.Compile {
    const fixture_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fixture_module.addIncludePath(generated_header_dir);
    fixture_module.addCSourceFile(.{
        .file = b.path(path),
        .flags = flags,
        .language = language,
    });
    linkDarwinRuntime(fixture_module, target);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = fixture_module,
    });
    return exe;
}

fn linkDarwinRuntime(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (!target.result.os.tag.isDarwin()) return;
    module.linkSystemLibrary("objc", .{ .needed = false, .weak = true });
    module.addCSourceFile(.{
        .file = module.owner.path("src/runtime/darwin.m"),
        .flags = &.{},
        .language = .objective_c,
    });
}

fn addPlatformCompile(
    b: *std.Build,
    step: *std.Build.Step,
    name: []const u8,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
) void {
    const generated_header_dir = generatedHeaders(b);
    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.resolveTargetQuery(query),
        .optimize = optimize,
        .link_libc = true,
    });
    platform_module.addIncludePath(generated_header_dir);

    const lib = b.addLibrary(.{
        .name = name,
        .root_module = platform_module,
        .linkage = .static,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    step.dependOn(&lib.step);
}

fn semver(major: u32, minor: u32, patch: u32) std.Target.Query.OsVersion {
    return .{ .semver = .{ .major = major, .minor = minor, .patch = patch } };
}
