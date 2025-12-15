// MyLittleKernel - Binary Loader
//
// Loads executables into process address spaces.
// Uses a simple flat binary format:
//
// MLK Binary Format v1:
//   Offset 0x00: Magic "MLK\x01" (4 bytes)
//   Offset 0x04: Entry point offset from code start (4 bytes, little-endian)
//   Offset 0x08: Code size in bytes (4 bytes, little-endian)
//   Offset 0x0C: Reserved (4 bytes, must be 0)
//   Offset 0x10: Code starts here
//
// Total header: 16 bytes
// Code is position-independent, loaded at USER_CODE_BASE.

const root = @import("root");
const scheduler = root.scheduler;
const memory = root.memory;
const mmu = root.mmu;
const user_program = root.user_program;
const console = root.console;

// ============================================================
// Binary Format
// ============================================================

pub const MAGIC: [4]u8 = .{ 'M', 'L', 'K', 0x01 };
pub const HEADER_SIZE: usize = 16;
pub const VERSION: u8 = 1;

pub const Header = struct {
    magic: [4]u8,
    entry_offset: u32, // Offset from code start to entry point
    code_size: u32, // Size of code section
    reserved: u32, // Must be 0
};

pub const LoadError = error{
    InvalidMagic,
    InvalidHeader,
    CodeTooLarge,
    OutOfMemory,
    ProcessCreationFailed,
};

// ============================================================
// Loader Functions
// ============================================================

/// Parse header from raw bytes
pub fn parseHeader(data: []const u8) LoadError!Header {
    if (data.len < HEADER_SIZE) {
        return LoadError.InvalidHeader;
    }

    // Check magic
    if (data[0] != MAGIC[0] or data[1] != MAGIC[1] or data[2] != MAGIC[2] or data[3] != MAGIC[3]) {
        return LoadError.InvalidMagic;
    }

    // Parse fields (little-endian)
    const entry_offset = @as(u32, data[4]) |
        (@as(u32, data[5]) << 8) |
        (@as(u32, data[6]) << 16) |
        (@as(u32, data[7]) << 24);

    const code_size = @as(u32, data[8]) |
        (@as(u32, data[9]) << 8) |
        (@as(u32, data[10]) << 16) |
        (@as(u32, data[11]) << 24);

    const reserved = @as(u32, data[12]) |
        (@as(u32, data[13]) << 8) |
        (@as(u32, data[14]) << 16) |
        (@as(u32, data[15]) << 24);

    // Validate
    if (reserved != 0) {
        return LoadError.InvalidHeader;
    }

    if (code_size == 0 or code_size > 1024 * 1024) { // Max 1MB code
        return LoadError.CodeTooLarge;
    }

    if (entry_offset >= code_size) {
        return LoadError.InvalidHeader;
    }

    return Header{
        .magic = MAGIC,
        .entry_offset = entry_offset,
        .code_size = code_size,
        .reserved = 0,
    };
}

/// Load a binary and create a process
/// Returns the main thread of the new process
pub fn loadBinary(data: []const u8, priority: scheduler.Priority) LoadError!*scheduler.Thread {
    // Parse header
    const header = try parseHeader(data);

    // Verify we have enough data
    if (data.len < HEADER_SIZE + header.code_size) {
        return LoadError.InvalidHeader;
    }

    // Extract code section
    const code = data[HEADER_SIZE .. HEADER_SIZE + header.code_size];

    // Create process with the code
    const thread = scheduler.createUserProcess(code, priority) orelse {
        return LoadError.ProcessCreationFailed;
    };

    return thread;
}

/// Load raw code (no header) - for backwards compatibility with machine code blobs
pub fn loadRawCode(code: []const u8, priority: scheduler.Priority) LoadError!*scheduler.Thread {
    const thread = scheduler.createUserProcess(code, priority) orelse {
        return LoadError.ProcessCreationFailed;
    };
    return thread;
}

// ============================================================
// Binary Builder (for creating MLK binaries)
// ============================================================

/// Create an MLK binary from raw code
/// Returns bytes in provided buffer, or null if buffer too small
pub fn createBinary(code: []const u8, entry_offset: u32, buffer: []u8) ?[]u8 {
    const total_size = HEADER_SIZE + code.len;
    if (buffer.len < total_size) {
        return null;
    }

    // Write magic
    buffer[0] = MAGIC[0];
    buffer[1] = MAGIC[1];
    buffer[2] = MAGIC[2];
    buffer[3] = MAGIC[3];

    // Write entry offset (little-endian)
    buffer[4] = @truncate(entry_offset);
    buffer[5] = @truncate(entry_offset >> 8);
    buffer[6] = @truncate(entry_offset >> 16);
    buffer[7] = @truncate(entry_offset >> 24);

    // Write code size (little-endian)
    const code_size: u32 = @truncate(code.len);
    buffer[8] = @truncate(code_size);
    buffer[9] = @truncate(code_size >> 8);
    buffer[10] = @truncate(code_size >> 16);
    buffer[11] = @truncate(code_size >> 24);

    // Reserved
    buffer[12] = 0;
    buffer[13] = 0;
    buffer[14] = 0;
    buffer[15] = 0;

    // Copy code
    for (code, 0..) |byte, i| {
        buffer[HEADER_SIZE + i] = byte;
    }

    return buffer[0..total_size];
}

// ============================================================
// Debug / Info
// ============================================================

/// Print information about a binary
pub fn printInfo(data: []const u8) void {
    const header = parseHeader(data) catch |err| {
        console.puts("  Invalid binary: ");
        switch (err) {
            LoadError.InvalidMagic => console.puts("bad magic\n"),
            LoadError.InvalidHeader => console.puts("bad header\n"),
            LoadError.CodeTooLarge => console.puts("code too large\n"),
            else => console.puts("unknown error\n"),
        }
        return;
    };

    console.puts("  MLK Binary v1\n");
    console.puts("    Entry offset: ");
    console.putHex(header.entry_offset);
    console.newline();
    console.puts("    Code size:    ");
    console.putDec(header.code_size);
    console.puts(" bytes\n");
}
