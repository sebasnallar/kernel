// MyLittleKernel - Hello World User Program
//
// This is a real user program that runs in EL0 (userspace).
// It uses syscalls to communicate with the kernel.

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const WRITE: u64 = 40;
};

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

fn syscall0(num: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
        : "memory"
    );
    return ret;
}

fn write(buf: []const u8) i64 {
    return syscall2(SYS.WRITE, @intFromPtr(buf.ptr), buf.len);
}

fn yield() void {
    _ = syscall0(SYS.YIELD);
}

export fn _start() callconv(.C) noreturn {
    const msg = "Hello from userspace!\n";

    while (true) {
        _ = write(msg);
        yield();
    }
}
