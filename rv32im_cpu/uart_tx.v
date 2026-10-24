module uart_tx(
    input  wire       clk,      // 我们的 80MHz 时钟
    input  wire       rst,
    input  wire [7:0] tx_data,  // CPU 传过来的字符
    input  wire       tx_en,    // CPU 发送指令
    output reg        tx_pin    // 连到外面的引脚
);
    // 80MHz / 115200 ≈ 694
    parameter CLK_FRE = 80000000;
    parameter BAUD    = 115200;
    localparam DIV_CNT = CLK_FRE / BAUD;

    reg [15:0] cnt;
    reg [3:0]  tx_bit_cnt;
    reg [9:0]  tx_shift_reg;
    reg        tx_busy;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_pin <= 1'b1;
            tx_busy <= 1'b0;
            cnt <= 0;
            tx_bit_cnt <= 0;
            tx_shift_reg <= 0;
        end else if (tx_en && !tx_busy) begin
            tx_shift_reg <= {1'b1, tx_data, 1'b0}; // 停止位 + 数据 + 起始位
            tx_busy <= 1'b1;
            cnt <= 0;
            tx_bit_cnt <= 0;
        end else if (tx_busy) begin
            if (cnt < DIV_CNT - 1) begin
                cnt <= cnt + 1;
            end else begin
                cnt <= 0;
                tx_pin <= tx_shift_reg[0];
                tx_shift_reg <= {1'b1, tx_shift_reg[9:1]};
                if (tx_bit_cnt < 9) begin
                    tx_bit_cnt <= tx_bit_cnt + 1;
                end else begin
                    tx_busy <= 1'b0;
                end
            end
        end
    end
endmodule