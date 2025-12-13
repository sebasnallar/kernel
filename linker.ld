/* MyLittleKernel Linker Script for ARM64 */
/* QEMU virt machine loads kernel at 0x40000000 */

ENTRY(_start)

SECTIONS
{
    /* QEMU virt machine RAM starts at 0x40000000 */
    . = 0x40000000;

    /* Code section */
    .text : ALIGN(4K)
    {
        KEEP(*(.text.boot))   /* Boot code must come first */
        *(.text .text.*)
    }

    /* Read-only data */
    .rodata : ALIGN(4K)
    {
        *(.rodata .rodata.*)
    }

    /* Initialized data */
    .data : ALIGN(4K)
    {
        *(.data .data.*)
    }

    /* Exception vector table (must be 2KB aligned, in writable memory) */
    .vectors : ALIGN(2K)
    {
        __vectors_start = .;
        KEEP(*(.data.vectors))
        __vectors_end = .;
    }

    /* Uninitialized data (zeroed) */
    .bss : ALIGN(4K)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    /* Stack space */
    . = ALIGN(4K);
    . += 64K;  /* 64KB kernel stack */
    __stack_top = .;

    /* Heap starts after stack */
    . = ALIGN(4K);
    __heap_start = .;

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
