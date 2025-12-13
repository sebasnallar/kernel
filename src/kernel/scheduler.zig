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
    stack_base: u64, // Base address of allocated stack
    stack_size: u32, // Size in bytes

    // Queue linkage
    next: ?*Thread,
    prev: ?*Thread,

    // Associated process (null for kernel threads)
    process: ?*Process,

    // True if thread hasn't started executing yet
    first_run: bool,
};

/// Process Control Block
pub const Process = struct {
    pid: Pid,
    name: [32]u8,
    name_len: u8,

    // Memory space
    page_table_root: u64,

    // Thread list
    thread_count: u32,

    // Parent
    parent_pid: ?Pid,
};

// ============================================================
// Scheduler State
// ============================================================

const NUM_PRIORITIES = 5;
const MAX_THREADS = 16; // Keep small for now
const MAX_PROCESSES = 8;
const KERNEL_STACK_SIZE: u32 = 4096; // 4KB stack per kernel thread

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
}} ** MAX_THREADS;
var thread_used: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS;

/// Process storage (zeroed)
var processes: [MAX_PROCESSES]Process = [_]Process{Process{
    .pid = 0,
    .name = [_]u8{0} ** 32,
    .name_len = 0,
    .page_table_root = 0,
    .thread_count = 0,
    .parent_pid = null,
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

// ============================================================
// Initialization
// ============================================================

/// Initialize the scheduler
pub fn init() void {
    // Clear all thread slots
    for (&thread_used) |*used| {
        used.* = false;
    }

    // Clear all process slots
    for (&process_used) |*used| {
        used.* = false;
    }

    // Clear ready queues
    for (&ready_queues) |*q| {
        q.* = null;
    }

    // Create the idle thread (uses boot stack, no allocation needed)
    const maybe_thread = allocThread();
    if (maybe_thread) |thread| {
        idle_thread = thread;
        // Set fields individually to avoid SIMD memset issues in freestanding
        idle_thread.tid = 0;
        idle_thread.state = .running; // Idle starts as "current" thread
        idle_thread.priority = .idle;
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
        idle_thread.stack_base = 0; // Uses boot stack
        idle_thread.stack_size = 0;
        idle_thread.next = null;
        idle_thread.prev = null;
        idle_thread.process = null;
        idle_thread.first_run = false; // Already running
        current = idle_thread; // Boot thread becomes idle thread
        initialized = true;
    }
    // If allocThread fails, initialized stays false
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

/// Create a new kernel thread
pub fn createKernelThread(entry: *const fn () void, priority: Priority) ?*Thread {
    const thread = allocThread() orelse return null;

    // Allocate stack (single 4KB page)
    const stack_base = memory.allocFrame() orelse {
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

    // Initialize CPU context for first execution
    context.initContext(&thread.context, @intFromPtr(entry), stack_top);

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

/// Add thread to ready queue
fn enqueue(thread: *Thread) void {
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

    if (old) |o| {
        if (thread.first_run) {
            // First time running this thread - save old, then start new
            thread.first_run = false;
            context.switchToNewInline(&o.context, &thread.context);
            // Returns here when old thread is scheduled again (via switchContext)
        } else {
            // Normal context switch - save old, restore new
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
pub fn blockCurrent(reason: State) void {
    if (current) |c| {
        c.state = reason;
        schedule();
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
pub fn checkReschedule() void {
    if (need_reschedule) {
        need_reschedule = false;
        schedule();
    }
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
