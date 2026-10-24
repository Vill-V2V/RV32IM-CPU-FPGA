`timescale 1ns / 1ps

// RV32M iterative divider with exact RISC-V corner-case behavior.
// Normal division uses 32 restoring iterations.  Common easy cases finish
// immediately, which improves larger/division-heavy tests without changing the
// CPU interface or architectural result.
module Divider (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    input  wire        is_signed,
    output wire [31:0] quotient,
    output wire [31:0] remainder,
    output wire        ready
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_CALC = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [5:0]  count;
    reg [31:0] reg_q;
    reg [31:0] reg_r;
    reg [31:0] reg_b;
    reg        sign_q;
    reg        sign_r;
    reg [1:0]  state;

    wire [31:0] neg_dividend;
    wire [31:0] neg_divisor;
    wire [31:0] abs_dividend;
    wire [31:0] abs_divisor;
    wire [32:0] div_sub;

    assign neg_dividend = ~dividend + 32'd1;
    assign neg_divisor  = ~divisor  + 32'd1;
    assign abs_dividend = (is_signed && dividend[31]) ? neg_dividend : dividend;
    assign abs_divisor  = (is_signed && divisor[31])  ? neg_divisor  : divisor;
    assign div_sub      = {reg_r, reg_q[31]} - {1'b0, reg_b};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state  <= ST_IDLE;
            count  <= 6'd0;
            reg_q  <= 32'd0;
            reg_r  <= 32'd0;
            reg_b  <= 32'd0;
            sign_q <= 1'b0;
            sign_r <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        sign_q <= is_signed && (dividend[31] ^ divisor[31]);
                        sign_r <= is_signed && dividend[31];
                        reg_b  <= abs_divisor;

                        // RISC-V division by zero: quotient is all ones and
                        // remainder equals the original dividend.
                        if (divisor == 32'd0) begin
                            reg_q  <= 32'hffff_ffff;
                            reg_r  <= dividend;
                            sign_q <= 1'b0;
                            sign_r <= 1'b0;
                            state  <= ST_DONE;
                        end else if (dividend == 32'd0) begin
                            reg_q <= 32'd0;
                            reg_r <= 32'd0;
                            state <= ST_DONE;
                        end else if (abs_divisor == 32'd1) begin
                            // Also covers INT_MIN / -1 correctly by modulo
                            // two's-complement arithmetic.
                            reg_q <= abs_dividend;
                            reg_r <= 32'd0;
                            state <= ST_DONE;
                        end else if (abs_dividend == abs_divisor) begin
                            reg_q <= 32'd1;
                            reg_r <= 32'd0;
                            state <= ST_DONE;
                        end else if (abs_dividend < abs_divisor) begin
                            reg_q <= 32'd0;
                            reg_r <= abs_dividend;
                            state <= ST_DONE;
                        end else begin
                            reg_q <= abs_dividend;
                            reg_r <= 32'd0;
                            count <= 6'd32;
                            state <= ST_CALC;
                        end
                    end
                end

                ST_CALC: begin
                    if (div_sub[32]) begin
                        reg_r <= {reg_r[30:0], reg_q[31]};
                        reg_q <= {reg_q[30:0], 1'b0};
                    end else begin
                        reg_r <= div_sub[31:0];
                        reg_q <= {reg_q[30:0], 1'b1};
                    end

                    if (count == 6'd1)
                        state <= ST_DONE;
                    else
                        count <= count - 6'd1;
                end

                ST_DONE: begin
                    // The CPU lowers start after accepting ready.
                    if (!start)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign ready     = (state == ST_DONE);
    assign quotient  = sign_q ? (~reg_q + 32'd1) : reg_q;
    assign remainder = sign_r ? (~reg_r + 32'd1) : reg_r;
endmodule
