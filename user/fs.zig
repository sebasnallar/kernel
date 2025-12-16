// MyLittleKernel - Filesystem Server
//
// A simple filesystem server that provides file operations via IPC.
// Uses a minimal filesystem format (MinFS) on top of the block device.
//
// MinFS Layout:
//   Sector 0: Superblock (magic, version, root_dir_sector, free_bitmap_sector)
//   Sector 1-N: Free bitmap
//   Sector N+1: Root directory
//   Remaining: File data
//
// Directory entry: 32 bytes
//   - name: 24 bytes (null-terminated)
//   - start_sector: 4 bytes
//   - size: 4 bytes

// ============================================================
// System Call Interface
// ============================================================

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const SEND: u64 = 10;
    const RECV: u64 = 11;
    const PORT_CREATE: u64 = 20;
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

fn recvMsg(port: u64, arg0: *u64, arg1: *u64) i64 {
    var op: i64 = undefined;
    var a0: u64 = undefined;
    var a1: u64 = undefined;
    asm volatile ("svc #0"
        : [op] "={x0}" (op),
          [a0] "={x1}" (a0),
          [a1] "={x2}" (a1),
        : [num] "{x8}" (SYS.RECV),
          [port] "{x0}" (port),
        : "memory"
    );
    arg0.* = a0;
    arg1.* = a1;
    return op;
}

fn portCreate() i64 {
    return syscall0(SYS.PORT_CREATE);
}

// ============================================================
// Console Output (via IPC)
// ============================================================

const CONSOLE_PORT: u64 = 2;
const CONSOLE_PUTC: u64 = 4;

fn consolePutc(c: u8) void {
    _ = syscall4(SYS.SEND, CONSOLE_PORT, CONSOLE_PUTC, c, 0);
}

fn print(s: []const u8) void {
    for (s) |c| consolePutc(c);
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

// ============================================================
// Block Device IPC Client
// ============================================================

const BLKDEV_PORT: u64 = 3;
const BLK_OP_READ: u64 = 1;
const BLK_OP_GET_CAPACITY: u64 = 2;
const BLK_OP_READ_DATA: u64 = 5; // Read and return data chunks

fn blkReadSector(sector: u64) bool {
    const result = syscall4(SYS.SEND, BLKDEV_PORT, BLK_OP_READ, sector, 0);
    return result >= 0;
}

// ============================================================
// MinFS Filesystem Structures
// ============================================================

const MINFS_MAGIC: u32 = 0x4D494E46; // "MINF"
const MINFS_VERSION: u32 = 1;
const SECTOR_SIZE: usize = 512;
const DIR_ENTRY_SIZE: usize = 32;
const MAX_FILENAME: usize = 24;
const ENTRIES_PER_SECTOR: usize = SECTOR_SIZE / DIR_ENTRY_SIZE; // 16

// Superblock structure (sector 0)
const Superblock = extern struct {
    magic: u32,
    version: u32,
    total_sectors: u32,
    root_dir_sector: u32,
    free_bitmap_sector: u32,
    first_data_sector: u32,
    reserved: [488]u8,
};

// Directory entry (32 bytes)
const DirEntry = extern struct {
    name: [MAX_FILENAME]u8,
    start_sector: u32,
    size: u32,

    fn isValid(self: *const DirEntry) bool {
        return self.name[0] != 0 and self.name[0] != 0xFF;
    }

    fn getName(self: *const DirEntry) []const u8 {
        var len: usize = 0;
        while (len < MAX_FILENAME and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }
};

// ============================================================
// Filesystem State
// ============================================================

var superblock: Superblock = undefined;
var fs_ready: bool = false;

// Sector buffer for reading
var sector_buffer: [SECTOR_SIZE]u8 = undefined;

// ============================================================
// Filesystem Operations
// ============================================================

fn initFilesystem() bool {
    print("[fs] Initializing filesystem...\n");

    // Read superblock (sector 0)
    if (!blkReadSector(0)) {
        print("[fs] Failed to read superblock\n");
        return false;
    }

    // For now, we can't actually get the data back from blkdev via simple IPC
    // We need to either:
    // 1. Use shared memory
    // 2. Extend the IPC to return data
    // 3. Have blkdev write to a known location

    // For now, let's just mark as ready and create a minimal in-memory filesystem
    print("[fs] Using in-memory filesystem (no disk)\n");

    // Initialize superblock with defaults
    superblock.magic = MINFS_MAGIC;
    superblock.version = MINFS_VERSION;
    superblock.total_sectors = 2048;
    superblock.root_dir_sector = 2;
    superblock.free_bitmap_sector = 1;
    superblock.first_data_sector = 3;

    fs_ready = true;
    return true;
}

// ============================================================
// Filesystem Service Protocol
// ============================================================

// FS gets port 3 (console=2, fs=3, blkdev=4)
const FS_EXPECTED_PORT: u64 = 3;

// Operations
const FS_OP_OPEN: u32 = 1;      // Open file (arg0 = name_ptr, arg1 = name_len) -> fd
const FS_OP_READ: u32 = 2;      // Read from file (arg0 = fd, arg1 = count) -> bytes read
const FS_OP_CLOSE: u32 = 3;     // Close file (arg0 = fd)
const FS_OP_LIST: u32 = 4;      // List directory -> prints files
const FS_OP_STAT: u32 = 5;      // Get file info (arg0 = name_ptr, arg1 = name_len) -> size

// Error codes
const FS_OK: i32 = 0;
const FS_ERR_NOT_FOUND: i32 = -1;
const FS_ERR_IO: i32 = -2;
const FS_ERR_INVALID: i32 = -3;

// ============================================================
// In-Memory File Table (for demo)
// ============================================================

const MAX_FILES: usize = 8;

const FileEntry = struct {
    name: [MAX_FILENAME]u8,
    data: [256]u8,
    size: u32,
    used: bool,
};

var file_table: [MAX_FILES]FileEntry = undefined;

fn initFileTable() void {
    // Clear all entries
    for (&file_table) |*f| {
        f.used = false;
        for (&f.name) |*c| c.* = 0;
        for (&f.data) |*c| c.* = 0;
        f.size = 0;
    }

    // Create some demo files
    createDemoFile(0, "hello.txt", "Hello from MinFS!\n");
    createDemoFile(1, "readme.txt", "MyLittleKernel Filesystem\nA simple microkernel OS.\n");
    createDemoFile(2, "test.txt", "This is a test file.\n");
}

fn createDemoFile(idx: usize, name: []const u8, content: []const u8) void {
    if (idx >= MAX_FILES) return;

    var f = &file_table[idx];
    f.used = true;

    // Copy name
    var i: usize = 0;
    while (i < name.len and i < MAX_FILENAME - 1) : (i += 1) {
        f.name[i] = name[i];
    }
    f.name[i] = 0;

    // Copy content
    i = 0;
    while (i < content.len and i < f.data.len) : (i += 1) {
        f.data[i] = content[i];
    }
    f.size = @intCast(content.len);
}

fn findFile(name: []const u8) ?*FileEntry {
    for (&file_table) |*f| {
        if (!f.used) continue;

        // Compare names
        var match = true;
        var i: usize = 0;
        while (i < name.len and i < MAX_FILENAME) : (i += 1) {
            if (f.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        if (match and (i >= MAX_FILENAME or f.name[i] == 0)) {
            return f;
        }
    }
    return null;
}

fn listFiles() void {
    print("[fs] Directory listing:\n");
    var count: u32 = 0;
    for (&file_table) |*f| {
        if (!f.used) continue;
        print("  ");
        var i: usize = 0;
        while (i < MAX_FILENAME and f.name[i] != 0) : (i += 1) {
            consolePutc(f.name[i]);
        }
        print(" (");
        printDec(f.size);
        print(" bytes)\n");
        count += 1;
    }
    print("[fs] ");
    printDec(count);
    print(" files\n");
}

// ============================================================
// Entry Point
// ============================================================

export fn _start() callconv(.C) noreturn {
    print("[fs] Starting filesystem server\n");

    // Initialize in-memory file table
    initFileTable();

    // Try to initialize real filesystem (will fall back to in-memory)
    _ = initFilesystem();

    // Create our service port
    const port = portCreate();
    if (port < 0) {
        print("[fs] Failed to create port!\n");
        _ = syscall1(SYS.EXIT, 1);
        unreachable;
    }
    print("[fs] Created port ");
    printDec(@bitCast(port));
    print("\n");

    // List files at startup
    listFiles();

    print("[fs] Ready for requests\n");

    // Service loop
    while (true) {
        var arg0: u64 = 0;
        var arg1: u64 = 0;

        const op = recvMsg(@bitCast(port), &arg0, &arg1);

        if (op < 0) {
            _ = syscall0(SYS.YIELD);
            continue;
        }

        switch (@as(u32, @truncate(@as(u64, @bitCast(op))))) {
            FS_OP_LIST => {
                listFiles();
            },

            FS_OP_STAT => {
                // arg0 would be filename pointer - but we can't access cross-process memory
                // For now, just acknowledge
                print("[fs] Stat request received\n");
            },

            else => {
                print("[fs] Unknown op: ");
                printDec(@as(u64, @bitCast(op)));
                print("\n");
            },
        }
    }
}
