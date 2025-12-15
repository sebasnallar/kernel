// MyLittleKernel - Memory Management
//
// Physical and virtual memory management:
//   - Bitmap-based physical frame allocator
//   - ARM64 page table management (4KB pages, 4-level)
//   - Kernel heap (simple bump allocator)

/// Page size (4KB)
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;

/// Physical address type
pub const PhysAddr = u64;
/// Virtual address type
pub const VirtAddr = u64;

// ============================================================
// Physical Frame Allocator
// ============================================================

/// Maximum supported RAM (4GB = 1M frames)
const MAX_FRAMES: usize = 1024 * 1024;
const BITMAP_SIZE: usize = MAX_FRAMES / 8;

/// Bitmap for frame allocation (1 = allocated, 0 = free)
var frame_bitmap: [BITMAP_SIZE]u8 = [_]u8{0} ** BITMAP_SIZE;

/// Allocator state
var alloc_base: PhysAddr = 0;
var alloc_frames: usize = 0;
var free_frames: usize = 0;
var initialized: bool = false;
var search_hint: usize = 0; // Hint for where to start searching

/// Initialize the physical memory allocator
pub fn init(base: PhysAddr, size: u64) void {
    alloc_base = base;
    alloc_frames = @intCast(size / PAGE_SIZE);
    free_frames = alloc_frames;

    // Ensure we don't exceed our bitmap capacity
    if (alloc_frames > MAX_FRAMES) {
        alloc_frames = MAX_FRAMES;
        free_frames = MAX_FRAMES;
    }

    // Clear bitmap (all frames free)
    for (&frame_bitmap) |*byte| {
        byte.* = 0;
    }

    initialized = true;
}

/// Allocate a single physical frame
pub fn allocFrame() ?PhysAddr {
    if (!initialized) return null;

    // Find first free frame by scanning bytes then bits
    const bitmap_bytes = (alloc_frames + 7) / 8;
    var byte_idx: usize = 0;

    while (byte_idx < bitmap_bytes) : (byte_idx += 1) {
        const byte = frame_bitmap[byte_idx];
        if (byte != 0xFF) {
            // Found a byte with at least one free bit
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                if ((byte & (@as(u8, 1) << bit)) == 0) {
                    const frame_idx = byte_idx * 8 + bit;
                    if (frame_idx >= alloc_frames) return null;

                    // Mark as allocated
                    frame_bitmap[byte_idx] |= (@as(u8, 1) << bit);
                    free_frames -= 1;
                    return alloc_base + frame_idx * PAGE_SIZE;
                }
            }
        }
    }
    return null;
}

/// Free a physical frame
pub fn freeFrame(addr: PhysAddr) void {
    if (!initialized) return;
    if (addr < alloc_base) return;

    const frame_idx = (addr - alloc_base) / PAGE_SIZE;
    if (frame_idx >= alloc_frames) return;

    const byte_idx = frame_idx / 8;
    const bit: u3 = @truncate(frame_idx % 8);

    // Only free if currently allocated
    if ((frame_bitmap[byte_idx] & (@as(u8, 1) << bit)) != 0) {
        frame_bitmap[byte_idx] &= ~(@as(u8, 1) << bit);
        free_frames += 1;
    }
}

/// Allocate contiguous physical frames
/// Returns 0 on failure (since physical address 0 is not in usable RAM)
/// Note: Use this function directly to avoid Zig optional return value codegen issues
pub fn allocContiguousRaw(count: usize) PhysAddr {
    if (!initialized or count == 0) return 0;

    // First-fit search for contiguous frames
    var start_frame: usize = 0;
    var found: usize = 0;

    var frame: usize = 0;
    while (frame < alloc_frames) : (frame += 1) {
        const byte_idx = frame / 8;
        const bit: u3 = @truncate(frame % 8);

        if ((frame_bitmap[byte_idx] & (@as(u8, 1) << bit)) == 0) {
            if (found == 0) start_frame = frame;
            found += 1;

            if (found == count) {
                // Mark all as allocated
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const f = start_frame + i;
                    const bi = f / 8;
                    const bt: u3 = @truncate(f % 8);
                    frame_bitmap[bi] |= (@as(u8, 1) << bt);
                }
                free_frames -= count;
                return alloc_base + start_frame * PAGE_SIZE;
            }
        } else {
            found = 0;
        }
    }
    return 0;
}

/// Allocate contiguous physical frames (optional wrapper)
/// WARNING: Due to a suspected Zig codegen issue with optional returns on ARM64
/// freestanding, prefer allocContiguousRaw() for new code
pub fn allocContiguous(count: usize) ?PhysAddr {
    const result = allocContiguousRaw(count);
    if (result == 0) return null;
    return result;
}

/// Allocate contiguous pages (returns virtual address)
/// For kernel memory, physical = virtual (identity mapped)
pub fn allocPages(count: usize) ?u64 {
    return allocContiguous(count);
}

/// Free contiguous pages
pub fn freePages(addr: u64, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        freeFrame(addr + i * PAGE_SIZE);
    }
}

/// Get total free memory in bytes
pub fn getFreeMemory() u64 {
    return @as(u64, free_frames) * PAGE_SIZE;
}

/// Get total memory in bytes
pub fn getTotalMemory() u64 {
    return @as(u64, alloc_frames) * PAGE_SIZE;
}

/// Get number of free frames
pub fn getFreeFrames() usize {
    return free_frames;
}

// ============================================================
// ARM64 Page Tables
// ============================================================

/// Page table entry flags (using u64 constants for clarity)
pub const PageFlags = struct {
    pub const VALID: u64 = 1 << 0;
    pub const TABLE: u64 = 1 << 1; // Table descriptor (not block)
    pub const PAGE: u64 = 1 << 1; // Page descriptor at level 3

    // Access permissions (AP[2:1] at bits 6-7)
    pub const AP_RW_EL1: u64 = 0 << 6; // EL1 read/write
    pub const AP_RW_ALL: u64 = 1 << 6; // EL1 and EL0 read/write
    pub const AP_RO_EL1: u64 = 2 << 6; // EL1 read-only
    pub const AP_RO_ALL: u64 = 3 << 6; // EL1 and EL0 read-only

    // Shareability (SH[1:0] at bits 8-9)
    pub const SH_NONE: u64 = 0 << 8;
    pub const SH_OUTER: u64 = 2 << 8;
    pub const SH_INNER: u64 = 3 << 8;

    // Access flag (bit 10)
    pub const AF: u64 = 1 << 10;

    // Not global (bit 11)
    pub const NG: u64 = 1 << 11;

    // Execute never (bits 53-54)
    pub const PXN: u64 = 1 << 53; // Privileged execute never
    pub const UXN: u64 = 1 << 54; // Unprivileged execute never

    // Memory attributes (AttrIndx[2:0] at bits 2-4)
    pub const ATTR_DEVICE: u64 = 0 << 2; // Device memory
    pub const ATTR_NORMAL: u64 = 1 << 2; // Normal cacheable

    // Common flag combinations
    pub const KERNEL_CODE: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_EL1 | UXN;
    pub const KERNEL_DATA: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_EL1 | PXN | UXN;
    pub const KERNEL_RODATA: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_EL1 | PXN | UXN;
    pub const DEVICE: u64 = VALID | PAGE | AF | ATTR_DEVICE | AP_RW_EL1 | PXN | UXN;
    pub const USER_CODE: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_ALL | NG;
    pub const USER_DATA: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_ALL | PXN | UXN | NG;
};

/// Page table (512 entries, 4KB)
pub const PageTable = struct {
    entries: [512]u64,

    pub fn clear(self: *PageTable) void {
        for (&self.entries) |*e| {
            e.* = 0;
        }
    }
};

// ============================================================
// Kernel Heap (Simple Bump Allocator)
// ============================================================

var heap_start: usize = 0;
var heap_end: usize = 0;
var heap_current: usize = 0;

/// Initialize kernel heap
pub fn initHeap(start: usize, size: usize) void {
    heap_start = start;
    heap_end = start + size;
    heap_current = start;
}

/// Allocate from kernel heap (bump allocator - no free!)
pub fn heapAlloc(size: usize, alignment: usize) ?[*]u8 {
    // Align current pointer
    const aligned = (heap_current + alignment - 1) & ~(alignment - 1);

    if (aligned + size > heap_end) {
        return null;
    }

    heap_current = aligned + size;
    return @ptrFromInt(aligned);
}
