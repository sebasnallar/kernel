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

/// Create test threads to verify scheduling
fn createTestThreads() void {
    if (scheduler.createKernelThread(&threadA, .normal)) |t| {
        console.puts("  Thread A created (TID ");
        console.putDec(t.tid);
        console.puts(")\n");
    } else {
        console.status("Thread A creation", false);
    }

    if (scheduler.createKernelThread(&threadB, .normal)) |t| {
        console.puts("  Thread B created (TID ");
        console.putDec(t.tid);
        console.puts(")\n");
    } else {
        console.status("Thread B creation", false);
    }

    console.status("Test threads ready", true);
}

// Global counters to avoid register/stack issues during context switch
var thread_a_counter: u32 = 0;
var thread_b_counter: u32 = 0;

/// Test thread A - prints periodically
fn threadA() void {
    while (true) {
        thread_a_counter += 1;
        console.puts(console.Color.cyan);
        console.puts("[A:");
        console.putDec(thread_a_counter);
        console.puts("] ");
        console.puts(console.Color.reset);

        // Busy wait to slow things down
        busyWait(500000);

        // Voluntarily yield after a few iterations
        if (thread_a_counter % 5 == 0) {
            scheduler.yield();
        }
    }
}

/// Test thread B - prints periodically
fn threadB() void {
    while (true) {
        thread_b_counter += 1;
        console.puts(console.Color.yellow);
        console.puts("[B:");
        console.putDec(thread_b_counter);
        console.puts("] ");
        console.puts(console.Color.reset);

        // Busy wait to slow things down
        busyWait(500000);

        // Voluntarily yield after a few iterations
        if (thread_b_counter % 5 == 0) {
            scheduler.yield();
        }
    }
}

/// Simple busy-wait delay
fn busyWait(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        asm volatile ("nop");
    }
}
