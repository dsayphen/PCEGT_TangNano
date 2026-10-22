`timescale 1ns/1ps
// Simulation-only stand-in for SPPU: NTSC line/frame timing (1364 mclk x 262)
// and no video. VRAM writes are not modelled; tb_snes_reset_dma checks the
// B-bus data where the real PPU samples it (SYSCLK_CE with PAWR_N low).
module SPPU(
    input wire RST_N,
    input wire CLK,
    input ENABLE,
    input DIS_SHORTLINE,
    input [7:0] PA,
    input PARD_N,
    input PAWR_N,
    input [7:0] DI,
    output [7:0] DO,
    input SYSCLK_CE,
    output [15:0] VRAM_ADDRA,
    output [15:0] VRAM_ADDRB,
    input [7:0] VRAM_DAI,
    input [7:0] VRAM_DBI,
    output [7:0] VRAM_DAO,
    output [7:0] VRAM_DBO,
    output VRAM_WRA_N,
    output VRAM_WRB_N,
    output VRAM_RD_N,
    output VRAM_READ_CE,
    input EXTLATCH,
    input PAL,
    input BLEND,
    output HIGH_RES,
    output DOTCLK,
    output reg HBLANK,
    output reg VBLANK,
    output reg [14:0] COLOR_OUT,
    output [8:0] X_OUT,
    output [8:0] Y_OUT,
    output reg HDE,
    output reg VDE,
    output V224,
    output FIELD_OUT,
    output INTERLACE,
    output reg HSYNC,
    output reg VSYNC,
    output reg FRAME_OUT,
    input [4:0] BG_EN
);
assign DO = 8'h00;
assign VRAM_ADDRA = 0;
assign VRAM_ADDRB = 0;
assign VRAM_DAO = 0;
assign VRAM_DBO = 0;
assign VRAM_WRA_N = 1'b1;
assign VRAM_WRB_N = 1'b1;
assign VRAM_RD_N = 1'b1;
assign VRAM_READ_CE = 1'b0;
assign HIGH_RES = 1'b0;
assign DOTCLK = 1'b0;
assign X_OUT = 0;
assign Y_OUT = 0;
assign V224 = 1'b1;
assign FIELD_OUT = 1'b0;
assign INTERLACE = 1'b0;

reg [10:0] h = 0;
reg [8:0] v = 0;
always @(posedge CLK) begin
    if (!RST_N) begin
        h <= 0; v <= 0; HBLANK <= 0; VBLANK <= 0;
    end else if (ENABLE) begin
        h <= h == 1363 ? 11'd0 : h + 11'd1;
        if (h == 1363) v <= v == 261 ? 9'd0 : v + 9'd1;
        HBLANK <= h >= 1096 || h < 88;
        VBLANK <= v >= 225;
    end
    COLOR_OUT <= 0; HDE <= 0; VDE <= 0; HSYNC <= 0; VSYNC <= 0; FRAME_OUT <= 0;
end
endmodule
