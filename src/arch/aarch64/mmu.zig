// MyLittleKernel - ARM64 MMU (Memory Management Unit)
//
// Handles ARM64 virtual memory:
//   - Page table creation and manipulation
//   - MMU register configuration
//   - TLB management
//   - Address space switching
//
// ARM64 4KB granule, 48-bit VA (4-level page tables):
//   Level 0: bits 47-39 (512GB per entry)
//   Level 1: bits 38-30 (1GB per entry)
//   Level 2: bits 29-21 (2MB per entry)
//   Level 3: bits 20-12 (4KB per entry)

const root = @import("root");
const memory = root.memory;

// ============================================================
// Constants
// ============================================================

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

/// Virtual address space split:
/// - TTBR0_EL1: 0x0000_0000_0000_0000 - 0x0000_FFFF_FFFF_FFFF (user)
/// - TTBR1_EL1: 0xFFFF_0000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF (kernel)
///
/// For simplicity, we use identity mapping for kernel (phys == virt)
/// and TTBR0 for per-process user mappings.

// Kernel virtual base (we'll identity map, so this equals physical)
pub const KERNEL_BASE: u64 = 0x40000000;

// User space range
pub const USER_BASE: u64 = 0x0000_0000_0010_0000; // 1MB (avoid null page)
pub const USER_END: u64 = 0x0000_7FFF_FFFF_FFFF; // Top of user space

// ============================================================
// Page Table Entry Flags
// ============================================================

pub const PTE = struct {
    // Descriptor type (bits 0-1)
    pub const VALID: u64 = 1 << 0;
    pub const TABLE: u64 = 1 << 1; // Table descriptor (L0-L2)
    pub const PAGE: u64 = 1 << 1; // Page descriptor (L3)
    pub const BLOCK: u64 = 0 << 1; // Block descriptor (L1-L2)

    // Lower attributes (bits 2-11)
    pub const ATTR_IDX_SHIFT: u6 = 2;
    pub const ATTR_DEVICE: u64 = 0 << 2; // Device-nGnRnE
    pub const ATTR_NORMAL: u64 = 1 << 2; // Normal cacheable
    pub const ATTR_NORMAL_NC: u64 = 2 << 2; // Normal non-cacheable

    pub const NS: u64 = 1 << 5; // Non-secure

    // AP[2:1] - Access permissions (bits 6-7)
    pub const AP_RW_EL1: u64 = 0b00 << 6; // EL1 RW, EL0 none
    pub const AP_RW_ALL: u64 = 0b01 << 6; // EL1 RW, EL0 RW
    pub const AP_RO_EL1: u64 = 0b10 << 6; // EL1 RO, EL0 none
    pub const AP_RO_ALL: u64 = 0b11 << 6; // EL1 RO, EL0 RO

    // SH[1:0] - Shareability (bits 8-9)
    pub const SH_NONE: u64 = 0b00 << 8;
    pub const SH_OUTER: u64 = 0b10 << 8;
    pub const SH_INNER: u64 = 0b11 << 8;

    pub const AF: u64 = 1 << 10; // Access flag
    pub const NG: u64 = 1 << 11; // Not global (use ASID)

    // Upper attributes (bits 50-63)
    pub const CONT: u64 = 1 << 52; // Contiguous hint
    pub const PXN: u64 = 1 << 53; // Privileged execute never
    pub const UXN: u64 = 1 << 54; // Unprivileged execute never

    // Address mask (bits 12-47)
    pub const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

    // Common combinations
    pub const KERNEL_RWX: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_EL1;
    pub const KERNEL_RW: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_EL1 | PXN | UXN;
    pub const KERNEL_RO: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_EL1 | PXN | UXN;
    pub const KERNEL_RX: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_EL1 | UXN;
    pub const DEVICE_RW: u64 = VALID | PAGE | AF | ATTR_DEVICE | AP_RW_EL1 | PXN | UXN;

    pub const USER_RWX: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_ALL | NG;
    pub const USER_RW: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_ALL | NG | PXN | UXN;
    pub const USER_RO: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_ALL | NG | PXN | UXN;
    pub const USER_RX: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RO_ALL | NG | PXN;

    // Shared kernel/user code - allows both EL1 and EL0 execution
    // Used for kernel code that embedded userspace test threads execute
    // Note: NG bit might be required for AP_RW_ALL to work properly
    pub const SHARED_RWX: u64 = VALID | PAGE | AF | SH_INNER | ATTR_NORMAL | AP_RW_ALL | NG;

    pub const TABLE_DESC: u64 = VALID | TABLE;
};

// ============================================================
// TCR_EL1 - Translation Control Register
// ============================================================

pub const TCR = struct {
    // T0SZ - Size of TTBR0 region (bits 0-5)
    // VA size = 64 - T0SZ, e.g., T0SZ=16 gives 48-bit VA
    pub const T0SZ_SHIFT: u6 = 0;

    // T1SZ - Size of TTBR1 region (bits 16-21)
    pub const T1SZ_SHIFT: u6 = 16;

    // TG0 - TTBR0 granule size (bits 14-15)
    pub const TG0_4KB: u64 = 0b00 << 14;
    pub const TG0_64KB: u64 = 0b01 << 14;
    pub const TG0_16KB: u64 = 0b10 << 14;

    // TG1 - TTBR1 granule size (bits 30-31)
    pub const TG1_16KB: u64 = 0b01 << 30;
    pub const TG1_4KB: u64 = 0b10 << 30;
    pub const TG1_64KB: u64 = 0b11 << 30;

    // SH0 - TTBR0 shareability (bits 12-13)
    pub const SH0_NONE: u64 = 0b00 << 12;
    pub const SH0_OUTER: u64 = 0b10 << 12;
    pub const SH0_INNER: u64 = 0b11 << 12;

    // SH1 - TTBR1 shareability (bits 28-29)
    pub const SH1_NONE: u64 = 0b00 << 28;
    pub const SH1_OUTER: u64 = 0b10 << 28;
    pub const SH1_INNER: u64 = 0b11 << 28;

    // ORGN0 - TTBR0 outer cacheability (bits 10-11)
    pub const ORGN0_NC: u64 = 0b00 << 10;
    pub const ORGN0_WBWA: u64 = 0b01 << 10; // Write-back write-allocate
    pub const ORGN0_WT: u64 = 0b10 << 10; // Write-through
    pub const ORGN0_WB: u64 = 0b11 << 10; // Write-back

    // IRGN0 - TTBR0 inner cacheability (bits 8-9)
    pub const IRGN0_NC: u64 = 0b00 << 8;
    pub const IRGN0_WBWA: u64 = 0b01 << 8;
    pub const IRGN0_WT: u64 = 0b10 << 8;
    pub const IRGN0_WB: u64 = 0b11 << 8;

    // ORGN1 - TTBR1 outer cacheability (bits 26-27)
    pub const ORGN1_NC: u64 = 0b00 << 26;
    pub const ORGN1_WBWA: u64 = 0b01 << 26;

    // IRGN1 - TTBR1 inner cacheability (bits 24-25)
    pub const IRGN1_NC: u64 = 0b00 << 24;
    pub const IRGN1_WBWA: u64 = 0b01 << 24;

    // IPS - Intermediate physical address size (bits 32-34)
    pub const IPS_32BIT: u64 = 0b000 << 32; // 4GB
    pub const IPS_36BIT: u64 = 0b001 << 32; // 64GB
    pub const IPS_40BIT: u64 = 0b010 << 32; // 1TB
    pub const IPS_42BIT: u64 = 0b011 << 32; // 4TB
    pub const IPS_44BIT: u64 = 0b100 << 32; // 16TB
    pub const IPS_48BIT: u64 = 0b101 << 32; // 256TB

    // A1 - ASID selection (bit 22)
    pub const A1: u64 = 1 << 22; // ASID from TTBR1

    // AS - ASID size (bit 36)
    pub const AS_8BIT: u64 = 0 << 36;
    pub const AS_16BIT: u64 = 1 << 36;

    // EPD0 - Disable TTBR0 walks (bit 7)
    pub const EPD0: u64 = 1 << 7;

    // EPD1 - Disable TTBR1 walks (bit 23)
    pub const EPD1: u64 = 1 << 23;
};

// ============================================================
// MAIR_EL1 - Memory Attribute Indirection Register
// ============================================================

pub const MAIR = struct {
    // Each attribute index is 8 bits
    // Attr0: Device-nGnRnE (0x00)
    // Attr1: Normal cacheable (0xFF = Inner/Outer write-back, read/write allocate)
    // Attr2: Normal non-cacheable (0x44)
    pub const DEVICE: u64 = 0x00;
    pub const NORMAL: u64 = 0xFF;
    pub const NORMAL_NC: u64 = 0x44;

    pub const VALUE: u64 = DEVICE | (NORMAL << 8) | (NORMAL_NC << 16);
};

// ============================================================
// State
// ============================================================

var kernel_l0_table: ?*PageTable = null;
var mmu_initialized: bool = false;

// ============================================================
// Page Table Structure
// ============================================================

pub const PageTable = extern struct {
    entries: [ENTRIES_PER_TABLE]u64 align(PAGE_SIZE),

    pub fn init() PageTable {
        return .{ .entries = [_]u64{0} ** ENTRIES_PER_TABLE };
    }

    pub fn clear(self: *PageTable) void {
        for (&self.entries) |*e| {
            e.* = 0;
        }
    }

    pub fn getEntry(self: *PageTable, index: usize) u64 {
        return self.entries[index];
    }

    pub fn setEntry(self: *PageTable, index: usize, value: u64) void {
        self.entries[index] = value;
    }

    pub fn physAddr(self: *PageTable) u64 {
        return @intFromPtr(self);
    }
};

// ============================================================
// Address Space (per-process)
// ============================================================

pub const AddressSpace = struct {
    /// L0 page table physical address (for TTBR0_EL1)
    root: u64,
    /// Address Space ID
    asid: u16,

    /// Create a new address space with an empty L0 table
    pub fn create() ?AddressSpace {
        // Use raw allocator to avoid optional return bug
        const l0_phys = memory.allocContiguousRaw(1);
        if (l0_phys == 0) return null;

        // Zero the table
        const l0: *PageTable = @ptrFromInt(l0_phys);
        l0.clear();

        return .{
            .root = l0_phys,
            .asid = allocAsid(),
        };
    }

    pub fn destroy(self: *AddressSpace) void {
        // Walk and free all page tables (L4-style recursive cleanup)
        freePageTableTree(@ptrFromInt(self.root), 0);
        freeAsid(self.asid);
    }

    /// Map a virtual address to a physical address (returns false on failure)
    pub fn mapRaw(self: *AddressSpace, virt: u64, phys: u64, flags: u64) bool {
        return mapPageRaw(@ptrFromInt(self.root), virt, phys, flags);
    }

    /// Map a range of pages (returns false on first failure)
    pub fn mapRangeRaw(self: *AddressSpace, virt_start: u64, phys_start: u64, size: u64, flags: u64) bool {
        var virt = virt_start;
        var phys = phys_start;
        const end = virt_start + size;

        while (virt < end) : ({
            virt += PAGE_SIZE;
            phys += PAGE_SIZE;
        }) {
            if (!self.mapRaw(virt, phys, flags)) return false;
        }
        return true;
    }

    /// Unmap a virtual address
    pub fn unmap(self: *AddressSpace, virt: u64) void {
        unmapPage(@ptrFromInt(self.root), virt);
    }

    /// Get the TTBR0 value for this address space (combines root + ASID)
    pub fn getTtbr0(self: *const AddressSpace) u64 {
        return self.root | (@as(u64, self.asid) << 48);
    }
};

// ============================================================
// ASID Management
// ============================================================

const MAX_ASID: u16 = 256; // 8-bit ASID
var asid_bitmap: [MAX_ASID / 8]u8 = [_]u8{0} ** (MAX_ASID / 8);
var next_asid: u16 = 1; // ASID 0 reserved for kernel

fn allocAsid() u16 {
    // Simple linear search
    var i: u16 = 1;
    while (i < MAX_ASID) : (i += 1) {
        const byte_idx = i / 8;
        const bit: u3 = @truncate(i % 8);
        if ((asid_bitmap[byte_idx] & (@as(u8, 1) << bit)) == 0) {
            asid_bitmap[byte_idx] |= (@as(u8, 1) << bit);
            return i;
        }
    }
    // Fall back to round-robin if all ASIDs used
    const asid = next_asid;
    next_asid = if (next_asid >= MAX_ASID - 1) 1 else next_asid + 1;
    return asid;
}

fn freeAsid(asid: u16) void {
    if (asid == 0 or asid >= MAX_ASID) return;
    const byte_idx = asid / 8;
    const bit: u3 = @truncate(asid % 8);
    asid_bitmap[byte_idx] &= ~(@as(u8, 1) << bit);
}

// ============================================================
// Page Table Manipulation
// ============================================================

/// Extract index for each level from virtual address
fn getL0Index(virt: u64) usize {
    return @truncate((virt >> 39) & 0x1FF);
}

fn getL1Index(virt: u64) usize {
    return @truncate((virt >> 30) & 0x1FF);
}

fn getL2Index(virt: u64) usize {
    return @truncate((virt >> 21) & 0x1FF);
}

fn getL3Index(virt: u64) usize {
    return @truncate((virt >> 12) & 0x1FF);
}

/// Get or create a page table at the next level
/// Returns the table address, or 0 on failure
fn getOrCreateTableRaw(table: *PageTable, index: usize) u64 {
    const entry = table.entries[index];

    if ((entry & PTE.VALID) != 0) {
        // Entry exists, extract table address
        return entry & PTE.ADDR_MASK;
    }

    // Use raw allocator to avoid optional return bug
    const new_table_phys = memory.allocContiguousRaw(1);
    if (new_table_phys == 0) return 0;

    const new_table: *PageTable = @ptrFromInt(new_table_phys);
    new_table.clear();

    // Create table descriptor
    table.entries[index] = new_table_phys | PTE.TABLE_DESC;

    return new_table_phys;
}

/// Map a single 4KB page
/// Returns true on success, false on failure
fn mapPageRaw(l0: *PageTable, virt: u64, phys: u64, flags: u64) bool {
    const l0_idx = getL0Index(virt);
    const l1_idx = getL1Index(virt);
    const l2_idx = getL2Index(virt);
    const l3_idx = getL3Index(virt);

    // Walk/create page tables
    const l1_phys = getOrCreateTableRaw(l0, l0_idx);
    if (l1_phys == 0) return false;
    const l1: *PageTable = @ptrFromInt(l1_phys);

    const l2_phys = getOrCreateTableRaw(l1, l1_idx);
    if (l2_phys == 0) return false;
    const l2: *PageTable = @ptrFromInt(l2_phys);

    const l3_phys = getOrCreateTableRaw(l2, l2_idx);
    if (l3_phys == 0) return false;
    const l3: *PageTable = @ptrFromInt(l3_phys);

    // Set L3 entry (4KB page)
    l3.entries[l3_idx] = (phys & PTE.ADDR_MASK) | flags;
    return true;
}

/// Map a single 4KB page (error union wrapper for compatibility)
fn mapPage(l0: *PageTable, virt: u64, phys: u64, flags: u64) !void {
    if (!mapPageRaw(l0, virt, phys, flags)) {
        return error.OutOfMemory;
    }
}

/// Recursively free all page tables in a tree
/// level: 0=L0, 1=L1, 2=L2, 3=L3
/// Note: Does NOT free the leaf pages (those are tracked separately in Process.memory_regions)
/// This follows L4/seL4 design where data pages are tracked separately from page table pages
fn freePageTableTree(table: *PageTable, level: u8) void {
    const boot = root.boot;

    // Walk all entries in this table
    for (table.entries) |entry| {
        // Skip invalid entries
        if ((entry & PTE.VALID) == 0) continue;

        // At L3, entries point to data pages (tracked separately), not tables
        if (level == 3) continue;

        // Get the address of the next-level table
        const next_addr = entry & PTE.ADDR_MASK;

        // Skip kernel memory (don't free kernel pages)
        // Kernel is identity-mapped at 0x40000000
        if (next_addr >= boot.MEMORY_BASE and next_addr < boot.MEMORY_BASE + 4 * 1024 * 1024) {
            continue;
        }

        // Recurse into next level
        const next_table: *PageTable = @ptrFromInt(next_addr);
        freePageTableTree(next_table, level + 1);

        // Free the next-level table itself
        memory.freeFrame(next_addr);
    }

    // Free this table (except L0 which is freed in destroy())
    if (level > 0) {
        // Table was already freed by parent, don't double-free
    } else {
        // L0 table - free it
        memory.freeFrame(@intFromPtr(table));
    }
}

/// Unmap a single page
fn unmapPage(l0: *PageTable, virt: u64) void {
    const l0_idx = getL0Index(virt);
    const l1_idx = getL1Index(virt);
    const l2_idx = getL2Index(virt);
    const l3_idx = getL3Index(virt);

    // Walk tables, abort if any level is invalid
    var entry = l0.entries[l0_idx];
    if ((entry & PTE.VALID) == 0) return;

    const l1: *PageTable = @ptrFromInt(entry & PTE.ADDR_MASK);
    entry = l1.entries[l1_idx];
    if ((entry & PTE.VALID) == 0) return;

    const l2: *PageTable = @ptrFromInt(entry & PTE.ADDR_MASK);
    entry = l2.entries[l2_idx];
    if ((entry & PTE.VALID) == 0) return;

    const l3: *PageTable = @ptrFromInt(entry & PTE.ADDR_MASK);

    // Clear the entry
    l3.entries[l3_idx] = 0;

    // Invalidate TLB for this address
    invalidateTlbVa(virt);
}

// ============================================================
// TLB Management
// ============================================================

/// Invalidate entire TLB
pub fn invalidateTlbAll() void {
    asm volatile (
        \\dsb ishst
        \\tlbi vmalle1is
        \\dsb ish
        \\isb
    );
}

/// Invalidate TLB for a specific virtual address
pub fn invalidateTlbVa(virt: u64) void {
    // TLBI VAE1IS - Invalidate by VA, EL1, Inner Shareable
    const va_shifted = virt >> 12;
    asm volatile ("tlbi vae1is, %[va]"
        :
        : [va] "r" (va_shifted),
    );
    asm volatile (
        \\dsb ish
        \\isb
    );
}

/// Invalidate TLB for an ASID
pub fn invalidateTlbAsid(asid: u16) void {
    const asid64: u64 = @as(u64, asid) << 48;
    asm volatile ("tlbi aside1is, %[asid]"
        :
        : [asid] "r" (asid64),
    );
    asm volatile (
        \\dsb ish
        \\isb
    );
}

// ============================================================
// MMU Register Access
// ============================================================

pub fn readTtbr0() u64 {
    return asm volatile ("mrs %[ttbr], ttbr0_el1"
        : [ttbr] "=r" (-> u64),
    );
}

pub fn writeTtbr0(value: u64) void {
    asm volatile ("msr ttbr0_el1, %[value]"
        :
        : [value] "r" (value),
    );
}

pub fn readTtbr1() u64 {
    return asm volatile ("mrs %[ttbr], ttbr1_el1"
        : [ttbr] "=r" (-> u64),
    );
}

pub fn writeTtbr1(value: u64) void {
    asm volatile ("msr ttbr1_el1, %[value]"
        :
        : [value] "r" (value),
    );
}

pub fn writeTcr(value: u64) void {
    asm volatile ("msr tcr_el1, %[value]"
        :
        : [value] "r" (value),
    );
}

pub fn writeMair(value: u64) void {
    asm volatile ("msr mair_el1, %[value]"
        :
        : [value] "r" (value),
    );
}

pub fn readSctlr() u64 {
    return asm volatile ("mrs %[sctlr], sctlr_el1"
        : [sctlr] "=r" (-> u64),
    );
}

pub fn writeSctlr(value: u64) void {
    asm volatile ("msr sctlr_el1, %[value]"
        :
        : [value] "r" (value),
    );
}

// ============================================================
// MMU Initialization
// ============================================================

/// Initialize the MMU with kernel identity mapping
pub fn init() void {
    const console = root.console;
    const boot = root.boot;

    // Allocate L0 table using raw allocator (avoids optional return codegen issue)
    const l0_phys = memory.allocContiguousRaw(1);
    if (l0_phys == 0) {
        console.puts("  Failed to allocate L0 table!\n");
        return;
    }
    console.puts("  L0 table at: ");
    console.putHex(l0_phys);
    console.newline();

    kernel_l0_table = @ptrFromInt(l0_phys);
    kernel_l0_table.?.clear();

    // Identity map kernel memory
    // We only map what we need for initial kernel operation
    console.puts("  Identity mapping kernel space...\n");

    // Map kernel code/data region AND page table area
    // The kernel code is in the first 1MB, but page tables get allocated
    // starting at 1MB mark. We need to map enough to include them.
    // Map 4MB to have headroom for page tables allocated during this mapping.
    var addr: u64 = boot.MEMORY_BASE;
    const kernel_end = boot.MEMORY_BASE + 4 * 1024 * 1024; // 4MB for kernel + page tables
    var page_count: u32 = 0;

    // Map 4MB with kernel-only permissions
    // Note: Userspace threads will need their own address space or special mapping
    while (addr < kernel_end) : (addr += PAGE_SIZE) {
        if (page_count % 64 == 0) {
            console.putc('.');
        }
        if (!mapPageRaw(kernel_l0_table.?, addr, addr, PTE.KERNEL_RWX)) {
            console.puts("\n  Failed to map kernel page at ");
            console.putHex(addr);
            console.puts("!\n");
            return;
        }
        page_count += 1;
    }
    console.newline();
    console.puts("  Mapped ");
    console.putDec(page_count);
    console.puts(" kernel pages\n");

    // Map device memory (UART, GIC)
    console.puts("  Mapping device memory...\n");
    _ = mapPageRaw(kernel_l0_table.?, boot.UART_BASE, boot.UART_BASE, PTE.DEVICE_RW);
    _ = mapPageRaw(kernel_l0_table.?, boot.GIC_DIST_BASE, boot.GIC_DIST_BASE, PTE.DEVICE_RW);
    _ = mapPageRaw(kernel_l0_table.?, boot.GIC_CPU_BASE, boot.GIC_CPU_BASE, PTE.DEVICE_RW);

    // Configure MMU registers
    console.puts("  Configuring MMU registers...\n");

    // Set MAIR (Memory Attribute Indirection Register)
    writeMair(MAIR.VALUE);

    // Set TCR (Translation Control Register)
    // T0SZ=16 (48-bit VA for user), T1SZ=16 (48-bit VA for kernel)
    // 4KB granule, inner shareable, write-back cacheable
    const tcr_value: u64 = (16 << TCR.T0SZ_SHIFT) | // T0SZ = 16 (48-bit)
        (16 << TCR.T1SZ_SHIFT) | // T1SZ = 16 (48-bit)
        TCR.TG0_4KB |
        TCR.TG1_4KB |
        TCR.SH0_INNER |
        TCR.SH1_INNER |
        TCR.ORGN0_WBWA |
        TCR.IRGN0_WBWA |
        TCR.ORGN1_WBWA |
        TCR.IRGN1_WBWA |
        TCR.IPS_40BIT; // 1TB physical address space

    writeTcr(tcr_value);

    // Set TTBR0 (user space - will be per-process)
    // For now, point to kernel table for identity mapping
    writeTtbr0(l0_phys);

    // Set TTBR1 (kernel space - shared across all processes)
    writeTtbr1(l0_phys);

    // Enable MMU
    console.puts("  Enabling MMU...");
    var sctlr = readSctlr();
    sctlr |= (1 << 0); // M bit - Enable MMU
    sctlr |= (1 << 2); // C bit - Enable data cache
    sctlr |= (1 << 12); // I bit - Enable instruction cache

    // Ensure changes are visible before enabling MMU
    asm volatile (
        \\dsb sy
        \\isb
    );

    // Enable!
    writeSctlr(sctlr);

    // Synchronization after MMU enable
    asm volatile (
        \\isb
    );

    console.puts("OK\n");

    // Invalidate TLB
    console.puts("  Invalidating TLB...");
    invalidateTlbAll();
    console.puts("OK\n");

    mmu_initialized = true;
    console.puts("  MMU enabled successfully\n");
}

/// Check if MMU is initialized
pub fn isInitialized() bool {
    return mmu_initialized;
}

/// Switch to a different address space (TTBR0)
pub fn switchAddressSpace(addr_space: *const AddressSpace) void {
    // Combine ASID and table base address
    const ttbr0_value = addr_space.root | (@as(u64, addr_space.asid) << 48);
    writeTtbr0(ttbr0_value);
    asm volatile ("isb");
}

/// Get the kernel page table root
pub fn getKernelRoot() u64 {
    if (kernel_l0_table) |table| {
        return @intFromPtr(table);
    }
    return 0;
}

/// Map a page in the kernel address space (for dynamically allocated kernel memory)
/// Returns true on success, false on failure
/// NOTE: Does NOT invalidate TLB - caller should call invalidateTlbAll() after bulk updates
pub fn mapKernelPageRaw(virt: u64, phys: u64, flags: u64) bool {
    if (kernel_l0_table) |table| {
        return mapPageRaw(table, virt, phys, flags);
    }
    return false;
}
