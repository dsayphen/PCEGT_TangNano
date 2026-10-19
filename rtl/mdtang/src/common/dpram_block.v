// Gowin dual-port RAM: small tables in distributed RAM, larger memories in BSRAM.
module dpram_block(clka, clkb, addr_a, datain_a, dataout_a, we_a, addr_b, datain_b, dataout_b, we_b);
    parameter                   ADDR_WIDTH = 6;
    parameter                   DATA_WIDTH = 8;     // 4,8,16
    
    input                       clka;
    input  [ADDR_WIDTH-1:0]     addr_a;
    input  [DATA_WIDTH-1:0]     datain_a;
    output reg [DATA_WIDTH-1:0]     dataout_a;
    input                       we_a;
    
    input                       clkb;
    input  [ADDR_WIDTH-1:0]     addr_b;
    input  [DATA_WIDTH-1:0]     datain_b;
    output reg [DATA_WIDTH-1:0]     dataout_b;
    input                       we_b;

if (DATA_WIDTH != 4 && DATA_WIDTH != 8 && DATA_WIDTH != 16)
    $error("ERROR: DATA_WIDTH must be 4, 8, or 16");
if (ADDR_WIDTH > 12)
    $error("ERROR: ADDR_WIDTH must be <= 12");

`ifdef VERILATOR
localparam USE_LOGIC_RAM = 1;
`else
// Keep small palette/scroll tables out of the Nano 20K's scarce BSRAM.
localparam USE_LOGIC_RAM = (ADDR_WIDTH <= 6);
`endif

generate if (!USE_LOGIC_RAM) begin : g_block
// default to bypass read and normal write    
DPB #(
    .BIT_WIDTH_0(DATA_WIDTH), .BIT_WIDTH_1(DATA_WIDTH)
) dpb (
    .CLKA(clka), .RESETA(1'b0), .CEA(1'b1), .OCEA(1'b1), .WREA(we_a), 
    .DIA(datain_a), .DOA(dataout_a), .BLKSELA(3'b0),
    .ADA(DATA_WIDTH == 4 ? {addr_a, 2'b0} :
         DATA_WIDTH == 8 ? {addr_a, 3'b0} :
         DATA_WIDTH == 16 ? {addr_a, 4'b0011} : 
         addr_a), 

    .CLKB(clkb), .RESETB(1'b0), .CEB(1'b1), .OCEB(1'b1), .WREB(we_b),
    .DIB(datain_b), .DOB(dataout_b), .BLKSELB(3'b0),
    .ADB(DATA_WIDTH == 4 ? {addr_b, 2'b0} :
         DATA_WIDTH == 8 ? {addr_b, 3'b0} :
         DATA_WIDTH == 16 ? {addr_b, 4'b0011} :
         addr_b)
);
end else begin : g_logic
reg [DATA_WIDTH-1:0] ram[0:2**ADDR_WIDTH-1] /* synthesis syn_ramstyle="distributed_ram" */ /* verilator public */;
integer i;
initial begin
    dataout_a = 0;
    dataout_b = 0;
    for (i = 0; i < 2**ADDR_WIDTH; i = i + 1)
        ram[i] = 0;
end

always @(posedge clka) begin
    // Port A
    if (we_a == 1'b1)
        ram[addr_a] <= datain_a;
    else 
        dataout_a <= ram[addr_a];
end
        
always @(posedge clkb) begin
    // Port B
    if (we_b == 1'b1)
        ram[addr_b] <= datain_b;
    else 
        dataout_b <= ram[addr_b];
end 
end endgenerate
    
endmodule
