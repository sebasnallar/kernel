// MyLittleKernel - Init Process
//
// The first user process. Spawns system services and manages them.
// Following microkernel philosophy: init spawns servers, not the kernel.

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SPAWN: u64 = 4;
    const WAIT: u64 = 5;
    const WRITE: u64 = 40;
};

// Binary IDs (must match binaries.zig)
const BINARY_HELLO: u64 = 0;
const BINARY_CONSOLE: u64 = 2;

fn syscall0(num: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
        : "memory"
    );
    return ret;
}

fn syscall1(num: u64, arg0: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
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

fn write(buf: []const u8) void {
    _ = syscall2(SYS.WRITE, @intFromPtr(buf.ptr), buf.len);
}

fn yield() void {
    _ = syscall0(SYS.YIELD);
}

fn getpid() i64 {
    return syscall0(SYS.GETPID);
}

fn spawn(binary_id: u64) i64 {
    return syscall1(SYS.SPAWN, binary_id);
}

fn wait(pid: i64) i64 {
    return syscall1(SYS.WAIT, @bitCast(pid));
}

fn exit(code: i64) noreturn {
    _ = syscall1(SYS.EXIT, @bitCast(code));
    unreachable;
}

fn putDec(val: u64) void {
    if (val == 0) {
        write("0");
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
    // Reverse and print
    while (i > 0) {
        i -= 1;
        _ = syscall2(SYS.WRITE, @intFromPtr(&buf[i]), 1);
    }
}

export fn _start() callconv(.C) noreturn {
    write("[init] Starting (PID ");
    putDec(@bitCast(getpid()));
    write(")\n");

    // Step 1: Spawn console server
    write("[init] Spawning console server...\n");
    const console_pid = spawn(BINARY_CONSOLE);
    if (console_pid > 0) {
        write("[init] Console server started (PID ");
        putDec(@bitCast(console_pid));
        write(")\n");
    } else {
        write("[init] Failed to spawn console server!\n");
    }

    // Give console server time to initialize
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        yield();
    }

    // Step 2: Spawn multiple application processes (test IPC sender queue)
    write("[init] Spawning 3 hello processes...\n");

    var pids: [3]i64 = undefined;
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        pids[j] = spawn(BINARY_HELLO);
        write("[init] Spawned hello (PID ");
        if (pids[j] > 0) {
            putDec(@bitCast(pids[j]));
        } else {
            write("ERROR");
        }
        write(")\n");
    }

    // Let everything run
    write("[init] System running. Entering idle loop.\n");

    while (true) {
        // Check for terminated children
        const result = wait(-1);
        if (result >= 0) {
            write("[init] Child exited with code ");
            putDec(@bitCast(result));
            write("\n");
        }
        yield();
    }
}
