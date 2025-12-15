// MyLittleKernel - Entry Point
// This file serves as the root module and ties everything together

// Architecture-specific
pub const boot = @import("arch/aarch64/boot.zig");
pub const context = @import("arch/aarch64/context.zig");
pub const vectors = @import("arch/aarch64/vectors.zig");
pub const mmu = @import("arch/aarch64/mmu.zig");

// Kernel core
pub const kernel = @import("kernel/main.zig");
pub const memory = @import("kernel/memory.zig");
pub const scheduler = @import("kernel/scheduler.zig");
pub const ipc = @import("kernel/ipc.zig");
pub const interrupt = @import("kernel/interrupt.zig");
pub const syscall = @import("kernel/syscall.zig");
pub const user_program = @import("kernel/user_program.zig");
pub const loader = @import("kernel/loader.zig");
pub const binaries = @import("embedded/binaries.zig");

// Libraries
pub const console = @import("lib/console.zig");

// Re-export _start so it's visible to the linker
comptime {
    _ = boot._start;
}
