const std = @import("std");
const Translator = @import("translate_c").Translator;
const build_zig_zon = @import("build.zig.zon");

const ReleaseTarget = struct {
    query: std.Target.Query,
    name: []const u8,
};

const release_targets: []const ReleaseTarget = &.{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "linux-musl-x64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "linux-musl-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "macos-x64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "macos-arm64" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const is_macos = target.result.os.tag == .macos;
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string for release") orelse
        @as([]const u8, build_zig_zon.version);

    const enable_daemon = b.option(bool, "daemon", "Include daemon support and Ghostty VT in zmx pkg") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const ghostty_ver = build_zig_zon.dependencies.ghostty.hash;
    options.addOption([]const u8, "ghostty_version", ghostty_ver);
    options.addOption(bool, "has_daemon", enable_daemon);

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "cross",
                .module = translator.mod,
            },
        },
    });
    exe_mod.addOptions("build_options", options);

    const dep = if (enable_daemon) b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        // Not redundant: in lib-vt mode emit-xcframework defaults to "xcodebuild
        // on PATH" (true even via the CLT stub), which pulls in the iOS SDK at
        // configure time and breaks builds without full Xcode.
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    }) else null;
    if (dep) |d| {
        const vt_mod = d.module("ghostty-vt");
        if (target.result.os.tag == .openbsd) vt_mod.sanitize_c = .off;
        exe_mod.addImport("ghostty-vt", vt_mod);
    }

    // zmx module: programmatic interface for embedding or external tools
    const zmx_pkg_mod = b.addModule("zmx", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "cross",
                .module = translator.mod,
            },
        },
    });

    zmx_pkg_mod.addOptions("build_options", options);
    if (dep) |d| {
        const vt_mod = d.module("ghostty-vt");
        if (target.result.os.tag == .openbsd) vt_mod.sanitize_c = .off;
        zmx_pkg_mod.addImport("ghostty-vt", vt_mod);
    }

    // Examples: build the usage examples in examples/ against the zmx module
    {
        const examples_step = b.step("examples", "Build usage examples");
        const Example = struct { name: []const u8, file: []const u8 };
        const example_sources: []const Example = &.{
            .{ .name = "example-run-and-wait", .file = "examples/run_and_wait.zig" },
            .{ .name = "example-list-sessions", .file = "examples/list_sessions.zig" },
        };
        for (example_sources) |ex| {
            const ex_mod = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{
                        .name = "cross",
                        .module = translator.mod,
                    },
                },
            });
            ex_mod.addImport("zmx", zmx_pkg_mod);
            const ex_exe = b.addExecutable(.{ .name = ex.name, .root_module = ex_mod });
            const install = b.addInstallArtifact(ex_exe, .{});
            examples_step.dependOn(&install.step);
        }
    }

    // Run
    {
        const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "zmx",
            // .use_llvm = true,
            // .use_lld = !is_macos,
            .root_module = exe_mod,
        });

        if (enable_daemon) {
            b.installArtifact(exe);
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            run_cmd.addPassthruArgs();
            run_step.dependOn(&run_cmd.step);
        }
    }

    // Test
    {
        const test_step = b.step("test", "Run unit tests");
        const test_module = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "cross",
                    .module = translator.mod,
                },
            },
        });
        test_module.addOptions("build_options", options);
        const test_dep = b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-lib-vt" = true,
            .@"emit-xcframework" = false,
            .@"emit-macos-app" = false,
        });
        test_module.addImport(
            "ghostty-vt",
            test_dep.module("ghostty-vt"),
        );
        const exe_unit_tests = b.addTest(.{
            .root_module = test_module,
            // .use_llvm = true,
            // .use_lld = !is_macos,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    // Check for LSP integration
    {
        const check = b.step("check", "Check if zmx compiles");
        if (enable_daemon) {
            const exe_check = b.addExecutable(.{
                .name = "zmx",
                .root_module = exe_mod,
            });
            check.dependOn(&exe_check.step);
        } else {
            const lib_check = b.addLibrary(.{
                .name = "zmx",
                .root_module = zmx_pkg_mod,
                .linkage = .static,
            });
            check.dependOn(&lib_check.step);
        }
    }

    // Release step - cross-compile .tzst archives for all targets from any host
    {
        const release_step = b.step(
            "release",
            "Build .tzst release archives for all platforms",
        );
        for (release_targets) |release_target| {
            const resolved = b.resolveTargetQuery(release_target.query);
            const release_translator: Translator = .init(translate_c, .{
                .c_source_file = b.path("src/c.h"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });
            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .link_libc = true,
                .imports = &.{
                    .{
                        .name = "cross",
                        .module = release_translator.mod,
                    },
                },
            });
            release_mod.addOptions("build_options", options);

            if (b.lazyDependency("ghostty", .{
                .target = resolved,
                .optimize = .ReleaseSafe,
                .@"emit-lib-vt" = true,
                .@"emit-xcframework" = false,
                .@"emit-macos-app" = false,
            })) |release_dep| {
                release_mod.addImport("ghostty-vt", release_dep.module("ghostty-vt"));
            }

            const release_exe = b.addExecutable(.{
                .name = "zmx",
                .root_module = release_mod,
            });

            const pkg_name = b.fmt("zmx-{s}-{s}", .{ version, release_target.name });
            const archive_name = b.fmt("{s}.tzst", .{pkg_name});

            const stage = b.addWriteFiles();
            _ = stage.addCopyFile(release_exe.getEmittedBin(), "bin/zmx");
            _ = stage.addCopyFile(b.path("LICENSE"), "LICENSE");
            _ = stage.addCopyFile(b.path("README.md"), "README.md");

            const pack = b.addSystemCommand(&.{"python3"});
            pack.setEnvironmentVariable("SOURCE_DATE_EPOCH", "0");
            pack.addFileArg(b.path("scripts/pack.py"));
            pack.addArgs(&.{ "--root", pkg_name });
            pack.addDirectoryArg(stage.getDirectory());
            const archive = pack.addOutputFileArg(archive_name);

            const install_archive = b.addInstallFile(archive, b.fmt("dist/{s}", .{archive_name}));
            release_step.dependOn(&install_archive.step);
        }
    }
}
