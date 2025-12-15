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
const mmu = root.mmu;
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

    // Phase 6: Virtual Memory (MMU)
    console.section("Virtual Memory");
    initMmu();

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
    console.puts("  Entering idle loop (userspace threads will preempt)\n");
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
}

/// Initialize MMU and virtual memory
fn initMmu() void {
    mmu.init();
    console.status("MMU enabled", mmu.isInitialized());
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

/// Create test processes/threads
/// Now uses proper per-process address spaces with separate TTBR0
fn createTestThreads() void {
    const user_program = root.user_program;

    console.puts("  Free frames before: ");
    console.putDec(memory.getFreeFrames());
    console.newline();

    // Create TRUE USER processes with their own address spaces
    // Each process gets its own TTBR0 page table

    // Process A: Simple yield loop
    const code_a = user_program.getYieldLoopCode();
    if (scheduler.createUserProcess(code_a, .normal)) |t| {
        console.puts("  Process A created (PID ");
        if (t.process) |p| {
            console.putDec(p.pid);
        }
        console.puts(", TID ");
        console.putDec(t.tid);
        console.puts(") - ");
        console.puts(console.Color.green);
        console.puts("USER (EL0)\n");
        console.puts(console.Color.reset);
    } else {
        console.status("Process A creation", false);
    }

    // Process B: Another yield loop
    const code_b = user_program.getYieldLoopCode();
    if (scheduler.createUserProcess(code_b, .normal)) |t| {
        console.puts("  Process B created (PID ");
        if (t.process) |p| {
            console.putDec(p.pid);
        }
        console.puts(", TID ");
        console.putDec(t.tid);
        console.puts(") - ");
        console.puts(console.Color.green);
        console.puts("USER (EL0)\n");
        console.puts(console.Color.reset);
    } else {
        console.status("Process B creation", false);
    }

    console.puts("  Free frames after: ");
    console.putDec(memory.getFreeFrames());
    console.newline();

    console.status("Test processes ready", true);
}

// Note: Old kernel thread test code has been removed.
// The kernel now creates true userspace processes with per-process
// address spaces. See createTestThreads() and user_program.zig.
