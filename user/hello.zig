// MyLittleKernel - Hello World User Program
//
// This is a real user program that runs in EL0 (userspace).
// It uses IPC to communicate through the console server.
// Following microkernel philosophy: I/O goes through userspace servers!

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SEND: u64 = 10;
    const WRITE: u64 = 40; // Direct write (fallback)
};

// Console server well-known port
const CONSOLE_PORT: u64 = 2;

// Console protocol operations
const CONSOLE_WRITE: u64 = 1;
const CONSOLE_PUTC: u64 = 4;

fn syscall0(num: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
        : "memory"
    );
    return ret;
}

fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
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

fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
          [arg1] "{x1}" (arg1),
          [arg2] "{x2}" (arg2),
          [arg3] "{x3}" (arg3),
        : "memory"
    );
    return ret;
}

fn getpid() i64 {
    return syscall0(SYS.GETPID);
}

fn yield() void {
    _ = syscall0(SYS.YIELD);
}

// Send message to console server
fn sendMsg(port: u64, op: u64, arg0: u64, arg1: u64) i64 {
    return syscall4(SYS.SEND, port, op, arg0, arg1);
}

// Write string via IPC - sends one character at a time (no cross-process pointers)
fn consoleWrite(buf: []const u8) void {
    for (buf) |c| {
        consolePutc(c);
    }
}

// Put a single character via IPC
fn consolePutc(c: u8) void {
    _ = sendMsg(CONSOLE_PORT, CONSOLE_PUTC, c, 0);
}

fn putDec(val: u64) void {
    if (val == 0) {
        consolePutc('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = val;
    while (v > 0) {
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        consolePutc(buf[i]);
    }
}

export fn _start() callconv(.C) noreturn {
    const pid = getpid();

    // Simple IPC test - just announce ourselves
    consoleWrite("[hello:");
    putDec(@bitCast(pid));
    consoleWrite("] Hi via IPC!\n");

    // Exit cleanly
    _ = syscall0(SYS.EXIT);
    unreachable;
}
