// MyLittleKernel - System Call Interface
//
// ARM64 system call ABI:
//   - SVC #0 triggers exception
//   - x8 = syscall number
//   - x0-x5 = arguments
//   - x0 = return value (0 = success, negative = error)
//
// This is the kernel's interface for user space (and kernel threads).

const root = @import("root");
const scheduler = root.scheduler;
const ipc = root.ipc;

// ============================================================
// System Call Numbers
// ============================================================

/// System call numbers - keep these stable for ABI compatibility
pub const SYS = struct {
    // Process/Thread control
    pub const EXIT: u64 = 0; // Exit current thread
    pub const YIELD: u64 = 1; // Yield time slice
    pub const GETPID: u64 = 2; // Get process ID
    pub const GETTID: u64 = 3; // Get thread ID

    // IPC - Synchronous message passing (microkernel core!)
    pub const SEND: u64 = 10; // Send message to port
    pub const RECV: u64 = 11; // Receive message from port
    pub const CALL: u64 = 12; // Send and wait for reply (RPC)
    pub const REPLY: u64 = 13; // Reply to received message

    // Port management
    pub const PORT_CREATE: u64 = 20; // Create a new port
    pub const PORT_DESTROY: u64 = 21; // Destroy a port
    pub const PORT_GRANT: u64 = 22; // Grant port access to another process

    // Memory management
    pub const MMAP: u64 = 30; // Map memory
    pub const MUNMAP: u64 = 31; // Unmap memory

    // Debug/Info
    pub const DEBUG_PRINT: u64 = 100; // Print debug message (kernel threads only)
    pub const GET_TICKS: u64 = 101; // Get timer tick count
};

// ============================================================
// Error Codes
// ============================================================

pub const Error = enum(i64) {
    SUCCESS = 0,
    INVALID_SYSCALL = -1,
    INVALID_ARGUMENT = -2,
    NO_PERMISSION = -3,
    NO_MEMORY = -4,
    WOULD_BLOCK = -5,
    INTERRUPTED = -6,
    NOT_FOUND = -7,
    ALREADY_EXISTS = -8,
    INVALID_PORT = -9,
    QUEUE_FULL = -10,
    QUEUE_EMPTY = -11,
};

// ============================================================
// System Call Frame
// ============================================================

/// Registers saved during syscall (passed to handler)
pub const SyscallFrame = struct {
    // Arguments and return value
    x0: u64, // arg0 / return value
    x1: u64, // arg1
    x2: u64, // arg2
    x3: u64, // arg3
    x4: u64, // arg4
    x5: u64, // arg5
    x6: u64,
    x7: u64,
    x8: u64, // syscall number
    // Saved state
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x30: u64, // link register
    elr: u64, // return address
    spsr: u64, // saved processor state
};

// ============================================================
// System Call Dispatcher
// ============================================================

/// Main syscall dispatcher - called from exception handler
/// Returns the result in frame.x0
pub fn dispatch(frame: *SyscallFrame) void {
    const syscall_num = frame.x8;

    const result: i64 = switch (syscall_num) {
        // Process/Thread control
        SYS.EXIT => sysExit(frame),
        SYS.YIELD => sysYield(),
        SYS.GETPID => sysGetPid(),
        SYS.GETTID => sysGetTid(),

        // IPC
        SYS.SEND => sysSend(frame),
        SYS.RECV => sysRecv(frame),
        SYS.CALL => sysCall(frame),
        SYS.REPLY => sysReply(frame),

        // Port management
        SYS.PORT_CREATE => sysPortCreate(),
        SYS.PORT_DESTROY => sysPortDestroy(frame),

        // Debug
        SYS.DEBUG_PRINT => sysDebugPrint(frame),
        SYS.GET_TICKS => sysGetTicks(),

        else => @intFromEnum(Error.INVALID_SYSCALL),
    };

    // Store result in x0 (will be restored on return)
    frame.x0 = @bitCast(result);
}

// ============================================================
// System Call Implementations
// ============================================================

/// Exit current thread
fn sysExit(frame: *SyscallFrame) i64 {
    _ = frame;
    if (scheduler.getCurrent()) |thread| {
        thread.state = .dead;
    }
    scheduler.yield();
    // Should not return
    return 0;
}

/// Yield time slice to another thread
fn sysYield() i64 {
    scheduler.yield();
    return 0;
}

/// Get current process ID
fn sysGetPid() i64 {
    if (scheduler.getCurrent()) |thread| {
        if (thread.process) |proc| {
            return @intCast(proc.pid);
        }
    }
    return 0; // Kernel thread, no process
}

/// Get current thread ID
fn sysGetTid() i64 {
    if (scheduler.getCurrent()) |thread| {
        return @intCast(thread.tid);
    }
    return 0;
}

const console = root.console;

// Debug counter for syscall activity
var send_count: u32 = 0;
var recv_count: u32 = 0;

// Static buffer for send (avoid stack issues)
var send_msg_buf: ipc.Message = .{};

/// Send message to a port
/// x0 = port_id, x1 = op, x2 = arg0, x3 = arg1
fn sysSend(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    const op: u32 = @truncate(frame.x1);
    const endpoint = ipc.EndpointId.fromRaw(port_id);

    // Build message in static buffer
    send_msg_buf.op = op;
    send_msg_buf.arg0 = frame.x2;
    send_msg_buf.arg1 = frame.x3;
    send_msg_buf.arg2 = 0;
    send_msg_buf.arg3 = 0;
    send_msg_buf.sender = .invalid;
    send_msg_buf.reply_to = .invalid;
    send_msg_buf.badge = 0;

    // Try to send
    ipc.send(endpoint, &send_msg_buf) catch |err| {
        return switch (err) {
            ipc.IpcError.InvalidEndpoint => @intFromEnum(Error.INVALID_PORT),
            ipc.IpcError.EndpointClosed => @intFromEnum(Error.INVALID_PORT),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };

    send_count += 1;
    if (send_count % 10 == 1) {
        console.puts(console.Color.cyan);
        console.puts("[KERN] Send #");
        console.putDec(send_count);
        console.puts(" op=");
        console.putDec(op);
        console.newline();
        console.puts(console.Color.reset);
    }
    return 0;
}

// Static buffer for receive (avoid stack issues)
var recv_msg_buf: ipc.Message = .{};

/// Receive message from a port
/// x0 = port_id, returns: x0 = op, x1 = arg0, x2 = arg1
fn sysRecv(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    const endpoint = ipc.EndpointId.fromRaw(port_id);

    // Try to receive (blocking) using static buffer
    ipc.receive(endpoint, &recv_msg_buf) catch |err| {
        return switch (err) {
            ipc.IpcError.InvalidEndpoint => @intFromEnum(Error.INVALID_PORT),
            ipc.IpcError.EndpointClosed => @intFromEnum(Error.INVALID_PORT),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };

    recv_count += 1;
    if (recv_count % 10 == 1) {
        console.puts(console.Color.green);
        console.puts("[KERN] Recv #");
        console.putDec(recv_count);
        console.puts(" op=");
        console.putDec(recv_msg_buf.op);
        console.newline();
        console.puts(console.Color.reset);
    }

    // Put results in frame for return
    frame.x1 = recv_msg_buf.arg0;
    frame.x2 = recv_msg_buf.arg1;
    return @intCast(recv_msg_buf.op);
}

/// Send and wait for reply (RPC style)
fn sysCall(frame: *SyscallFrame) i64 {
    // For now, just do send + receive
    const send_result = sysSend(frame);
    if (send_result < 0) return send_result;
    return sysRecv(frame);
}

/// Reply to a received message
fn sysReply(frame: *SyscallFrame) i64 {
    _ = frame;
    // TODO: Implement proper reply mechanism
    return 0;
}

/// Create a new IPC port
fn sysPortCreate() i64 {
    const endpoint = ipc.createEndpoint() catch |err| {
        return switch (err) {
            ipc.IpcError.OutOfEndpoints => @intFromEnum(Error.NO_MEMORY),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };
    return @intCast(endpoint.raw());
}

/// Destroy an IPC port
fn sysPortDestroy(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    ipc.destroyEndpoint(ipc.EndpointId.fromRaw(port_id));
    return 0;
}

/// Debug print (for kernel threads)
/// x0 = string pointer, x1 = length
fn sysDebugPrint(frame: *SyscallFrame) i64 {
    const ptr: [*]const u8 = @ptrFromInt(frame.x0);
    const len: usize = @truncate(frame.x1);

    // Safety: limit length
    const safe_len = if (len > 256) 256 else len;

    // Print character by character
    for (ptr[0..safe_len]) |c| {
        console.putc(c);
    }

    return @intCast(safe_len);
}

/// Get timer tick count
fn sysGetTicks() i64 {
    const interrupt = root.interrupt;
    return @intCast(interrupt.getTimerTicks());
}

// ============================================================
// Syscall Helper for Kernel Threads
// ============================================================

/// Helper to make syscalls from kernel threads (inline assembly)
pub inline fn syscall0(num: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
        : "memory"
    );
    return ret;
}

pub inline fn syscall1(num: u64, arg0: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : "memory"
    );
    return ret;
}

pub inline fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
        : "memory"
    );
    return ret;
}

// ============================================================
// User-Friendly Wrappers
// ============================================================

pub fn yield() void {
    _ = syscall0(SYS.YIELD);
}

pub fn exit() noreturn {
    _ = syscall0(SYS.EXIT);
    unreachable;
}

pub fn getTid() u32 {
    return @intCast(@as(u64, @bitCast(syscall0(SYS.GETTID))));
}

pub fn getTicks() u64 {
    return @bitCast(syscall0(SYS.GET_TICKS));
}
