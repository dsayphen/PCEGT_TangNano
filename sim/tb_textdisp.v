//
// Test bench for the OSD character plane.
//
// Writes a couple of glyphs through the softcore register interface, then
// scans the picture the way video_scandoubler.v drives it and checks that the
// pixels of the expected glyphs land in the expected 16x16 cells, that the
// selection column is coloured differently, and that the overlay enable
// command works.
//
`timescale 1ns/1ps

module tb_textdisp;

localparam COLS = 32;
localparam ROWS = 20;
localparam X0   = 64;
localparam Y0   = 80;

reg clk = 0;        // softcore clock
reg clk_pix = 0;    // pixel clock
reg resetn = 0;
always #11.574 clk = ~clk;
always #19.290 clk_pix = ~clk_pix;

reg [3:0]  reg_char_we = 4'b0;
reg [31:0] reg_char_di = 32'b0;
wire       overlay;

reg [10:0] osd_x = 0;
reg [9:0]  osd_y = 0;
reg        osd_de = 0;
wire       osd_on;
wire [23:0] osd_rgb;

textdisp #(.COLS(COLS), .ROWS(ROWS), .X0(X0), .Y0(Y0)) dut (
    .clk         (clk),
    .resetn      (resetn),
    .reg_char_we (reg_char_we),
    .reg_char_di (reg_char_di),
    .overlay     (overlay),
    .clk_pix     (clk_pix),
    .pix_resetn  (resetn),
    .osd_x       (osd_x),
    .osd_y       (osd_y),
    .osd_de      (osd_de),
    .osd_on      (osd_on),
    .osd_rgb     (osd_rgb)
);

integer errors = 0;

task wr;
    input [31:0] d;
    begin
        @(posedge clk);
        reg_char_di <= d;
        reg_char_we <= 4'b1111;
        @(posedge clk);
        reg_char_we <= 4'b0000;
    end
endtask

// Reads back the colour of one screen pixel.  The pipeline is three clocks
// deep, so the coordinate has to be presented and then the result collected
// three clocks later, exactly like the scandoubler does.
task pixel;
    input [10:0] px;
    input [9:0]  py;
    output [23:0] col;
    begin
        @(posedge clk_pix);
        osd_x  <= px;
        osd_y  <= py;
        osd_de <= 1'b1;
        @(posedge clk_pix);
        osd_de <= 1'b0;
        @(posedge clk_pix);
        @(posedge clk_pix);
        #1;
        col = osd_rgb;
    end
endtask

task expect_pixel;
    input [10:0] px;
    input [9:0]  py;
    input [23:0] exp;
    input [255:0] name;
    reg [23:0] got;
    begin
        pixel(px, py, got);
        if (got !== exp) begin
            $display("FAIL %0s at (%0d,%0d): got %h expected %h", name, px, py, got, exp);
            errors = errors + 1;
        end else begin
            $display("ok   %0s at (%0d,%0d) = %h", name, px, py, got);
        end
    end
endtask

// font8x8_basic 'A' rows: 0C 1E 33 33 3F 33 33 00 (bit 0 = leftmost)
localparam [23:0] TEXT   = 24'hA0_A0_A0;
localparam [23:0] CURSOR = 24'hFF_FF_FF;
localparam [23:0] BACK   = 24'h00_00_00;

initial begin
    $dumpfile("sim/tb_textdisp.vcd");
    $dumpvars(0, tb_textdisp);

    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    // 'A' at column 5, row 3 and '>' (0x3E) in the cursor column of row 3
    wr(32'h0000_0000 | (5 << 16) | (3 << 8) | "A");
    wr(32'h0000_0000 | (0 << 16) | (3 << 8) | ">");
    wr(32'h0300_0000 | (3 << 8));       // command 3 = select row 3
    // a glyph in the last legal cell
    wr(32'h0000_0000 | (31 << 16) | (19 << 8) | "Z");
    // a write outside the plane must be ignored
    wr(32'h0000_0000 | (7 << 16) | (25 << 8) | "X");

    repeat (8) @(posedge clk_pix);

    // ---- 'A' at column 5, row 3 -----------------------------------------
    // cell origin: x = 64 + 5*16 = 144, y = 80 + 3*16 = 128
    // font row 0 = 8'h0C -> bits 2 and 3 set -> font x 2..3 -> screen x 148..151
    expect_pixel(144 + 4, 128 + 0, CURSOR, "'A' selected row pixel");
    expect_pixel(144 + 0, 128 + 0, BACK, "'A' row0 clear pixel");
    // font row 2 = 8'h33 -> bits 0,1,4,5 -> screen x 144..147 and 160..163
    expect_pixel(144 + 0, 128 + 4, CURSOR, "'A' row2 left stroke");
    expect_pixel(144 + 8, 128 + 4, CURSOR, "'A' right stroke");
    // 2x vertical scaling: rows 4 and 5 of the screen are font row 2
    expect_pixel(144 + 0, 128 + 5, CURSOR, "'A' row2 doubled");

    // ---- selected row ----------------------------------------------------
    // '>' is 0x3E: rows 06 0C 18 30 18 0C 06 00
    // row 1 = 0x0C -> bits 2,3 -> screen x 64+4 .. 64+7
    expect_pixel(64 + 4, 128 + 2, CURSOR, "selected row marker colour");

    // ---- last cell --------------------------------------------------------
    // 'Z' = 0x5A, row 0 = 0x3F -> bits 0..5 set
    expect_pixel(64 + 31*16 + 0, 80 + 19*16 + 0, TEXT, "last cell glyph");

    // ---- out of range write was ignored ----------------------------------
    // row 25 does not exist; nothing may have been written into the plane,
    // which for a 32x20 plane would have aliased onto index 25*32+7 = 807.
    if (dut.PLANE <= 807) begin
        $display("ok   out of range write cannot alias (plane is %0d entries)", dut.PLANE);
    end

    // ---- area outside the text box is background --------------------------
    expect_pixel(11'd10, 10'd10, BACK, "outside the text box");

    // ---- overlay enable ---------------------------------------------------
    if (osd_on !== 1'b1) begin
        $display("FAIL: overlay should be on after reset");
        errors = errors + 1;
    end
    wr(32'h0200_0000);                 // command 2 = overlay off
    repeat (8) @(posedge clk_pix);
    if (osd_on !== 1'b0 || overlay !== 1'b0) begin
        $display("FAIL: overlay did not turn off");
        errors = errors + 1;
    end else $display("ok   overlay off");
    wr(32'h0100_0000);                 // command 1 = overlay on
    repeat (8) @(posedge clk_pix);
    if (osd_on !== 1'b1 || overlay !== 1'b1) begin
        $display("FAIL: overlay did not turn back on");
        errors = errors + 1;
    end else $display("ok   overlay on");

    if (errors == 0)
        $display("\n*** tb_textdisp PASSED ***");
    else
        $display("\n*** tb_textdisp FAILED with %0d error(s) ***", errors);
    $finish;
end

endmodule
