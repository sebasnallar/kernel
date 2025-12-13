# MyLittleKernel

A pure microkernel written in Zig, targeting Apple Silicon (ARM64).

## Vision

A minimal, event-driven microkernel where everything is a service communicating through message passing. Inspired by the elegance of Minix and seL4, but with a modern twist using Zig's safety features and clean syntax.

```
┌─────────────────────────────────────────────────────────────────┐
│  User Space Services                                            │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │   VFS   │ │ Network │ │  Block  │ │ Console │ │  Init   │   │
│  │ Service │ │ Service │ │ Driver  │ │ Driver  │ │ Service │   │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘   │
│       │          │          │          │          │            │
│       └──────────┴──────────┴────┬─────┴──────────┘            │
│                                  │                              │
│                          ┌───────▼───────┐                      │
│                          │  IPC Messages │                      │
├──────────────────────────┴───────────────┴──────────────────────┤
│  MyLittleKernel (Microkernel)                                   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐ │
│  │     IPC     │ │  Scheduler  │ │   Memory    │ │ Interrupt │ │
│  │  (message   │ │  (simple    │ │  (virtual   │ │  Router   │ │
│  │  passing)   │ │  priority)  │ │  memory)    │ │           │ │
│  └─────────────┘ └─────────────┘ └─────────────┘ └───────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   Apple Silicon M1+   │
                    │       (ARM64)         │
                    └───────────────────────┘
```

## Design Principles

1. **Minimal Kernel** - Only four things live in the kernel:
   - IPC (Inter-Process Communication) via message passing
   - Process/Thread scheduling
   - Virtual memory management
   - Interrupt handling and routing

2. **Everything is a Service** - Drivers, filesystems, networking — all run in user space as isolated services.

3. **Message-Driven Architecture** - Services communicate exclusively through typed messages. No shared state.

4. **Capability-Based Security** - Access to resources is controlled through unforgeable capability tokens.

5. **Written in Zig** - Memory safety without garbage collection, C interop when needed, comptime magic.

## Target Platform

- **Architecture**: ARM64 (AArch64)
- **Primary Target**: Apple Silicon Macs (M1/M2/M3)
- **Boot Method**: UEFI via [Asahi Linux](https://asahilinux.org/) bootloader or QEMU for development

## Project Structure

```
mylittlekernel/
├── src/
│   ├── kernel/
│   │   ├── main.zig          # Kernel entry point
│   │   ├── ipc.zig           # Message passing system
│   │   ├── scheduler.zig     # Process/thread scheduler
│   │   ├── memory.zig        # Virtual memory manager
│   │   └── interrupt.zig     # Interrupt handling
│   ├── arch/
│   │   └── aarch64/
│   │       ├── boot.zig      # ARM64 boot code
│   │       ├── mmu.zig       # Memory management unit
│   │       ├── exceptions.zig # Exception vectors
│   │       └── timer.zig     # ARM timer
│   └── lib/
│       └── std.zig           # Freestanding stdlib subset
├── services/
│   ├── init/                 # First userspace service
│   ├── console/              # Console/UART driver
│   └── vfs/                  # Virtual filesystem
├── build.zig                 # Zig build configuration
├── linker.ld                 # Kernel linker script
└── README.md
```

## Building

### Prerequisites

- Zig 0.13+ (master recommended for ARM64 freestanding)
- QEMU with ARM64 support (`qemu-system-aarch64`)
- Optional: Cross-compilation toolchain for debugging

### Build Commands

```bash
# Build the kernel
zig build

# Build and run in QEMU
zig build run

# Build in release mode
zig build -Doptimize=ReleaseSafe
```

## Development Phases

### Phase 1: Boot and Print (Current)
- [x] Project setup
- [ ] Basic ARM64 boot code
- [ ] UART output (serial console)
- [ ] "Hello from MyLittleKernel!"

### Phase 2: Memory Foundation
- [ ] Physical memory allocator
- [ ] Page table setup (ARM64 4KB pages)
- [ ] Virtual memory regions
- [ ] Kernel heap

### Phase 3: Scheduling
- [ ] Process/Thread structures
- [ ] Context switching (ARM64)
- [ ] Simple round-robin scheduler
- [ ] Timer interrupts

### Phase 4: IPC - The Heart
- [ ] Message structures
- [ ] Synchronous send/receive
- [ ] Asynchronous notifications
- [ ] Capability system basics

### Phase 5: First Service
- [ ] User-mode execution
- [ ] System call interface
- [ ] Init service
- [ ] Console service

### Phase 6: Beyond
- [ ] VFS service
- [ ] RAM disk
- [ ] More drivers
- [ ] Shell?

## Running on Real Hardware

Running on actual Apple Silicon requires the Asahi Linux boot infrastructure. For development, we'll primarily use QEMU:

```bash
qemu-system-aarch64 \
  -M virt \
  -cpu cortex-a72 \
  -m 1G \
  -nographic \
  -kernel zig-out/bin/kernel.elf
```

## Resources & Inspiration

- [OSDev Wiki](https://wiki.osdev.org/) - Essential OS development resource
- [Minix 3](https://www.minix3.org/) - The microkernel that inspired this
- [seL4](https://sel4.systems/) - Formally verified microkernel
- [Writing an OS in Rust](https://os.phil-opp.com/) - Great tutorial (Rust, but concepts apply)
- [Zig Bare Bones](https://github.com/AndreaOrru/zig-bare-bones) - Zig OS starting point
- [ARM Architecture Reference Manual](https://developer.arm.com/documentation/ddi0487/latest)

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

This is a learning project! Contributions, suggestions, and discussions are welcome.

---

*"Because the world needs another hobby OS project"* 🦎
