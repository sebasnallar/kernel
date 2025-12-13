// MyLittleKernel - ARM64 Boot Code
//
// This is the first code that runs when the kernel starts.
// Responsible for:
//   - CPU initialization (enable FP/SIMD)
//   - Stack setup
//   - BSS zeroing
//   - Hand-off to kernel main

const root = @import("root");
const console = root.console;

// External symbols from linker script
extern const __bss_start: u8;
extern const __bss_end: u8;
extern const __stack_top: u8;

// Memory layout constants (QEMU virt machine)
pub const MEMORY_BASE: u64 = 0x40000000;
pub const MEMORY_SIZE: u64 = 1024 * 1024 * 1024; // 1GB (from QEMU -m 1G)

// Device addresses
pub const UART_BASE: u64 = 0x09000000;
pub const GIC_DIST_BASE: u64 = 0x08000000;
pub const GIC_CPU_BASE: u64 = 0x08010000;

/// Entry point - first instruction executed
pub export fn _start() linksection(".text.boot") callconv(.Naked) noreturn {
    @setRuntimeSafety(false);
    asm volatile (
        // Enable FP/SIMD (CPACR_EL1.FPEN = 0b11)
        \\mov x0, #(3 << 20)
        \\msr cpacr_el1, x0
        \\isb
        \\
        // Set up stack pointer
        \\adrp x0, __stack_top
        \\add x0, x0, :lo12:__stack_top
        \\mov sp, x0
        \\
        // Jump to boot main
        \\b _boot_main
    );
}

/// Boot main - called after basic CPU setup
export fn _boot_main() callconv(.C) noreturn {
    // Zero BSS section
    zeroBss();

    // Print boot banner
    console.clear();
    console.printBanner();
    console.printSystemInfo(MEMORY_SIZE);

    // Start kernel initialization
    console.section("Kernel Initialization");
    root.kernel.init();
}

/// Zero the BSS section
fn zeroBss() void {
    const bss_start: [*]u8 = @ptrFromInt(@intFromPtr(&__bss_start));
    const bss_end: [*]u8 = @ptrFromInt(@intFromPtr(&__bss_end));
    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    if (bss_len > 0) {
        @memset(bss_start[0..bss_len], 0);
    }
}

/// Read current exception level
pub fn getCurrentEL() u2 {
    var el: u64 = undefined;
    asm volatile ("mrs %[el], CurrentEL"
        : [el] "=r" (el),
    );
    return @truncate((el >> 2) & 0x3);
}

/// Halt the CPU (low power wait)
pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfe");
    }
}

/// Panic and halt
pub fn panic(msg: []const u8) noreturn {
    console.puts("\n");
    console.puts(console.Color.red);
    console.puts(console.Color.bold);
    console.puts("!!! KERNEL PANIC !!!\n");
    console.puts(console.Color.reset);
    console.puts(console.Color.red);
    console.puts(msg);
    console.puts("\n");
    console.puts(console.Color.reset);
    halt();
}
