.section .init, "ax"
.global _start

_start:
    /* 初始化所有的 32 个寄存器为 0 (防止有乱码) */
    li x1, 0
    li x2, 0
    li x3, 0
    /* ... 假装这里初始化了所有寄存器 ... */

    /* 设置栈指针 SP (x2) 指向内存 DRAM 的高处，假设是 0x00010000 */
    li sp, 0x00010000

    /* 猛踩油门，跳入 C 语言的 main 函数！ */
    jal main

_end:
    j _end