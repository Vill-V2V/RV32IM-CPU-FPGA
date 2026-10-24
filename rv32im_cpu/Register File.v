module RegFile (
    input  wire        clk,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    input  wire        we,
    input  wire [4:0]  rd,
    input  wire [31:0] wdata
);
    reg [31:0] regs [0:31];

    // Read ports (Asynchronous read)
    // 解决内部数据前推（Internal Forwarding）：如果读和写在同一周期发生，直接读出新写的数据
    assign rdata1 = (rs1 == 5'b0) ? 32'b0 : ((we && rs1 == rd) ? wdata : regs[rs1]);
    assign rdata2 = (rs2 == 5'b0) ? 32'b0 : ((we && rs2 == rd) ? wdata : regs[rs2]);

    // Write port (Synchronous write)
    integer i;
    initial begin
        for(i=0; i<32; i=i+1) regs[i] = 32'b0;
    end

    always @(posedge clk) begin
        if (we && rd != 5'b0) begin
            regs[rd] <= wdata;
        end
    end
endmodule