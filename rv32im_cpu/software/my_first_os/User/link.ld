OUTPUT_ARCH( "riscv" )
ENTRY( _start )

MEMORY
{
    IROM (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
    DRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text :
    {
        *(.text*)
        *(.rodata*)
    } > IROM

    .data :
    {
        *(.data*)
    } > DRAM

    .bss :
    {
        *(.bss*)
    } > DRAM
}