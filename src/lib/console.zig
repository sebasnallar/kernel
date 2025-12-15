// MyLittleKernel - Console Output
//
// Professional logging and console output with:
//   - ANSI color support
//   - Status indicators [OK] [FAIL] [WARN]
//   - Kernel log levels
//   - Hex/number formatting

// UART hardware interface (PL011)
const UART_BASE: usize = 0x09000000;
const UART_DR: *volatile u32 = @ptrFromInt(UART_BASE + 0x00); // Data register
const UART_FR: *volatile u32 = @ptrFromInt(UART_BASE + 0x18); // Flag register
const FR_TXFF: u32 = 1 << 5; // TX FIFO full
const FR_RXFE: u32 = 1 << 4; // RX FIFO empty

// ANSI escape codes for colors
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    // Foreground colors
    pub const black = "\x1b[30m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";

    // Bright foreground
    pub const bright_black = "\x1b[90m";
    pub const bright_red = "\x1b[91m";
    pub const bright_green = "\x1b[92m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_blue = "\x1b[94m";
    pub const bright_magenta = "\x1b[95m";
    pub const bright_cyan = "\x1b[96m";
    pub const bright_white = "\x1b[97m";
};

// Log levels
pub const Level = enum {
    debug,
    info,
    warn,
    err,
    boot,
};

/// Write a single character
pub fn putc(c: u8) void {
    while ((UART_FR.* & FR_TXFF) != 0) {}
    UART_DR.* = c;
}

/// Write a string
pub fn puts(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

/// Read a single character (blocking)
pub fn getc() u8 {
    while ((UART_FR.* & FR_RXFE) != 0) {}
    return @truncate(UART_DR.*);
}

/// Try to read a single character (non-blocking)
/// Returns null if no data available
pub fn tryGetc() ?u8 {
    if ((UART_FR.* & FR_RXFE) != 0) {
        return null;
    }
    return @truncate(UART_DR.*);
}

/// Write a formatted hex value
pub fn putHex(value: u64) void {
    puts("0x");
    const hex = "0123456789abcdef";

    // Find first non-zero nibble (or print at least one digit)
    var started = false;
    var i: u32 = 16; // 16 nibbles in u64
    while (i > 0) {
        i -= 1;
        const shift: u6 = @truncate(i * 4);
        const nibble: u4 = @truncate(value >> shift);
        if (nibble != 0 or started or i == 0) {
            putc(hex[nibble]);
            started = true;
        }
    }
}

/// Write a decimal number
pub fn putDec(value: u64) void {
    if (value == 0) {
        putc('0');
        return;
    }

    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = value;

    while (v > 0) {
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
        i += 1;
    }

    while (i > 0) {
        i -= 1;
        putc(buf[i]);
    }
}

/// Write size in human-readable format (KB, MB, GB)
pub fn putSize(bytes: u64) void {
    if (bytes >= 1024 * 1024 * 1024) {
        putDec(bytes / (1024 * 1024 * 1024));
        puts(" GB");
    } else if (bytes >= 1024 * 1024) {
        putDec(bytes / (1024 * 1024));
        puts(" MB");
    } else if (bytes >= 1024) {
        putDec(bytes / 1024);
        puts(" KB");
    } else {
        putDec(bytes);
        puts(" B");
    }
}

/// Print a log message with level prefix
pub fn log(level: Level, comptime msg: []const u8) void {
    switch (level) {
        .debug => {
            puts(Color.dim);
            puts("[DEBUG] ");
            puts(Color.reset);
        },
        .info => {
            puts(Color.cyan);
            puts("[INFO]  ");
            puts(Color.reset);
        },
        .warn => {
            puts(Color.yellow);
            puts("[WARN]  ");
            puts(Color.reset);
        },
        .err => {
            puts(Color.red);
            puts("[ERROR] ");
            puts(Color.reset);
        },
        .boot => {
            puts(Color.blue);
            puts("[BOOT]  ");
            puts(Color.reset);
        },
    }
    puts(msg);
    puts("\n");
}

/// Print a status line: description followed by [OK], [FAIL], etc.
pub fn status(comptime desc: []const u8, ok: bool) void {
    puts("  ");
    puts(desc);

    // Pad to column 60
    const padding = if (desc.len < 55) 55 - desc.len else 1;
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        putc(' ');
    }

    if (ok) {
        puts("[");
        puts(Color.green);
        puts("  OK  ");
        puts(Color.reset);
        puts("]\n");
    } else {
        puts("[");
        puts(Color.red);
        puts(" FAIL ");
        puts(Color.reset);
        puts("]\n");
    }
}

/// Print status with custom message
pub fn statusMsg(comptime desc: []const u8, comptime result: []const u8, color: []const u8) void {
    puts("  ");
    puts(desc);

    const padding = if (desc.len < 55) 55 - desc.len else 1;
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        putc(' ');
    }

    puts("[");
    puts(color);
    puts(result);
    puts(Color.reset);
    puts("]\n");
}

/// Print the kernel boot banner
pub fn printBanner() void {
    puts("\n");
    puts(Color.bright_cyan);
    puts("    __  ___      __    _ __  __  __     __ __                    __\n");
    puts("   /  |/  /_  __/ /   (_) /_/ /_/ /__  / //_/__  _________  ___  / /\n");
    puts("  / /|_/ / / / / /   / / __/ __/ / _ \\/ ,< / _ \\/ ___/ __ \\/ _ \\/ / \n");
    puts(" / /  / / /_/ / /___/ / /_/ /_/ /  __/ /| /  __/ /  / / / /  __/ /  \n");
    puts("/_/  /_/\\__, /_____/_/\\__/\\__/_/\\___/_/ |_\\___/_/  /_/ /_/\\___/_/   \n");
    puts("       /____/                                                       \n");
    puts(Color.reset);
    puts("\n");
}

/// Print system information
pub fn printSystemInfo(ram_size: u64) void {
    puts(Color.bold);
    puts("System Information\n");
    puts(Color.reset);
    puts(Color.dim);
    puts("─────────────────────────────────────────────────────────────────\n");
    puts(Color.reset);

    puts("  Architecture:    ");
    puts(Color.white);
    puts("AArch64 (ARM64)\n");
    puts(Color.reset);

    puts("  Platform:        ");
    puts(Color.white);
    puts("QEMU virt machine\n");
    puts(Color.reset);

    puts("  RAM Size:        ");
    puts(Color.white);
    putSize(ram_size);
    puts("\n");
    puts(Color.reset);

    puts("  Kernel:          ");
    puts(Color.white);
    puts("MyLittleKernel v0.1.0\n");
    puts(Color.reset);

    puts("  Design:          ");
    puts(Color.white);
    puts("Pure Microkernel\n");
    puts(Color.reset);

    puts(Color.dim);
    puts("─────────────────────────────────────────────────────────────────\n");
    puts(Color.reset);
    puts("\n");
}

/// Print section header for boot stages
pub fn section(comptime title: []const u8) void {
    puts("\n");
    puts(Color.bold);
    puts(Color.yellow);
    puts(">> ");
    puts(title);
    puts("\n");
    puts(Color.reset);
}

/// Clear screen
pub fn clear() void {
    puts("\x1b[2J\x1b[H");
}

/// Newline
pub fn newline() void {
    puts("\n");
}
