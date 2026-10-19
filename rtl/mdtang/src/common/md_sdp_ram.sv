// Single-writer video tables use distributed RAM, leaving BSRAM for bulk storage.
module md_sdp_ram #(
    parameter ADDR_WIDTH = 9,
    parameter DATA_WIDTH = 8
) (
    input  wire                      wr_clk,
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire [DATA_WIDTH-1:0]     wr_data,
    input  wire                      wr_en,
    input  wire [DATA_WIDTH/8-1:0]   wr_be,
    input  wire                      rd_clk,
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output wire [DATA_WIDTH-1:0]     rd_data
);
    if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0)
        $error("md_sdp_ram DATA_WIDTH must be a positive multiple of 8");

    for (genvar lane = 0; lane < DATA_WIDTH/8; lane = lane + 1) begin : g_byte
        reg [7:0] mem [0:(1 << ADDR_WIDTH)-1] /* synthesis syn_ramstyle="distributed_ram" */;
        reg [7:0] q = 0;
        integer i;
        initial begin
            for (i = 0; i < (1 << ADDR_WIDTH); i = i + 1)
                mem[i] = 0;
        end
        always @(posedge wr_clk)
            if (wr_en && wr_be[lane])
                mem[wr_addr] <= wr_data[lane*8 +: 8];
        always @(posedge rd_clk)
            q <= mem[rd_addr];
        assign rd_data[lane*8 +: 8] = q;
    end
endmodule
