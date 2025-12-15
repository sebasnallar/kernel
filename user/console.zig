// MyLittleKernel - Console Server
//
// Userspace server that owns the UART and provides console I/O via IPC.
// Following the microkernel philosophy: drivers in userspace!
//
// Protocol:
//   CONSOLE_WRITE: arg0 = buffer ptr, arg1 = length -> bytes written
//   CONSOLE_READ:  arg0 = buffer ptr, arg1 = max length -> bytes read
//   CONSOLE_GETC:  (no args) -> character in arg0, or -1 if none

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SEND: u64 = 10;
    const RECV: u64 = 11;
    const PORT_CREATE: u64 = 20;
    const WRITE: u64 = 40; // Direct UART write (kernel syscall, for bootstrap)
    const READ: u64 = 41; // Direct UART read (kernel syscall, for bootstrap)
};

// Console protocol operations
pub const CONSOLE_WRITE: u32 = 1;
pub const CONSOLE_READ: u32 = 2;
pub const CONSOLE_GETC: u32 = 3;
pub const CONSOLE_PUTC: u32 = 4;

// Well-known port ID for console server (set by init)
pub var CONSOLE_PORT: u64 = 0;

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

// Receive message from port, returns op code
// x1, x2 contain arg0, arg1 on return
fn recvMsg(port: u64) struct { op: i64, arg0: u64, arg1: u64 } {
    var op: i64 = undefined;
    var arg0: u64 = undefined;
    var arg1: u64 = undefined;
    asm volatile ("svc #0"
        : [op] "={x0}" (op),
          [arg0] "={x1}" (arg0),
          [arg1] "={x2}" (arg1),
        : [num] "{x8}" (@as(u64, SYS.RECV)),
          [port] "{x0}" (port),
        : "memory"
    );
    return .{ .op = op, .arg0 = arg0, .arg1 = arg1 };
}

fn sendMsg(port: u64, op: u64, arg0: u64, arg1: u64) i64 {
    return syscall4(SYS.SEND, port, op, arg0, arg1);
}

fn createPort() i64 {
    return syscall0(SYS.PORT_CREATE);
}

fn directWrite(buf: []const u8) i64 {
    return syscall2(SYS.WRITE, @intFromPtr(buf.ptr), buf.len);
}

fn directRead(buf: []u8) i64 {
    return syscall2(SYS.READ, @intFromPtr(buf.ptr), buf.len);
}

fn yield() void {
    _ = syscall0(SYS.YIELD);
}

fn exit(code: i64) noreturn {
    _ = syscall1(SYS.EXIT, @bitCast(code));
    unreachable;
}

fn getpid() i64 {
    return syscall0(SYS.GETPID);
}

export fn _start() callconv(.C) noreturn {
    _ = directWrite("[console] Starting console server (PID ");
    putDec(@bitCast(getpid()));
    _ = directWrite(")\n");

    // Create our service port
    const port = createPort();
    if (port < 0) {
        _ = directWrite("[console] Failed to create port!\n");
        exit(1);
    }

    _ = directWrite("[console] Created port ");
    putDec(@bitCast(port));
    _ = directWrite("\n");

    // Store port ID globally (init will read this somehow)
    CONSOLE_PORT = @bitCast(port);

    _ = directWrite("[console] Ready for requests\n");

    // Main server loop
    while (true) {
        // Wait for a message
        const msg = recvMsg(@bitCast(port));

        if (msg.op < 0) {
            // Error receiving
            yield();
            continue;
        }

        const op: u32 = @truncate(@as(u64, @bitCast(msg.op)));

        switch (op) {
            CONSOLE_WRITE => {
                // arg0 = buffer ptr, arg1 = length
                const buf_ptr: [*]const u8 = @ptrFromInt(msg.arg0);
                const len: usize = @truncate(msg.arg1);
                // Use direct kernel write for now
                const written = directWrite(buf_ptr[0..len]);
                // TODO: Reply to sender with bytes written
                _ = written;
            },
            CONSOLE_READ => {
                // arg0 = buffer ptr, arg1 = max length
                const buf_ptr: [*]u8 = @ptrFromInt(msg.arg0);
                const max_len: usize = @truncate(msg.arg1);
                const read_count = directRead(buf_ptr[0..max_len]);
                // TODO: Reply to sender with bytes read
                _ = read_count;
            },
            CONSOLE_PUTC => {
                // arg0 = character
                var c: [1]u8 = .{@truncate(msg.arg0)};
                _ = directWrite(&c);
            },
            else => {
                // Unknown operation - ignore
            },
        }

        // Don't yield - server should be always ready to receive
        // The blocking recvMsg will naturally give up CPU when no messages
    }
}

fn putDec(val: u64) void {
    if (val == 0) {
        _ = directWrite("0");
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
        _ = syscall2(SYS.WRITE, @intFromPtr(&buf[i]), 1);
    }
}
