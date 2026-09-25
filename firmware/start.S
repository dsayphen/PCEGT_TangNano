# Startup code for the PicoRV32 IO subsystem firmware.
#
# Based on the SNESTang start.S (nand2mario, GPLv3).  The stack top matches
# the firmware RAM window described in baremetal.ld.

.text
.global _start
.type _start, @function

.equ    STACK_TOP, 0x1B0000       # CD RAM starts here; stack grows down into firmware RAM

_start:
    li  sp,STACK_TOP    # load stack pointer

# zero-init bss section
    la a0, _sbss
    la a1, _ebss
    bge a0, a1, end_init_bss
loop_init_bss:
    sw zero, 0(a0)
    addi a0, a0, 4
    blt a0, a1, loop_init_bss

end_init_bss:
    call main
hang:
    j hang
