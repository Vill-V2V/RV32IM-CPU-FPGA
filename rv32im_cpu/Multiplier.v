`timescale 1ns / 1ps

// Verilog-2001-compatible single-cycle RV32M multiplier.
// A fixed signed 32x32 product supplies MUL/MULH.  The mixed/unsigned high
// words are obtained by exact modulo-2^32 correction identities.
module Multiplier (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] product_low,
    output wire [31:0] product_high_ss,
    output wire [31:0] product_high_su,
    output wire [31:0] product_high_uu
);
    wire signed [31:0] a_signed;
    wire signed [31:0] b_signed;
    wire signed [63:0] product_ss;
    wire [31:0] correction_su;
    wire [31:0] correction_uu_a;
    wire [31:0] correction_uu_b;

    assign a_signed = a;
    assign b_signed = b;
    assign product_ss = a_signed * b_signed;

    assign product_low     = product_ss[31:0];
    assign product_high_ss = product_ss[63:32];

    assign correction_su   = b[31] ? a : 32'b0;
    assign correction_uu_a = a[31] ? b : 32'b0;
    assign correction_uu_b = b[31] ? a : 32'b0;

    assign product_high_su = product_ss[63:32] + correction_su;
    assign product_high_uu = product_ss[63:32]
                           + correction_uu_a
                           + correction_uu_b;
endmodule
