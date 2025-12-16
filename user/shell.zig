// MyLittleKernel - Shell
//
// A simple interactive shell for the microkernel.
// Communicates with services via IPC.

// ============================================================
// System Call Interface
// ============================================================

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SEND: u64 = 10;
    const RECV: u64 = 11;
    const SPAWN: u64 = 4;
    const READ: u64 = 41;
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

fn yield() void {
    _ = syscall0(SYS.YIELD);
}

fn getpid() i64 {
    return syscall0(SYS.GETPID);
}

fn spawn(binary_id: u64) i64 {
    return syscall1(SYS.SPAWN, binary_id);
}

// ============================================================
// Console I/O
// ============================================================

const CONSOLE_PORT: u64 = 2;
const CONSOLE_PUTC: u64 = 4;

fn consolePutc(c: u8) void {
    _ = syscall4(SYS.SEND, CONSOLE_PORT, CONSOLE_PUTC, c, 0);
}

fn print(s: []const u8) void {
    for (s) |c| consolePutc(c);
}

fn printDec(val: u64) void {
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

fn printHex(val: u64) void {
    const hex = "0123456789abcdef";
    print("0x");
    var i: u6 = 60;
    var started = false;
    while (true) : (i -= 4) {
        const digit: u4 = @truncate((val >> i) & 0xf);
        if (digit != 0 or started or i == 0) {
            consolePutc(hex[digit]);
            started = true;
        }
        if (i == 0) break;
    }
}

// Read from console (direct syscall)
fn consoleRead(buf: []u8) usize {
    const result = syscall2(SYS.READ, @intFromPtr(buf.ptr), buf.len);
    if (result < 0) return 0;
    return @intCast(@as(u64, @bitCast(result)));
}

// ============================================================
// IPC to Services
// ============================================================

const FS_PORT: u64 = 3;
const BLKDEV_PORT: u64 = 4;

const BLK_OP_GET_CAPACITY: u64 = 2;
const FS_OP_LIST: u32 = 4;

fn sendMsg(port: u64, op: u64, arg0: u64, arg1: u64) i64 {
    return syscall4(SYS.SEND, port, op, arg0, arg1);
}

// ============================================================
// Command Parser
// ============================================================

const MAX_CMD_LEN: usize = 64;
var cmd_buffer: [MAX_CMD_LEN]u8 = undefined;
var cmd_len: usize = 0;

fn resetCmd() void {
    cmd_len = 0;
    for (&cmd_buffer) |*c| c.* = 0;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn startsWith(str: []const u8, prefix: []const u8) bool {
    if (str.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (str[i] != c) return false;
    }
    return true;
}

fn processCommand() void {
    if (cmd_len == 0) return;

    const cmd = cmd_buffer[0..cmd_len];

    // Trim trailing whitespace/newline
    var end = cmd_len;
    while (end > 0 and (cmd[end - 1] == '\n' or cmd[end - 1] == '\r' or cmd[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return;

    const trimmed = cmd[0..end];

    if (strEql(trimmed, "help")) {
        print("Available commands:\n");
        print("  help     - Show this help\n");
        print("  ps       - List processes (not implemented)\n");
        print("  ls       - List files\n");
        print("  disk     - Show disk info\n");
        print("  hello    - Spawn hello process\n");
        print("  clear    - Clear screen\n");
        print("  exit     - Exit shell\n");
    } else if (strEql(trimmed, "ls")) {
        print("Requesting file list...\n");
        const result = sendMsg(FS_PORT, FS_OP_LIST, 0, 0);
        if (result < 0) {
            print("Error: filesystem not available (");
            printDec(@abs(result));
            print(")\n");
        }
    } else if (strEql(trimmed, "disk")) {
        print("Requesting disk info...\n");
        const result = sendMsg(BLKDEV_PORT, BLK_OP_GET_CAPACITY, 0, 0);
        if (result < 0) {
            print("Error: block device not available\n");
        } else {
            print("Disk query sent\n");
        }
    } else if (strEql(trimmed, "hello")) {
        print("Spawning hello process...\n");
        const pid = spawn(0); // BINARY_HELLO = 0
        if (pid > 0) {
            print("Started process PID ");
            printDec(@bitCast(pid));
            print("\n");
        } else {
            print("Failed to spawn\n");
        }
    } else if (strEql(trimmed, "clear")) {
        // ANSI clear screen
        print("\x1b[2J\x1b[H");
    } else if (strEql(trimmed, "exit")) {
        print("Goodbye!\n");
        _ = syscall1(SYS.EXIT, 0);
        unreachable;
    } else if (strEql(trimmed, "ps")) {
        print("Process list not yet implemented\n");
    } else {
        print("Unknown command: ");
        print(trimmed);
        print("\nType 'help' for available commands.\n");
    }
}

// ============================================================
// Entry Point
// ============================================================

export fn _start() callconv(.C) noreturn {
    const pid = getpid();

    // Clear screen and show banner
    print("\x1b[2J\x1b[H");
    print("=====================================\n");
    print("  MyLittleKernel Shell v0.1\n");
    print("  Type 'help' for commands\n");
    print("=====================================\n\n");

    print("[shell] Started (PID ");
    printDec(@bitCast(pid));
    print(")\n\n");

    // Main loop
    while (true) {
        // Print prompt
        print("mlk> ");

        // Read input character by character
        resetCmd();
        var done = false;

        while (!done) {
            var buf: [1]u8 = undefined;
            const n = consoleRead(&buf);

            if (n > 0) {
                const c = buf[0];

                if (c == '\r' or c == '\n') {
                    consolePutc('\n');
                    done = true;
                } else if (c == 127 or c == 8) {
                    // Backspace
                    if (cmd_len > 0) {
                        cmd_len -= 1;
                        print("\x08 \x08"); // Move back, space, move back
                    }
                } else if (c >= 32 and c < 127 and cmd_len < MAX_CMD_LEN - 1) {
                    cmd_buffer[cmd_len] = c;
                    cmd_len += 1;
                    consolePutc(c); // Echo
                }
            } else {
                // No input available, yield
                yield();
            }
        }

        // Process the command
        processCommand();
    }
}
