const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for sound analysis logic
    const sound_mod = b.createModule(.{
        .root_source_file = b.path("src/sound.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Cross-compilation SDK paths (e.g. -Dtarget=x86_64-macos on aarch64 host)
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!is_native and target_os == .macos) {
        const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");
        if (macos_sdk) |sdk| {
            sound_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            sound_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    if (target_os == .macos) {
        sound_mod.linkSystemLibrary("objc", .{});
        sound_mod.linkFramework("Foundation", .{});
        sound_mod.linkFramework("SoundAnalysis", .{});
        sound_mod.linkFramework("AVFoundation", .{});
        sound_mod.linkFramework("CoreAudio", .{});
        sound_mod.linkFramework("CoreMedia", .{});
    }

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "cacophony",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sound", .module = sound_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the cacophony CLI");
    run_step.dependOn(&run_cmd.step);
}
