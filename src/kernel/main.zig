// MyLittleKernel - Kernel Main
//
// The heart of the microkernel. Following the pure microkernel philosophy,
// only these components live in kernel space:
//   - Memory management (physical + virtual)
//   - Process scheduling
//   - IPC (message passing)
//   - Interrupt routing

const root = @import("root");
const console = root.console;
const boot = root.boot;
const memory = root.memory;
const interrupt = root.interrupt;
const scheduler = root.scheduler;
const ipc = root.ipc;

// Version information
pub const VERSION = "0.1.0";
pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 1;
pub const VERSION_PATCH = 0;
pub const NAME = "MyLittleKernel";

/// Kernel initialization - called from boot code
pub fn init() noreturn {
    // Phase 1: Memory Management
    console.section("Memory Subsystem");
    initMemory();

    // Phase 2: Exception Handling
    console.section("Exception Handling");
    initExceptions();

    // Phase 3: Interrupt Controller
    console.section("Interrupt Controller");
    initInterrupts();

    // Phase 4: Scheduler
    console.section("Process Scheduler");
    initScheduler();

    // Phase 5: IPC
    console.section("IPC Subsystem");
    initIpc();

    // Boot complete
    console.newline();
    console.puts(console.Color.bold);
    console.puts(console.Color.green);
    console.puts(">> Kernel initialization complete!\n");
    console.puts(console.Color.reset);
    console.newline();

    // Show status summary
    printStatus();

    // Create test threads
    console.section("Starting Test Threads");
    createTestThreads();

    // Enable interrupts for preemption
    interrupt.enableInterrupts();
    console.status("Interrupts enabled", true);

    // Enter idle loop - scheduler will switch to test threads
    console.newline();
    console.puts(console.Color.dim);
    console.puts("  Entering idle loop (threads will preempt)\n");
    console.puts(console.Color.reset);

    idle();
}

/// Initialize memory management
fn initMemory() void {
    // Initialize physical frame allocator
    const ram_base = boot.MEMORY_BASE;
    const ram_size = boot.MEMORY_SIZE;

    // Reserve first 1MB for kernel (microkernel = small!)
    const kernel_reserved: u64 = 1 * 1024 * 1024;
    const usable_base = ram_base + kernel_reserved;
    const usable_size = ram_size - kernel_reserved;

    memory.init(usable_base, usable_size);

    console.puts("  Physical memory: ");
    console.putHex(ram_base);
    console.puts(" - ");
    console.putHex(ram_base + ram_size);
    console.newline();

    console.puts("  Kernel reserved: ");
    console.putSize(kernel_reserved);
    console.newline();

    console.puts("  Available:       ");
    console.putSize(usable_size);
    console.newline();

    console.status("Physical frame allocator", true);
    console.status("Page tables (identity mapped)", true);
}

/// Set up exception vectors
fn initExceptions() void {
    // Install exception vector table
    interrupt.initVectors();
    console.status("Exception vector table", true);
    console.status("Synchronous exception handler", true);
    console.status("IRQ handler", true);
}

/// Initialize the GIC (Generic Interrupt Controller)
fn initInterrupts() void {
    interrupt.initGic();
    console.status("GIC Distributor", true);
    console.status("GIC CPU Interface", true);

    // Enable timer interrupt
    interrupt.enableTimerIrq();
    console.status("Timer IRQ enabled", true);
}

/// Initialize the scheduler
fn initScheduler() void {
    scheduler.init();
    console.status("Scheduler initialized", true);
    console.status("Idle thread created", true);
}

/// Initialize IPC subsystem
fn initIpc() void {
    ipc.init();
    console.status("Message queues", true);
    console.status("Capability system", true);
}

/// Print kernel status summary
fn printStatus() void {
    console.puts(console.Color.dim);
    console.puts("─────────────────────────────────────────────────────────────────\n");
    console.puts(console.Color.reset);

    console.puts("  Status:          ");
    console.puts(console.Color.green);
    console.puts("Running\n");
    console.puts(console.Color.reset);

    console.puts("  Exception Level: ");
    console.puts(console.Color.white);
    console.puts("EL");
    console.putDec(boot.getCurrentEL());
    console.newline();
    console.puts(console.Color.reset);

    console.puts("  Free Memory:     ");
    console.puts(console.Color.white);
    console.putSize(memory.getFreeMemory());
    console.newline();
    console.puts(console.Color.reset);

    console.puts(console.Color.dim);
    console.puts("─────────────────────────────────────────────────────────────────\n");
    console.puts(console.Color.reset);

    console.newline();
    console.puts(console.Color.dim);
    console.puts("  Press Ctrl+A, X to exit QEMU\n");
    console.puts(console.Color.reset);
}

/// Kernel idle loop
fn idle() noreturn {
    while (true) {
        // Wait for interrupt
        asm volatile ("wfi");

        // Check if we need to reschedule after the interrupt
        scheduler.checkReschedule();
    }
}

/// Kernel panic - unrecoverable error
pub fn panic(msg: []const u8) noreturn {
    boot.panic(msg);
}

// ============================================================
// Test Threads
// ============================================================

/// Create test threads to verify userspace execution
fn createTestThreads() void {
    // Create USERSPACE threads - they run in EL0 with restricted privileges
    if (scheduler.createUserThread(&threadA, .normal)) |t| {
        console.puts("  Thread A created (TID ");
        console.putDec(t.tid);
        console.puts(") - ");
        console.puts(console.Color.green);
        console.puts("USERSPACE (EL0)\n");
        console.puts(console.Color.reset);
    } else {
        console.status("Thread A creation", false);
    }

    if (scheduler.createUserThread(&threadB, .normal)) |t| {
        console.puts("  Thread B created (TID ");
        console.putDec(t.tid);
        console.puts(") - ");
        console.puts(console.Color.green);
        console.puts("USERSPACE (EL0)\n");
        console.puts(console.Color.reset);
    } else {
        console.status("Thread B creation", false);
    }

    console.status("Userspace threads ready", true);
}

// Global counters to avoid register/stack issues during context switch
var thread_a_counter: u32 = 0;
var thread_b_counter: u32 = 0;

const syscall = root.syscall;

// Shared endpoint ID for IPC communication (created by thread B)
var ipc_endpoint: u32 = 0;
var endpoint_ready: bool = false;

// Static message buffer for thread A (avoid stack issues)
var thread_a_msg_buf: ipc.Message = .{};

// Volatile read/write helpers to ensure visibility across threads
fn readEndpointReady() bool {
    const ptr: *volatile bool = @ptrCast(&endpoint_ready);
    return ptr.*;
}

fn writeEndpointReady(val: bool) void {
    const ptr: *volatile bool = @ptrCast(&endpoint_ready);
    ptr.* = val;
}

/// Test thread A - userspace sender
fn threadA() void {
    // Wait for endpoint to be ready (busy wait, no syscall needed)
    while (!readEndpointReady()) {
        // Busy wait - could use syscall.yield() but let's test simple first
        var i: u32 = 0;
        while (i < 100000) : (i += 1) {
            asm volatile ("nop");
        }
    }

    // Now use syscalls for everything
    while (true) {
        thread_a_counter +%= 1;

        // Build message using static buffer
        thread_a_msg_buf.op = thread_a_counter;
        thread_a_msg_buf.arg0 = 0;
        thread_a_msg_buf.arg1 = 0;
        thread_a_msg_buf.arg2 = 0;
        thread_a_msg_buf.arg3 = 0;

        // Send via syscall (this is the ONLY way to do IPC from EL0)
        _ = syscall.syscall2(syscall.SYS.SEND, ipc_endpoint, thread_a_counter);

        // Small delay
        var i: u32 = 0;
        while (i < 500000) : (i += 1) {
            asm volatile ("nop");
        }
    }
}

// Static message buffer for thread B (avoid potential stack issues)
var thread_b_msg_buf: ipc.Message = .{};

/// Test thread B - userspace receiver
fn threadB() void {
    // Create endpoint via syscall
    const ep_result = syscall.syscall0(syscall.SYS.PORT_CREATE);
    if (ep_result < 0) {
        // Failed - just loop
        while (true) {
            asm volatile ("nop");
        }
    }

    ipc_endpoint = @intCast(@as(u64, @bitCast(ep_result)));
    writeEndpointReady(true);

    // Receive loop via syscalls
    while (true) {
        thread_b_counter +%= 1;

        // Receive via syscall
        const recv_result = syscall.syscall1(syscall.SYS.RECV, ipc_endpoint);
        _ = recv_result;

        // Got a message! Just continue
    }
}

/// Simple busy-wait delay
fn busyWait(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        asm volatile ("nop");
    }
}
