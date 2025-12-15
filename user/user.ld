/* User Program Linker Script for MyLittleKernel */
/* Programs are loaded at USER_CODE_BASE (0x100000) */

ENTRY(_start)

SECTIONS
{
    /* User code base address */
    . = 0x100000;

    /* Code section */
    .text : ALIGN(16)
    {
        *(.text .text.*)
    }

    /* Read-only data */
    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
    }

    /* Initialized data */
    .data : ALIGN(16)
    {
        *(.data .data.*)
    }

    /* Uninitialized data */
    .bss : ALIGN(16)
    {
        *(.bss .bss.*)
        *(COMMON)
    }

    /* Discard unnecessary sections */
    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
