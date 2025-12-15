// MyLittleKernel - User Program Module
//
// Contains a minimal user-mode program that can be loaded into
// a process's address space. This is position-independent code
// that makes syscalls to communicate with the kernel.

const root = @import("root");
const syscall = root.syscall;

// ============================================================
// User Program Entry Points (compiled as position-independent)
// ============================================================

// Virtual addresses for user programs (in user address space)
pub const USER_CODE_BASE: u64 = 0x0000_0000_0010_0000; // 1MB
pub const USER_STACK_BASE: u64 = 0x0000_0000_7F00_0000; // ~2GB, grows down
pub const USER_STACK_SIZE: u64 = 16 * 1024; // 16KB stack

/// User program A - sends IPC messages
/// This function is copied to user address space and executed in EL0
pub fn userProgramA() callconv(.C) noreturn {
    // Simple counter loop with syscalls
    var counter: u32 = 0;

    while (true) {
        counter +%= 1;

        // Yield every iteration to let other threads run
        // SVC #0 with x8=1 (SYS.YIELD)
        asm volatile (
            \\mov x8, #1
            \\svc #0
            :
            :
            : "x0", "x8", "memory"
        );
    }
}

/// User program B - receives IPC messages
pub fn userProgramB() callconv(.C) noreturn {
    var counter: u32 = 0;

    while (true) {
        counter +%= 1;

        // Yield
        asm volatile (
            \\mov x8, #1
            \\svc #0
            :
            :
            : "x0", "x8", "memory"
        );
    }
}

/// Get the size of user program A (for copying)
pub fn getUserProgramASize() usize {
    // Approximate size - we'll copy more than needed to be safe
    return 256;
}

/// Get the size of user program B
pub fn getUserProgramBSize() usize {
    return 256;
}

// ============================================================
// Machine Code Blobs (pre-assembled position-independent code)
// ============================================================

// These are pre-assembled ARM64 instructions for simple user programs
// that don't rely on any relocations or absolute addresses.

/// Simple loop that yields forever:
///   loop:
///     mov x8, #1    // SYS.YIELD
///     svc #0        // syscall
///     b loop        // infinite loop
pub const yield_loop_code = [_]u32{
    0xD2800028, // mov x8, #1 (YIELD syscall)
    0xD4000001, // svc #0
    0x17FFFFFE, // b -8 (loop back)
};

/// IPC sender loop:
///   Sends counter to endpoint in x20 (set by kernel before start)
///   loop:
///     mov x0, x20       // endpoint ID (set by kernel)
///     mov x1, x21       // counter
///     add x21, x21, #1  // increment counter
///     mov x8, #10       // SYS.SEND
///     svc #0
///     mov x8, #1        // SYS.YIELD
///     svc #0
///     b loop
pub const ipc_sender_code = [_]u32{
    0xAA1403E0, // mov x0, x20 (endpoint ID from x20)
    0xAA1503E1, // mov x1, x21 (counter from x21)
    0x910006B5, // add x21, x21, #1
    0xD2800148, // mov x8, #10 (SEND syscall)
    0xD4000001, // svc #0
    0xD2800028, // mov x8, #1 (YIELD syscall)
    0xD4000001, // svc #0
    0x17FFFFF8, // b -32 (loop back)
};

/// IPC receiver loop:
///   Creates endpoint, then receives messages
///   mov x8, #20       // SYS.PORT_CREATE
///   svc #0
///   mov x20, x0       // save endpoint ID
///   loop:
///     mov x0, x20     // endpoint ID
///     mov x8, #11     // SYS.RECV
///     svc #0
///     mov x8, #1      // SYS.YIELD
///     svc #0
///     b loop
pub const ipc_receiver_code = [_]u32{
    0xD2800288, // mov x8, #20 (PORT_CREATE syscall)
    0xD4000001, // svc #0
    0xAA0003F4, // mov x20, x0 (save endpoint ID)
    // loop:
    0xAA1403E0, // mov x0, x20 (endpoint ID)
    0xD2800168, // mov x8, #11 (RECV syscall)
    0xD4000001, // svc #0
    0xD2800028, // mov x8, #1 (YIELD syscall)
    0xD4000001, // svc #0
    0x17FFFFFA, // b -24 (loop back to mov x0, x20)
};

/// Get yield loop code as bytes
pub fn getYieldLoopCode() []const u8 {
    return @as([*]const u8, @ptrCast(&yield_loop_code))[0 .. yield_loop_code.len * 4];
}

/// Get IPC sender code as bytes
pub fn getIpcSenderCode() []const u8 {
    return @as([*]const u8, @ptrCast(&ipc_sender_code))[0 .. ipc_sender_code.len * 4];
}

/// Get IPC receiver code as bytes
pub fn getIpcReceiverCode() []const u8 {
    return @as([*]const u8, @ptrCast(&ipc_receiver_code))[0 .. ipc_receiver_code.len * 4];
}
