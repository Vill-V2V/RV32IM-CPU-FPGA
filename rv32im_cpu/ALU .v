`timescale 1ns / 1ps

module ALU (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    input  wire [6:0]  funct7,
    output reg  [31:0] result,
    output wire        zero,
    output wire        lt,
    output wire        ltu
);
    wire is_r_type = (opcode == 7'b0110011);
    wire is_i_type = (opcode == 7'b0010011);
    wire is_m_type = is_r_type && (funct7 == 7'b0000001);
    wire [4:0] shamt = b[4:0];

    always @(*) begin
        if (is_m_type) begin
            // RV32M is handled by Multiplier/Divider in myCPU.
            result = 32'b0;
        end else if ((opcode == 7'b0110111) || (opcode == 7'b0010111)) begin
            result = (opcode == 7'b0010111) ? (a + b) : b; // AUIPC / LUI
        end else if ((opcode == 7'b1101111) || (opcode == 7'b1100111)) begin
            result = a + b; // target calculation helper
        end else if ((opcode == 7'b0000011) || (opcode == 7'b0100011)) begin
            result = a + b; // load/store address
        end else if (is_r_type || is_i_type) begin
            case (funct3)
                3'b000: result = (is_r_type && funct7[5]) ? (a - b) : (a + b);
                3'b001: result = a << shamt;
                3'b010: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                3'b011: result = (a < b) ? 32'd1 : 32'd0;
                3'b100: result = a ^ b;
                3'b101: begin
                    if (funct7[5])
                        result = $signed(a) >>> shamt;
                    else
                        result = a >> shamt;
                end
                3'b110: result = a | b;
                3'b111: result = a & b;
                default: result = 32'b0;
            endcase
        end else begin
            result = a - b;
        end
    end

    assign zero = (a == b);
    assign lt   = ($signed(a) < $signed(b));
    assign ltu  = (a < b);
endmodule
