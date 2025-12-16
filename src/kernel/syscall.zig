// MyLittleKernel - System Call Interface
//
// ARM64 system call ABI:
//   - SVC #0 triggers exception
//   - x8 = syscall number
//   - x0-x5 = arguments
//   - x0 = return value (0 = success, negative = error)
//
// This is the kernel's interface for user space (and kernel threads).

const root = @import("root");
const scheduler = root.scheduler;
const ipc = root.ipc;
const console = root.console;
const loader = root.loader;
const binaries = root.binaries;

// ============================================================
// System Call Numbers
// ============================================================

/// System call numbers - keep these stable for ABI compatibility
pub const SYS = struct {
    // Process/Thread control
    pub const EXIT: u64 = 0; // Exit current thread/process (x0=exit_code)
    pub const YIELD: u64 = 1; // Yield time slice
    pub const GETPID: u64 = 2; // Get process ID
    pub const GETTID: u64 = 3; // Get thread ID
    pub const SPAWN: u64 = 4; // Spawn process from embedded binary (x0=binary_id) -> pid
    pub const WAIT: u64 = 5; // Wait for child process (x0=pid, -1=any) -> exit_code
    pub const GETPPID: u64 = 6; // Get parent process ID

    // IPC - Synchronous message passing (microkernel core!)
    pub const SEND: u64 = 10; // Send message to port
    pub const RECV: u64 = 11; // Receive message from port
    pub const CALL: u64 = 12; // Send and wait for reply (RPC)
    pub const REPLY: u64 = 13; // Reply to received message

    // Port management
    pub const PORT_CREATE: u64 = 20; // Create a new port
    pub const PORT_DESTROY: u64 = 21; // Destroy a port
    pub const PORT_GRANT: u64 = 22; // Grant port access to another process

    // Memory management
    pub const MMAP: u64 = 30; // Map memory
    pub const MUNMAP: u64 = 31; // Unmap memory
    pub const MAP_DEVICE: u64 = 32; // Map device MMIO region (x0=phys, x1=size) -> virt addr
    pub const ALLOC_DMA: u64 = 33; // Allocate DMA memory (x0=size) -> virt addr (x1=phys returned)
    pub const GET_PHYS: u64 = 34; // Get physical address of virtual address (x0=virt) -> phys

    // Console I/O
    pub const WRITE: u64 = 40; // Write to console (x0=buf, x1=len) -> bytes written
    pub const READ: u64 = 41; // Read from console (x0=buf, x1=len) -> bytes read

    // Debug/Info
    pub const DEBUG_PRINT: u64 = 100; // Print debug message (kernel threads only)
    pub const GET_TICKS: u64 = 101; // Get timer tick count
};

// ============================================================
// Error Codes
// ============================================================

pub const Error = enum(i64) {
    SUCCESS = 0,
    INVALID_SYSCALL = -1,
    INVALID_ARGUMENT = -2,
    NO_PERMISSION = -3,
    NO_MEMORY = -4,
    WOULD_BLOCK = -5,
    INTERRUPTED = -6,
    NOT_FOUND = -7,
    ALREADY_EXISTS = -8,
    INVALID_PORT = -9,
    QUEUE_FULL = -10,
    QUEUE_EMPTY = -11,
    NO_CHILDREN = -12,
    CHILD_RUNNING = -13,
};

// ============================================================
// System Call Frame
// ============================================================

/// Registers saved during syscall (passed to handler)
pub const SyscallFrame = struct {
    // Arguments and return value
    x0: u64, // arg0 / return value
    x1: u64, // arg1
    x2: u64, // arg2
    x3: u64, // arg3
    x4: u64, // arg4
    x5: u64, // arg5
    x6: u64,
    x7: u64,
    x8: u64, // syscall number
    // Saved state
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x30: u64, // link register
    elr: u64, // return address
    spsr: u64, // saved processor state
};

// ============================================================
// System Call Dispatcher
// ============================================================

/// Special return value indicating "don't modify frame.x0"
/// Used by blocking syscalls that will have their return value set by unblocking code
const SYSCALL_BLOCKED: i64 = -0x7FFFFFFF_FFFFFFFF;

/// Main syscall dispatcher - called from exception handler
/// Returns the result in frame.x0
pub fn dispatch(frame: *SyscallFrame) void {
    const syscall_num = frame.x8;

    const result: i64 = switch (syscall_num) {
        // Process/Thread control
        SYS.EXIT => sysExit(frame),
        SYS.YIELD => sysYield(),
        SYS.GETPID => sysGetPid(),
        SYS.GETTID => sysGetTid(),
        SYS.SPAWN => sysSpawn(frame),
        SYS.WAIT => sysWait(frame),
        SYS.GETPPID => sysGetPpid(),

        // IPC
        SYS.SEND => sysSend(frame),
        SYS.RECV => sysRecv(frame),
        SYS.CALL => sysCall(frame),
        SYS.REPLY => sysReply(frame),

        // Port management
        SYS.PORT_CREATE => sysPortCreate(),
        SYS.PORT_DESTROY => sysPortDestroy(frame),

        // Memory management
        SYS.MAP_DEVICE => sysMapDevice(frame),
        SYS.ALLOC_DMA => sysAllocDma(frame),
        SYS.GET_PHYS => sysGetPhys(frame),

        // Console I/O
        SYS.WRITE => sysWrite(frame),
        SYS.READ => sysRead(frame),

        // Debug
        SYS.DEBUG_PRINT => sysDebugPrint(frame),
        SYS.GET_TICKS => sysGetTicks(),

        else => @intFromEnum(Error.INVALID_SYSCALL),
    };

    // Store result in x0 (will be restored on return)
    // UNLESS it's SYSCALL_BLOCKED, which means the sender will set the return value
    if (result != SYSCALL_BLOCKED) {
        frame.x0 = @bitCast(result);
    }
}

// ============================================================
// System Call Implementations
// ============================================================

/// Exit current process with exit code
/// x0 = exit_code
fn sysExit(frame: *SyscallFrame) i64 {
    const exit_code: i32 = @truncate(@as(i64, @bitCast(frame.x0)));
    scheduler.exitProcess(exit_code);
    // Should not return - scheduler will switch to another process
    return 0;
}

/// Yield time slice to another thread
fn sysYield() i64 {
    // For EL0 threads, we need to trigger a reschedule after the syscall returns.
    // This is done by setting need_reschedule and re-enqueueing the current thread.
    if (scheduler.getCurrent()) |thread| {
        scheduler.enqueue(thread);
    }
    scheduler.setNeedReschedule();
    return 0;
}

/// Get current process ID
fn sysGetPid() i64 {
    if (scheduler.getCurrent()) |thread| {
        if (thread.process) |proc| {
            return @intCast(proc.pid);
        }
    }
    return 0; // Kernel thread, no process
}

/// Get current thread ID
fn sysGetTid() i64 {
    if (scheduler.getCurrent()) |thread| {
        return @intCast(thread.tid);
    }
    return 0;
}

/// Get parent process ID
fn sysGetPpid() i64 {
    if (scheduler.getCurrent()) |thread| {
        if (thread.process) |proc| {
            if (proc.parent_pid) |ppid| {
                return @intCast(ppid);
            }
        }
    }
    return 0; // No parent (init process or kernel thread)
}

/// Spawn a new process from embedded binary
/// x0 = binary_id (0 = hello)
/// Returns: child PID on success, negative error on failure
fn sysSpawn(frame: *SyscallFrame) i64 {
    const binary_id = frame.x0;

    // Get current process PID as parent
    const parent_pid: ?scheduler.Pid = if (scheduler.getCurrent()) |thread|
        if (thread.process) |proc| proc.pid else null
    else
        null;

    // Select binary based on ID
    const binary_data: []const u8 = switch (binary_id) {
        binaries.BINARY_HELLO => binaries.hello,
        binaries.BINARY_INIT => binaries.init,
        binaries.BINARY_CONSOLE => binaries.console,
        binaries.BINARY_BLKDEV => binaries.blkdev,
        binaries.BINARY_FS => binaries.fs,
        binaries.BINARY_SHELL => binaries.shell,
        else => return @intFromEnum(Error.INVALID_ARGUMENT),
    };

    // Load the binary with parent relationship
    const thread = scheduler.createUserProcessWithParent(
        binary_data[loader.HEADER_SIZE..],
        .normal,
        parent_pid,
    ) orelse return @intFromEnum(Error.NO_MEMORY);

    // Return the child's PID
    if (thread.process) |proc| {
        return @intCast(proc.pid);
    }
    return @intFromEnum(Error.NO_MEMORY);
}

/// Wait for a child process to exit
/// x0 = target PID (-1 = any child)
/// Returns: exit code on success, negative error on failure
fn sysWait(frame: *SyscallFrame) i64 {
    const target: i64 = @bitCast(frame.x0);
    const target_pid: ?scheduler.Pid = if (target < 0) null else @intCast(@as(u64, @bitCast(target)));

    // Check if we have any children at all
    if (!scheduler.hasChildren()) {
        return @intFromEnum(Error.NO_CHILDREN);
    }

    // Try to collect a zombie child
    if (scheduler.waitForChild(target_pid)) |result| {
        // Return exit code in x0, pid in x1
        frame.x1 = result.pid;
        return result.exit_code;
    }

    // No zombie child yet - block and wait
    scheduler.blockCurrent(.blocked_wait);
    return SYSCALL_BLOCKED;
}

// Static send buffer to avoid stack issues with struct initialization
var send_msg_buf: ipc.Message = .{
    .op = 0,
    .arg0 = 0,
    .arg1 = 0,
    .arg2 = 0,
    .arg3 = 0,
    .sender = .invalid,
    .reply_to = .invalid,
    .badge = 0,
};

/// Send message to a port
/// x0 = port_id, x1 = op, x2 = arg0, x3 = arg1
fn sysSend(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    const endpoint = ipc.EndpointId.fromRaw(port_id);

    // Fill static buffer field by field
    send_msg_buf.op = @truncate(frame.x1);
    send_msg_buf.arg0 = frame.x2;
    send_msg_buf.arg1 = frame.x3;
    send_msg_buf.arg2 = 0;
    send_msg_buf.arg3 = 0;
    send_msg_buf.sender = .invalid;
    send_msg_buf.reply_to = .invalid;
    send_msg_buf.badge = 0;

    ipc.send(endpoint, &send_msg_buf) catch |err| {
        return switch (err) {
            ipc.IpcError.InvalidEndpoint, ipc.IpcError.EndpointClosed => @intFromEnum(Error.INVALID_PORT),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };

    return 0;
}

// Static receive buffer to avoid stack issues with struct initialization
var recv_msg_buf: ipc.Message = .{
    .op = 0,
    .arg0 = 0,
    .arg1 = 0,
    .arg2 = 0,
    .arg3 = 0,
    .sender = .invalid,
    .reply_to = .invalid,
    .badge = 0,
};

/// Receive message from a port
/// x0 = port_id, returns: x0 = op, x1 = arg0, x2 = arg1
fn sysRecv(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    const endpoint = ipc.EndpointId.fromRaw(port_id);

    // Clear the static buffer
    recv_msg_buf.op = 0;
    recv_msg_buf.arg0 = 0;
    recv_msg_buf.arg1 = 0;
    recv_msg_buf.arg2 = 0;
    recv_msg_buf.arg3 = 0;
    recv_msg_buf.sender = .invalid;
    recv_msg_buf.reply_to = .invalid;
    recv_msg_buf.badge = 0;

    // Try to receive - if no message available, register as waiting and block
    const result = ipc.tryReceive(endpoint, &recv_msg_buf);

    // Check for errors
    if (result == .invalid_endpoint or result == .endpoint_closed) {
        return @intFromEnum(Error.INVALID_PORT);
    }

    if (result == .no_message) {
        // Register as waiting receiver so sender can find us
        // Pass the frame pointer so sender can set return values directly
        ipc.registerWaitingReceiver(endpoint, &recv_msg_buf, frame);
        scheduler.blockCurrent(.blocked_ipc);
        // When the sender delivers a message, it will:
        // 1. Copy message to recv_msg_buf
        // 2. Set frame.x0/x1/x2 with return values directly
        // 3. Unblock this thread
        // Return SYSCALL_BLOCKED to tell dispatch() not to overwrite frame.x0
        return SYSCALL_BLOCKED;
    }

    // Got a message immediately (sender was waiting)
    frame.x1 = recv_msg_buf.arg0;
    frame.x2 = recv_msg_buf.arg1;
    return @intCast(recv_msg_buf.op);
}

/// Send and wait for reply (RPC style)
/// x0 = port_id, x1 = op, x2 = arg0, x3 = arg1
/// Returns: x0 = reply op, x1 = reply arg0, x2 = reply arg1
fn sysCall(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    const endpoint = ipc.EndpointId.fromRaw(port_id);

    // Create request message
    var msg = ipc.Message.init(@truncate(frame.x1));
    msg.arg0 = frame.x2;
    msg.arg1 = frame.x3;

    // Do RPC call - blocks until reply received
    const result = ipc.call(endpoint, &msg);
    if (result) |reply| {
        frame.x1 = reply.arg0;
        frame.x2 = reply.arg1;
        return @intCast(reply.op);
    } else |err| {
        return switch (err) {
            ipc.IpcError.InvalidEndpoint, ipc.IpcError.EndpointClosed => @intFromEnum(Error.INVALID_PORT),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    }
}

/// Reply to a received message
/// x0 = sender_tid (from received message), x1 = op, x2 = arg0, x3 = arg1
fn sysReply(frame: *SyscallFrame) i64 {
    const sender_tid: u32 = @truncate(frame.x0);

    // Create reply message
    var reply = ipc.Message.init(@truncate(frame.x1));
    reply.arg0 = frame.x2;
    reply.arg1 = frame.x3;

    // Send reply to the waiting caller
    ipc.reply(ipc.EndpointId.fromRaw(sender_tid), &reply) catch |err| {
        return switch (err) {
            ipc.IpcError.InvalidEndpoint => @intFromEnum(Error.NOT_FOUND),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };

    return 0;
}

/// Create a new IPC port
fn sysPortCreate() i64 {
    const endpoint = ipc.createEndpoint() catch |err| {
        return switch (err) {
            ipc.IpcError.OutOfEndpoints => @intFromEnum(Error.NO_MEMORY),
            else => @intFromEnum(Error.INVALID_ARGUMENT),
        };
    };
    return @intCast(endpoint.raw());
}

/// Destroy an IPC port
fn sysPortDestroy(frame: *SyscallFrame) i64 {
    const port_id: u32 = @truncate(frame.x0);
    ipc.destroyEndpoint(ipc.EndpointId.fromRaw(port_id));
    return 0;
}

// ============================================================
// Memory Management Syscalls
// ============================================================

const mmu = root.mmu;

/// Well-known device regions that can be mapped (whitelist for security)
const DeviceRegion = struct {
    phys: u64,
    size: u64,
};

/// Allowed device regions (QEMU virt machine)
const ALLOWED_DEVICES = [_]DeviceRegion{
    // VirtIO MMIO devices: 32 slots, 512 bytes each = 0x4000 bytes total
    // Range: 0x0a000000 - 0x0a003fff
    .{ .phys = 0x0a000000, .size = 0x4000 }, // VirtIO device region
    // GIC (for interrupt management)
    .{ .phys = 0x08000000, .size = 0x20000 }, // GIC distributor + CPU interface
    // UART (already mapped, but drivers might want it)
    .{ .phys = 0x09000000, .size = 0x1000 }, // PL011 UART
};

/// Fixed virtual base for device mappings in user space
const USER_DEVICE_BASE: u64 = 0x10000000; // 256MB mark

/// Map device MMIO region into user address space
/// x0 = physical address
/// x1 = size
/// Returns: virtual address on success, negative error on failure
fn sysMapDevice(frame: *SyscallFrame) i64 {
    const phys = frame.x0;
    const size = frame.x1;

    // Validate this is an allowed device region
    var allowed = false;
    for (ALLOWED_DEVICES) |dev| {
        if (phys >= dev.phys and phys + size <= dev.phys + dev.size) {
            allowed = true;
            break;
        }
    }

    if (!allowed) {
        return @intFromEnum(Error.NO_PERMISSION);
    }

    // Get current process
    const thread = scheduler.getCurrent() orelse return @intFromEnum(Error.INVALID_ARGUMENT);
    const proc = thread.process orelse return @intFromEnum(Error.INVALID_ARGUMENT);

    // Calculate virtual address: USER_DEVICE_BASE + offset from phys base
    // This creates a predictable mapping
    const virt = USER_DEVICE_BASE + (phys & 0x0FFFFFFF);

    // Map each page as device memory (uncached)
    var offset: u64 = 0;
    while (offset < size) : (offset += mmu.PAGE_SIZE) {
        const page_phys = phys + offset;
        const page_virt = virt + offset;

        // Map with device attributes, accessible from EL0
        const flags = mmu.PTE.VALID | mmu.PTE.PAGE | mmu.PTE.AF |
            mmu.PTE.ATTR_DEVICE | mmu.PTE.AP_RW_ALL | mmu.PTE.NG | mmu.PTE.PXN | mmu.PTE.UXN;

        if (!proc.address_space.mapRaw(page_virt, page_phys, flags)) {
            return @intFromEnum(Error.NO_MEMORY);
        }
    }

    // Invalidate TLB
    mmu.invalidateTlbAll();

    return @bitCast(virt);
}

/// Fixed virtual base for DMA allocations
const USER_DMA_BASE: u64 = 0x20000000; // 512MB mark
var dma_alloc_offset: u64 = 0;

/// Allocate DMA-capable memory (physically contiguous, uncached)
/// x0 = size (will be rounded up to page size)
/// Returns: virtual address in x0, physical address in x1
fn sysAllocDma(frame: *SyscallFrame) i64 {
    const memory = root.memory;

    const size = frame.x0;
    if (size == 0 or size > 16 * mmu.PAGE_SIZE) { // Max 64KB DMA allocation
        return @intFromEnum(Error.INVALID_ARGUMENT);
    }

    // Round up to page size
    const pages: u32 = @intCast((size + mmu.PAGE_SIZE - 1) / mmu.PAGE_SIZE);

    // Get current process
    const thread = scheduler.getCurrent() orelse return @intFromEnum(Error.INVALID_ARGUMENT);
    const proc = thread.process orelse return @intFromEnum(Error.INVALID_ARGUMENT);

    // Allocate physically contiguous pages
    const phys = memory.allocContiguous(pages) orelse return @intFromEnum(Error.NO_MEMORY);

    // Track memory for cleanup
    _ = proc.trackMemory(phys, pages);

    // Calculate virtual address
    const virt = USER_DMA_BASE + dma_alloc_offset;
    dma_alloc_offset += @as(u64, pages) * mmu.PAGE_SIZE;

    // Map as uncached (device-like) memory for DMA coherency
    var offset: u64 = 0;
    while (offset < @as(u64, pages) * mmu.PAGE_SIZE) : (offset += mmu.PAGE_SIZE) {
        const page_phys = phys + offset;
        const page_virt = virt + offset;

        // Use non-cacheable normal memory for DMA
        const flags = mmu.PTE.VALID | mmu.PTE.PAGE | mmu.PTE.AF |
            mmu.PTE.ATTR_NORMAL_NC | mmu.PTE.AP_RW_ALL | mmu.PTE.NG |
            mmu.PTE.SH_INNER | mmu.PTE.PXN | mmu.PTE.UXN;

        if (!proc.address_space.mapRaw(page_virt, page_phys, flags)) {
            // Cleanup on failure
            memory.freePages(phys, pages);
            return @intFromEnum(Error.NO_MEMORY);
        }
    }

    // Invalidate TLB
    mmu.invalidateTlbAll();

    // Return virtual in x0, physical in x1
    frame.x1 = phys;
    return @bitCast(virt);
}

/// Get physical address for a virtual address
/// x0 = virtual address
/// Returns: physical address, or negative error
fn sysGetPhys(frame: *SyscallFrame) i64 {
    const virt = frame.x0;

    // For our simple DMA allocations, we can compute this directly
    // DMA region: virt = USER_DMA_BASE + offset, phys = allocation_base + offset
    // But we need to walk page tables for general case

    // Get current process
    const thread = scheduler.getCurrent() orelse return @intFromEnum(Error.INVALID_ARGUMENT);
    const proc = thread.process orelse return @intFromEnum(Error.INVALID_ARGUMENT);

    // Walk the page tables to find physical address
    const l0: *mmu.PageTable = @ptrFromInt(proc.address_space.root);

    const l0_idx = (virt >> 39) & 0x1FF;
    const l1_idx = (virt >> 30) & 0x1FF;
    const l2_idx = (virt >> 21) & 0x1FF;
    const l3_idx = (virt >> 12) & 0x1FF;
    const page_offset = virt & 0xFFF;

    var entry = l0.entries[l0_idx];
    if ((entry & mmu.PTE.VALID) == 0) return @intFromEnum(Error.INVALID_ARGUMENT);

    const l1: *mmu.PageTable = @ptrFromInt(entry & mmu.PTE.ADDR_MASK);
    entry = l1.entries[l1_idx];
    if ((entry & mmu.PTE.VALID) == 0) return @intFromEnum(Error.INVALID_ARGUMENT);

    const l2: *mmu.PageTable = @ptrFromInt(entry & mmu.PTE.ADDR_MASK);
    entry = l2.entries[l2_idx];
    if ((entry & mmu.PTE.VALID) == 0) return @intFromEnum(Error.INVALID_ARGUMENT);

    const l3: *mmu.PageTable = @ptrFromInt(entry & mmu.PTE.ADDR_MASK);
    entry = l3.entries[l3_idx];
    if ((entry & mmu.PTE.VALID) == 0) return @intFromEnum(Error.INVALID_ARGUMENT);

    const phys_page = entry & mmu.PTE.ADDR_MASK;
    return @bitCast(phys_page | page_offset);
}

/// Debug print (for kernel threads)
/// x0 = string pointer, x1 = length
fn sysDebugPrint(frame: *SyscallFrame) i64 {
    const ptr: [*]const u8 = @ptrFromInt(frame.x0);
    const len: usize = @truncate(frame.x1);

    // Safety: limit length
    const safe_len = if (len > 256) 256 else len;

    // Print character by character
    for (ptr[0..safe_len]) |c| {
        console.putc(c);
    }

    return @intCast(safe_len);
}

/// Get timer tick count
fn sysGetTicks() i64 {
    const interrupt = root.interrupt;
    return @intCast(interrupt.getTimerTicks());
}

// ============================================================
// Console I/O Syscalls
// ============================================================

/// Write to console
/// x0 = buffer pointer (user virtual address)
/// x1 = length
/// Returns: number of bytes written, or negative error
fn sysWrite(frame: *SyscallFrame) i64 {
    const buf_addr = frame.x0;
    const len = frame.x1;

    // Validate length
    if (len == 0) return 0;
    const safe_len: usize = if (len > 4096) 4096 else @truncate(len);

    // Validate address is in user range
    if (buf_addr < 0x10000 or buf_addr > 0x8000_0000_0000) {
        return @intFromEnum(Error.INVALID_ARGUMENT);
    }

    const ptr: [*]const u8 = @ptrFromInt(buf_addr);

    // Write each character to console
    var written: usize = 0;
    while (written < safe_len) : (written += 1) {
        console.putc(ptr[written]);
    }

    return @intCast(written);
}

/// Read from console
/// x0 = buffer pointer (user virtual address)
/// x1 = max length
/// Returns: number of bytes read, or negative error
fn sysRead(frame: *SyscallFrame) i64 {
    const buf_addr = frame.x0;
    const max_len = frame.x1;

    // Validate length
    if (max_len == 0) return 0;
    const safe_len: usize = if (max_len > 4096) 4096 else @truncate(max_len);

    // Validate address is in user range
    if (buf_addr < 0x10000 or buf_addr > 0x8000_0000_0000) {
        return @intFromEnum(Error.INVALID_ARGUMENT);
    }

    const ptr: [*]u8 = @ptrFromInt(buf_addr);

    // Non-blocking read from UART
    var read_count: usize = 0;
    while (read_count < safe_len) {
        if (console.tryGetc()) |c| {
            ptr[read_count] = c;
            read_count += 1;
            if (c == '\n') break;
        } else {
            break;
        }
    }

    return @intCast(read_count);
}

// ============================================================
// Syscall Helper for Kernel Threads
// ============================================================

/// Helper to make syscalls from kernel threads (inline assembly)
pub inline fn syscall0(num: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
        : "memory"
    );
    return ret;
}

pub inline fn syscall1(num: u64, arg0: u64) i64 {
    var ret: i64 = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [num] "{x8}" (num),
          [arg0] "{x0}" (arg0),
        : "memory"
    );
    return ret;
}

pub inline fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
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

// ============================================================
// User-Friendly Wrappers
// ============================================================

pub fn yield() void {
    _ = syscall0(SYS.YIELD);
}

pub fn exit() noreturn {
    _ = syscall0(SYS.EXIT);
    unreachable;
}

pub fn getTid() u32 {
    return @intCast(@as(u64, @bitCast(syscall0(SYS.GETTID))));
}

pub fn getTicks() u64 {
    return @bitCast(syscall0(SYS.GET_TICKS));
}
