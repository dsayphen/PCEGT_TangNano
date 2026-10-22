`timescale 1ns/1ps
// Exercise the actual PPU range/fetch block, extracted by run_snes_sprite_clip.ps1.
module tb_snes_sprite_clip;
reg CLK = 0;
always #5 CLK = ~CLK;
reg RST_N = 0;
reg ENABLE = 1, DOT_CLKR_CE = 1, FORCE_BLANK = 0;
reg [8:0] H_CNT = 0, V_CNT = 20;
localparam LAST_DOT = 340, LAST_LINE = 261, LAST_VIS_LINE = 224;
localparam OBJ_TIME_START = 270;
reg [31:0] OAM_Q = 0;
reg HOAM_X8 = 0, HOAM_S = 0;
reg [2:0] OBJSIZE = 0;
reg OBJINTERLACE = 0, FIELD = 0;
reg [1:0] OBJNAME = 0;
reg [9:0] OAM_ADDR = 0;
reg [6:0] OAM_RANGE [0:31];
reg [6:0] OAM_TIME_INDEX;
reg [5:0] RANGE_CNT, TILES_OAM_CNT;
reg [2:0] TILES_CNT;
reg OBJ_RANGE = 0, OBJ_TIME = 0, OBJ_FETCH = 0;
reg OBJ_RANGE_OFL, OBJ_TIME_OFL, OBJ_RANGE_DONE, OBJ_TIME_DONE, OBJ_TIME_SAVE;
reg [3:0] OBJ_TILE_COL, OBJ_TILE_ROW;
reg [2:0] OBJ_TILE_LINE, OBJ_TILE_PAL;
reg [14:0] OBJ_TILE_GAP;
reg OBJ_TILE_HFLIP;
reg [1:0] OBJ_TILE_PRIO;
reg [8:0] OBJ_TILE_X;
reg [31:0] SPR_TILE_DATA;
reg [15:0] SPR_TILE_DATA_TEMP;
reg [8:0] SPR_TILE_X;
reg [2:0] SPR_TILE_PAL;
reg [1:0] SPR_TILE_PRIO;
wire [15:0] VRAM_DAI = 16'hffff, VRAM_DBI = 16'hffff;
`include "snes_sprite_sizes.vh"
function [5:0] SprWidth(input [3:0] size);
    SprWidth = SPR_WIDTH[size][5:0];
endfunction
function [5:0] SprHeight(input [3:0] size);
    SprHeight = SPR_HEIGHT[size][5:0];
endfunction
function [7:0] FlipPlane(input [7:0] bp, input flip);
    FlipPlane = flip ? {bp[0], bp[1], bp[2], bp[3], bp[4], bp[5], bp[6], bp[7]} : bp;
endfunction
`include "snes_sprite_engine.vh"

task tick;
    begin @(posedge CLK); #1; @(negedge CLK); end
endtask

integer errors = 0, cases = 0;
task check_sprite(input integer x, input integer size, input integer flip);
    integer width, visible, tile, pixel, px, expected_col, slivers, expected_slivers;
    reg [255:0] pixels, expected;
    reg [8:0] tile_x;
    begin
        RST_N = 0; OBJ_RANGE = 0; OBJ_TIME = 0; OBJ_FETCH = 0;
        tick;
        RST_N = 1;
        OBJSIZE = size % 8; HOAM_S = size / 8;
        HOAM_X8 = x < 0 || x >= 256;
        OAM_Q = {1'b0, flip[0], 6'b0, 8'h00, 8'd20, x[7:0]};
        H_CNT = 1; OBJ_RANGE = 1;
        tick;
        OBJ_RANGE = 0;
        width = SPR_WIDTH[size] + 1;
        // X=$100 is the same encoded coordinate as -256 and is a PPU special case.
        visible = (x < 256 && x + width > 0) || x == 256 || x == -256;
        if ((!RANGE_CNT[5]) !== visible[0]) begin
            if (errors < 12) $display("range failure x=%0d width=%0d got=%h", x, width, RANGE_CNT);
            errors = errors + 1;
        end
        H_CNT = 269; tick;
        OBJ_TIME = 1;
        pixels = 0; expected = 0; slivers = 0;
        for (px = 0; px < 256; px = px + 1)
            if (px >= x && px < x + width) expected[px] = 1;
        expected_slivers = 0;
        if (visible)
            for (tile = 0; tile < width / 8; tile = tile + 1)
                if (x == 256 || x == -256 || (x + tile * 8 < 256 && x + tile * 8 + 8 > 0))
                    expected_slivers = expected_slivers + 1;
        for (tile = 0; tile < 34; tile = tile + 1) begin
            H_CNT = 271 + tile * 2;
            tick;
            if (!OBJ_TIME_DONE) begin
                slivers = slivers + 1;
                tile_x = OBJ_TILE_X;
                for (pixel = 0; pixel < 8; pixel = pixel + 1) begin
                    px = (tile_x + pixel) % 512;
                    if (px < 256) pixels[px] = 1;
                end
                expected_col = ((tile_x - (x & 511)) & 511) / 8;
                if (flip) expected_col = width / 8 - 1 - expected_col;
                if (OBJ_TILE_COL !== expected_col[3:0]) begin
                    errors = errors + 1;
                    if (errors < 12) $display("tile column failure x=%0d flip=%0d", x, flip);
                end
            end
        end
        if (pixels !== expected || slivers != expected_slivers) begin
            if (errors < 12)
                $display("clip failure x=%0d width=%0d flip=%0d slivers=%0d expected=%0d pixels=%h expected=%h",
                    x, width, flip, slivers, expected_slivers, pixels, expected);
            errors = errors + 1;
        end
        cases = cases + 1;
    end
endtask

integer x, size, flip;
initial begin
    @(negedge CLK);
    for (size = 0; size < 16; size = size + 1)
        for (flip = 0; flip < 2; flip = flip + 1)
            for (x = -256; x <= 256; x = x + 1)
                check_sprite(x, size, flip);
    if (errors) $fatal(1, "FAIL: %0d errors in %0d cases", errors, cases);
    $display("PASS: %0d sprite cases, all X positions, sizes and horizontal flips", cases);
    $finish;
end
endmodule
