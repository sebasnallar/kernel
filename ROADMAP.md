# MyLittleKernel Roadmap

## Current State

### Kernel Components - Ready
- **Scheduler**: Priority queues, preemption, context switching
- **MMU**: Per-process address spaces, TTBR0 switching, ASID management
- **Memory**: Bitmap frame allocator, page mapping
- **IPC**: Endpoints, send/receive, blocking queues
- **Interrupts**: Timer, GIC, exception handling
- **Syscalls**: Framework ready (partial implementation)

### Blockers for Real Use
- ~~No console I/O syscalls~~ DONE (SYS_WRITE, SYS_READ)
- ~~No program loader~~ DONE (MLK binary format + loader)
- No process spawn/exit (can't create processes or cleanup)

---

## Milestones

### Milestone 1: Console I/O ✓
**Status**: COMPLETE

**Goal**: User processes can print and read from console

**Completed**:
- [x] Add SYS_WRITE syscall (write buffer to UART)
- [x] Add SYS_READ syscall (read from UART)
- [x] Update user program to print "Hello from userspace!"
- [x] Test end-to-end

**Unlocks**: Debugging, basic user interaction

---

### Milestone 2: Binary Loader ✓
**Status**: COMPLETE

**Goal**: Load real compiled programs instead of hardcoded blobs

**Completed**:
- [x] Define MLK binary format (16-byte header + flat code)
- [x] Create loader: parseHeader, loadBinary functions
- [x] Build system: compile user/hello.zig separately
- [x] Embed hello.mlk in kernel via @embedFile
- [x] Load and run as userspace processes

**Unlocks**: Write real programs in Zig, compile and run them

---

### Milestone 3: Process Lifecycle
**Status**: IN PROGRESS

**Goal**: Proper process creation and cleanup

**Tasks**:
- [ ] SYS_SPAWN syscall (create child process from binary)
- [ ] SYS_EXIT syscall (cleanup memory, close endpoints, notify parent)
- [ ] SYS_WAIT syscall (parent waits for child termination)
- [ ] Process resource tracking and cleanup

**Unlocks**: Multi-process OS, proper resource management

---

### Milestone 4: Init + Console Server
**Status**: NOT STARTED

**Goal**: User-space OS foundation following microkernel philosophy

**Tasks**:
- [ ] Init process: first user process, spawns services
- [ ] Console server: owns UART, provides I/O via IPC
- [ ] IPC protocol for console requests
- [ ] Redirect process I/O through console server

**Unlocks**: True microkernel architecture (services in userspace)

---

### Milestone 5: Shell
**Status**: NOT STARTED

**Goal**: Interactive OS with command interface

**Tasks**:
- [ ] Shell process: read commands, parse, execute
- [ ] Built-in commands: ps, echo, help
- [ ] Run external programs
- [ ] Basic job control

**Unlocks**: Usable interactive system

---

## Future Ideas (Post-Shell)
- File system server (ramfs or simple fs)
- Device driver framework
- Networking stack
- Graphics/framebuffer
- Multiple terminals
