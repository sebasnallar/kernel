// MyLittleKernel - Process Scheduler
//
// Priority-based preemptive scheduler for the microkernel.
// Handles:
//   - Thread/Process management
//   - Priority-based scheduling
//   - Context switching (ARM64)
//   - Preemption via timer

const root = @import("root");
const context = root.context;
const memory = root.memory;
const mmu = root.mmu;

// ============================================================
// Types
// ============================================================

/// Thread state
pub const State = enum {
    ready, // Can run
    running, // Currently executing
    blocked_ipc, // Waiting for IPC
    blocked_wait, // Waiting for resource
    dead, // Terminated
};

/// Priority levels (0 = highest)
pub const Priority = enum(u8) {
    realtime = 0, // Critical, interrupt handlers
    high = 1, // System services
    normal = 2, // Normal tasks
    low = 3, // Background
    idle = 4, // Only when nothing else
};

/// Process ID
pub const Pid = u32;

/// Thread ID
pub const Tid = u32;

/// ARM64 saved context
pub const CpuContext = struct {
    // Callee-saved registers (x19-x30)
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0, // Frame pointer
    x30: u64 = 0, // Link register (return address)
    sp: u64 = 0, // Stack pointer
    pc: u64 = 0, // Entry point (for new threads)
};

/// Thread Control Block
pub const Thread = struct {
    tid: Tid,
    state: State,
    priority: Priority,
    context: CpuContext,

    // Scheduling
    time_slice: u32,
    total_runtime: u64,

    // Stack
    stack_base: u64, // Base address of allocated stack (physical)
    stack_size: u32, // Size in bytes

    // Queue linkage
    next: ?*Thread,
    prev: ?*Thread,

    // Associated process (null for kernel threads)
    process: ?*Process,

    // True if thread hasn't started executing yet
    first_run: bool,

    // Userspace support (EL0)
    is_user: bool, // True if this runs in EL0 (userspace)
    user_sp: u64, // User stack pointer (SP_EL0)
    kernel_sp: u64, // Kernel stack for syscall/exception handling

    // Resource tracking for cleanup
    kernel_stack_base: u64, // Physical address of kernel stack (for freeing)
};

/// Process state
pub const ProcessState = enum {
    running, // Process is active (has threads)
    zombie, // Process exited, waiting for parent to wait()
    dead, // Process fully cleaned up
};

/// Memory region descriptor for resource tracking
pub const MemoryRegion = struct {
    phys_base: u64, // Physical base address
    page_count: u32, // Number of pages
    in_use: bool, // Whether this slot is active
};

/// Maximum tracked memory regions per process
/// Following seL4/L4 approach: explicit resource tracking
const MAX_REGIONS_PER_PROCESS = 8;

/// Process Control Block
pub const Process = struct {
    pid: Pid,
    name: [32]u8,
    name_len: u8,

    // Virtual memory address space
    address_space: mmu.AddressSpace,

    // Thread list
    thread_count: u32,

    // Parent-child relationship
    parent_pid: ?Pid,

    // Process state and exit info
    state: ProcessState,
    exit_code: i32,

    // Resource tracking (L4/seL4 style - explicit resource management)
    // All physical memory owned by this process is tracked here
    memory_regions: [MAX_REGIONS_PER_PROCESS]MemoryRegion,

    /// Add a memory region to tracking
    pub fn trackMemory(self: *Process, phys: u64, pages: u32) bool {
        for (&self.memory_regions) |*region| {
            if (!region.in_use) {
                region.phys_base = phys;
                region.page_count = pages;
                region.in_use = true;
                return true;
            }
        }
        return false; // No free slots
    }

    /// Free all tracked memory regions
    pub fn freeAllMemory(self: *Process) void {
        for (&self.memory_regions) |*region| {
            if (region.in_use) {
                memory.freePages(region.phys_base, region.page_count);
                region.in_use = false;
            }
        }
    }
};

// ============================================================
// Scheduler State
// ============================================================

const NUM_PRIORITIES = 5;
const MAX_THREADS = 64; // Increased from 16
const MAX_PROCESSES = 32; // Increased from 8
const KERNEL_STACK_SIZE: u32 = 16384; // 16KB stack per kernel thread

/// Default empty memory region
const EMPTY_REGION = MemoryRegion{
    .phys_base = 0,
    .page_count = 0,
    .in_use = false,
};

/// Thread storage (zeroed, not undefined)
var threads: [MAX_THREADS]Thread = [_]Thread{Thread{
    .tid = 0,
    .state = .dead,
    .priority = .idle,
    .context = .{},
    .time_slice = 0,
    .total_runtime = 0,
    .stack_base = 0,
    .stack_size = 0,
    .next = null,
    .prev = null,
    .process = null,
    .first_run = false,
    .is_user = false,
    .user_sp = 0,
    .kernel_sp = 0,
    .kernel_stack_base = 0,
}} ** MAX_THREADS;
var thread_used: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS;

/// Process storage (zeroed)
var processes: [MAX_PROCESSES]Process = [_]Process{Process{
    .pid = 0,
    .name = [_]u8{0} ** 32,
    .name_len = 0,
    .address_space = .{ .root = 0, .asid = 0 },
    .thread_count = 0,
    .parent_pid = null,
    .state = .dead,
    .exit_code = 0,
    .memory_regions = [_]MemoryRegion{EMPTY_REGION} ** MAX_REGIONS_PER_PROCESS,
}} ** MAX_PROCESSES;
var process_used: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;

/// Ready queues (one per priority)
var ready_queues: [NUM_PRIORITIES]?*Thread = [_]?*Thread{null} ** NUM_PRIORITIES;

/// Currently running thread
var current: ?*Thread = null;

/// Idle thread
var idle_thread: *Thread = undefined;

/// ID counters
var next_tid: Tid = 1;
var next_pid: Pid = 1;

/// Scheduler initialized
var initialized: bool = false;

/// Reschedule pending (set in IRQ, checked on return from interrupt)
var need_reschedule: bool = false;

/// Whether kernel code has been remapped for userspace access
var kernel_code_user_accessible: bool = false;

// ============================================================
// Initialization
// ============================================================

/// Initialize the scheduler
pub fn init() void {
    // Create the idle thread (uses boot stack, no allocation needed)
    const thread = allocThread() orelse return;

    // Set fields individually to avoid SIMD/memset in freestanding mode
    idle_thread = thread;
    idle_thread.tid = 0;
    idle_thread.state = .running;
    idle_thread.priority = .idle;
    // Context fields set individually
    idle_thread.context.x19 = 0;
    idle_thread.context.x20 = 0;
    idle_thread.context.x21 = 0;
    idle_thread.context.x22 = 0;
    idle_thread.context.x23 = 0;
    idle_thread.context.x24 = 0;
    idle_thread.context.x25 = 0;
    idle_thread.context.x26 = 0;
    idle_thread.context.x27 = 0;
    idle_thread.context.x28 = 0;
    idle_thread.context.x29 = 0;
    idle_thread.context.x30 = 0;
    idle_thread.context.sp = 0;
    idle_thread.context.pc = 0;
    idle_thread.time_slice = 1;
    idle_thread.total_runtime = 0;
    idle_thread.stack_base = 0;
    idle_thread.stack_size = 0;
    idle_thread.next = null;
    idle_thread.prev = null;
    idle_thread.process = null;
    idle_thread.first_run = false;
    idle_thread.is_user = false;
    idle_thread.user_sp = 0;
    idle_thread.kernel_sp = 0;

    current = idle_thread;
    initialized = true;
}

// ============================================================
// Thread Management
// ============================================================

/// Allocate a thread slot
fn allocThread() ?*Thread {
    for (&threads, 0..) |*t, i| {
        if (!thread_used[i]) {
            thread_used[i] = true;
            return t;
        }
    }
    return null;
}

/// Free a thread slot
fn freeThread(thread: *Thread) void {
    const idx = (@intFromPtr(thread) - @intFromPtr(&threads)) / @sizeOf(Thread);
    if (idx < MAX_THREADS) {
        thread_used[idx] = false;
    }
}

/// Create a new kernel thread (runs in EL1 - full kernel privileges)
pub fn createKernelThread(entry: *const fn () void, priority: Priority) ?*Thread {
    const thread = allocThread() orelse return null;

    // Allocate stack (contiguous pages for 16KB)
    const stack_pages = KERNEL_STACK_SIZE / memory.PAGE_SIZE;
    const stack_base = memory.allocContiguous(stack_pages) orelse {
        freeThread(thread);
        return null;
    };
    const stack_top = stack_base + KERNEL_STACK_SIZE;

    // Initialize thread fields
    thread.tid = next_tid;
    thread.state = .ready;
    thread.priority = priority;
    thread.time_slice = getTimeSlice(priority);
    thread.total_runtime = 0;
    thread.stack_base = stack_base;
    thread.stack_size = KERNEL_STACK_SIZE;
    thread.next = null;
    thread.prev = null;
    thread.process = null;
    thread.first_run = true;
    thread.is_user = false;
    thread.user_sp = 0;
    thread.kernel_sp = 0;

    // Initialize CPU context for first execution
    context.initContext(&thread.context, @intFromPtr(entry), stack_top);

    next_tid += 1;

    // Add to ready queue
    enqueue(thread);

    return thread;
}

/// Make kernel code region accessible to userspace (for embedded test threads)
/// This is a one-time operation that remaps the first 1MB of kernel memory
/// to allow EL0 access. Only needed because test threads are in the kernel binary.
fn makeKernelCodeUserAccessible() void {
    if (kernel_code_user_accessible) return; // Already done

    const boot = @import("root").boot;
    var code_addr: u64 = boot.MEMORY_BASE;
    const code_end = boot.MEMORY_BASE + 1 * 1024 * 1024; // First 1MB
    var count: u32 = 0;

    console.puts("  Remapping kernel code for user access");

    while (code_addr < code_end) : (code_addr += memory.PAGE_SIZE) {
        if (!mmu.mapKernelPageRaw(code_addr, code_addr, mmu.PTE.SHARED_RWX)) {
            console.puts(" FAILED\n");
            return;
        }
        count += 1;
        if (count % 64 == 0) {
            console.putc('.');
        }
    }
    console.newline();

    mmu.invalidateTlbAll();
    kernel_code_user_accessible = true;
}

/// Create a new user thread (runs in EL0 - restricted userspace)
/// Entry function runs with limited privileges - must use syscalls for kernel services
pub fn createUserThread(entry: *const fn () void, priority: Priority) ?*Thread {
    const thread = allocThread() orelse return null;

    const stack_pages = KERNEL_STACK_SIZE / memory.PAGE_SIZE;

    // Allocate USER stack (where the thread runs)
    const user_stack_base = memory.allocContiguous(stack_pages) orelse {
        freeThread(thread);
        return null;
    };
    const user_stack_top = user_stack_base + KERNEL_STACK_SIZE;

    // Map user stack pages with SHARED_RWX permissions (allows both EL0 and EL1 access)
    if (mmu.isInitialized()) {
        var addr: u64 = user_stack_base;
        while (addr < user_stack_top) : (addr += memory.PAGE_SIZE) {
            if (!mmu.mapKernelPageRaw(addr, addr, mmu.PTE.SHARED_RWX)) {
                memory.freePages(user_stack_base, stack_pages);
                freeThread(thread);
                return null;
            }
        }
        // Invalidate TLB for new stack mappings
        mmu.invalidateTlbAll();

        // Make kernel code region user-accessible (only done once)
        // TODO: This causes issues - skipping for now
        // makeKernelCodeUserAccessible();
    }

    // Allocate KERNEL stack (for handling syscalls/exceptions)
    const kernel_stack_base = memory.allocContiguous(stack_pages) orelse {
        memory.freePages(user_stack_base, stack_pages);
        freeThread(thread);
        return null;
    };
    const kernel_stack_top = kernel_stack_base + KERNEL_STACK_SIZE;

    // Initialize thread fields
    thread.tid = next_tid;
    thread.state = .ready;
    thread.priority = priority;
    thread.time_slice = getTimeSlice(priority);
    thread.total_runtime = 0;
    thread.stack_base = user_stack_base;
    thread.stack_size = KERNEL_STACK_SIZE;
    thread.next = null;
    thread.prev = null;
    thread.process = null;
    thread.first_run = true;
    thread.is_user = true;
    thread.user_sp = user_stack_top;
    thread.kernel_sp = kernel_stack_top;

    // Initialize CPU context - entry point and kernel stack
    // The actual EL0 drop happens via ERET in context switch
    context.initUserContext(&thread.context, @intFromPtr(entry), kernel_stack_top, user_stack_top);

    next_tid += 1;

    // Add to ready queue
    enqueue(thread);

    return thread;
}

/// Get time slice for priority
fn getTimeSlice(priority: Priority) u32 {
    return switch (priority) {
        .realtime => 100,
        .high => 50,
        .normal => 20,
        .low => 10,
        .idle => 1,
    };
}

// ============================================================
// Scheduling
// ============================================================

/// Set the need_reschedule flag (for syscalls that want to yield)
pub fn setNeedReschedule() void {
    need_reschedule = true;
}

/// Add thread to ready queue
pub fn enqueue(thread: *Thread) void {
    const qi = @intFromEnum(thread.priority);
    thread.state = .ready;
    thread.next = null;

    if (ready_queues[qi]) |head| {
        // Find tail
        var tail = head;
        while (tail.next) |n| {
            tail = n;
        }
        tail.next = thread;
        thread.prev = tail;
    } else {
        ready_queues[qi] = thread;
        thread.prev = null;
    }
}

/// Remove thread from ready queue
fn dequeue(thread: *Thread) void {
    const qi = @intFromEnum(thread.priority);

    if (thread.prev) |p| {
        p.next = thread.next;
    } else {
        ready_queues[qi] = thread.next;
    }

    if (thread.next) |n| {
        n.prev = thread.prev;
    }

    thread.next = null;
    thread.prev = null;
}

/// Pick next thread to run
pub fn schedule() void {
    if (!initialized) return;

    // Find highest priority ready thread
    var qi: usize = 0;
    while (qi < NUM_PRIORITIES) : (qi += 1) {
        if (ready_queues[qi]) |thread| {
            // Remove from queue
            ready_queues[qi] = thread.next;
            if (thread.next) |n| {
                n.prev = null;
            }
            thread.next = null;

            // Switch to it
            switchTo(thread);
            return;
        }
    }

    // Nothing ready - run idle
    switchTo(idle_thread);
}

const console = root.console;

/// Switch to a thread
fn switchTo(thread: *Thread) void {
    if (current == thread) return;

    const old = current;
    current = thread;
    thread.state = .running;

    // Handle address space switching for user threads
    if (thread.is_user and thread.process != null) {
        // Switch to the new process's address space
        switchToProcessAddressSpace(thread.process.?);
    } else if (old != null and old.?.is_user and old.?.process != null) {
        // Switching from user to kernel thread - restore kernel address space
        switchToKernelAddressSpace();
    }

    if (old) |o| {
        if (thread.first_run) {
            // First time running this thread
            thread.first_run = false;

            if (thread.is_user) {
                // User thread: drop to EL0 via ERET
                context.startUserThreadInline(
                    &o.context,
                    thread.context.pc, // Entry point
                    thread.user_sp, // User stack (SP_EL0)
                    thread.kernel_sp, // Kernel stack (SP_EL1)
                );
            } else {
                // Kernel thread: normal branch to entry
                context.switchToNewInline(&o.context, &thread.context);
            }
            // Returns here when old thread is scheduled again (via switchContext)
        } else {
            // Normal context switch - save old, restore new
            // This works for both kernel and user threads (user threads save
            // their state in exception handlers before getting here)
            context.switchContext(&o.context, &thread.context);
            // Returns here when old thread is scheduled again
        }
    } else {
        // No old thread (shouldn't happen normally)
        if (thread.first_run) {
            thread.first_run = false;
            context.startThread(&thread.context);
        }
    }
}

/// Yield current thread's time slice
pub fn yield() void {
    if (current) |c| {
        if (c != idle_thread) {
            enqueue(c);
        }
        schedule();
    }
}

/// Block current thread
/// For EL0 threads, we just set the state and flag for reschedule.
/// The actual schedule() will happen after the syscall handler returns.
pub fn blockCurrent(reason: State) void {
    if (current) |c| {
        c.state = reason;
        // Set flag for reschedule - checkReschedule() will call schedule()
        // after the exception handler returns. This is necessary because
        // we can't context switch from within a syscall handler directly.
        need_reschedule = true;
    }
}

/// Unblock a thread
pub fn unblock(thread: *Thread) void {
    if (thread.state == .blocked_ipc or thread.state == .blocked_wait) {
        enqueue(thread);
    }
}

/// Timer tick - called from interrupt handler
/// Only sets flags; actual context switch happens after IRQ returns
pub fn timerTick() void {
    if (!initialized) return;

    if (current) |c| {
        c.total_runtime += 1;

        if (c == idle_thread) {
            // Idle thread: always check if real work is available
            need_reschedule = true;
        } else {
            // Normal thread: decrement time slice
            if (c.time_slice > 0) {
                c.time_slice -= 1;
            }

            // Time slice expired: mark for reschedule
            // Note: Don't enqueue here - yield() will do it when the thread
            // cooperatively yields or when we properly implement preemption
            if (c.time_slice == 0) {
                c.time_slice = getTimeSlice(c.priority);
                need_reschedule = true;
            }
        }
    }
}

/// Check if reschedule is needed (called after returning from interrupt)
/// This puts the current thread back in the ready queue before scheduling
pub fn checkReschedule() void {
    if (need_reschedule) {
        need_reschedule = false;
        // Put current thread back in ready queue (unless it's idle or blocked)
        if (current) |c| {
            if (c != idle_thread and c.state == .running) {
                enqueue(c);
            }
        }
        schedule();
    }
}

/// Debug: check ready queue state
pub fn debugReadyQueues() void {
    console.puts("[DBG] Ready queues: ");
    var qi: usize = 0;
    while (qi < NUM_PRIORITIES) : (qi += 1) {
        if (ready_queues[qi]) |thread| {
            console.puts("Q");
            console.putDec(@intCast(qi));
            console.puts(":TID");
            console.putDec(thread.tid);
            console.puts(" ");
        }
    }
    console.newline();
}

/// Get current thread
pub fn getCurrent() ?*Thread {
    return current;
}

/// Get thread count
pub fn getThreadCount() u32 {
    var count: u32 = 0;
    for (thread_used) |used| {
        if (used) count += 1;
    }
    return count;
}

// ============================================================
// Process Management (Per-Process Address Spaces)
// ============================================================

const user_program = root.user_program;

/// Allocate a process slot
fn allocProcess() ?*Process {
    for (&processes, 0..) |*p, i| {
        if (!process_used[i]) {
            process_used[i] = true;
            return p;
        }
    }
    return null;
}

/// Free a process slot
fn freeProcess(proc: *Process) void {
    const idx = (@intFromPtr(proc) - @intFromPtr(&processes)) / @sizeOf(Process);
    if (idx < MAX_PROCESSES) {
        process_used[idx] = false;
    }
}

/// Create a new user process with its own address space
/// code: machine code to copy into user space
/// code_len: length of code in bytes
/// Returns the main thread of the process
pub fn createUserProcess(code: []const u8, priority: Priority) ?*Thread {
    const boot = root.boot;

    // Step 1: Allocate process structure
    const proc = allocProcess() orelse return null;

    // Step 2: Create address space for the process
    const addr_space = mmu.AddressSpace.create() orelse {
        freeProcess(proc);
        return null;
    };

    // Step 2.5: Map kernel code/data in user address space (kernel-only permissions)
    // This is necessary because TTBR0 is used for all low addresses, including kernel
    // The kernel is identity-mapped at 0x40000000
    var addr_space_init = addr_space;
    var kaddr: u64 = boot.MEMORY_BASE;
    const kend = boot.MEMORY_BASE + 4 * 1024 * 1024; // 4MB kernel region
    while (kaddr < kend) : (kaddr += memory.PAGE_SIZE) {
        if (!addr_space_init.mapRaw(kaddr, kaddr, mmu.PTE.KERNEL_RWX)) {
            freeProcess(proc);
            return null;
        }
    }
    // Also map device memory (UART, GIC)
    _ = addr_space_init.mapRaw(boot.UART_BASE, boot.UART_BASE, mmu.PTE.DEVICE_RW);
    _ = addr_space_init.mapRaw(boot.GIC_DIST_BASE, boot.GIC_DIST_BASE, mmu.PTE.DEVICE_RW);
    _ = addr_space_init.mapRaw(boot.GIC_CPU_BASE, boot.GIC_CPU_BASE, mmu.PTE.DEVICE_RW);

    // Step 3: Allocate physical pages for user code
    const code_pages = (code.len + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE;
    const code_pages_count = if (code_pages == 0) 1 else code_pages;
    const code_phys = memory.allocContiguousRaw(code_pages_count);
    if (code_phys == 0) {
        freeProcess(proc);
        return null;
    }

    // Step 4: Copy code to physical memory
    const code_ptr: [*]u8 = @ptrFromInt(code_phys);
    for (code, 0..) |byte, i| {
        code_ptr[i] = byte;
    }

    // Step 5: Map code in user address space at USER_CODE_BASE
    if (!addr_space_init.mapRangeRaw(
        user_program.USER_CODE_BASE,
        code_phys,
        code_pages_count * memory.PAGE_SIZE,
        mmu.PTE.USER_RWX,
    )) {
        memory.freePages(code_phys, code_pages_count);
        freeProcess(proc);
        return null;
    }

    // Step 6: Allocate and map user stack
    const stack_pages = user_program.USER_STACK_SIZE / memory.PAGE_SIZE;
    const stack_phys = memory.allocContiguousRaw(stack_pages);
    if (stack_phys == 0) {
        memory.freePages(code_phys, code_pages_count);
        freeProcess(proc);
        return null;
    }

    // Map stack at USER_STACK_BASE - USER_STACK_SIZE (stack grows down)
    const stack_virt_base = user_program.USER_STACK_BASE - user_program.USER_STACK_SIZE;
    if (!addr_space_init.mapRangeRaw(
        stack_virt_base,
        stack_phys,
        user_program.USER_STACK_SIZE,
        mmu.PTE.USER_RW,
    )) {
        memory.freePages(stack_phys, stack_pages);
        memory.freePages(code_phys, code_pages_count);
        freeProcess(proc);
        return null;
    }

    // Step 7: Initialize process structure
    proc.pid = next_pid;
    proc.name = [_]u8{0} ** 32;
    proc.name_len = 0;
    proc.address_space = addr_space_init;
    proc.thread_count = 0;
    proc.parent_pid = null;
    proc.state = .running;
    proc.exit_code = 0;
    // Clear and initialize memory tracking (L4/seL4 style resource management)
    for (&proc.memory_regions) |*region| {
        region.* = EMPTY_REGION;
    }
    // Track allocated memory - code and stack owned by this process
    _ = proc.trackMemory(code_phys, @intCast(code_pages_count));
    _ = proc.trackMemory(stack_phys, @intCast(stack_pages));
    next_pid += 1;

    // Step 8: Create the main thread for this process
    const thread = allocThread() orelse {
        memory.freePages(stack_phys, stack_pages);
        memory.freePages(code_phys, code_pages_count);
        freeProcess(proc);
        return null;
    };

    // Allocate kernel stack (for syscall/exception handling)
    const kernel_stack_pages = KERNEL_STACK_SIZE / memory.PAGE_SIZE;
    const kernel_stack_base = memory.allocContiguous(kernel_stack_pages) orelse {
        freeThread(thread);
        memory.freePages(stack_phys, stack_pages);
        memory.freePages(code_phys, code_pages_count);
        freeProcess(proc);
        return null;
    };
    const kernel_stack_top = kernel_stack_base + KERNEL_STACK_SIZE;

    // Initialize thread fields
    thread.tid = next_tid;
    thread.state = .ready;
    thread.priority = priority;
    thread.time_slice = getTimeSlice(priority);
    thread.total_runtime = 0;
    thread.stack_base = stack_phys; // Physical address of user stack
    thread.stack_size = @intCast(user_program.USER_STACK_SIZE);
    thread.next = null;
    thread.prev = null;
    thread.process = proc;
    thread.first_run = true;
    thread.is_user = true;
    thread.user_sp = user_program.USER_STACK_BASE; // Virtual user stack top
    thread.kernel_sp = kernel_stack_top;
    thread.kernel_stack_base = kernel_stack_base; // Track for cleanup

    // Track kernel stack in process memory (so it gets freed on process exit)
    _ = proc.trackMemory(kernel_stack_base, @intCast(kernel_stack_pages));

    // Initialize CPU context
    context.initUserContext(
        &thread.context,
        user_program.USER_CODE_BASE, // Entry point in user VA
        kernel_stack_top,
        user_program.USER_STACK_BASE,
    );

    next_tid += 1;
    proc.thread_count = 1;

    // Add to ready queue
    enqueue(thread);

    return thread;
}

/// Switch to a user process's address space
/// Called before context switching to a user thread
pub fn switchToProcessAddressSpace(proc: *const Process) void {
    if (!mmu.isInitialized()) return;
    mmu.switchAddressSpace(&proc.address_space);
}

/// Switch back to kernel address space (no user mappings)
/// Called after context switching away from a user thread
pub fn switchToKernelAddressSpace() void {
    if (!mmu.isInitialized()) return;
    // Set TTBR0 to kernel page table (identity mapping)
    mmu.writeTtbr0(mmu.getKernelRoot());
    asm volatile ("isb");
}

// ============================================================
// Process Lifecycle
// ============================================================

/// Terminate the current process with an exit code
/// Marks all threads as dead, puts process in zombie state
pub fn exitProcess(exit_code: i32) void {
    const curr = current orelse return;
    const proc = curr.process orelse return;

    // Mark all threads belonging to this process as dead
    for (&threads, 0..) |*t, i| {
        if (thread_used[i] and t.process == proc) {
            t.state = .dead;
        }
    }

    // Put process in zombie state (waiting for parent to collect exit code)
    proc.state = .zombie;
    proc.exit_code = exit_code;

    // Wake up parent if it's waiting on us
    if (proc.parent_pid) |ppid| {
        if (findProcess(ppid)) |parent_proc| {
            _ = parent_proc; // Parent might have a waiting thread
            // Wake up any thread waiting on this child
            for (&threads, 0..) |*t, i| {
                if (thread_used[i] and t.process != null) {
                    if (t.process.?.pid == ppid and t.state == .blocked_wait) {
                        unblock(t);
                    }
                }
            }
        }
    }

    // Schedule another process
    setNeedReschedule();
}

/// Wait for a child process to exit
/// Returns the exit code, or error if no children
pub const WaitResult = struct {
    pid: Pid,
    exit_code: i32,
};

pub fn waitForChild(target_pid: ?Pid) ?WaitResult {
    const curr = current orelse return null;
    const proc = curr.process orelse return null;
    const my_pid = proc.pid;

    // Find a zombie child
    for (&processes, 0..) |*p, i| {
        if (process_used[i] and p.parent_pid == my_pid) {
            // Found a child
            if (target_pid == null or target_pid == p.pid) {
                if (p.state == .zombie) {
                    // Collect the zombie
                    const result = WaitResult{
                        .pid = p.pid,
                        .exit_code = p.exit_code,
                    };
                    // Clean up the process
                    cleanupProcess(p);
                    return result;
                }
            }
        }
    }

    return null; // No zombie children found
}

/// Check if current process has any children
pub fn hasChildren() bool {
    const curr = current orelse return false;
    const proc = curr.process orelse return false;
    const my_pid = proc.pid;

    for (&processes, 0..) |*p, i| {
        if (process_used[i] and p.parent_pid == my_pid) {
            return true;
        }
    }
    return false;
}

/// Find a process by PID
pub fn findProcess(pid: Pid) ?*Process {
    for (&processes, 0..) |*p, i| {
        if (process_used[i] and p.pid == pid) {
            return p;
        }
    }
    return null;
}

/// Clean up a zombie process (free all resources)
/// Following L4/seL4 design: explicit resource tracking and deallocation
fn cleanupProcess(proc: *Process) void {
    // Free all tracked memory regions (code, stack, kernel stack)
    // This is the key fix - we now properly free all process memory
    proc.freeAllMemory();

    // Destroy address space (frees page tables and ASID)
    var addr_space = proc.address_space;
    addr_space.destroy();

    // Mark as fully dead and free the PCB slot
    proc.state = .dead;
    freeProcess(proc);
}

/// Create a user process with a specified parent
pub fn createUserProcessWithParent(code: []const u8, priority: Priority, parent_pid: ?Pid) ?*Thread {
    const thread = createUserProcess(code, priority) orelse return null;
    if (thread.process) |proc| {
        proc.parent_pid = parent_pid;
    }
    return thread;
}
