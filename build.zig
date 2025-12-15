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

    // ============================================================
    // User Programs
    // ============================================================

    // Build hello world user program
    const hello = b.addExecutable(.{
        .name = "hello",
        .root_source_file = b.path("user/hello.zig"),
        .target = target,
        .optimize = .ReleaseSmall, // Small code for user programs
        .code_model = .small,
        .pic = true, // Position independent code
    });
    hello.setLinkerScript(b.path("user/user.ld"));
    hello.root_module.stack_protector = false;
    hello.root_module.link_libc = false;

    // Create raw binary from hello ELF
    const hello_bin = hello.addObjCopy(.{
        .basename = "hello.bin",
        .format = .bin,
    });

    // Create MLK binary with header using a custom step
    const mkbin_step = MkBinStep.create(b, hello_bin.getOutput(), "hello.mlk");

    // Install the hello MLK binary
    const install_hello = b.addInstallBinFile(mkbin_step.getOutput(), "hello.mlk");
    b.default_step.dependOn(&install_hello.step);

    // Build init user program
    const init = b.addExecutable(.{
        .name = "init",
        .root_source_file = b.path("user/init.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
        .pic = true,
    });
    init.setLinkerScript(b.path("user/user.ld"));
    init.root_module.stack_protector = false;
    init.root_module.link_libc = false;

    const init_bin = init.addObjCopy(.{
        .basename = "init.bin",
        .format = .bin,
    });

    const init_mkbin = MkBinStep.create(b, init_bin.getOutput(), "init.mlk");
    const install_init = b.addInstallBinFile(init_mkbin.getOutput(), "init.mlk");
    b.default_step.dependOn(&install_init.step);

    // Build console server
    const console_srv = b.addExecutable(.{
        .name = "console",
        .root_source_file = b.path("user/console.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
        .pic = true,
    });
    console_srv.setLinkerScript(b.path("user/user.ld"));
    console_srv.root_module.stack_protector = false;
    console_srv.root_module.link_libc = false;

    const console_bin = console_srv.addObjCopy(.{
        .basename = "console.bin",
        .format = .bin,
    });

    const console_mkbin = MkBinStep.create(b, console_bin.getOutput(), "console.mlk");
    const install_console = b.addInstallBinFile(console_mkbin.getOutput(), "console.mlk");
    b.default_step.dependOn(&install_console.step);

    // ============================================================
    // Kernel
    // ============================================================

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

    // Make MLK binaries available for @embedFile
    const write_hello = WriteFileStep.create(b, mkbin_step.getOutput(), "src/embedded/hello.mlk");
    const write_init = WriteFileStep.create(b, init_mkbin.getOutput(), "src/embedded/init.mlk");
    const write_console = WriteFileStep.create(b, console_mkbin.getOutput(), "src/embedded/console.mlk");
    kernel.step.dependOn(&write_hello.step);
    kernel.step.dependOn(&write_init.step);
    kernel.step.dependOn(&write_console.step);

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

// ============================================================
// Custom Build Step: Create MLK Binary
// ============================================================

const MkBinStep = struct {
    step: std.Build.Step,
    input: std.Build.LazyPath,
    output: std.Build.GeneratedFile,

    fn create(b: *std.Build, input: std.Build.LazyPath, name: []const u8) *MkBinStep {
        const self = b.allocator.create(MkBinStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = name,
                .owner = b,
                .makeFn = make,
            }),
            .input = input,
            .output = .{ .step = &self.step },
        };
        input.addStepDependencies(&self.step);
        return self;
    }

    fn getOutput(self: *MkBinStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.output } };
    }

    fn make(step: *std.Build.Step, _: std.Progress.Node) anyerror!void {
        const self: *MkBinStep = @fieldParentPtr("step", step);
        const b = step.owner;

        // Read input binary
        const input_path = self.input.getPath2(b, step);
        const raw_code = std.fs.cwd().readFileAlloc(b.allocator, input_path, 1024 * 1024) catch |err| {
            return step.fail("Failed to read input: {}", .{err});
        };

        // Create MLK header + code
        const header_size: usize = 16;
        const total_size = header_size + raw_code.len;
        const output = b.allocator.alloc(u8, total_size) catch @panic("OOM");

        // Magic: "MLK\x01"
        output[0] = 'M';
        output[1] = 'L';
        output[2] = 'K';
        output[3] = 0x01;

        // Entry offset (0 = start of code)
        output[4] = 0;
        output[5] = 0;
        output[6] = 0;
        output[7] = 0;

        // Code size (little-endian)
        const code_size: u32 = @intCast(raw_code.len);
        output[8] = @truncate(code_size);
        output[9] = @truncate(code_size >> 8);
        output[10] = @truncate(code_size >> 16);
        output[11] = @truncate(code_size >> 24);

        // Reserved
        output[12] = 0;
        output[13] = 0;
        output[14] = 0;
        output[15] = 0;

        // Copy code
        @memcpy(output[header_size..], raw_code);

        // Write output to cache directory
        const sub_path = "mlk_bins";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Build path: <cache_root>/mlk_bins/<name>
        const cache_path = b.cache_root.path orelse ".";
        const mlk_dir_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_path, sub_path }) catch @panic("path too long");

        std.fs.cwd().makePath(mlk_dir_path) catch {};

        var out_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const output_path = std.fmt.bufPrint(&out_path_buf, "{s}/{s}", .{ mlk_dir_path, step.name }) catch @panic("path too long");

        const output_file = std.fs.cwd().createFile(output_path, .{}) catch |err| {
            return step.fail("Failed to create output: {}", .{err});
        };
        defer output_file.close();
        output_file.writeAll(output) catch |err| {
            return step.fail("Failed to write output: {}", .{err});
        };

        self.output.path = b.allocator.dupe(u8, output_path) catch @panic("OOM");
    }
};

// ============================================================
// Custom Build Step: Write file to source tree
// ============================================================

const WriteFileStep = struct {
    step: std.Build.Step,
    input: std.Build.LazyPath,
    dest_path: []const u8,

    fn create(b: *std.Build, input: std.Build.LazyPath, dest_path: []const u8) *WriteFileStep {
        const self = b.allocator.create(WriteFileStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "write_file",
                .owner = b,
                .makeFn = make,
            }),
            .input = input,
            .dest_path = dest_path,
        };
        input.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Progress.Node) anyerror!void {
        const self: *WriteFileStep = @fieldParentPtr("step", step);
        const b = step.owner;

        // Read input
        const input_path = self.input.getPath2(b, step);
        const data = std.fs.cwd().readFileAlloc(b.allocator, input_path, 1024 * 1024) catch |err| {
            return step.fail("Failed to read input: {}", .{err});
        };

        // Ensure parent directory exists
        if (std.fs.path.dirname(self.dest_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        // Write to destination
        std.fs.cwd().writeFile(.{ .sub_path = self.dest_path, .data = data }) catch |err| {
            return step.fail("Failed to write to {s}: {}", .{ self.dest_path, err });
        };
    }
};
