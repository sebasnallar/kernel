const std = @import("std");

pub fn build(b: *std.Build) void {
    // Target: ARM64 freestanding (no OS)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Optimize for safety during development
    const optimize = b.standardOptimizeOption(.{});

    // The kernel executable - start.zig is the root module
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
    });

    // Use our custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Disable stack protector (no runtime support in freestanding)
    kernel.root_module.stack_protector = false;

    // Don't link libc
    kernel.root_module.link_libc = false;

    // Install the kernel binary
    b.installArtifact(kernel);

    // Also create a raw binary for direct loading
    const bin = kernel.addObjCopy(.{
        .basename = "kernel.bin",
        .format = .bin,
    });
    const copy_bin = b.addInstallBinFile(bin.getOutput(), "kernel.bin");
    b.default_step.dependOn(&copy_bin.step);

    // Run step - launch QEMU
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt",
        "-cpu",
        "cortex-a72",
        "-m",
        "1G",
        "-nographic",
        "-kernel",
    });
    run_cmd.addArtifactArg(kernel);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&run_cmd.step);

    // Debug step - QEMU with GDB server
    const debug_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt",
        "-cpu",
        "cortex-a72",
        "-m",
        "1G",
        "-nographic",
        "-kernel",
    });
    debug_cmd.addArtifactArg(kernel);
    debug_cmd.addArgs(&.{
        "-S", // Stop at startup
        "-s", // GDB server on port 1234
    });
    debug_cmd.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Run in QEMU with GDB server (port 1234)");
    debug_step.dependOn(&debug_cmd.step);
}
