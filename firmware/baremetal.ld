/*
 * Linker script for the PicoRV32 IO subsystem firmware of the Tang Nano 20K
 * PC Engine port.
 *
 * The softcore uses 1984 KiB at address 0, which iosys.v maps onto SDRAM
 * 0x400000..0x5EFFFF. The final 64 KiB of bank 2 is reserved for VDC1 VRAM.
 * _start (start.S) must sit at address 0 because that is where the core
 * begins executing once the firmware has been copied out of SPI flash.
 *
 * Only the first FIRMWARE_SIZE bytes (128 KiB, see rtl/top_tang_nano20k.v)
 * are copied from flash, so .text + .data must stay below that; .bss is
 * zeroed by start.S and may live anywhere in the remaining 1984 KiB.
 *
 * Based on the SNESTang baremetal.ld (nand2mario, GPLv3).
 */
MEMORY
{
    RAM (RWX) : ORIGIN = 0x00000, LENGTH = 0x1F0000
}
SECTIONS
{
    .text :
    {
        start.o (.text)
        *(.text)
        *(.text*)
        _end = .;
    }

    /* global and static variables with initial values */
    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.rodata)
        *(.rodata*)
        *(.data)
        *(.data*)
        *(.sdata)
        *(.sdata*)
        . = ALIGN(4);
        _edata = .;
    }

    /* global and static variables without initial values, zeroed by start.S */
    .bss :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss)
        *(.bss*)
        *(.sbss)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    }

    .heap :
    {
        . = ALIGN(4);
        _heap_start = .;
    }
}
