// MyLittleKernel - VirtIO Block Device Driver (Userspace Service)
//
// This is a userspace block device driver following microkernel philosophy.
// It communicates with the VirtIO MMIO device and provides block I/O services
// to other processes via IPC.
//
// VirtIO MMIO specification: https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html
// QEMU virt machine VirtIO MMIO: 0x0a000000 - 0x0a003e00 (8 devices, 512 bytes each)

// ============================================================
// System Call Interface
// ============================================================

const SYS = struct {
    const EXIT: u64 = 0;
    const YIELD: u64 = 1;
    const GETPID: u64 = 2;
    const GETTID: u64 = 3;
    const SEND: u64 = 10;
    const RECV: u64 = 11;
    const CALL: u64 = 12;
    const REPLY: u64 = 13;
    const PORT_CREATE: u64 = 20;
    const MAP_DEVICE: u64 = 32;
    const ALLOC_DMA: u64 = 33;
    const GET_PHYS: u64 = 34;
    const WRITE: u64 = 40;
};

fn gettid() u64 {
    return @bitCast(syscall0(SYS.GETTID));
}

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

// Receive message - returns op code, populates arg0/arg1 via out params
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

// Reply to sender - for RPC-style calls
fn replyMsg(sender_tid: u64, op: u64, arg0: u64, arg1: u64) i64 {
    return syscall4(SYS.REPLY, sender_tid, op, arg0, arg1);
}

// Create a port
fn portCreate() i64 {
    return syscall0(SYS.PORT_CREATE);
}

// ============================================================
// Console I/O (via IPC to console server)
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
// VirtIO MMIO Definitions
// ============================================================

// QEMU virt machine: VirtIO MMIO devices at 0x0a000000, 0x200 bytes each
const VIRTIO_MMIO_BASE: u64 = 0x0a000000;
const VIRTIO_MMIO_SIZE: u64 = 0x200;

// VirtIO device types
const VIRTIO_DEV_NET: u32 = 1;
const VIRTIO_DEV_BLK: u32 = 2;
const VIRTIO_DEV_CONSOLE: u32 = 3;
const VIRTIO_DEV_RNG: u32 = 4;

// VirtIO MMIO register offsets
const VIRTIO_MMIO_MAGIC: u64 = 0x000; // Magic value "virt"
const VIRTIO_MMIO_VERSION: u64 = 0x004; // Version (1 = legacy, 2 = modern)
const VIRTIO_MMIO_DEVICE_ID: u64 = 0x008; // Device type
const VIRTIO_MMIO_VENDOR_ID: u64 = 0x00c; // Vendor ID
const VIRTIO_MMIO_DEVICE_FEATURES: u64 = 0x010; // Device features
const VIRTIO_MMIO_DEVICE_FEATURES_SEL: u64 = 0x014; // Feature selector
const VIRTIO_MMIO_DRIVER_FEATURES: u64 = 0x020; // Driver features
const VIRTIO_MMIO_DRIVER_FEATURES_SEL: u64 = 0x024; // Feature selector
const VIRTIO_MMIO_QUEUE_SEL: u64 = 0x030; // Queue selector
const VIRTIO_MMIO_QUEUE_NUM_MAX: u64 = 0x034; // Max queue size
const VIRTIO_MMIO_QUEUE_NUM: u64 = 0x038; // Queue size
// Legacy (version 1) registers
const VIRTIO_MMIO_QUEUE_PFN: u64 = 0x040; // Queue PFN (legacy)
const VIRTIO_MMIO_QUEUE_READY: u64 = 0x044; // Queue ready (version 2 only)
const VIRTIO_MMIO_QUEUE_NOTIFY: u64 = 0x050; // Queue notify
const VIRTIO_MMIO_INTERRUPT_STATUS: u64 = 0x060; // Interrupt status
const VIRTIO_MMIO_INTERRUPT_ACK: u64 = 0x064; // Interrupt ACK
const VIRTIO_MMIO_STATUS: u64 = 0x070; // Device status
// Version 2 registers
const VIRTIO_MMIO_QUEUE_DESC_LOW: u64 = 0x080; // Descriptor table low
const VIRTIO_MMIO_QUEUE_DESC_HIGH: u64 = 0x084; // Descriptor table high
const VIRTIO_MMIO_QUEUE_DRIVER_LOW: u64 = 0x090; // Available ring low
const VIRTIO_MMIO_QUEUE_DRIVER_HIGH: u64 = 0x094; // Available ring high
const VIRTIO_MMIO_QUEUE_DEVICE_LOW: u64 = 0x0a0; // Used ring low
const VIRTIO_MMIO_QUEUE_DEVICE_HIGH: u64 = 0x0a4; // Used ring high
const VIRTIO_MMIO_CONFIG: u64 = 0x100; // Config space

// Virtqueue alignment for legacy devices
const VIRTQUEUE_ALIGN: u64 = 4096;

// VirtIO status bits
const VIRTIO_STATUS_ACKNOWLEDGE: u32 = 1;
const VIRTIO_STATUS_DRIVER: u32 = 2;
const VIRTIO_STATUS_DRIVER_OK: u32 = 4;
const VIRTIO_STATUS_FEATURES_OK: u32 = 8;
const VIRTIO_STATUS_FAILED: u32 = 128;

// VirtIO block device config (at offset 0x100)
const VIRTIO_BLK_CAPACITY_LOW: u64 = 0x100;
const VIRTIO_BLK_CAPACITY_HIGH: u64 = 0x104;

// VirtIO feature bits
const VIRTIO_F_VERSION_1: u64 = 1 << 32;

// VirtIO block feature bits
const VIRTIO_BLK_F_SIZE_MAX: u32 = 1 << 1;
const VIRTIO_BLK_F_SEG_MAX: u32 = 1 << 2;
const VIRTIO_BLK_F_RO: u32 = 1 << 5;
const VIRTIO_BLK_F_BLK_SIZE: u32 = 1 << 6;

// ============================================================
// VirtIO Queue Structures
// ============================================================

const QUEUE_SIZE: u16 = 16;

// Descriptor flags
const VRING_DESC_F_NEXT: u16 = 1;
const VRING_DESC_F_WRITE: u16 = 2;

// Block request types
const VIRTIO_BLK_T_IN: u32 = 0; // Read
const VIRTIO_BLK_T_OUT: u32 = 1; // Write

// Block request status
const VIRTIO_BLK_S_OK: u8 = 0;
const VIRTIO_BLK_S_IOERR: u8 = 1;
const VIRTIO_BLK_S_UNSUPP: u8 = 2;

// Descriptor table entry
const VringDesc = extern struct {
    addr: u64, // Physical address of buffer
    len: u32, // Length of buffer
    flags: u16, // Flags
    next: u16, // Next descriptor index
};

// Available ring
const VringAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]u16,
};

// Used ring element
const VringUsedElem = extern struct {
    id: u32,
    len: u32,
};

// Used ring
const VringUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]VringUsedElem,
};

// Block request header
const VirtioBlkReqHeader = extern struct {
    type_: u32,
    reserved: u32,
    sector: u64,
};

// ============================================================
// Driver State
// ============================================================

var device_base: u64 = 0;
var device_capacity: u64 = 0;
var device_version: u32 = 0;

// DMA memory pointers (allocated at runtime)
var desc_table: ?*[QUEUE_SIZE]VringDesc = null;
var avail_ring: ?*VringAvail = null;
var used_ring: ?*VringUsed = null;
var req_header: ?*VirtioBlkReqHeader = null;
var req_status: ?*u8 = null;
var data_buffer: ?*[512]u8 = null;

// Physical addresses for device
var desc_table_phys: u64 = 0;
var avail_ring_phys: u64 = 0;
var used_ring_phys: u64 = 0;
var req_header_phys: u64 = 0;
var req_status_phys: u64 = 0;
var data_buffer_phys: u64 = 0;

// For legacy virtio - single allocation for entire queue
var queue_mem: ?[*]u8 = null;
var queue_mem_phys: u64 = 0;
var actual_queue_size: u16 = QUEUE_SIZE;

var last_used_idx: u16 = 0;

// Allocate DMA memory and return virtual/physical addresses
fn allocDma(size: u64) struct { virt: u64, phys: u64 } {
    var phys: u64 = undefined;
    const virt_result = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
          [phys_out] "={x1}" (phys),
        : [num] "{x8}" (SYS.ALLOC_DMA),
          [arg0] "{x0}" (size),
        : "memory"
    );

    if (virt_result < 0) {
        return .{ .virt = 0, .phys = 0 };
    }
    return .{ .virt = @bitCast(virt_result), .phys = phys };
}

// Allocate request data DMA buffers (not the queue structures!)
fn initDmaBuffers() bool {
    // Allocate request header
    const req_alloc = allocDma(@sizeOf(VirtioBlkReqHeader));
    if (req_alloc.virt == 0) {
        print("[blkdev] Failed to allocate request header\n");
        return false;
    }
    req_header = @ptrFromInt(req_alloc.virt);
    req_header_phys = req_alloc.phys;

    // Allocate status byte (needs its own page for alignment)
    const status_alloc = allocDma(16);
    if (status_alloc.virt == 0) {
        print("[blkdev] Failed to allocate status\n");
        return false;
    }
    req_status = @ptrFromInt(status_alloc.virt);
    req_status_phys = status_alloc.phys;

    // Allocate data buffer
    const data_alloc = allocDma(512);
    if (data_alloc.virt == 0) {
        print("[blkdev] Failed to allocate data buffer\n");
        return false;
    }
    data_buffer = @ptrFromInt(data_alloc.virt);
    data_buffer_phys = data_alloc.phys;

    print("[blkdev] Request DMA buffers allocated\n");
    print("  req_header: phys=");
    printHex(req_header_phys);
    print("\n  data_buffer: phys=");
    printHex(data_buffer_phys);
    print("\n");

    return true;
}

// Allocate queue structures for modern VirtIO (separate allocations)
fn initQueueDmaBuffers() bool {
    // Allocate descriptor table (needs to be 16-byte aligned, we get 4K alignment)
    const desc_size = @sizeOf([QUEUE_SIZE]VringDesc);
    const desc_alloc = allocDma(desc_size);
    if (desc_alloc.virt == 0) {
        print("[blkdev] Failed to allocate descriptor table\n");
        return false;
    }
    desc_table = @ptrFromInt(desc_alloc.virt);
    desc_table_phys = desc_alloc.phys;

    // Allocate available ring
    const avail_size = @sizeOf(VringAvail);
    const avail_alloc = allocDma(avail_size);
    if (avail_alloc.virt == 0) {
        print("[blkdev] Failed to allocate avail ring\n");
        return false;
    }
    avail_ring = @ptrFromInt(avail_alloc.virt);
    avail_ring_phys = avail_alloc.phys;

    // Allocate used ring
    const used_size = @sizeOf(VringUsed);
    const used_alloc = allocDma(used_size);
    if (used_alloc.virt == 0) {
        print("[blkdev] Failed to allocate used ring\n");
        return false;
    }
    used_ring = @ptrFromInt(used_alloc.virt);
    used_ring_phys = used_alloc.phys;

    return true;
}

// ============================================================
// MMIO Access
// ============================================================

fn mmioRead32(offset: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(device_base + offset);
    return ptr.*;
}

fn mmioWrite32(offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(device_base + offset);
    ptr.* = value;
}

// ============================================================
// Device Initialization
// ============================================================

fn probeDevice(dev_idx: u32) bool {
    const base = VIRTIO_MMIO_BASE + @as(u64, dev_idx) * VIRTIO_MMIO_SIZE;

    // Map the device MMIO region
    const virt = syscall2(SYS.MAP_DEVICE, base, VIRTIO_MMIO_SIZE);
    if (virt < 0) {
        return false;
    }

    device_base = @bitCast(virt);

    // Check magic value
    const magic = mmioRead32(VIRTIO_MMIO_MAGIC);
    if (magic != 0x74726976) { // "virt"
        return false;
    }

    // Check device ID
    const device_id = mmioRead32(VIRTIO_MMIO_DEVICE_ID);
    if (device_id == 0) {
        return false;
    }

    if (device_id != VIRTIO_DEV_BLK) {
        // Found a device but not a block device
        print("[blkdev] Slot ");
        printDec(dev_idx);
        print(": device type ");
        printDec(device_id);
        print("\n");
        return false;
    }

    // Check version
    device_version = mmioRead32(VIRTIO_MMIO_VERSION);
    print("[blkdev] Found block device at slot ");
    printDec(dev_idx);
    print(" (");
    printHex(base);
    print(") version ");
    printDec(device_version);
    print("\n");

    return true;
}

fn initDevice() bool {
    // Reset device
    mmioWrite32(VIRTIO_MMIO_STATUS, 0);

    // Memory barrier and small delay for device reset
    asm volatile ("dmb sy");
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        asm volatile ("nop");
    }

    // Acknowledge device
    mmioWrite32(VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE);
    asm volatile ("dmb sy");
    mmioWrite32(VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);
    asm volatile ("dmb sy");

    // Read device features
    mmioWrite32(VIRTIO_MMIO_DEVICE_FEATURES_SEL, 0);
    asm volatile ("dmb sy");
    const features_low = mmioRead32(VIRTIO_MMIO_DEVICE_FEATURES);
    mmioWrite32(VIRTIO_MMIO_DEVICE_FEATURES_SEL, 1);
    asm volatile ("dmb sy");
    const features_high = mmioRead32(VIRTIO_MMIO_DEVICE_FEATURES);

    print("[blkdev] Features: ");
    printHex(features_low);
    print(" / ");
    printHex(features_high);
    print("\n");

    // Accept VERSION_1 feature (bit 0 of high word = bit 32)
    // This is required for modern VirtIO
    const accept_low: u32 = 0; // No special features from low word
    const accept_high: u32 = if ((features_high & 1) != 0) 1 else 0; // VIRTIO_F_VERSION_1

    mmioWrite32(VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
    asm volatile ("dmb sy");
    mmioWrite32(VIRTIO_MMIO_DRIVER_FEATURES, accept_low);
    mmioWrite32(VIRTIO_MMIO_DRIVER_FEATURES_SEL, 1);
    asm volatile ("dmb sy");
    mmioWrite32(VIRTIO_MMIO_DRIVER_FEATURES, accept_high);
    asm volatile ("dmb sy");

    print("[blkdev] Accepted features: ");
    printHex(accept_low);
    print(" / ");
    printHex(accept_high);
    print("\n");

    // Set FEATURES_OK
    var status = mmioRead32(VIRTIO_MMIO_STATUS);
    status |= VIRTIO_STATUS_FEATURES_OK;
    mmioWrite32(VIRTIO_MMIO_STATUS, status);
    asm volatile ("dmb sy");

    // Check FEATURES_OK is still set
    status = mmioRead32(VIRTIO_MMIO_STATUS);
    if ((status & VIRTIO_STATUS_FEATURES_OK) == 0) {
        print("[blkdev] Feature negotiation failed\n");
        return false;
    }

    // Read capacity
    const cap_low = mmioRead32(VIRTIO_BLK_CAPACITY_LOW);
    const cap_high = mmioRead32(VIRTIO_BLK_CAPACITY_HIGH);
    device_capacity = (@as(u64, cap_high) << 32) | cap_low;

    print("[blkdev] Capacity: ");
    printDec(device_capacity);
    print(" sectors (");
    printDec(device_capacity * 512 / 1024 / 1024);
    print(" MB)\n");

    // Initialize virtqueue
    if (!initQueue()) {
        return false;
    }

    // Set DRIVER_OK
    status = mmioRead32(VIRTIO_MMIO_STATUS);
    status |= VIRTIO_STATUS_DRIVER_OK;
    mmioWrite32(VIRTIO_MMIO_STATUS, status);

    print("[blkdev] Device initialized\n");
    return true;
}

// Calculate virtqueue size for legacy layout (VirtIO 1.0 spec section 2.6)
fn virtqueueSize(qsz: u16) u64 {
    const desc_size = @as(u64, qsz) * @sizeOf(VringDesc);
    const avail_size = 6 + @as(u64, qsz) * 2; // flags + idx + ring + used_event
    const used_size = 6 + @as(u64, qsz) * @sizeOf(VringUsedElem); // flags + idx + ring + avail_event

    // Descriptor table + available ring, aligned to 4K
    const first_part = ((desc_size + avail_size + VIRTQUEUE_ALIGN - 1) / VIRTQUEUE_ALIGN) * VIRTQUEUE_ALIGN;
    // Plus used ring
    return first_part + used_size;
}

fn initQueue() bool {
    // Select queue 0
    mmioWrite32(VIRTIO_MMIO_QUEUE_SEL, 0);
    asm volatile ("dmb sy");

    // For legacy, check QueuePFN is 0 (queue not in use)
    if (device_version == 1) {
        if (mmioRead32(VIRTIO_MMIO_QUEUE_PFN) != 0) {
            print("[blkdev] Queue already in use\n");
            return false;
        }
    }

    // Get max queue size
    const max_size = mmioRead32(VIRTIO_MMIO_QUEUE_NUM_MAX);
    if (max_size == 0) {
        print("[blkdev] Queue not available\n");
        return false;
    }

    print("[blkdev] Max queue size: ");
    printDec(max_size);
    print("\n");

    // Set queue size (use smaller of max and our default)
    actual_queue_size = if (max_size < QUEUE_SIZE) @truncate(max_size) else QUEUE_SIZE;
    mmioWrite32(VIRTIO_MMIO_QUEUE_NUM, actual_queue_size);
    asm volatile ("dmb sy");

    // For legacy device, allocate a single contiguous memory block
    if (device_version == 1) {
        return initQueueLegacy();
    } else {
        return initQueueModern();
    }
}

fn initQueueLegacy() bool {
    // Calculate total size needed for legacy virtqueue
    const total_size = virtqueueSize(actual_queue_size);
    print("[blkdev] Legacy queue, total size: ");
    printDec(total_size);
    print("\n");

    // Allocate single contiguous DMA buffer for entire queue
    const alloc = allocDma(total_size);
    if (alloc.virt == 0) {
        print("[blkdev] Failed to allocate queue memory\n");
        return false;
    }

    queue_mem = @ptrFromInt(alloc.virt);
    queue_mem_phys = alloc.phys;

    // Zero the entire memory region
    const mem_ptr: [*]u8 = queue_mem.?;
    var i: usize = 0;
    while (i < total_size) : (i += 1) {
        mem_ptr[i] = 0;
    }

    // Calculate offsets within the allocation
    const desc_offset: u64 = 0;
    const avail_offset: u64 = @as(u64, actual_queue_size) * @sizeOf(VringDesc);
    const used_offset: u64 = ((avail_offset + 6 + @as(u64, actual_queue_size) * 2 + VIRTQUEUE_ALIGN - 1) / VIRTQUEUE_ALIGN) * VIRTQUEUE_ALIGN;

    // Set up pointers
    desc_table = @ptrFromInt(alloc.virt + desc_offset);
    avail_ring = @ptrFromInt(alloc.virt + avail_offset);
    used_ring = @ptrFromInt(alloc.virt + used_offset);

    desc_table_phys = alloc.phys + desc_offset;
    avail_ring_phys = alloc.phys + avail_offset;
    used_ring_phys = alloc.phys + used_offset;

    print("[blkdev] Queue layout:\n");
    print("  desc:  ");
    printHex(desc_table_phys);
    print("\n  avail: ");
    printHex(avail_ring_phys);
    print("\n  used:  ");
    printHex(used_ring_phys);
    print("\n");

    // Now allocate separate DMA buffers for request data
    if (!initDmaBuffers()) {
        return false;
    }

    // Initialize avail ring
    const ar = avail_ring.?;
    ar.flags = 0;
    ar.idx = 0;

    // Set QueuePFN register - this is the page frame number (phys >> 12)
    // This is how legacy VirtIO MMIO works
    const pfn: u32 = @truncate(alloc.phys >> 12);
    print("[blkdev] Setting QueuePFN to ");
    printHex(pfn);
    print("\n");

    mmioWrite32(VIRTIO_MMIO_QUEUE_PFN, pfn);
    asm volatile ("dmb sy");

    // Verify it was set
    const verify_pfn = mmioRead32(VIRTIO_MMIO_QUEUE_PFN);
    print("[blkdev] QueuePFN readback: ");
    printHex(verify_pfn);
    print("\n");

    print("[blkdev] Legacy queue initialized\n");
    return true;
}

fn initQueueModern() bool {
    // First allocate queue structure DMA buffers
    if (!initQueueDmaBuffers()) {
        return false;
    }
    // Then allocate request data buffers
    if (!initDmaBuffers()) {
        return false;
    }

    // Initialize structures using the DMA pointers
    const dt = desc_table.?;
    for (dt) |*d| {
        d.addr = 0;
        d.len = 0;
        d.flags = 0;
        d.next = 0;
    }

    const ar = avail_ring.?;
    ar.flags = 0;
    ar.idx = 0;
    for (&ar.ring) |*r| r.* = 0;

    const ur = used_ring.?;
    ur.flags = 0;
    ur.idx = 0;
    for (&ur.ring) |*r| {
        r.id = 0;
        r.len = 0;
    }

    // Set queue addresses using physical addresses
    print("[blkdev] Setting queue addrs:\n");
    print("  desc: ");
    printHex(desc_table_phys);
    print("\n  avail: ");
    printHex(avail_ring_phys);
    print("\n  used: ");
    printHex(used_ring_phys);
    print("\n");

    mmioWrite32(VIRTIO_MMIO_QUEUE_DESC_LOW, @truncate(desc_table_phys));
    mmioWrite32(VIRTIO_MMIO_QUEUE_DESC_HIGH, @truncate(desc_table_phys >> 32));
    asm volatile ("dmb sy");
    mmioWrite32(VIRTIO_MMIO_QUEUE_DRIVER_LOW, @truncate(avail_ring_phys));
    mmioWrite32(VIRTIO_MMIO_QUEUE_DRIVER_HIGH, @truncate(avail_ring_phys >> 32));
    asm volatile ("dmb sy");
    mmioWrite32(VIRTIO_MMIO_QUEUE_DEVICE_LOW, @truncate(used_ring_phys));
    mmioWrite32(VIRTIO_MMIO_QUEUE_DEVICE_HIGH, @truncate(used_ring_phys >> 32));
    asm volatile ("dmb sy");

    // Enable queue
    mmioWrite32(VIRTIO_MMIO_QUEUE_READY, 1);
    asm volatile ("dmb sy");

    // Verify queue is ready
    const ready = mmioRead32(VIRTIO_MMIO_QUEUE_READY);
    print("[blkdev] Queue ready: ");
    printDec(ready);
    print("\n");

    print("[blkdev] Modern queue initialized\n");
    return true;
}

// ============================================================
// Block I/O Operations
// ============================================================

fn readSector(sector: u64) bool {
    if (sector >= device_capacity) {
        return false;
    }

    // Get DMA pointers
    const rh = req_header.?;
    const rs = req_status.?;
    const db = data_buffer.?;
    const dt = desc_table.?;
    const ar = avail_ring.?;
    const ur = used_ring.?;

    // Set up request header
    rh.type_ = VIRTIO_BLK_T_IN;
    rh.reserved = 0;
    rh.sector = sector;
    rs.* = 0xFF; // Invalid status

    // Clear data buffer
    for (db) |*b| b.* = 0;

    // Memory barrier before setting up descriptors
    asm volatile ("dmb sy");

    // Descriptor 0: Request header (device reads) - use physical address
    dt[0].addr = req_header_phys;
    dt[0].len = @sizeOf(VirtioBlkReqHeader);
    dt[0].flags = VRING_DESC_F_NEXT;
    dt[0].next = 1;

    // Descriptor 1: Data buffer (device writes) - use physical address
    dt[1].addr = data_buffer_phys;
    dt[1].len = 512;
    dt[1].flags = VRING_DESC_F_WRITE | VRING_DESC_F_NEXT;
    dt[1].next = 2;

    // Descriptor 2: Status byte (device writes) - use physical address
    dt[2].addr = req_status_phys;
    dt[2].len = 1;
    dt[2].flags = VRING_DESC_F_WRITE;
    dt[2].next = 0;

    // Memory barrier after setting up descriptors
    asm volatile ("dmb sy");

    // Add to available ring
    const avail_idx = ar.idx;
    ar.ring[avail_idx % actual_queue_size] = 0; // First descriptor in chain

    // Memory barrier before updating index
    asm volatile ("dmb sy");

    ar.idx = avail_idx +% 1;

    // Memory barrier before notifying device
    asm volatile ("dmb sy");

    // Print debug info
    print("[blkdev] desc_table @ ");
    printHex(@intFromPtr(dt));
    print(" (phys ");
    printHex(desc_table_phys);
    print(")\n");
    print("[blkdev] Desc[0]: addr=");
    printHex(dt[0].addr);
    print(" len=");
    printDec(dt[0].len);
    print(" flags=");
    printDec(dt[0].flags);
    print(" next=");
    printDec(dt[0].next);
    print("\n");
    print("[blkdev] Desc[1]: addr=");
    printHex(dt[1].addr);
    print(" len=");
    printDec(dt[1].len);
    print(" flags=");
    printDec(dt[1].flags);
    print(" next=");
    printDec(dt[1].next);
    print("\n");
    print("[blkdev] Desc[2]: addr=");
    printHex(dt[2].addr);
    print(" len=");
    printDec(dt[2].len);
    print(" flags=");
    printDec(dt[2].flags);
    print("\n");
    print("[blkdev] avail_ring @ ");
    printHex(@intFromPtr(ar));
    print(" idx=");
    printDec(ar.idx);
    print(" ring[0]=");
    printDec(ar.ring[0]);
    print("\n");
    print("[blkdev] used_ring @ ");
    printHex(@intFromPtr(ur));
    print(" idx=");
    printDec(ur.idx);
    print("\n");

    // Strong memory barrier before notify
    asm volatile ("dsb sy");

    // Notify device
    print("[blkdev] Notifying device...\n");
    mmioWrite32(VIRTIO_MMIO_QUEUE_NOTIFY, 0);

    // Barrier after notify
    asm volatile ("dsb sy");

    // Wait for completion (polling)
    var timeout: u32 = 1000000;
    var printed_status = false;
    while (ur.idx == last_used_idx) {
        asm volatile ("dmb sy");
        timeout -= 1;
        if (timeout == 0) {
            // Print final status
            print("[blkdev] Read timeout. Used idx=");
            printDec(ur.idx);
            print(" last=");
            printDec(last_used_idx);
            print("\n  Status reg: ");
            printHex(mmioRead32(VIRTIO_MMIO_STATUS));
            print("\n  InterruptStatus: ");
            printHex(mmioRead32(VIRTIO_MMIO_INTERRUPT_STATUS));
            print("\n");
            return false;
        }
        // Print status once at halfway
        if (!printed_status and timeout == 500000) {
            print("[blkdev] Waiting... intr=");
            printHex(mmioRead32(VIRTIO_MMIO_INTERRUPT_STATUS));
            print(" status=");
            printHex(mmioRead32(VIRTIO_MMIO_STATUS));
            print("\n");
            printed_status = true;
        }
        // Small delay
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            asm volatile ("nop");
        }
    }

    last_used_idx = ur.idx;

    // Check status
    if (rs.* != VIRTIO_BLK_S_OK) {
        print("[blkdev] Read error: ");
        printDec(rs.*);
        print("\n");
        return false;
    }

    return true;
}

// ============================================================
// Block Device Service Protocol
// ============================================================

// IPC operations
const BLK_OP_READ: u32 = 1; // Read sector (arg0=sector) -> returns status, data preview in arg0/arg1
const BLK_OP_GET_CAPACITY: u32 = 2; // Get capacity in sectors
const BLK_OP_GET_STATUS: u32 = 3; // Get device status
const BLK_OP_READ_BYTES: u32 = 4; // Read bytes (arg0=sector, arg1=offset) -> returns 8 bytes at offset

// Well-known port for block device service (fs=3, blkdev=4)
const BLKDEV_PORT: u64 = 4;

// Error codes
const BLK_OK: u32 = 0;
const BLK_ERR_IO: u32 = 1;
const BLK_ERR_INVALID: u32 = 2;
const BLK_ERR_NOT_READY: u32 = 3;

// ============================================================
// Entry Point
// ============================================================

export fn _start() callconv(.C) noreturn {
    print("[blkdev] Starting block device driver\n");

    // Probe for VirtIO block device (QEMU virt has 32 slots)
    var found = false;
    var dev_idx: u32 = 0;
    while (dev_idx < 32) : (dev_idx += 1) {
        if (probeDevice(dev_idx)) {
            found = true;
            break;
        }
    }

    if (!found) {
        print("[blkdev] No VirtIO block device found\n");
        print("[blkdev] Note: Run QEMU with -drive file=disk.img,format=raw,if=virtio\n");
        _ = syscall1(SYS.EXIT, 1);
        unreachable;
    }

    // Initialize the device
    if (!initDevice()) {
        print("[blkdev] Device initialization failed\n");
        _ = syscall1(SYS.EXIT, 1);
        unreachable;
    }

    // Test: Read first sector
    print("[blkdev] Reading sector 0...\n");
    if (readSector(0)) {
        print("[blkdev] Sector 0 data: ");
        const db = data_buffer.?;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const b = db[i];
            const hex = "0123456789abcdef";
            consolePutc(hex[b >> 4]);
            consolePutc(hex[b & 0xf]);
            consolePutc(' ');
        }
        print("...\n");

        // Show ASCII for "Hello from disk!" test
        print("[blkdev] ASCII: ");
        i = 0;
        while (i < 20) : (i += 1) {
            const c = db[i];
            if (c >= 0x20 and c < 0x7f) {
                consolePutc(c);
            } else {
                consolePutc('.');
            }
        }
        print("\n");
    }

    print("[blkdev] Block device service ready\n");

    // Create our service port
    // Note: Port IDs are allocated sequentially. Console gets port 2.
    // We need to create port 3 for ourselves.
    const port = portCreate();
    if (port < 0) {
        print("[blkdev] Failed to create port! Error: ");
        printDec(@abs(port));
        print("\n");
        _ = syscall1(SYS.EXIT, 1);
        unreachable;
    }
    print("[blkdev] Created port ");
    printDec(@bitCast(port));
    print("\n");

    // Verify we got port 3 (well-known blkdev port)
    if (port != BLKDEV_PORT) {
        print("[blkdev] WARNING: Expected port ");
        printDec(BLKDEV_PORT);
        print(" but got ");
        printDec(@bitCast(port));
        print("\n");
    }

    // IPC service loop
    print("[blkdev] Listening on port ");
    printDec(@bitCast(port));
    print("...\n");

    while (true) {
        var arg0: u64 = 0;
        var arg1: u64 = 0;

        // Blocking receive on our port
        const op = recvMsg(@bitCast(port), &arg0, &arg1);

        if (op < 0) {
            print("[blkdev] Recv error: ");
            printDec(@abs(op));
            print("\n");
            _ = syscall0(SYS.YIELD);
            continue;
        }

        // Get sender TID from arg0 of the message (passed by kernel)
        // For synchronous IPC, sender TID is embedded in the message
        // Since we use simple send/recv, the sender info comes through the kernel

        switch (@as(u32, @truncate(@as(u64, @bitCast(op))))) {
            BLK_OP_READ => {
                // arg0 = sector number
                const sector = arg0;
                if (sector >= device_capacity) {
                    // Can't reply without knowing sender - just log
                    print("[blkdev] Invalid sector: ");
                    printDec(sector);
                    print("\n");
                } else {
                    if (readSector(sector)) {
                        // Success - print data preview
                        print("[blkdev] Read sector ");
                        printDec(sector);
                        print(" OK\n");
                    } else {
                        print("[blkdev] Read sector ");
                        printDec(sector);
                        print(" FAILED\n");
                    }
                }
            },

            BLK_OP_GET_CAPACITY => {
                print("[blkdev] Capacity query: ");
                printDec(device_capacity);
                print(" sectors\n");
            },

            BLK_OP_GET_STATUS => {
                print("[blkdev] Status query\n");
            },

            else => {
                print("[blkdev] Unknown op: ");
                printDec(@as(u64, @bitCast(op)));
                print("\n");
            },
        }
    }
}
