`timescale 1ns / 1ps

// Performance-oriented, functionally exact RV32IM/Zicsr core.
// V4 adds an 8-line write-through stack-word forwarding cache on top of V3.
// The cache recognizes full-word loads/stores addressed through x2(sp) or
// x8(s0/fp).  It removes most O0 compiler stack load-use bubbles while all
// stores still reach DRAM, so a miss only loses performance, never correctness.
// External CPU interfaces and architectural behavior are unchanged.
// V5 aggressive general optimization:
//   1) MEM-stage load-to-EX same-cycle forwarding;
//   2) 64-entry 2-bit branch history table;
//   3) official RV32 Zbkx XPERM4 support.
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
    localparam [31:0] RESET_PC = 32'h8000_0000;

    localparam [3:0] ALU_ADD  = 4'd0;
    localparam [3:0] ALU_SUB  = 4'd1;
    localparam [3:0] ALU_SLL  = 4'd2;
    localparam [3:0] ALU_SLT  = 4'd3;
    localparam [3:0] ALU_SLTU = 4'd4;
    localparam [3:0] ALU_XOR  = 4'd5;
    localparam [3:0] ALU_SRL  = 4'd6;
    localparam [3:0] ALU_SRA  = 4'd7;
    localparam [3:0] ALU_OR   = 4'd8;
    localparam [3:0] ALU_AND  = 4'd9;
    localparam [3:0] ALU_XPERM4 = 4'd10;

    // Set either option to 0 for a quick timing fallback.
    localparam ENABLE_MEM_LOAD_BYPASS = 1'b1;
    localparam ENABLE_DYNAMIC_BHT     = 1'b1;

    // ================================================================
    // 1. IF stage
    // ================================================================
    reg  [31:0] pc;
    wire        stall_if;
    wire        ex_redirect;
    wire [31:0] ex_redirect_target;
    wire        id_redirect;
    wire [31:0] id_redirect_target;

    // Older EX-stage recovery always has priority over the younger ID-stage
    // prediction.  ID redirection is used for JAL and backward branches.
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            pc <= RESET_PC;
        else if (ex_redirect)
            pc <= ex_redirect_target;
        else if (id_redirect)
            pc <= id_redirect_target;
        else if (!stall_if)
            pc <= pc + 32'd4;
    end

    assign irom_addr = pc;

    // ================================================================
    // 2. IF/ID pipeline register
    // Only the valid bit is reset/flushed. Wide data registers do not need
    // reset muxes because every side effect is gated by the valid bits.
    // ================================================================
    reg         id_valid;
    reg  [31:0] id_pc;
    reg  [31:0] id_inst;
    wire        stall_id;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            id_valid <= 1'b0;
        end else if (ex_redirect || id_redirect) begin
            id_valid <= 1'b0;
        end else if (!stall_id) begin
            id_valid <= 1'b1;
            id_pc    <= pc;
            id_inst  <= irom_data;
        end
    end

    // ================================================================
    // 3. ID stage: immediate generation and early decode
    // ================================================================
    wire [4:0]  id_rs1     = id_inst[19:15];
    wire [4:0]  id_rs2     = id_inst[24:20];
    wire [4:0]  id_rd      = id_inst[11:7];
    wire [6:0]  id_opcode  = id_inst[6:0];
    wire [2:0]  id_funct3  = id_inst[14:12];
    wire [6:0]  id_funct7  = id_inst[31:25];
    wire [11:0] id_csr_addr= id_inst[31:20];

    wire wb_wen;
    wire [4:0] wb_rd;
    wire [31:0] wb_wdata;
    wire [31:0] reg_rdata1;
    wire [31:0] reg_rdata2;

    RegFile u_RegFile (
        .clk   (cpu_clk),
        .rs1   (id_rs1),
        .rs2   (id_rs2),
        .rdata1(reg_rdata1),
        .rdata2(reg_rdata2),
        .we    (wb_wen),
        .rd    (wb_rd),
        .wdata (wb_wdata)
    );

    reg [31:0] id_imm;
    always @(*) begin
        case (id_opcode)
            7'b0010011, 7'b0000011, 7'b1100111:
                id_imm = {{20{id_inst[31]}}, id_inst[31:20]};
            7'b0100011:
                id_imm = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
            7'b1100011:
                id_imm = {{20{id_inst[31]}}, id_inst[7], id_inst[30:25],
                          id_inst[11:8], 1'b0};
            7'b0110111, 7'b0010111:
                id_imm = {id_inst[31:12], 12'b0};
            7'b1101111:
                id_imm = {{12{id_inst[31]}}, id_inst[19:12], id_inst[20],
                          id_inst[30:21], 1'b0};
            default:
                id_imm = 32'b0;
        endcase
    end

    wire id_is_r       = (id_opcode == 7'b0110011);
    wire id_is_alu_imm = (id_opcode == 7'b0010011);
    wire id_is_load    = (id_opcode == 7'b0000011);
    wire id_is_store   = (id_opcode == 7'b0100011);
    wire id_is_branch  = (id_opcode == 7'b1100011);
    wire id_is_lui     = (id_opcode == 7'b0110111);
    wire id_is_auipc   = (id_opcode == 7'b0010111);
    wire id_is_jal     = (id_opcode == 7'b1101111);
    wire id_is_jalr    = (id_opcode == 7'b1100111);
    wire id_is_system  = (id_opcode == 7'b1110011);
    wire id_is_csr     = id_is_system && (id_funct3 != 3'b000);
    wire id_is_ecall   = id_is_system && (id_funct3 == 3'b000) &&
                         (id_csr_addr == 12'h000);
    wire id_is_mret    = id_is_system && (id_funct3 == 3'b000) &&
                         (id_csr_addr == 12'h302);
    wire id_is_xperm4 = id_is_r &&
                         (id_funct7 == 7'b0010100) &&
                         (id_funct3 == 3'b010);
    wire id_is_m_ext   = id_is_r && (id_funct7 == 7'b0000001);
    wire id_is_mul     = id_is_m_ext && !id_funct3[2];
    wire id_is_div     = id_is_m_ext &&  id_funct3[2];

    wire id_regwrite = id_is_r || id_is_alu_imm || id_is_load ||
                       id_is_lui || id_is_auipc || id_is_jal ||
                       id_is_jalr || id_is_csr;

    wire id_uses_rs1 = id_is_r || id_is_alu_imm || id_is_load ||
                       id_is_store || id_is_branch || id_is_jalr ||
                       (id_is_csr && !id_funct3[2]);

    reg [3:0] id_alu_ctrl;
    always @(*) begin
        id_alu_ctrl = ALU_ADD;
        if (id_is_r && !id_is_m_ext) begin
            case (id_funct3)
                3'b000: id_alu_ctrl = id_funct7[5] ? ALU_SUB : ALU_ADD;
                3'b001: id_alu_ctrl = ALU_SLL;
                3'b010: id_alu_ctrl = id_is_xperm4 ? ALU_XPERM4 : ALU_SLT;
                3'b011: id_alu_ctrl = ALU_SLTU;
                3'b100: id_alu_ctrl = ALU_XOR;
                3'b101: id_alu_ctrl = id_funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: id_alu_ctrl = ALU_OR;
                3'b111: id_alu_ctrl = ALU_AND;
                default:id_alu_ctrl = ALU_ADD;
            endcase
        end else if (id_is_alu_imm) begin
            case (id_funct3)
                3'b000: id_alu_ctrl = ALU_ADD;
                3'b001: id_alu_ctrl = ALU_SLL;
                3'b010: id_alu_ctrl = ALU_SLT;
                3'b011: id_alu_ctrl = ALU_SLTU;
                3'b100: id_alu_ctrl = ALU_XOR;
                3'b101: id_alu_ctrl = id_funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: id_alu_ctrl = ALU_OR;
                3'b111: id_alu_ctrl = ALU_AND;
                default:id_alu_ctrl = ALU_ADD;
            endcase
        end
    end

    wire id_use_imm = id_is_alu_imm || id_is_load || id_is_store;

    // A store needs rs1 in EX for its address, but rs2 is not consumed until
    // MEM.  This distinction lets a load followed by a store of the loaded
    // value proceed without a bubble; the value is forwarded in MEM.
    wire id_uses_rs2_in_ex = id_is_r || id_is_branch;

    // Precompute PC-relative targets and link values in ID, then register them.
    // This removes target/link adders from the EX control and writeback paths.
    wire [31:0] id_pc_imm_target = id_pc + id_imm;
    wire [31:0] id_link_value    = id_pc + 32'd4;

    // V5 branch predictor:
    // - backward branches retain the reliable V4 taken prediction;
    // - a 64-entry 2-bit BHT learns repeatedly taken forward branches.
    // Exact resolution still happens in EX, so aliasing only affects speed.
    reg [1:0] branch_bht [0:63];
    integer bht_i;

    wire [5:0] id_bht_index = id_pc[7:2];
    wire id_bht_taken = ENABLE_DYNAMIC_BHT &&
                        branch_bht[id_bht_index][1];
    wire id_predict_taken = id_valid && id_is_branch &&
                            (id_imm[31] || id_bht_taken);

    assign id_redirect = id_valid && !stall_id && !ex_redirect &&
                         (id_is_jal || id_predict_taken);
    assign id_redirect_target = id_pc_imm_target;

    // ================================================================
    // 4. ID/EX pipeline register
    // ================================================================
    reg         ex_valid;
    reg  [31:0] ex_pc;
    reg  [31:0] ex_rdata1;
    reg  [31:0] ex_rdata2;
    reg  [31:0] ex_imm;
    reg  [31:0] ex_pc_target;
    reg  [31:0] ex_link_value;
    reg  [4:0]  ex_rd;
    reg  [4:0]  ex_rs1;
    reg  [4:0]  ex_rs2;
    reg  [3:0]  ex_alu_ctrl;
    reg  [2:0]  ex_funct3;
    reg  [11:0] ex_csr_addr;
    reg         ex_use_imm;
    reg         ex_is_load;
    reg         ex_is_store;
    reg         ex_is_branch;
    reg         ex_is_lui;
    reg         ex_is_auipc;
    reg         ex_is_jal;
    reg         ex_is_jalr;
    reg         ex_is_mul;
    reg         ex_is_div;
    reg         ex_is_csr;
    reg         ex_is_ecall;
    reg         ex_is_mret;
    reg         ex_regwrite;
    reg         ex_pred_taken;

    wire flush_ex;
    wire stall_ex;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            ex_valid <= 1'b0;
        end else if (flush_ex) begin
            ex_valid <= 1'b0;
        end else if (!stall_ex) begin
            ex_valid      <= id_valid;
            ex_pc         <= id_pc;
            ex_rdata1     <= reg_rdata1;
            ex_rdata2     <= reg_rdata2;
            ex_imm        <= id_imm;
            ex_pc_target  <= id_pc_imm_target;
            ex_link_value <= id_link_value;
            ex_rd         <= id_rd;
            ex_rs1        <= id_rs1;
            ex_rs2        <= id_rs2;
            ex_alu_ctrl   <= id_alu_ctrl;
            ex_funct3     <= id_funct3;
            ex_csr_addr   <= id_csr_addr;
            ex_use_imm    <= id_use_imm;
            ex_is_load    <= id_is_load;
            ex_is_store   <= id_is_store;
            ex_is_branch  <= id_is_branch;
            ex_is_lui     <= id_is_lui;
            ex_is_auipc   <= id_is_auipc;
            ex_is_jal     <= id_is_jal;
            ex_is_jalr    <= id_is_jalr;
            ex_is_mul     <= id_is_mul;
            ex_is_div     <= id_is_div;
            ex_is_csr     <= id_is_csr;
            ex_is_ecall   <= id_is_ecall;
            ex_is_mret    <= id_is_mret;
            ex_regwrite   <= id_regwrite;
            ex_pred_taken <= id_predict_taken;
        end
    end

    // ================================================================
    // 5. EX stage and forwarding
    // ================================================================
    reg         mem_valid;
    reg  [31:0] mem_result;
    reg  [31:0] mem_store_data;
    reg  [4:0]  mem_rd;
    reg  [4:0]  mem_store_rs2;
    reg  [2:0]  mem_funct3;
    reg         mem_is_load;
    reg         mem_is_store;
    reg         mem_regwrite;
    reg         mem_stack_access;

    // The platform specification makes peripheral/DRAM reads available in
    // the current cycle. V5 extends a MEM-stage load and forwards it directly
    // into the following EX-stage instruction.
    function automatic [31:0] extend_load_data;
        input [31:0] raw_data;
        input [2:0]  funct3;
        begin
            case (funct3)
                3'b000: extend_load_data =
                    {{24{raw_data[7]}}, raw_data[7:0]};
                3'b001: extend_load_data =
                    {{16{raw_data[15]}}, raw_data[15:0]};
                3'b010: extend_load_data = raw_data;
                3'b100: extend_load_data = {24'b0, raw_data[7:0]};
                3'b101: extend_load_data = {16'b0, raw_data[15:0]};
                default:extend_load_data = raw_data;
            endcase
        end
    endfunction

    wire [31:0] mem_load_data =
        extend_load_data(perip_rdata, mem_funct3);

    // Final store data is needed both by the DRAM write port and by the
    // same-cycle store-to-load bypass below.
    wire [31:0] mem_store_data_final =
        (mem_valid && mem_is_store && wb_wen &&
         (mem_store_rs2 != 5'b0) && (mem_store_rs2 == wb_rd)) ?
        wb_wdata : mem_store_data;

    wire mem_forward_wen = mem_valid && mem_regwrite &&
                           (mem_rd != 5'b0) &&
                           (!mem_is_load || ENABLE_MEM_LOAD_BYPASS);
    wire [31:0] mem_forward_value =
        mem_is_load ? mem_load_data : mem_result;

    wire [31:0] forward_a =
        (mem_forward_wen && (mem_rd == ex_rs1) &&
         (ex_rs1 != 5'b0)) ? mem_forward_value :
        (wb_wen && (wb_rd == ex_rs1) &&
         (ex_rs1 != 5'b0)) ? wb_wdata :
        ex_rdata1;

    wire [31:0] forward_b_reg =
        (mem_forward_wen && (mem_rd == ex_rs2) &&
         (ex_rs2 != 5'b0)) ? mem_forward_value :
        (wb_wen && (wb_rd == ex_rs2) &&
         (ex_rs2 != 5'b0)) ? wb_wdata :
        ex_rdata2;

    wire [31:0] alu_b_in = ex_use_imm ? ex_imm : forward_b_reg;

    // The compact ALU is implemented locally instead of instantiating the
    // project ALU module.  This avoids an interface conflict with the original
    // ALU.sv, whose ports are opcode/funct3/funct7 rather than alu_ctrl.


    function automatic [3:0] xperm4_select;
        input [31:0] source;
        input [3:0]  index;
        begin
            case (index)
                4'd0: xperm4_select = source[3:0];
                4'd1: xperm4_select = source[7:4];
                4'd2: xperm4_select = source[11:8];
                4'd3: xperm4_select = source[15:12];
                4'd4: xperm4_select = source[19:16];
                4'd5: xperm4_select = source[23:20];
                4'd6: xperm4_select = source[27:24];
                4'd7: xperm4_select = source[31:28];
                default: xperm4_select = 4'b0000;
            endcase
        end
    endfunction
    reg [31:0] alu_result;
    always @(*) begin
        case (ex_alu_ctrl)
            ALU_ADD:  alu_result = forward_a + alu_b_in;
            ALU_SUB:  alu_result = forward_a - alu_b_in;
            ALU_SLL:  alu_result = forward_a << alu_b_in[4:0];
            ALU_SLT:  alu_result = ($signed(forward_a) < $signed(alu_b_in)) ? 32'd1 : 32'd0;
            ALU_SLTU: alu_result = (forward_a < alu_b_in) ? 32'd1 : 32'd0;
            ALU_XOR:  alu_result = forward_a ^ alu_b_in;
            ALU_SRL:  alu_result = forward_a >> alu_b_in[4:0];
            ALU_SRA:  alu_result = $signed(forward_a) >>> alu_b_in[4:0];
            ALU_OR:   alu_result = forward_a | alu_b_in;
            ALU_AND:  alu_result = forward_a & alu_b_in;
            ALU_XPERM4: alu_result = {
                xperm4_select(forward_a, forward_b_reg[31:28]),
                xperm4_select(forward_a, forward_b_reg[27:24]),
                xperm4_select(forward_a, forward_b_reg[23:20]),
                xperm4_select(forward_a, forward_b_reg[19:16]),
                xperm4_select(forward_a, forward_b_reg[15:12]),
                xperm4_select(forward_a, forward_b_reg[11:8]),
                xperm4_select(forward_a, forward_b_reg[7:4]),
                xperm4_select(forward_a, forward_b_reg[3:0])
            };
            default:  alu_result = forward_a + alu_b_in;
        endcase
    end

    // ---------------- Fast stack-word forwarding cache ----------------
    // The supplied benchmark is compiled without aggressive register
    // allocation and repeatedly spills loop variables to stack slots.  A
    // normal load followed immediately by a dependent ALU instruction costs
    // one bubble in this core.  The small cache below remembers the latest
    // full 32-bit values of eight stack words and turns a hit into an EX-stage
    // result, so the following instruction can use normal MEM forwarding.
    //
    // It is write-through: stores are still issued to DRAM.  Partial stores
    // invalidate a matching line.  Only x2/x8 based accesses are allocated,
    // which prevents matrix-array traffic from thrashing the stack entries.
    localparam integer STACK_CACHE_LINES = 8;
    reg        stack_cache_valid [0:STACK_CACHE_LINES-1];
    reg [26:0] stack_cache_tag   [0:STACK_CACHE_LINES-1];
    reg [31:0] stack_cache_data  [0:STACK_CACHE_LINES-1];

    wire [31:0] ex_mem_addr = forward_a + ex_imm;
    wire        ex_stack_access = (ex_rs1 == 5'd2) || (ex_rs1 == 5'd8);
    wire        ex_dram_addr = (ex_mem_addr[31:20] == 12'h801) &&
                               (ex_mem_addr[19:18] == 2'b00);
    wire [2:0]  ex_stack_index = ex_mem_addr[4:2];
    wire [26:0] ex_stack_tag   = ex_mem_addr[31:5];

    wire stack_cache_hit = ex_valid && ex_is_load && ex_stack_access &&
                           ex_dram_addr && (ex_funct3 == 3'b010) &&
                           (ex_mem_addr[1:0] == 2'b00) &&
                           stack_cache_valid[ex_stack_index] &&
                           (stack_cache_tag[ex_stack_index] == ex_stack_tag);

    // If the older instruction in MEM is a full-word store to exactly the
    // address being loaded in EX, its final value is newer than the cache and
    // must win.  This also handles SW immediately followed by LW.
    wire mem_store_is_word = mem_valid && mem_is_store &&
                             (mem_funct3 == 3'b010) &&
                             (mem_result[1:0] == 2'b00);
    wire mem_store_same_word = mem_store_is_word &&
                               (mem_result == ex_mem_addr);

    wire ex_fast_load_hit = ex_valid && ex_is_load && ex_stack_access &&
                            ex_dram_addr && (ex_funct3 == 3'b010) &&
                            (ex_mem_addr[1:0] == 2'b00) &&
                            (mem_store_same_word || stack_cache_hit);
    wire [31:0] ex_fast_load_data = mem_store_same_word ?
                                     mem_store_data_final :
                                     stack_cache_data[ex_stack_index];

    // ---------------- RV32M multiply ----------------
    wire [31:0] mul_low;
    wire [31:0] mul_high_ss;
    wire [31:0] mul_high_su;
    wire [31:0] mul_high_uu;

    Multiplier u_Multiplier (
        .a              (forward_a),
        .b              (forward_b_reg),
        .product_low    (mul_low),
        .product_high_ss(mul_high_ss),
        .product_high_su(mul_high_su),
        .product_high_uu(mul_high_uu)
    );

    reg [31:0] mul_result32;
    always @(*) begin
        case (ex_funct3)
            3'b000: mul_result32 = mul_low;
            3'b001: mul_result32 = mul_high_ss;
            3'b010: mul_result32 = mul_high_su;
            default:mul_result32 = mul_high_uu;
        endcase
    end

    // ---------------- RV32M divide/remainder ----------------
    reg  div_active;
    wire div_start = ex_valid && ex_is_div && !div_active;
    wire div_signed = (ex_funct3 == 3'b100) || (ex_funct3 == 3'b110);
    wire [31:0] div_quotient;
    wire [31:0] div_remainder;
    wire div_ready;

    Divider u_Divider (
        .clk      (cpu_clk),
        .rst      (cpu_rst),
        .start    (div_start),
        .dividend (forward_a),
        .divisor  (forward_b_reg),
        .is_signed(div_signed),
        .quotient (div_quotient),
        .remainder(div_remainder),
        .ready    (div_ready)
    );

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            div_active <= 1'b0;
        else if (div_start)
            div_active <= 1'b1;
        else if (div_active && div_ready)
            div_active <= 1'b0;
    end

    wire div_wait = ex_valid && ex_is_div && !(div_active && div_ready);
    assign stall_ex = div_wait;

    wire [31:0] div_result32 =
        ((ex_funct3 == 3'b100) || (ex_funct3 == 3'b101)) ?
        div_quotient : div_remainder;

    // ---------------- Zicsr + ECALL/MRET ----------------
    wire [31:0] csr_rdata;
    wire [31:0] mtvec_out;
    wire [31:0] mepc_out;
    wire [31:0] mstatus_out;
    wire [31:0] csr_operand = ex_funct3[2] ? {27'b0, ex_rs1} : forward_a;

    reg csr_write_enable;
    reg [31:0] csr_write_data;
    always @(*) begin
        csr_write_enable = 1'b0;
        csr_write_data   = csr_rdata;
        if (ex_valid && ex_is_csr) begin
            case (ex_funct3[1:0])
                2'b01: begin
                    csr_write_enable = 1'b1;
                    csr_write_data   = csr_operand;
                end
                2'b10: begin
                    csr_write_enable = (csr_operand != 32'b0);
                    csr_write_data   = csr_rdata | csr_operand;
                end
                2'b11: begin
                    csr_write_enable = (csr_operand != 32'b0);
                    csr_write_data   = csr_rdata & ~csr_operand;
                end
                default: begin
                    csr_write_enable = 1'b0;
                    csr_write_data   = csr_rdata;
                end
            endcase
        end
    end

    CSR_Reg u_CSR_Reg (
        .clk        (cpu_clk),
        .rst        (cpu_rst),
        .csr_raddr  (ex_csr_addr),
        .csr_rdata  (csr_rdata),
        .csr_waddr  (ex_csr_addr),
        .csr_wen    (ex_valid && ex_is_csr && csr_write_enable),
        .csr_wdata  (csr_write_data),
        .trap_enter (ex_valid && ex_is_ecall),
        .trap_exit  (ex_valid && ex_is_mret),
        .trap_pc    (ex_pc),
        .trap_cause (32'd11),
        .mtvec_out  (mtvec_out),
        .mepc_out   (mepc_out),
        .mstatus_out(mstatus_out)
    );

    // Dedicated branch comparators remove the general ALU decoder/result mux
    // from the PC-control path.
    wire branch_eq  = (forward_a == forward_b_reg);
    wire branch_lt  = ($signed(forward_a) < $signed(forward_b_reg));
    wire branch_ltu = (forward_a < forward_b_reg);

    reg branch_condition;
    always @(*) begin
        case (ex_funct3)
            3'b000: branch_condition =  branch_eq;
            3'b001: branch_condition = !branch_eq;
            3'b100: branch_condition =  branch_lt;
            3'b101: branch_condition = !branch_lt;
            3'b110: branch_condition =  branch_ltu;
            3'b111: branch_condition = !branch_ltu;
            default:branch_condition = 1'b0;
        endcase
    end

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            for (bht_i = 0; bht_i < 64; bht_i = bht_i + 1)
                branch_bht[bht_i] <= 2'b01;
        end else if (ENABLE_DYNAMIC_BHT &&
                     ex_valid && ex_is_branch && !div_wait) begin
            if (branch_condition) begin
                if (branch_bht[ex_pc[7:2]] != 2'b11)
                    branch_bht[ex_pc[7:2]] <=
                        branch_bht[ex_pc[7:2]] + 2'b01;
            end else begin
                if (branch_bht[ex_pc[7:2]] != 2'b00)
                    branch_bht[ex_pc[7:2]] <=
                        branch_bht[ex_pc[7:2]] - 2'b01;
            end
        end
    end

    wire branch_mispredict = ex_valid && ex_is_branch &&
                               (branch_condition != ex_pred_taken);
    wire jalr_redirect = ex_valid && ex_is_jalr;
    wire trap_redirect = ex_valid && (ex_is_ecall || ex_is_mret);

    wire [31:0] jalr_target = (forward_a + ex_imm) & 32'hffff_fffe;
    assign ex_redirect = branch_mispredict || jalr_redirect || trap_redirect;
    assign ex_redirect_target =
        ex_is_ecall ? {mtvec_out[31:2], 2'b00} :
        ex_is_mret  ? {mepc_out[31:1], 1'b0} :
        ex_is_jalr  ? jalr_target :
        branch_condition ? ex_pc_target : ex_link_value;

    reg [31:0] ex_result;
    always @(*) begin
        if (ex_is_csr)
            ex_result = csr_rdata;
        else if (ex_is_mul)
            ex_result = mul_result32;
        else if (ex_is_div)
            ex_result = div_result32;
        else if (ex_is_jal || ex_is_jalr)
            ex_result = ex_link_value;
        else if (ex_is_auipc)
            ex_result = ex_pc_target;
        else if (ex_is_lui)
            ex_result = ex_imm;
        else if (ex_is_load && ex_fast_load_hit)
            ex_result = ex_fast_load_data;
        else
            ex_result = alu_result;
    end

    // A normal load still needs one load-use bubble because its value is
    // available from WB.  A fast stack-cache hit already produces the value in
    // EX and is forwarded from MEM like an ALU result, so no bubble is needed.
    wire load_use_hazard = !ENABLE_MEM_LOAD_BYPASS &&
        ex_valid && ex_is_load && !ex_fast_load_hit &&
        (ex_rd != 5'b0) && id_valid &&
        ((id_uses_rs1 && (ex_rd == id_rs1)) ||
         (id_uses_rs2_in_ex && (ex_rd == id_rs2)));

    assign stall_if = load_use_hazard || div_wait;
    assign stall_id = load_use_hazard || div_wait;
    assign flush_ex = load_use_hazard || ex_redirect;

    // ================================================================
    // 6. EX/MEM pipeline register
    // ================================================================
    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            mem_valid <= 1'b0;
        end else if (div_wait) begin
            mem_valid <= 1'b0;
        end else begin
            mem_valid      <= ex_valid;
            mem_result     <= ex_result;
            mem_store_data <= forward_b_reg;
            mem_rd         <= ex_rd;
            mem_store_rs2  <= ex_rs2;
            mem_funct3      <= ex_funct3;
            // A stack-cache hit has already produced the architectural load
            // value.  Mark it as a normal result so MEM forwarding is enabled.
            mem_is_load     <= ex_is_load && !ex_fast_load_hit;
            mem_is_store    <= ex_is_store;
            mem_regwrite    <= ex_regwrite;
            mem_stack_access<= ex_stack_access;
        end
    end

    // ================================================================
    // 7. MEM stage
    // ================================================================
    assign perip_addr = mem_result;

    // Write-through stack cache maintenance.  Full-word stack stores update
    // a line; full-word stack loads fill a missed line from DRAM.  A store via
    // a different base register to a cached word invalidates/updates it so the
    // cache can never return stale architectural data.
    integer stack_i;
    wire mem_dram_addr = (mem_result[31:20] == 12'h801) &&
                         (mem_result[19:18] == 2'b00);
    wire [2:0]  mem_stack_index = mem_result[4:2];
    wire [26:0] mem_stack_tag   = mem_result[31:5];

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            for (stack_i = 0; stack_i < STACK_CACHE_LINES; stack_i = stack_i + 1)
                stack_cache_valid[stack_i] <= 1'b0;
        end else begin
            if (mem_valid && mem_is_store && mem_dram_addr) begin
                if ((mem_funct3 == 3'b010) &&
                    (mem_result[1:0] == 2'b00) && mem_stack_access) begin
                    stack_cache_valid[mem_stack_index] <= 1'b1;
                    stack_cache_tag[mem_stack_index]   <= mem_stack_tag;
                    stack_cache_data[mem_stack_index]  <= mem_store_data_final;
                end else if (stack_cache_valid[mem_stack_index] &&
                             (stack_cache_tag[mem_stack_index] == mem_stack_tag)) begin
                    // Non-stack aliases and byte/half stores may change only
                    // part of the word, so discard the old cached value.
                    stack_cache_valid[mem_stack_index] <= 1'b0;
                end
            end else if (mem_valid && mem_is_load && mem_dram_addr &&
                         mem_stack_access && (mem_funct3 == 3'b010) &&
                         (mem_result[1:0] == 2'b00)) begin
                stack_cache_valid[mem_stack_index] <= 1'b1;
                stack_cache_tag[mem_stack_index]   <= mem_stack_tag;
                stack_cache_data[mem_stack_index]  <= perip_rdata;
            end
        end
    end

    assign perip_wdata =
        (mem_funct3 == 3'b000) ? {4{mem_store_data_final[7:0]}} :
        (mem_funct3 == 3'b001) ? {2{mem_store_data_final[15:0]}} :
                                 mem_store_data_final;
    assign perip_wen = mem_valid && mem_is_store;
    assign perip_mask =
        ((mem_funct3 == 3'b000) || (mem_funct3 == 3'b100)) ? 2'b00 :
        ((mem_funct3 == 3'b001) || (mem_funct3 == 3'b101)) ? 2'b01 :
                                                             2'b10;

    // ================================================================
    // 8. MEM/WB pipeline register
    // The load extension is completed before this register. Consequently the
    // WB and MEM-load results can both forward directly into EX.
    // ================================================================
    reg         wb_valid;
    reg  [31:0] wb_result;
    reg  [4:0]  wb_rd_reg;
    reg         wb_regwrite;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            wb_valid <= 1'b0;
        end else begin
            wb_valid    <= mem_valid;
            wb_result   <= mem_is_load ? mem_load_data : mem_result;
            wb_rd_reg   <= mem_rd;
            wb_regwrite <= mem_regwrite;
        end
    end

    // ================================================================
    // 9. WB stage
    // ================================================================
    assign wb_rd    = wb_rd_reg;
    assign wb_wdata = wb_result;
    assign wb_wen   = wb_valid && wb_regwrite && (wb_rd_reg != 5'b0);

    // Simulation-only performance counters.  They are ignored by synthesis
    // and can be inspected hierarchically in Vivado simulation.
    //   perf_cycles          total active clock cycles
    //   perf_retired         instructions reaching WB
    //   perf_load_stalls     ordinary load-use bubbles
    //   perf_fast_stack_hits loads accelerated by the stack cache/bypass
    //   perf_branch_count    conditional branches executed
    //   perf_mispredicts     branch prediction recoveries
    //   perf_mul_count       multiply instructions executed
    //   perf_div_wait_cycles cycles frozen by division
    // synthesis translate_off
    reg [63:0] perf_cycles;
    reg [63:0] perf_retired;
    reg [63:0] perf_load_stalls;
    reg [63:0] perf_fast_stack_hits;
    reg [63:0] perf_branch_count;
    reg [63:0] perf_mispredicts;
    reg [63:0] perf_mem_load_bypasses;
    reg [63:0] perf_mul_count;
    reg [63:0] perf_div_wait_cycles;

    always @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst) begin
            perf_cycles          <= 64'd0;
            perf_retired         <= 64'd0;
            perf_load_stalls     <= 64'd0;
            perf_fast_stack_hits <= 64'd0;
            perf_branch_count    <= 64'd0;
            perf_mispredicts     <= 64'd0;
            perf_mem_load_bypasses <= 64'd0;
            perf_mul_count       <= 64'd0;
            perf_div_wait_cycles <= 64'd0;
        end else begin
            perf_cycles <= perf_cycles + 64'd1;
            if (wb_valid)
                perf_retired <= perf_retired + 64'd1;
            if (load_use_hazard)
                perf_load_stalls <= perf_load_stalls + 64'd1;
            if (ex_valid && ex_is_load && ex_fast_load_hit)
                perf_fast_stack_hits <= perf_fast_stack_hits + 64'd1;
            if (ex_valid && ex_is_branch && !div_wait)
                perf_branch_count <= perf_branch_count + 64'd1;
            if (branch_mispredict)
                perf_mispredicts <= perf_mispredicts + 64'd1;
            if (ENABLE_MEM_LOAD_BYPASS && mem_valid && mem_is_load &&
                mem_regwrite && (mem_rd != 5'b0) && ex_valid &&
                (((ex_rs1 != 5'b0) && (ex_rs1 == mem_rd)) ||
                 ((ex_rs2 != 5'b0) && (ex_rs2 == mem_rd))))
                perf_mem_load_bypasses <=
                    perf_mem_load_bypasses + 64'd1;
            if (ex_valid && ex_is_mul && !div_wait)
                perf_mul_count <= perf_mul_count + 64'd1;
            if (div_wait)
                perf_div_wait_cycles <= perf_div_wait_cycles + 64'd1;
        end
    end
    // synthesis translate_on

endmodule
