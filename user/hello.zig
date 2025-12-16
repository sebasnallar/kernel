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

// Block device server well-known port
const BLKDEV_PORT: u64 = 4;

// Console protocol operations
const CONSOLE_WRITE: u64 = 1;
const CONSOLE_PUTC: u64 = 4;

// Block device protocol operations
const BLK_OP_READ: u64 = 1;
const BLK_OP_GET_CAPACITY: u64 = 2;

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

    // Wait for block device to be ready (it needs to init hardware)
    // Retry the send until it succeeds (port 3 exists)
    consoleWrite("[hello:");
    putDec(@bitCast(pid));
    consoleWrite("] Waiting for blkdev...\n");

    // Test block device IPC - request capacity (with retries)
    var cap_result: i64 = -1;
    var retry: u32 = 0;
    while (cap_result < 0 and retry < 100) : (retry += 1) {
        // Wait before each attempt
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            yield();
        }
        cap_result = sendMsg(BLKDEV_PORT, BLK_OP_GET_CAPACITY, 0, 0);
    }

    consoleWrite("[hello:");
    putDec(@bitCast(pid));
    if (cap_result < 0) {
        consoleWrite("] Capacity request failed after retries\n");
    } else {
        consoleWrite("] Capacity request sent!\n");
    }

    // Yield to let blkdev process the request
    var j: u32 = 0;
    while (j < 50) : (j += 1) {
        yield();
    }

    // Test block device IPC - request sector 0 read
    consoleWrite("[hello:");
    putDec(@bitCast(pid));
    consoleWrite("] Requesting sector 0 read...\n");
    const read_result = sendMsg(BLKDEV_PORT, BLK_OP_READ, 0, 0);
    if (read_result < 0) {
        consoleWrite("[hello:");
        putDec(@bitCast(pid));
        consoleWrite("] Read request failed: ");
        putDec(@abs(read_result));
        consoleWrite("\n");
    } else {
        consoleWrite("[hello:");
        putDec(@bitCast(pid));
        consoleWrite("] Read request sent!\n");
    }

    // Yield to let blkdev process the request
    j = 0;
    while (j < 100) : (j += 1) {
        yield();
    }

    consoleWrite("[hello:");
    putDec(@bitCast(pid));
    consoleWrite("] Done!\n");

    // Exit cleanly
    _ = syscall0(SYS.EXIT);
    unreachable;
}
