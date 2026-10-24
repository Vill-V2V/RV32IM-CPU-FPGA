RV32M/DRAM 诊断程序

数码管结果：
60000001 = MUL、MULH、MULHU、MULHSU、MUL结果前递、DRAM字读写全部通过
60000011 = MUL低32位错误
60000022 = DRAM字读写或流水线前递错误
60000033 = MULH错误
60000044 = MULHU错误
60000055 = MULHSU错误

使用：临时用 irom_mul_diag.coe 初始化IROM，用 dram_zero_diag.coe 初始化DRAM，重新生成IP Output Products，Reset Synthesis/Implementation Runs 后重新生成bitstream。测试后恢复官方coe。
