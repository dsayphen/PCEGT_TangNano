//
// On-screen display for the Tang Nano 20K PC Engine port.
//
// A 32 x 20 character text plane in an 8x8 font, doubled to 16x16 pixel cells
// and centred in the 640x480 picture produced by video_scandoubler.v:
//
//     x =  64 .. 575   (32 * 16 pixels)
//     y =  80 .. 399   (20 * 16 pixels)
//
// This is the SNESTang `textdisp.v` idea (nand2mario, GPLv3) reworked for a
// board where every one of the 46 block RAMs is already taken by the PC Engine
// core: the character plane is a LUT based distributed RAM and the font is a
// LUT based ROM (font_rom.v), so the OSD costs no BSRAM at all.
//
// Two clock domains:
//
//   * clk      - the PicoRV32 writes single characters through reg_char_*
//   * clk_pix  - the pixel pipeline reads the plane and the font
//
// The character plane is written from clk and read asynchronously from
// clk_pix, which is the normal use of a distributed dual-port RAM.  A read
// that races the softcore's write returns either the old or the new byte, so
// the worst case is one wrong glyph for one frame while the menu is redrawn.
// The `overlay` enable is a proper two-flop synchroniser because it gates the
// whole screen.
//
// Pixel pipeline (three clk_pix stages, which is exactly the lead that
// video_scandoubler.v gives on osd_x / osd_y / osd_de):
//
//   stage 0   latch column/row, read the character plane
//   stage 1   read the font ROM
//   stage 2   select the pixel and produce the colour
//
// Register interface (one 32 bit write per character, mirrors SNESTang):
//
//   [25:24]  command  0 = write character, 1 = overlay on, 2 = overlay off,
//                        3 = select row
//   [20:16]  x   0..31
//   [12:8]   y   0..19
//   [7:0]    character (0x20..0x7F, anything else prints as '?')
//

module textdisp #(
    parameter COLS   = 32,
    parameter ROWS   = 20,
    parameter X0     = 64,      // left edge of the text area, in pixels
    parameter Y0     = 80,      // top edge of the text area, in pixels
    // 8:8:8 colours
    parameter [23:0] COLOR_BACK   = 24'h00_00_00,
    parameter [23:0] COLOR_TEXT   = 24'hA0_A0_A0,
    parameter [23:0] COLOR_CURSOR = 24'hFF_FF_FF
) (
    // ---- softcore side -----------------------------------------------
    input  wire        clk,
    input  wire        resetn,
    input  wire [3:0]  reg_char_we,
    input  wire [31:0] reg_char_di,
    output wire        overlay,          // clk domain copy, for the softcore

    // ---- pixel side --------------------------------------------------
    input  wire        clk_pix,
    input  wire        pix_resetn,
    input  wire [10:0] osd_x,            // leads the visible pixel by 3 clocks
    input  wire [9:0]  osd_y,
    input  wire        osd_de,
    output reg         osd_on,           // 1: replace the picture with the OSD
    output reg  [23:0] osd_rgb
);

localparam PLANE = COLS * ROWS;
localparam [5:0] ROWS6 = ROWS[5:0];

// ===========================================================================
// Character plane, written by the softcore
// ===========================================================================
wire [1:0] cmd       = reg_char_di[25:24];
wire [4:0] text_x    = reg_char_di[20:16];
wire [4:0] text_y    = reg_char_di[12:8];
wire [7:0] text_char = reg_char_di[7:0];

// text_x is five bits wide and COLS is 32, so only the row needs a range check
wire char_we = reg_char_we[0] && (cmd == 2'd0) && ({1'b0, text_y} < ROWS6);

// COLS is 32, so the row start is just a shift
wire [9:0] char_waddr = {text_y, text_x};

(* syn_ramstyle = "distributed_ram" *)
reg [7:0] plane [0:PLANE-1];

// Start on a blank screen: the softcore only clears the plane once its
// firmware has been fetched from flash, which takes ~100 ms after power-on.
integer i;
initial
    for (i = 0; i < PLANE; i = i + 1)
        plane[i] = 8'h20;

always @(posedge clk)
    if (char_we)
        plane[char_waddr] <= text_char;

// overlay enable, owned by the clk domain
reg overlay_r = 1'b1;
reg [4:0] selected_row = 5'd31;
assign overlay = overlay_r;

always @(posedge clk) begin
    if (!resetn) begin
        overlay_r <= 1'b1;
        selected_row <= 5'd31;
    end else if (reg_char_we[0]) begin
        case (cmd)
            2'd1: overlay_r <= 1'b1;
            2'd2: overlay_r <= 1'b0;
            2'd3: selected_row <= text_y;
            default: ;
        endcase
    end
end

// ===========================================================================
// Pixel pipeline, clk_pix domain
// ===========================================================================
reg [2:0] overlay_sync = 3'b000;
always @(posedge clk_pix)
    overlay_sync <= {overlay_sync[1:0], overlay_r};
wire overlay_pix = overlay_sync[2];

// text area coordinates.  The subtraction wraps for pixels left of / above the
// box, and the magnitude comparison below rejects those.
wire [10:0] bx = osd_x - X0[10:0];
wire [9:0]  by = osd_y - Y0[9:0];

wire in_box = osd_de && (bx < (COLS*16)) && (by < (ROWS*16));

// 2x scale: one font pixel is two screen pixels in both directions
wire [7:0] tx = bx[9:1];        // 0 .. COLS*8-1
wire [7:0] ty = by[8:1];        // 0 .. ROWS*8-1

// ---- stage 0 --------------------------------------------------------------
reg        s0_box;
reg [2:0]  s0_xoff, s0_yoff;
reg        s0_cursor;
reg [7:0]  s0_char;
reg        s0_de;

wire [9:0] char_raddr = {ty[7:3], tx[7:3]};
wire [7:0] char_rdata = plane[char_raddr];

always @(posedge clk_pix) begin
    s0_box    <= in_box;
    s0_de     <= osd_de;
    s0_xoff   <= tx[2:0];
    s0_yoff   <= ty[2:0];
    s0_cursor <= (ty[7:3] == selected_row);
    s0_char   <= char_rdata;
end

// ---- stage 1 : font lookup ------------------------------------------------
// Anything outside the printable range shows as '?'.
wire [7:0] glyph = (s0_char >= 8'h20 && s0_char <= 8'h7F) ? s0_char : 8'h3F;
wire [6:0] glyph_idx = glyph[6:0] - 7'h20;
wire [9:0] font_addr = {glyph_idx, s0_yoff};

wire [7:0] font_data;

font_rom u_font (
    .clk  (clk_pix),
    .addr (font_addr),
    .data (font_data)
);

reg       s1_box;
reg [2:0] s1_xoff;
reg       s1_cursor;
reg       s1_de;

always @(posedge clk_pix) begin
    s1_box    <= s0_box;
    s1_xoff   <= s0_xoff;
    s1_cursor <= s0_cursor;
    s1_de     <= s0_de;
end

// ---- stage 2 : colour -----------------------------------------------------
always @(posedge clk_pix) begin
    osd_on  <= overlay_pix;
    osd_rgb <= COLOR_BACK;
    if (s1_de && s1_box && font_data[s1_xoff])
        osd_rgb <= s1_cursor ? COLOR_CURSOR : COLOR_TEXT;

    if (!pix_resetn) begin
        osd_on  <= 1'b0;
        osd_rgb <= COLOR_BACK;
    end
end

endmodule
