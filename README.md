# 面向嵌入式实时应用的轻量化 RV32IM 特权架构 CPU



本项目是 RV32I 五级流水线 CPU 的升级版本，在保持机器模式 CSR、Trap 异常处理和定时器中断的基础上，扩展了 **RV32M 整数乘除法** 与 **Zbkx XPERM4** 指令，并对流水线前端、访存旁路和分支预测进行了架构级优化。项目基于 Verilog / SystemVerilog 实现，支持 105 MHz 目标时序收敛。
仅供学习参考不可用于竞赛或作业，仅供参考，性能不高喵（）

- **指令集**：RV32I + RV32M + Zicsr + Zbkx XPERM4
- **微架构**：IF / ID / EX / MEM / WB 五级流水线
- **目标频率**：105 MHz
- **开发环境**：Vivado 2023.2 + MounRiver Studio
- **设计语言**：Verilog / SystemVerilog

---

## 目录

- [项目概述](#项目概述)
- [主要特性](#主要特性)
- [系统架构](#系统架构)
- [五级流水线设计](#五级流水线设计)
- [数据通路模块](#数据通路模块)
- [流水线冒险处理](#流水线冒险处理)
- [特权架构与异常中断](#特权架构与异常中断)
- [硬件定时器与外设](#硬件定时器与外设)
- [V2 版本新增特性](#v2-版本新增特性)
- [性能优化](#性能优化)
- [指令支持](#指令支持)
- [工程结构](#工程结构)
- [快速开始](#快速开始)
- [仿真验证](#仿真验证)
- [设计文档与图片](#设计文档与图片)
- [说明](#说明)

---

## 项目概述

本项目在初赛 RV32I 处理器的基础上，针对整数计算能力、控制冒险开销和访存停顿三个方向进行升级：

1. 扩展 RV32M 标准乘法/除法指令，增加 `MUL`、`MULH`、`MULHSU`、`MULHU`、`DIV`、`DIVU`、`REM`、`REMU` 共 8 条指令；
2. 新增 Zbkx `XPERM4` 位操作指令；
3. 新增 MEM 级 Load 到 EX 级同拍旁路，减少访存相关气泡；
4. 加入 64 项 2-bit 动态分支历史表（BHT）；
5. 加入 8 行写穿式栈字前推缓存，降低 O0 编译器产生的栈 Load-Use 停顿；
6. 保留 CSR、Trap、定时器中断等系统能力，最终实现 105 MHz 时序收敛。

处理器保持与初赛相同的外部接口，可继续部署于数字孪生 SoC 平台。

---

## 主要特性

### 处理器核心

- 完整支持 RV32I 基础整数指令集，共 37 条基础操作指令
- 支持 RV32M 乘除法扩展：`MUL` / `MULH` / `MULHSU` / `MULHU` / `DIV` / `DIVU` / `REM` / `REMU`
- 支持 Zbkx `XPERM4` 指令
- 支持 `CSRRW`、`CSRRS`、`CSRRC` 及立即数形式 Zicsr 指令
- 支持 `ECALL` 环境调用与 `MRET` 异常返回
- 经典五级线性流水线：IF / ID / EX / MEM / WB
- 32 × 32 bit 通用寄存器堆，`x0` 恒为 0
- 哈佛存储架构
- 支持字节、半字、字加载与存储

### 流水线控制

- EX/MEM、MEM/WB 到 EX 的全通路数据前推
- MEM 级 Load 到 EX 级同拍旁路
- ID 阶段分支提前重定向
- 64 项 2-bit 动态分支历史表
- Load-Use 冒险检测与单周期气泡插入
- 除法器多周期等待与流水线冻结
- 分支跳转与 Trap 触发时的流水线冲刷

### 特权与系统支持

- 机器模式 CSR：`mstatus`、`mtvec`、`mepc`、`mcause`
- 精确异常入口与现场保存
- `MRET` 恢复 `mstatus.MIE` 并返回 `mepc`
- 32 位硬件定时器 `mtime` / `mtimecmp`
- 定时器中断请求与全局中断使能门控
- 内存映射 I/O 外设接口

### SoC 与外设

- IROM / DRAM 存储接口
- UART 串口控制器
- 数码管显示驱动
- 外设桥接与地址译码
- 数字孪生控制器
- 板级顶层与验证测试平台
- 仿真性能计数器

---
## 系统架构

本项目采用哈佛存储架构与五级线性流水线拓扑。CPU 顶层模块 `myCPU` 连接指令存储器 IROM 和外设总线，内部划分为取指、译码、执行、访存、写回五个解耦阶段。

<p align="center">
  <img src="./docs/图1-CPU整体架构图.png" alt="CPU整体架构图" width="760">
</p>

<p align="center"><b>图 1　CPU 整体架构图</b></p>

CPU 顶层主要接口如下：

| 信号 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `cpu_rst` | 输入 | 1 | CPU 复位信号，高电平有效 |
| `cpu_clk` | 输入 | 1 | CPU 时钟信号 |
| `irom_addr` | 输出 | 32 | 指令 ROM 读取地址，输出当前 PC |
| `irom_data` | 输入 | 32 | 指令 ROM 返回的指令数据 |
| `perip_addr` | 输出 | 32 | 外设总线地址 |
| `perip_wen` | 输出 | 1 | 外设总线写使能 |
| `perip_mask` | 输出 | 2 | 写掩码：00=字节，01=半字，10=字 |
| `perip_wdata` | 输出 | 32 | 外设总线写数据 |
| `perip_rdata` | 输入 | 32 | 外设总线读数据 |

复位后 PC 初始化为 `32'h8000_0000`，流水线各级状态清零。

---

## 五级流水线设计

CPU 将指令执行过程划分为五个阶段，并通过四组流水线寄存器进行时序解耦：

```text
IF ──► IF/ID ──► ID ──► ID/EX ──► EX ──► EX/MEM ──► MEM ──► MEM/WB ──► WB
```

<p align="center">
  <img src="./docs/图2-CPU内部五级流水线数据通路原理图.png" alt="CPU内部五级流水线数据通路原理图" width="920">
</p>

<p align="center"><b>图 2　CPU 内部五级流水线数据通路原理图</b></p>

### 各阶段功能

| 阶段 | 主要功能 |
| --- | --- |
| IF | 维护 PC，输出取指地址，接收 IROM 指令数据 |
| ID | 指令译码、读取寄存器堆、生成立即数、分支比较、BHT 预测与重定向 |
| EX | ALU / Multiplier / Divider 运算、数据前推选择、CSR 写数据生成、异常与中断判断 |
| MEM | 数据存储器/外设访问、字节/半字/字写掩码处理、Load 旁路 |
| WB | 选择 ALU 结果、Load 数据、PC+4 或 CSR 数据写回寄存器堆 |

### 流水线寄存器

| 流水线寄存器 | 主要保存内容 |
| --- | --- |
| IF/ID | `id_valid`、`id_pc`、`id_inst` |
| ID/EX | `ex_valid`、`ex_pc`、`ex_rdata1`、`ex_rdata2`、`ex_imm`、`ex_rd`、`ex_rs1`、`ex_rs2`、`ex_opcode`、`ex_funct3`、`ex_funct7`、`ex_is_mul`、`ex_is_div` 等 |
| EX/MEM | `mem_alu_result`、`mem_rdata2`、`mem_rd`、`mem_opcode`、`mem_funct3`、`mem_pc`、CSR 相关信号 |
| MEM/WB | `wb_alu_result`、`wb_rd`、`wb_opcode`、`wb_funct3`、`wb_pc`、`wb_csr_rdata`、`wb_mem_rdata` |

---

## 数据通路模块

### IF 取指模块

- 包含 PC 寄存器，用于生成下一条指令地址。
- 根据 `ex_redirect` 与 `id_redirect` 决定 PC 更新优先级。
- 根据 `stall_if` 决定是否保持当前 PC。
- PC 通过 `irom_addr` 输出到指令存储器，并通过 `irom_data` 接收指令。

### ID 译码模块

- 通过 IF/ID 寄存器保存当前指令与 PC。
- 解析 `rs1`、`rs2`、`rd`、`opcode`、`funct3`、`funct7` 和 CSR 地址。
- 识别 RV32M 乘除法指令，生成 `id_is_mul` / `id_is_div` 标识。
- 识别 Zbkx `XPERM4` 指令并生成对应 ALU 控制码。
- 根据 BHT 预测结果与分支比较结果产生 ID 级重定向。

### EX 执行模块

- ALU 完成 RV32I 算术、逻辑、移位、比较运算。
- Multiplier 在 EX 阶段完成 RV32M 乘法并选择低/高 32 位结果。
- Divider 多周期执行除法/取余，未完成时冻结前级流水线。
- CSR 写数据生成与异常/中断判断在本级完成。

### MEM 访存模块

- 从 `mem_alu_result` 获取访存地址 `perip_addr`。
- 支持字节、半字、字写操作，通过 `perip_mask` 和 `perip_wdata` 控制写掩码与数据复制。
- 特殊地址映射：
  - `0xE0000000`：读取 `mtime`
  - `0xE0000004`：读取 `mtimecmp`
- 启用 Load 旁路时，可将 MEM 级读回数据直接送回 EX 级。

### WB 写回模块

- 根据指令类型选择写回数据：
  - Load：符号/零扩展后的存储器数据
  - JAL / JALR：`PC + 4`
  - CSR 指令：CSR 读值
  - 乘除法：乘法/除法结果
  - 其他指令：ALU 结果
- 由 `wb_wen` 控制寄存器堆写使能，写回目标为 `wb_rd`。

### 主要子模块

| 模块 | 功能 |
| --- | --- |
| `ImmGen` | 将指令中的 I/S/B/U/J 型位段拼接并符号扩展为 32 位立即数 |
| `BranchComp` | 根据 `opcode`、`funct3` 和两个比较数判断分支是否成立 |
| `ALU` | 执行算术、逻辑、移位、比较、XPERM4 等运算 |
| `Multiplier` | RV32M 乘法器，组合输出 64 位有符号乘积及高半字修正 |
| `Divider` | RV32M 除法器，32 次恢复式试商迭代 |
| `RegFile` | 32 × 32 bit 通用寄存器堆，支持双端口读和同步写 |
| `ForwardingUnit` | 检测跨流水级 RAW 依赖并生成前推选择信号 |
| `HazardUnit` | 检测 Load-Use 与分支依赖，产生 Stall / Flush 信号 |
| `CSR_Reg` | 管理 `mstatus`、`mtvec`、`mepc`、`mcause` |
| `TimerUnit` | 维护 `mtime` / `mtimecmp` 并产生定时器中断 |

---
## 流水线冒险处理

### 数据冒险

当后级指令需要读取前级指令尚未写回的结果时，会发生 RAW（Read After Write）数据冒险。本项目采用前推优先、必要时停顿的策略。

<p align="center">
  <img src="./docs/图3-RV32I核心数据前推网络微架构拓扑图.png" alt="RV32I核心数据前推网络微架构拓扑图" width="680">
</p>

<p align="center"><b>图 3　RV32I 核心数据前推网络微架构拓扑图</b></p>

前推路径包括：

- EX/MEM → EX
- MEM/WB → EX
- MEM 级 Load 读回数据 → EX（V2 新增同拍旁路）
- ID 阶段分支比较操作数前推

前推优先级：

| 条件 | 数据来源 | 优先级 |
| --- | --- | --- |
| MEM 阶段写寄存器与 EX 源寄存器匹配 | MEM 阶段 ALU 结果 | 最高 |
| WB 阶段写寄存器与 EX 源寄存器匹配 | WB 阶段写回数据 | 次高 |
| 无冲突 | 寄存器堆原始读数据 | 默认 |

### Load-Use 冒险

Load 指令的数据要到 MEM 阶段末才能获得，若下一条指令在 EX 阶段立即使用该数据，则无法仅靠前推解决。

处理方式：

1. 检测 EX 阶段是否为 Load 指令；
2. 判断其目标寄存器是否与 ID 阶段源寄存器冲突；
3. 拉高 `stall_if` 与 `stall_id`，保持 PC 和 IF/ID 寄存器；
4. 拉高 `flush_ex`，向 EX 阶段插入一个 NOP；
5. 下一拍数据到达后，再通过前推网络送入 ALU。

### 除法器多周期控制

- Divider 内部状态机在 `IDLE → CALC → DONE` 间迁移；
- 当 `DivOp=1` 且 `div_ready=0` 时，`div_wait` 拉高；
- `div_wait` 同时冻结 IF/ID 并清空 EX/MEM 寄存器（注入气泡）；
- 除法完成后 `div_ready` 有效，流水线继续。

### 控制冒险

- ID 阶段完成分支比较和跳转重定向；
- 64 项 2-bit BHT 提供分支方向预测；
- 分支/JALR 源寄存器存在依赖时先停顿并冲刷 EX；
- EX 级重定向优先级高于 ID 级重定向。

---

## 特权架构与异常中断

### CSR 寄存器

本项目实现机器模式下的核心 CSR：

| 寄存器 | 地址 | 核心位域 | 作用 |
| --- | --- | --- | --- |
| `mstatus` | `0x300` | `MIE`：全局中断使能；`MPIE`：异常前中断状态 | 控制中断开关，保存/恢复中断现场 |
| `mtvec` | `0x301` | `BASE`：异常入口基址；`MODE`：直接/向量模式 | 配置 Trap 入口地址 |
| `mepc` | `0x341` | 保存异常/中断发生时的 PC | 异常返回地址 |
| `mcause` | `0x342` | `Interrupt`：中断/异常标志；`Exception Code`：原因编码 | 异常原因诊断 |

### Trap 处理流程

1. `ECALL` 指令执行或定时器中断满足条件；
2. 控制器产生 `trap_enter`；
3. 流水线冲刷 IF/ID 与 EX 级无效指令；
4. 硬件将当前 PC 写入 `mepc`；
5. 将异常原因写入 `mcause`；
6. 保存 `MIE` 到 `MPIE`，并关闭全局中断；
7. 下一 PC 跳转到 `mtvec` 指向的入口。

### 异常返回

执行 `MRET` 时：

- 从 `mepc` 恢复 PC；
- 从 `MPIE` 恢复 `MIE`；
- 冲刷流水线并返回原程序执行流。

<p align="center">
  <img src="./docs/图5-硬件%20Trap%20触发与恢复的时序状态机流程图.png" alt="硬件Trap触发与恢复的时序状态机流程图" width="430">
</p>

<p align="center"><b>图 5　硬件 Trap 触发与恢复的时序状态机流程图</b></p>

---

## 硬件定时器与外设

### 定时器架构

CPU 内部集成 32 位硬件定时器：

- `mtime`：自由运行计数器，每个时钟上升沿自增；
- `mtimecmp`：比较阈值寄存器；
- 当 `mtime >= mtimecmp` 时，`timer_irq` 拉高；
- 只有 `mstatus.MIE = 1` 时，定时器中断才会被 CPU 接受。

### MMIO 地址映射

| 地址 | 读写 | 寄存器 | 功能 |
| --- | --- | --- | --- |
| `0xE0000000` | R/W | `mtime` | 32 位自由运行计数器 |
| `0xE0000004` | R/W | `mtimecmp` | 定时器比较值 |

### SoC 外设

| 外设 | 说明 |
| --- | --- |
| IROM | 指令存储器，PC 复位地址为 `0x8000_0000` |
| DRAM | 数据存储器 |
| UART | 串口收发与调试输出 |
| 数码管 | 显示调试状态或运行结果 |
| `perip_bridge` | 外设地址译码与总线桥接 |
| `twin_controller` | 数字孪生平台控制器 |
| `student_top` / `top` | 学生顶层与板级顶层 |

---
## V2 版本新增特性

### RV32M 乘除法扩展

本版本在 EX 阶段新增 `Multiplier` 与 `Divider` 模块，支持完整的 RV32M 子集。

| 单元 | 实现方式 | 性能 | 作用 |
| --- | --- | --- | --- |
| 乘法器 | 33×33 有符号乘积 + 高位修正项，组合逻辑输出 | `MUL`/`MULH`/`MULHSU`/`MULHU` 在 EX 阶段完成，不额外暂停 | 可综合到 FPGA DSP 资源，避免大量 LUT 组合乘法 |
| 除法器 | 迭代式 32 位恢复除法 | `DIV`/`DIVU`/`REM`/`REMU` 多周期完成，期间 `div_wait` 冻结前级流水线 | 避免长组合逻辑，换取更好的时序可收敛性 |

乘法器使用有符号 33×33 乘积作为基础结果，再通过补码修正公式得到混合符号/无符号高 32 位结果，保证 `MULHSU`、`MULHU` 的精确行为。

### Zbkx XPERM4 指令

在 ALU 中新增 `XPERM4` 操作，根据源寄存器 `rs2` 的 8 个 4-bit 索引，对 `rs1` 的 8 个半字节进行任意排列，输出 32 位结果。

### MEM 级 Load 到 EX 同拍旁路

当 EX 级指令的操作数与 MEM 级 Load 指令目标寄存器冲突时，可将 MEM 级读回数据在同拍送回 EX 级输入，减少 1 拍 Load-Use 气泡。

### 64 项 2-bit 动态分支历史表

采用 2-bit 饱和计数器 BHT，根据历史跳转行为预测分支方向，降低控制冒险带来的流水线空泡。

### 8 行栈字前推缓存

针对 O0 编译器通过 `x2(sp)` / `x8(s0/fp)` 频繁读写栈变量产生的 Load-Use 气泡，加入 8 行写穿式全字栈缓存：

- 命中时直接前推，消除大部分 O0 栈访问气泡；
- 未命中只损失性能，不影响正确性；
- 所有 Store 仍写穿到 DRAM，保证数据一致。

### 仿真性能计数器

CPU 中内置仿真专用性能计数器，可分层观测：

- `perf_load_stalls`：Load-Use 停顿周期
- `perf_mul_count`：乘法指令执行次数
- `perf_div_wait_cycles`：除法等待周期

这些计数器仅用于仿真观测，综合时会被忽略。

---

## 性能优化

### 五级流水线时序解耦

项目从初赛 80 MHz 起步，通过四组流水线寄存器切割关键路径、级间负载均衡与单周期 BRAM 访存对齐，最终在终赛版本实现 105 MHz 时序收敛。

| 指标 | 初赛优化前 | 初赛优化后 | 终赛目标 |
| --- | --- | --- | --- |
| 目标频率 | 80 MHz | 100 MHz | 105 MHz |
| CPU 核心 LUT | 1341 | 1628 | 设计文档未给出终赛口径 |
| LUT 增幅 | — | 约 21% | — |
| 频率提升 | — | 25% | — |
| 时序裕量 | 时序违例 | WNS 收敛为正 | Slack 为正 |

### 数据前推网络

保留 MEM/WB → EX 的全通路旁路网络，并新增 MEM Load 旁路，减少访存相关停顿。

### 分支提前判决与动态预测

在 ID 阶段提前重定向跳转目标，并配合 BHT 减少条件分支冲刷。

### 跨时钟域约束优化

系统存在 50 MHz 外设时钟域与 100/105 MHz CPU 时钟域。设计在 XDC 中使用异步时钟组约束：

```tcl
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_pins pll_inst/clk_out1]] \
  -group [get_clocks -of_objects [get_pins pll_inst/clk_out2]]
```

通过切断两个时钟域在时序分析中的耦合边，避免工具对异步跨域路径施加过严的建立/保持时间约束，将布局布线资源重新集中到 CPU 核心关键路径上。

---
## 指令支持

### RV32I 基础指令

| 类型 | 指令 |
| --- | --- |
| 算术运算 | `ADD`、`SUB`、`ADDI` |
| 逻辑运算 | `AND`、`OR`、`XOR`、`ANDI`、`ORI`、`XORI` |
| 移位运算 | `SLL`、`SRL`、`SRA`、`SLLI`、`SRLI`、`SRAI` |
| 比较运算 | `SLT`、`SLTU`、`SLTI`、`SLTIU` |
| 加载 | `LB`、`LH`、`LW`、`LBU`、`LHU` |
| 存储 | `SB`、`SH`、`SW` |
| 分支 | `BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU` |
| 跳转 | `JAL`、`JALR` |
| 立即数 | `LUI`、`AUIPC` |

### RV32M 乘除法指令

| 指令 | 说明 |
| --- | --- |
| `MUL` | 低 32 位有符号乘法 |
| `MULH` | 高 32 位有符号乘法 |
| `MULHSU` | 高 32 位有符号 × 无符号乘法 |
| `MULHU` | 高 32 位无符号乘法 |
| `DIV` | 有符号除法 |
| `DIVU` | 无符号除法 |
| `REM` | 有符号取余 |
| `REMU` | 无符号取余 |

### 特权与扩展指令

| 指令 | 说明 |
| --- | --- |
| `XPERM4` | Zbkx 半字节重排 |
| `CSRRW` / `CSRRS` / `CSRRC` | CSR 读改写 |
| `CSRRWI` / `CSRRSI` / `CSRRCI` | CSR 立即数读改写 |
| `ECALL` | 环境调用，进入机器模式异常 |
| `MRET` | 从异常返回，恢复 PC 与中断状态 |

### 写回数据来源

| 指令类型 | 写回数据 |
| --- | --- |
| ALU 类 | ALU 结果 |
| Load 类 | 扩展后的存储器数据 |
| JAL / JALR | `PC + 4` |
| CSR 类 | CSR 旧值 |
| M 扩展 | 乘法/除法结果 |
| Store / Branch | 不写回 |

---

## 工程结构

```text
.
├─ rv32im_cpu/                         # 基础 RV32IM CPU 工程
│  ├─ ALU .v                           # 算术逻辑单元
│  ├─ CSR_Reg.v                        # CSR 特权寄存器
│  ├─ Divider.v                        # RV32M 除法器
│  ├─ Multiplier.v                     # RV32M 乘法器
│  ├─ Multiplier.txt                   # 乘法器设计说明
│  ├─ Register File.v                  # 通用寄存器堆
│  ├─ myCPU.v                          # CPU 顶层（基础工程）
│  ├─ tb_myCPU.v                       # CPU 测试平台
│  ├─ uart_tx.v                        # UART 发送模块
│  ├─ os.coe / dram.coe / irom*.coe    # 测试程序机器码
│  ├─ coe/                             # 多组 IROM/DRAM 初始化文件
│  ├─ addd/                            # 乘法诊断 COE
│  ├─ withMext/                        # 含 M 扩展测试 COE
│  ├─ withoutMext/                     # 不含 M 扩展测试 COE
│  ├─ new/xperm4/                      # XPERM4 测试 COE
│  ├─ project_1/                       # Vivado 基础工程
│  │  ├─ project_1.xpr
│  │  └─ tb_myCPU_behav.wcfg
│  └─ software/my_first_os/            # MounRiver Studio 裸机软件工程
│     ├─ .cproject
│     ├─ .project
│     ├─ my_first_os.launch
│     ├─ my_first_os.wvproj
│     └─ User/
│        ├─ main.c
│        ├─ start.S
│        └─ link.ld
│
├─ digital_twin/                       # 数字孪生 SoC 工程
│  ├─ digital_twin.xpr
│  └─ digital_twin.srcs/
│     ├─ sources_1/
│     │  ├─ imports/new/               # CPU 核心 RTL（RV32IM + XPERM4）
│     │  ├─ imports/test_src/          # COE 初始化文件
│     │  ├─ new/                       # SoC 外设 RTL
│     │  └─ ip/                        # Vivado IP 配置
│     ├─ sim_1/new/                    # tb_myCPU / tb_top / tb_uart
│     └─ constrs_1/new/                # 时序与引脚约束
│
├─ docs/
│  ├─ CICC1003583 设计报告.docx
│  ├─ 图1-CPU整体架构图.png
│  ├─ 图2-CPU内部五级流水线数据通路原理图.png
│  ├─ 图3-RV32I核心数据前推网络微架构拓扑图.png
│  └─ 图5-硬件 Trap 触发与恢复的时序状态机流程图.png
│
├─ README.md
└─ .gitignore
```

---

## 快速开始

### 环境要求

- Vivado Design Suite 2023.2
- MounRiver Studio
- Xilinx 7 系列 FPGA 开发板
- 串口调试工具

### 1. 克隆仓库

```bash
git clone https://github.com/<your-name>/RV32IM-CPU-FPGA.git
cd RV32IM-CPU-FPGA
```

### 2. 打开 FPGA 工程

基础 CPU 工程：

```text
rv32im_cpu/project_1/project_1.xpr
```

完整数字孪生 SoC 工程：

```text
digital_twin/digital_twin.xpr
```

使用 Vivado 打开工程后：

1. 检查 IP 状态；
2. 如提示 IP 需要更新，执行 `Report IP Status`；
3. 按需执行 `Upgrade IP`；
4. 运行综合与实现；
5. 生成 Bitstream 并下载到 FPGA。

### 3. 编译软件

使用 MounRiver Studio 导入：

```text
rv32im_cpu/software/my_first_os
```

编译 `main.c` / `start.S`，生成裸机程序，并转换为 IROM/DRAM 初始化文件。

### 4. 软硬协同验证

1. 将软件编译生成的 `.coe` 文件放入对应工程；
2. 重新生成 IROM/DRAM IP；
3. 综合、实现并下载；
4. 通过 UART 观察程序运行结果；
5. 使用 Vivado 仿真检查流水线关键信号。

---

## 仿真验证

工程中包含以下测试平台：

| 测试平台 | 验证内容 |
| --- | --- |
| `tb_myCPU.sv` | RV32IM 指令执行、流水线控制、寄存器写回 |
| `tb_top.sv` | SoC 顶层、IROM/DRAM、外设互连 |
| `tb_uart.sv` | UART 发送时序与数据格式 |

仿真建议重点观察：

- PC 是否按预期跳转；
- 流水线寄存器在 Stall / Flush 时的行为；
- 乘法结果 `mul_low` / `mul_high_ss` / `mul_high_su` / `mul_high_uu` 是否正确；
- 除法器 `div_ready` 与 `div_wait` 行为；
- `XPERM4` 半字节重排结果；
- Load 旁路是否减少气泡；
- Trap 进入/退出时 `mepc`、`mcause`、`mstatus` 是否正确；
- `mtime >= mtimecmp` 时是否产生 `timer_irq`；
- 仿真性能计数器是否正常累加。

---

## 设计文档与图片

完整设计报告：

- [CICC1003583 设计报告](<./docs/CICC1003583 设计报告.docx>)

图片素材：

- [图 1 - CPU 整体架构图](./docs/图1-CPU整体架构图.png)
- [图 2 - CPU 内部五级流水线数据通路原理图](./docs/图2-CPU内部五级流水线数据通路原理图.png)
- [图 3 - RV32I 核心数据前推网络微架构拓扑图](./docs/图3-RV32I核心数据前推网络微架构拓扑图.png)
- [图 5 - 硬件 Trap 触发与恢复的时序状态机流程图](./docs/图5-硬件%20Trap%20触发与恢复的时序状态机流程图.png)

> 设计文档中的部分性能数据来自特定 Vivado 实现配置，实际综合结果可能因器件型号、约束版本和工具版本而有所不同。

---

## 说明

- 仓库仅保留 RTL 源码、Vivado 工程配置、约束、IP 配置、软件工程和设计文档。
- 不包含 Vivado 综合/实现缓存、Bitstream、安装包和许可证文件。
- 若打开工程后提示 IP 版本不匹配，请在 Vivado 中更新 IP。
- 如用于实际开发板，请根据板卡原理图检查引脚约束与时钟约束。
- 本项目为竞赛作品，如需引用或复用，请注明出处。

---

## License

本仓库暂未指定开源许可证。如需开源，可添加 MIT License 或 Apache-2.0 License。
##仅供学习参考不可用于比赛或作业
