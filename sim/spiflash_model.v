//
// Behavioural model of the on-board SPI NOR flash, limited to the 03h READ
// command that rtl/tang/iosys/spiflash.v issues.  SPI mode 0, MSB first:
// the master samples MISO on the rising edge, so the model changes it on the
// falling edge.
//
// The contents are loaded from a hex file (one byte per line) whose first
// byte corresponds to flash address BASE_ADDR.
//
module spiflash_model #(
    parameter        MEM_BYTES = 262144,
    parameter [23:0] BASE_ADDR = 24'h50_0000,
    parameter        HEXFILE   = "prog.hex"
) (
    input  wire ncs,
    input  wire sck,
    input  wire mosi,
    output wire miso
);

reg [7:0] mem [0:MEM_BYTES-1];

integer k;
initial begin
    for (k = 0; k < MEM_BYTES; k = k + 1)
        mem[k] = 8'hFF;
    $readmemh(HEXFILE, mem);
    sh        = 32'd0;
    n         = 24'd0;
    read_addr = 24'd0;
    miso_r    = 1'b1;
end

reg [31:0] sh;
reg [23:0] n;           // rising edges since chip select went low
reg [23:0] read_addr;
reg        miso_r;

assign miso = miso_r;

always @(posedge sck or posedge ncs) begin
    if (ncs) begin
        n  <= 24'd0;
        sh <= 32'd0;
    end else begin
        sh <= {sh[30:0], mosi};
        n  <= n + 24'd1;
        if (n == 24'd31)
            read_addr <= {sh[22:0], mosi};
    end
end

integer idx;
reg [7:0] b;
always @(negedge sck) begin
    if (!ncs && n >= 24'd32) begin
        idx = read_addr + ((n - 32) >> 3) - BASE_ADDR;
        b   = (idx >= 0 && idx < MEM_BYTES) ? mem[idx] : 8'hFF;
        miso_r <= b[7 - ((n - 32) & 7)];
    end
end

endmodule
