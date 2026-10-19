// Console + SDRAM resource boundary, not a board top or a flashable build.
module megadrive_sdram_probe #(
    parameter FREQ = 53_693_175,
    parameter [22:0] WORK_RAM_BASE = 23'h600000,
    parameter [22:0] CART_RAM_BASE = 23'h620000
) (
    input wire mclk, clk_z80, clk_sdram, reset_n, loading, pause, console_reset, j3but,
    input wire [1:0] console_region,
    input wire [11:0] joy1, joy2,
    input wire [24:1] rom_size,
    input wire [22:2] host_addr,
    input wire [31:0] host_wdata,
    input wire [3:0] host_be,
    input wire host_we, host_req,
    output wire [31:0] host_rdata,
    output wire host_ack, init_done, address_fault,
    inout wire [31:0] SDRAM_DQ,
    output wire [10:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire [3:0] SDRAM_DQM,
    output wire SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE,
    output wire [3:0] red, green, blue,
    output wire hs, vs, hblank, vblank, ce_pix, interlace, field,
    output wire [1:0] resolution,
    output wire [15:0] audio_left, audio_right
);
    wire [24:1] mem_addr;
    wire [15:0] mem_rdata, mem_wdata;
    wire [1:0] mem_be;
    wire mem_we, mem_req, mem_ack;
    wire memory_fault;
    wire rom_too_large = rom_size > 24'h300000;
    reg core_enable = 0;
    // Keep the ROM-size comparator off the console-wide reset fanout.
    always @(posedge mclk)
        core_enable <= reset_n && init_done && !loading && !rom_too_large && !console_reset;
    assign address_fault = memory_fault || rom_too_large;

    megadrive_probe console (
        .mclk(mclk), .clk_z80(clk_z80), .reset_n(reset_n && core_enable),
        .pal(console_region[1]), .export_region(!console_region[0]),
        .loading(loading), .pause(pause), .j3but(j3but), .joy1(joy1), .joy2(joy2), .rom_size(rom_size),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_be(mem_be), .mem_req(mem_req), .mem_ack(mem_ack),
        .red(red), .green(green), .blue(blue), .hs(hs), .vs(vs),
        .hblank(hblank), .vblank(vblank), .ce_pix(ce_pix),
        .interlace(interlace), .field(field), .resolution(resolution),
        .audio_left(audio_left), .audio_right(audio_right)
    );
    megadrive_sdram #(.FREQ(FREQ), .WORK_RAM_BASE(WORK_RAM_BASE), .CART_RAM_BASE(CART_RAM_BASE)) memory (
        .clk(mclk), .clk_sdram(clk_sdram), .resetn(reset_n), .core_enable(core_enable),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_wdata(mem_wdata),
        .mem_we(mem_we), .mem_be(mem_be), .mem_req(mem_req), .mem_ack(mem_ack),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_be(host_be),
        .host_we(host_we), .host_req(host_req), .host_rdata(host_rdata), .host_ack(host_ack),
        .init_done(init_done), .address_fault(memory_fault),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM(SDRAM_DQM), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE)
    );
endmodule
