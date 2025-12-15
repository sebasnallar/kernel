// MyLittleKernel - Init Process
//
// The first user process. Spawns child processes and manages them.

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SPAWN: u64 = 4;
    const WAIT: u64 = 5;
    const WRITE: u64 = 40;
};

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

    // Spawn 3 child processes
    write("[init] Spawning 3 hello processes...\n");

    var pids: [3]i64 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        pids[i] = spawn(0); // binary_id 0 = hello
        write("[init] Spawned child PID ");
        if (pids[i] > 0) {
            putDec(@bitCast(pids[i]));
        } else {
            write("ERROR");
        }
        write("\n");
    }

    // Let children run for a bit
    write("[init] Letting children run...\n");
    var loops: u32 = 0;
    while (loops < 50) : (loops += 1) {
        yield();
    }

    write("[init] Init process exiting\n");
    exit(0);
}
