//
// Genlocked line doubler for the Tang Nano 20K PC Engine port.
//
// The HuC6260 produces a 15.7 kHz / 60 Hz signal with 2730 system clocks per
// scan line and 262 or 263 lines per frame.  The system clock (43.2 MHz) and
// the HDMI pixel clock (25.92 MHz) are in an exact 5:3 ratio, therefore
//
//     one PCE scan line = 2730 * 3/5 = 1638 pixel clocks
//                       = exactly two HDMI lines of 819 pixels
//
// so the output can be genlocked to the core: the horizontal counter is
// realigned on every incoming HSYNC and the vertical counter on every incoming
// VSYNC.  In the steady state those corrections are zero, which means there is
// no tearing, no dropped frames and no frame buffer - just two line buffers.
//
// Output timing (819 x 524/526 @ 25.92 MHz, i.e. 31.65 kHz / 60.2 Hz) is
// within ~0.6 % of VGA 640x480@60 and is accepted as such by HDMI sinks.
//
//   hcnt   0 ..  95   hsync (96 px)
//        155 .. 794   640 active pixels
//        818          end of line
//   HDMI line  0 ..   5   vsync (6 lines)   (= core lines 0..2)
//             42 .. 521   480 active lines  (= core lines 21..260, doubled)
//
// The core's active area is always 2160 system clocks wide, which is
// 270 / 360 / 540 dots depending on the VCE dot clock (VIDEO_DCC).  Those are
// scaled with a nearest neighbour DDA whose step is exact in 1/256 units.
// The horizontal zoom mode (zoom_in, from iosys' video_zoom register) selects
// how they are mapped onto the 640 pixel wide output:
//
//   0 = 2x       two output pixels per source dot (step=128).
//   1 = stretch  upscaled to fill all 640 pixels (step=108/144/216), the
//                previous fixed behaviour and the reset default, giving the
//                correct 4:3 aspect ratio as on a real TV.
//   2 = bilinear, same geometry as stretch with horizontal interpolation.
//
// A 2x picture narrower than 640 pixels is centered with black pillarbox
// borders; wider than 640 (e.g. the 540 dot mode) it is centered and cropped.
//
// The vertical dimension is always exactly doubled by the line buffer above
// (a true 1:1, unscaled vertical mode is not possible here: the 5:3 system /
// pixel clock ratio genlocks the doubler so that one core scan line *always*
// maps to exactly two HDMI lines - there is no frame buffer to reposition or
// skip lines).  Instead, scan_in selects a scanline effect that darkens the
// duplicated copy of every line, which is the closest equivalent a
// line-doubler architecture like this one can offer to an unscaled picture:
//
//   0 = off        both copies at full brightness (previous behaviour).
//   1 = 25 %       duplicate copy dimmed to 75 % brightness.
//   2 = 50 %       duplicate copy dimmed to 50 % brightness.
//   3 = 100 %      duplicate copy fully black (hard scanlines).
//

module video_scandoubler (
    // ---- core side (clk_sys, 43.2 MHz) ---------------------------------
    input  wire        clk_sys,
    input  wire        ce_pix,        // VIDEO_CE, dot clock enable
    input  wire [2:0]  r_in,
    input  wire [2:0]  g_in,
    input  wire [2:0]  b_in,
    input  wire        hs_in,         // VIDEO_HS, active high
    input  wire        vs_in,         // VIDEO_VS, active high
    input  wire        hbl_in,        // VIDEO_HBL, high during blanking
    input  wire [1:0]  dcc_in,        // VIDEO_DCC, VCE dot clock select
    input  wire [6:0]  hdw_in,        // VDC HDW, active width in 8-pixel units
    input  wire [6:0]  hds_in,        // VDC HDS, horizontal display start
    input  wire [1:0]  zoom_in,       // 0 = integer, 1 = stretch, 2 = bilinear
    input  wire [1:0]  scan_in,       // 0/1/2/3 = 0/25/50/100% scanlines

    // ---- HDMI side (clk_pix, 25.92 MHz) --------------------------------
    input  wire        clk_pix,
    input  wire        pix_resetn,
    output reg  [7:0]  vga_r,
    output reg  [7:0]  vga_g,
    output reg  [7:0]  vga_b,
    output reg         vga_hs,        // active high
    output reg         vga_vs,        // active high
    output reg         vga_de,

    // ---- OSD timing (combinational, leads vga_* by exactly 3 clocks) ----
    // textdisp.v needs three clk_pix stages to turn a coordinate into a
    // colour, which is exactly the depth of the output pipeline below, so the
    // pre-pipeline coordinates line up with vga_de without any extra delay.
    output wire [10:0] osd_x,         // 0..639 inside the active area
    output wire [9:0]  osd_y,         // 0..479 inside the active area
    output wire        osd_de
);

localparam [10:0] H_TOTAL  = 11'd819;
localparam [10:0] H_SYNC   = 11'd96;
localparam [10:0] H_START  = 11'd155;   // first displayed pixel
localparam [10:0] H_ACTIVE = 11'd640;

localparam [9:0]  V_SYNC   = 10'd6;     // in HDMI lines
localparam [9:0]  V_START  = 10'd42;    // first displayed HDMI line
localparam [9:0]  V_ACTIVE = 10'd480;

// The read pointer and the data enable run three clocks ahead of the visible
// pixel: acc -> lb_raddr -> lb_rdata -> vga_*.
localparam [10:0] H_PRE    = H_START - 11'd3;

// ===========================================================================
// Write side - core clock domain
// ===========================================================================
reg        ce_d;
reg        hs_d;
reg        vs_d;
reg [9:0]  wr_addr;
reg        wr_bank;
reg [9:0]  wr_addr_max;
reg [9:0]  wr_addr_max_lat;
reg        line_tgl;      // toggles at the end of every core scan line
reg        frame_tgl;     // toggles at the start of every core frame
reg [1:0]  dcc_lat;
reg [6:0]  hdw_lat;
reg [1:0]  zoom_lat;
reg [1:0]  scan_lat;

wire [8:0] pix_in = {g_in, r_in, b_in};

reg        lb_we;
reg [10:0] lb_waddr;
reg [8:0]  lb_wdata;

initial begin
    wr_addr   = 10'd0;
    wr_bank   = 1'b0;
    line_tgl  = 1'b0;
    frame_tgl = 1'b0;
    dcc_lat   = 2'b10;
    hdw_lat   = 7'd0;
    zoom_lat  = 2'b10;
    scan_lat  = 2'b00;
    lb_we     = 1'b0;
    wr_addr_max     = 10'd0;
    wr_addr_max_lat = 10'd0;
end

always @(posedge clk_sys) begin
    ce_d  <= ce_pix;
    hs_d  <= hs_in;
    vs_d  <= vs_in;
    lb_we <= 1'b0;

    // The HuC6260 registers its RGB / blanking outputs on the dot clock
    // enable, so sample one clock later.
    if (ce_d && !hbl_in) begin
        lb_we    <= 1'b1;
        lb_waddr <= {wr_bank, wr_addr};
        lb_wdata <= pix_in;
        if (wr_addr != 10'd1023)
            wr_addr <= wr_addr + 10'd1;
        if (wr_addr > wr_addr_max)          // <-- ajout
            wr_addr_max <= wr_addr;         // <-- ajout

    end

    // End of line: swap buffers.  VIDEO_HS rises well after the end of the
    // active area and well before the start of the next one.
    if (hs_in && !hs_d) begin
        wr_addr  <= 10'd0;
        wr_bank  <= ~wr_bank;
        dcc_lat  <= dcc_in;
        hdw_lat  <= hdw_in;
        zoom_lat <= zoom_in;
        scan_lat <= scan_in;
        line_tgl <= ~line_tgl;
        wr_addr_max_lat <= wr_addr_max;     // <-- ajout
        wr_addr_max     <= 10'd0;           // <-- ajout
    end

    if (vs_in && !vs_d)
        frame_tgl <= ~frame_tgl;
end

// ===========================================================================
// Line buffer - 2 x 1024 x 9 bit
// ===========================================================================
reg  [10:0] lb_raddr;
wire [8:0]  lb_rdata;
reg  [10:0] lb_raddr_next;
wire [8:0]  lb_rdata_next;

dpram_dc #(.AW(11), .DW(9)) linebuf (
    .wrclk  (clk_sys),
    .we     (lb_we),
    .waddr  (lb_waddr),
    .wdata  (lb_wdata),
    .rdclk  (clk_pix),
    .raddr  (lb_raddr),
    .rdata  (lb_rdata)
);

dpram_dc #(.AW(11), .DW(9)) linebuf_next (
    .wrclk  (clk_sys),
    .we     (lb_we),
    .waddr  (lb_waddr),
    .wdata  (lb_wdata),
    .rdclk  (clk_pix),
    .raddr  (lb_raddr_next),
    .rdata  (lb_rdata_next)
);

// ===========================================================================
// Read side - pixel clock domain
// ===========================================================================
reg [2:0] line_sync;
reg [2:0] frame_sync;
reg [2:0] bank_sync;
reg [1:0] dcc_sync0;
reg [1:0] dcc_sync;
reg [6:0] hdw_sync0;
reg [6:0] hdw_sync;
reg [1:0] zoom_sync0;
reg [1:0] zoom_sync;
reg [1:0] scan_sync0;
reg [1:0] scan_sync;
reg [9:0] wr_addr_max_sync0;
reg [9:0] wr_addr_max_sync;

wire line_ev  = line_sync[2]  ^ line_sync[1];
wire frame_ev = frame_sync[2] ^ frame_sync[1];

reg [10:0] hcnt;
reg [9:0]  vline;      // core line counter, 0 at vsync
reg        half;       // 0 = first, 1 = second copy of the line
reg        frame_pend;

reg [17:0] acc;        // 10.8 fixed point source pointer

reg [1:0]  de_p;
reg [1:0]  deg_p;      // pipeline for the (possibly narrower) game window
reg [1:0]  hs_p;
reg [1:0]  vs_p;
reg [1:0]  half_p;      // pipeline for "half" (0 = first copy, 1 = duplicate)

reg [7:0]  frac_p1;
reg [7:0]  frac_p2;
reg        bilinear_p1;
reg        bilinear_p2;
// The line buffer contains only active pixels because its write enable is
// gated by hbl_in. Use the VDC active width for all modes so the visible game
// area, including Integer, is centered from the actual image width.
reg [10:0] dcc_src_w;
reg [10:0] src_w;
always @(*) begin
    case (dcc_sync)
        2'b00:   dcc_src_w = 11'd270;
        2'b01:   dcc_src_w = 11'd360;
        default: dcc_src_w = 11'd540;
    endcase

    if (hdw_sync == 7'd0)
        src_w = dcc_src_w;
    else
        src_w = {hdw_sync, 3'b000};
end

// Requested on-screen width for the current zoom mode: doubled (2x) or
// stretched to fill the 640 pixel wide output.  Clipped to the output width
// so an oversized 2x picture is centered and cropped instead of overflowing
// into the sync/porch area (see left_skip below).
reg [10:0] want_w;
always @(*) begin
    case (zoom_sync)
        2'b00:   want_w = src_w << 1;                     // 2x - integer double
        default: want_w = (src_w == 11'd540) ? 11'd540 : H_ACTIVE;
    endcase
end

wire [10:0] vis_w = (want_w > H_ACTIVE) ? H_ACTIVE : want_w;
wire [10:0] h_off = (H_ACTIVE - vis_w) >> 1;   // centers the picture

// When the requested width overflows 640 (e.g. 2x on a 360/540 dot mode),
// crop symmetrically: skip half the overflow's worth of source pixels at the
// start instead of just cutting off the right edge.
wire [10:0] overflow  = (want_w > H_ACTIVE) ? (want_w - H_ACTIVE) : 11'd0;
wire [10:0] left_skip = overflow >> 1;

reg  [8:0]  step;
wire [18:0] stretch_step_full = ({8'd0, src_w} << 8) / H_ACTIVE;
always @(*) begin
    case (zoom_sync)
        2'b00:   step = 9'd128;   // 2x: one source dot per two output pixels
        default: step = stretch_step_full[8:0];
    endcase
end

wire [9:0] hdmi_line = {vline[8:0], half};

wire [17:0] acc_next = acc + {9'd0, step};

function [2:0] bilinear3;
    input [2:0] a;
    input [2:0] b;
    input [7:0] frac;
    reg [10:0] weighted;
    begin
        weighted = (a * (9'd256 - frac)) + (b * frac);
        bilinear3 = weighted >> 8;
    end
endfunction

wire [2:0] bilinear_r = bilinear3(lb_rdata[5:3], lb_rdata_next[5:3], frac_p2);
wire [2:0] bilinear_g = bilinear3(lb_rdata[8:6], lb_rdata_next[8:6], frac_p2);
wire [2:0] bilinear_b = bilinear3(lb_rdata[2:0], lb_rdata_next[2:0], frac_p2);

// Scanline attenuation: darkens the duplicated copy of a line (half == 1)
// according to scan_sync (0/25/50/100%).  The first copy (half == 0) is
// never touched.
function [7:0] scanline_atten;
    input [7:0] v;
    input [1:0] level;
    input       dup;
    begin
        if (!dup)
            scanline_atten = v;
        else case (level)
            2'b00:   scanline_atten = v;                   // off
            2'b01:   scanline_atten = v - (v >> 2);         // 75% brightness
            2'b10:   scanline_atten = v >> 1;               // 50% brightness
            default: scanline_atten = 8'd0;                 // fully black
        endcase
    end
endfunction

// Décalage horizontal de centrage par résolution, déterminé empiriquement
// (remplace l'ancien calcul dérivé de hds_in/dcc_in). Indexé sur hdw_sync
// (largeur active en unités de 8 pixels). À compléter/ajuster pour 512px
// une fois l'image visible.
reg [10:0] hds_skip;
always @(*) begin
    case (hdw_sync)
        7'd32:   hds_skip = 11'd11;    // 256 px OK
        7'd40:   hds_skip = 11'd23;   // 320 px OK
        7'd44:   hds_skip = 11'd8;    // 352 px OK
        7'd64:   hds_skip = 11'd600;    // 512 px - à ajuster
        default: hds_skip = 11'd400;
    endcase
end

// Fixed-point starting offset into the source line for the accumulator.
wire [19:0] acc_start_full = (left_skip * step) + {hds_skip, 8'd0};
wire [17:0] acc_start = acc_start_full[17:0];

wire v_active = (vline >= (V_START >> 1)) &&
                (vline <  ((V_START + V_ACTIVE) >> 1));

// Full 640 wide active area - drives vga_de/osd_de and is unaffected by the
// zoom mode, so the OSD menu always covers the whole screen.
wire de_full = v_active && (hcnt >= H_PRE) && (hcnt < H_PRE + H_ACTIVE);
// Narrower, centered window that actually carries the scaled picture; the
// rest of de_full is painted black (letterbox/pillarbox borders).
wire de_game = v_active && (hcnt >= H_PRE + h_off) && (hcnt < H_PRE + h_off + vis_w);
wire hs_c = (hcnt < H_SYNC);
wire vs_c = (hdmi_line < V_SYNC);

// OSD coordinates, taken at the head of the output pipeline
assign osd_x  = hcnt - H_PRE;
assign osd_y  = hdmi_line - V_START;
assign osd_de = de_full;

initial begin
    hcnt       = 11'd0;
    vline      = 10'd0;
    half       = 1'b0;
    frame_pend = 1'b0;
    acc        = 18'd0;
end

always @(posedge clk_pix) begin
    line_sync  <= {line_sync[1:0],  line_tgl};
    frame_sync <= {frame_sync[1:0], frame_tgl};
    bank_sync  <= {bank_sync[1:0],  wr_bank};
    dcc_sync0  <= dcc_lat;
    dcc_sync   <= dcc_sync0;
    hdw_sync0  <= hdw_lat;
    hdw_sync   <= hdw_sync0;
    zoom_sync0 <= zoom_lat;
    zoom_sync  <= zoom_sync0;
    scan_sync0 <= scan_lat;
    scan_sync  <= scan_sync0;
    wr_addr_max_sync0 <= wr_addr_max_lat;
    wr_addr_max_sync  <= wr_addr_max_sync0;

    // ---- free running counters ------------------------------------------
    if (hcnt == H_TOTAL - 11'd1) begin
        hcnt <= 11'd0;
        half <= ~half;
    end else begin
        hcnt <= hcnt + 11'd1;
    end

    if (frame_ev && !line_ev)
        frame_pend <= 1'b1;

    // ---- realignment by the core (wins over the free running counters) ---
    if (line_ev) begin
        hcnt       <= 11'd0;
        half       <= 1'b0;
        frame_pend <= 1'b0;
        if (frame_pend || frame_ev)
            vline <= 10'd0;
        else
            vline <= vline + 10'd1;
    end

    // ---- horizontal scaler ----------------------------------------------
    if (hcnt == H_PRE + h_off - 11'd1)
        acc <= acc_start;
    else
        acc <= acc + {9'd0, step};

    lb_raddr <= {~bank_sync[2], acc[17:8]};
    lb_raddr_next <= {~bank_sync[2], acc_next[17:8]};
    frac_p1 <= acc[7:0];
    frac_p2 <= frac_p1;
    bilinear_p1 <= (zoom_sync == 2'b10);
    bilinear_p2 <= bilinear_p1;

    // ---- output pipeline (matches the line buffer read latency) ----------
    de_p  <= {de_p[0],  de_full};
    deg_p <= {deg_p[0], de_game};
    hs_p <= {hs_p[0], hs_c};
    vs_p <= {vs_p[0], vs_c};
    half_p <= {half_p[0], half};

    vga_de <= de_p[1];
    vga_hs <= hs_p[1];
    vga_vs <= vs_p[1];

    if (de_p[1]) begin
        vga_r <= {lb_rdata[5:3], lb_rdata[5:3], lb_rdata[5:4]};
        vga_g <= {lb_rdata[8:6], lb_rdata[8:6], lb_rdata[8:7]};
        vga_b <= {lb_rdata[2:0], lb_rdata[2:0], lb_rdata[2:1]};
    end else begin
        vga_r <= 8'd0;
        vga_g <= 8'd0;
        vga_b <= 8'd0;
    end

// ---- DEBUG: barre horizontale = nb de pixels réellement écrits/ligne ----
// Longueur proportionnelle à wr_addr_max_sync (nb de pixels source écrits
// dans le buffer pour la dernière ligne). Affichée sur vline==25 (dans la
// zone active), en surimpression, indépendamment de deg_p/de_full.
if (vline == 10'd25 && hcnt >= H_PRE &&
    hcnt < H_PRE + {1'b0, wr_addr_max_sync}) begin
    vga_r <= 8'hFF;
    vga_g <= 8'hFF;
    vga_b <= 8'hFF;
end

    if (!pix_resetn) begin
        hcnt       <= 11'd0;
        vline      <= 10'd0;
        half       <= 1'b0;
        frame_pend <= 1'b0;
        acc        <= 18'd0;
        de_p       <= 2'b00;
        deg_p      <= 2'b00;
        hs_p       <= 2'b00;
        vs_p       <= 2'b00;
        half_p     <= 2'b00;
        frac_p1    <= 8'd0;
        frac_p2    <= 8'd0;
        bilinear_p1 <= 1'b0;
        bilinear_p2 <= 1'b0;
        vga_de     <= 1'b0;
        wr_addr_max_sync0 <= 10'd0;
        wr_addr_max_sync  <= 10'd0;
    end
end

endmodule


//
// Simple dual clock, dual port block RAM (one write port, one read port).
//
module dpram_dc #(
    parameter AW = 11,
    parameter DW = 9
) (
    input  wire            wrclk,
    input  wire            we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   wdata,
    input  wire            rdclk,
    input  wire [AW-1:0]   raddr,
    output reg  [DW-1:0]   rdata
);

reg [DW-1:0] mem [0:(1<<AW)-1];

always @(posedge wrclk)
    if (we) mem[waddr] <= wdata;

always @(posedge rdclk)
    rdata <= mem[raddr];

endmodule
