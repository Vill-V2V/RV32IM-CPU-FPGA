`timescale 1ns / 1ps

module myCPU (
    input  wire        cpu_rst,     
    input  wire        cpu_clk,     
    
    output wire [31:0] irom_addr,   
    input  wire [31:0] irom_data,   
    
    output wire [31:0] perip_addr,  
    output wire        perip_wen,   
    output wire [1:0]  perip_mask,  
    output wire [31:0] perip_wdata, 
    input  wire [31:0] perip_rdata  
);

    // =================================================================
    // 1. IF Stage
    // =================================================================
    reg  [31:0] pc;
    wire [31:0] next_pc;
    wire        stall_if; 
    wire        flush_if; 

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            pc <= 32'h8000_0000; 
        end else if (!stall_if) begin
            pc <= next_pc;
        end
    end

    assign irom_addr = pc;
    wire [31:0] if_inst = (flush_if) ? 32'h00000013 : irom_data; 

    // =================================================================
    // 2. IF/ID Pipeline Register
    // =================================================================
    reg [31:0] id_pc, id_inst;
    wire stall_id; // Load-Use Hazard 停顿
    
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst || flush_if) begin
            id_pc   <= 32'b0;
            id_inst <= 32'h00000013; // NOP
        end else if (!stall_id) begin
            id_pc   <= pc;
            id_inst <= if_inst;
        end
    end

    // =================================================================
    // 3. ID Stage
    // =================================================================
    wire [4:0]  rs1    = id_inst[19:15];
    wire [4:0]  rs2    = id_inst[24:20];
    wire [4:0]  rd     = id_inst[11:7];
    wire [6:0]  opcode = id_inst[6:0];
    wire [2:0]  funct3 = id_inst[14:12];
    wire [6:0]  funct7 = id_inst[31:25];
    
    wire [31:0] reg_rdata1, reg_rdata2;
    wire        wb_wen;       
    wire [4:0]  wb_rd;        
    wire [31:0] wb_wdata;     

    RegFile u_RegFile (
        .clk(cpu_clk),
        .rs1(rs1), .rs2(rs2),
        .rdata1(reg_rdata1), .rdata2(reg_rdata2),
        .we(wb_wen), .rd(wb_rd), .wdata(wb_wdata)
    );

    // 完整的立即数生成器 (ImmGen)
    reg [31:0] imm;
    always @(*) begin
        case (opcode)
            // I-Type (ADDI, SLTI, etc), Load, JALR
            7'b0010011, 7'b0000011, 7'b1100111: 
                imm = {{20{id_inst[31]}}, id_inst[31:20]};
            // S-Type (Store)
            7'b0100011: 
                imm = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
            // B-Type (Branch)
            7'b1100011: 
                imm = {{20{id_inst[31]}}, id_inst[7], id_inst[30:25], id_inst[11:8], 1'b0};
            // U-Type (LUI, AUIPC)
            7'b0110111, 7'b0010111: 
                imm = {id_inst[31:12], 12'b0};
            // J-Type (JAL)
            7'b1101111: 
                imm = {{12{id_inst[31]}}, id_inst[19:12], id_inst[20], id_inst[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end

    // =================================================================
    // 4. ID/EX Pipeline Register
    // =================================================================
    reg [31:0] ex_pc, ex_rdata1, ex_rdata2, ex_imm;
    reg [4:0]  ex_rd, ex_rs1, ex_rs2; 
    reg [6:0]  ex_opcode, ex_funct7;
    reg [2:0]  ex_funct3;
    wire       flush_ex;
    
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst || flush_ex) begin
            ex_opcode <= 7'b0; ex_rs1 <= 5'b0; ex_rs2 <= 5'b0; ex_rd <= 5'b0;
        end else begin
            ex_pc     <= id_pc;
            ex_rdata1 <= reg_rdata1;
            ex_rdata2 <= reg_rdata2;
            ex_imm    <= imm;
            ex_rd     <= rd;
            ex_rs1    <= rs1; 
            ex_rs2    <= rs2; 
            ex_opcode <= opcode;
            ex_funct3 <= funct3;
            ex_funct7 <= funct7;
        end
    end

    // =================================================================
    // 5. EX Stage (Execution & Forwarding)
    // =================================================================
    wire mem_wen; 
    wire [31:0] forward_a, forward_b_reg;
    
    assign forward_a = (mem_wen && (mem_rd == ex_rs1) && (ex_rs1 != 5'b0)) ? mem_alu_result :
                       (wb_wen  && (wb_rd  == ex_rs1) && (ex_rs1 != 5'b0)) ? wb_wdata : ex_rdata1;

    assign forward_b_reg = (mem_wen && (mem_rd == ex_rs2) && (ex_rs2 != 5'b0)) ? mem_alu_result :
                           (wb_wen  && (wb_rd  == ex_rs2) && (ex_rs2 != 5'b0)) ? wb_wdata : ex_rdata2;

    // ALU 源操作数 MUX (支持所有指令类别)
    wire use_imm = (ex_opcode == 7'b0010011 || ex_opcode == 7'b0000011 || ex_opcode == 7'b0100011);
    wire [31:0] alu_a_in = (ex_opcode == 7'b0010111 || ex_opcode == 7'b1101111) ? ex_pc : forward_a; // AUIPC, JAL
    wire [31:0] alu_b_in = (ex_opcode == 7'b0110111 || ex_opcode == 7'b0010111 || ex_opcode == 7'b1101111) ? ex_imm : // LUI, AUIPC, JAL
                           use_imm ? ex_imm : forward_b_reg;

    wire [31:0] alu_result;
    wire        alu_zero, alu_lt, alu_ltu;
    
    ALU u_ALU (
        .a(alu_a_in), .b(alu_b_in),
        .opcode(ex_opcode), .funct3(ex_funct3), .funct7(ex_funct7),
        .result(alu_result), .zero(alu_zero), .lt(alu_lt), .ltu(alu_ltu)
    );

    // 分支判断逻辑 (Branch Unit)
    reg branch_taken;
    always @(*) begin
        if (ex_opcode == 7'b1100011) begin // Branch
            case (ex_funct3)
                3'b000: branch_taken = alu_zero;           // BEQ
                3'b001: branch_taken = !alu_zero;          // BNE
                3'b100: branch_taken = alu_lt;             // BLT
                3'b101: branch_taken = !alu_lt;            // BGE
                3'b110: branch_taken = alu_ltu;            // BLTU
                3'b111: branch_taken = !alu_ltu;           // BGEU
                default: branch_taken = 1'b0;
            endcase
        end else if (ex_opcode == 7'b1101111 || ex_opcode == 7'b1100111) begin // JAL, JALR
            branch_taken = 1'b1;
        end else begin
            branch_taken = 1'b0;
        end
    end

    // PC 跳转地址计算 (JALR 需要截断最低位)
    wire [31:0] jump_target = (ex_opcode == 7'b1100111) ? ((forward_a + ex_imm) & ~32'b1) : (ex_pc + ex_imm);
    assign next_pc = branch_taken ? jump_target : (pc + 4);
    
    // Load-Use Hazard 停顿逻辑
    wire ex_is_load = (ex_opcode == 7'b0000011);
    wire load_use_hazard = ex_is_load && (ex_rd != 5'b0) && ((ex_rd == rs1) || (ex_rd == rs2));
    
    assign stall_if = load_use_hazard;
    assign stall_id = load_use_hazard;
    assign flush_ex = load_use_hazard || branch_taken; 
    assign flush_if = branch_taken;

    // =================================================================
    // 6. EX/MEM Pipeline Register
    // =================================================================
    reg [31:0] mem_alu_result, mem_rdata2, mem_pc;
    reg [4:0]  mem_rd;
    reg [6:0]  mem_opcode;
    reg [2:0]  mem_funct3;
    
    always @(posedge cpu_clk) begin
        mem_alu_result <= alu_result;
        mem_rdata2     <= forward_b_reg; 
        mem_rd         <= ex_rd;
        mem_opcode     <= ex_opcode;
        mem_funct3     <= ex_funct3;
        mem_pc         <= ex_pc;
    end

    assign mem_wen = (mem_rd != 5'b0) && (mem_opcode != 7'b0100011) && (mem_opcode != 7'b1100011);

    // =================================================================
    // 7. MEM Stage (Memory Access)
    // =================================================================
    assign perip_addr  = mem_alu_result;
    assign perip_wdata = (mem_funct3 == 3'b000) ? {4{mem_rdata2[7:0]}} :   // SB
                         (mem_funct3 == 3'b001) ? {2{mem_rdata2[15:0]}} :  // SH
                         mem_rdata2;                                       // SW
    assign perip_wen   = (mem_opcode == 7'b0100011) ? 1'b1 : 1'b0; 
    
    // 动态内存掩码 (00:Byte, 01:Half, 10:Word)
    assign perip_mask  = (mem_funct3 == 3'b000 || mem_funct3 == 3'b100) ? 2'b00 : // LB, LBU, SB
                         (mem_funct3 == 3'b001 || mem_funct3 == 3'b101) ? 2'b01 : // LH, LHU, SH
                         2'b10; // LW, SW

    // =================================================================
    // 8. MEM/WB Pipeline Register
    // =================================================================
    reg [31:0] wb_alu_result, wb_mem_rdata, wb_pc;
    reg [4:0]  wb_rd_reg;
    reg [6:0]  wb_opcode;
    reg [2:0]  wb_funct3;

    always @(posedge cpu_clk) begin
        wb_alu_result <= mem_alu_result;
        wb_mem_rdata  <= perip_rdata;
        wb_rd_reg     <= mem_rd;
        wb_opcode     <= mem_opcode;
        wb_funct3     <= mem_funct3;
        wb_pc         <= mem_pc;
    end

    // =================================================================
    // 9. WB Stage (Write Back & Load Sign Extension)
    // =================================================================
    assign wb_rd = wb_rd_reg;
    assign wb_wen = (wb_rd != 5'b0) && (wb_opcode != 7'b0100011) && (wb_opcode != 7'b1100011); 
    
    reg [31:0] load_data;
    
    // Load 数据的符号/零扩展
    always @(*) begin
        case (wb_funct3)
            3'b000: load_data = {{24{wb_mem_rdata[7]}}, wb_mem_rdata[7:0]};     // LB
            3'b001: load_data = {{16{wb_mem_rdata[15]}}, wb_mem_rdata[15:0]};   // LH
            3'b010: load_data = wb_mem_rdata;                                   // LW
            3'b100: load_data = {24'b0, wb_mem_rdata[7:0]};                     // LBU
            3'b101: load_data = {16'b0, wb_mem_rdata[15:0]};                    // LHU
            default: load_data = wb_mem_rdata;
        endcase
    end

    // JAL/JALR 写入的是 PC+4，Load 写入 load_data，其他写入 alu_result
    assign wb_wdata = (wb_opcode == 7'b0000011) ? load_data :
                      (wb_opcode == 7'b1101111 || wb_opcode == 7'b1100111) ? (wb_pc + 4) : 
                      wb_alu_result;

endmodule