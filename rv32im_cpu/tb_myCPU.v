`timescale 1ns / 1ps

module tb_myCPU;
    reg         clk;
    reg         rst;
    wire [31:0] irom_addr;
    reg  [31:0] irom_data;
    wire [31:0] perip_addr;
    wire        perip_wen;
    wire [1:0]  perip_mask;
    wire [31:0] perip_wdata;
    reg  [31:0] perip_rdata;

    // 实例化待测 CPU
    myCPU u_cpu (
        .cpu_rst(rst),
        .cpu_clk(clk),
        .irom_addr(irom_addr),
        .irom_data(irom_data),
        .perip_addr(perip_addr),
        .perip_wen(perip_wen),
        .perip_mask(perip_mask),
        .perip_wdata(perip_wdata),
        .perip_rdata(perip_rdata)
    );

    // 时钟生成 (50MHz -> 周期 20ns)
    initial begin
        clk = 0;
        forever #10 clk = ~clk;
    end

    // 模拟 IROM (只读指令存储器)
    reg [31:0] mem_irom [0:1023]; 
    always @(*) begin
        // 将 0x8000_0000 映射到数组索引 0
        irom_data = mem_irom[(irom_addr - 32'h8000_0000) >> 2];
    end

    initial begin
        // 汇编指令机器码测试用例:
        // 0x8000_0000: addi x1, x0, 5    (00500093)
        // 0x8000_0004: addi x2, x0, 10   (00a00113)
        // 0x8000_0008: add  x3, x1, x2   (002081b3)
        mem_irom[0] = 32'h00500093; 
        mem_irom[1] = 32'h00a00113; 
        mem_irom[2] = 32'h002081b3; 
        mem_irom[3] = 32'h00000013; // NOP
        mem_irom[4] = 32'h00000013; // NOP

        rst = 1;
        perip_rdata = 32'b0;
        #25 rst = 0; // 错开时钟上升沿释放复位

        #200;
        $finish; // 结束仿真
    end
    
    // 监控波形输出
    initial begin
        $dumpfile("cpu_wave.vcd");
        $dumpvars(0, tb_myCPU);
    end
endmodule