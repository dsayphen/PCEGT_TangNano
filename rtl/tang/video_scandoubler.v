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
// upscaled to the full 640 pixels with a nearest neighbour DDA whose step is
// exact in 1/256 units (108 / 144 / 216), so the picture always fills the
// screen with the correct 4:3 aspect ratio.
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
reg        line_tgl;      // toggles at the end of every core scan line
reg        frame_tgl;     // toggles at the start of every core frame
reg [1:0]  dcc_lat;

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
    lb_we     = 1'b0;
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
    end

    // End of line: swap buffers.  VIDEO_HS rises well after the end of the
    // active area and well before the start of the next one.
    if (hs_in && !hs_d) begin
        wr_addr  <= 10'd0;
        wr_bank  <= ~wr_bank;
        dcc_lat  <= dcc_in;
        line_tgl <= ~line_tgl;
    end

    if (vs_in && !vs_d)
        frame_tgl <= ~frame_tgl;
end

// ===========================================================================
// Line buffer - 2 x 1024 x 9 bit
// ===========================================================================
reg  [10:0] lb_raddr;
wire [8:0]  lb_rdata;

dpram_dc #(.AW(11), .DW(9)) linebuf (
    .wrclk  (clk_sys),
    .we     (lb_we),
    .waddr  (lb_waddr),
    .wdata  (lb_wdata),
    .rdclk  (clk_pix),
    .raddr  (lb_raddr),
    .rdata  (lb_rdata)
);

// ===========================================================================
// Read side - pixel clock domain
// ===========================================================================
reg [2:0] line_sync;
reg [2:0] frame_sync;
reg [2:0] bank_sync;
reg [1:0] dcc_sync0;
reg [1:0] dcc_sync;

wire line_ev  = line_sync[2]  ^ line_sync[1];
wire frame_ev = frame_sync[2] ^ frame_sync[1];

reg [10:0] hcnt;
reg [9:0]  vline;      // core line counter, 0 at vsync
reg        half;       // 0 = first, 1 = second copy of the line
reg        frame_pend;

reg [17:0] acc;        // 10.8 fixed point source pointer

reg [1:0]  de_p;
reg [1:0]  hs_p;
reg [1:0]  vs_p;

reg [7:0]  step;
always @(*) begin
    case (dcc_sync)
        2'b00:   step = 8'd108;   // 270 source dots -> 640
        2'b01:   step = 8'd144;   // 360 source dots -> 640
        default: step = 8'd216;   // 540 source dots -> 640
    endcase
end

wire [9:0] hdmi_line = {vline[8:0], half};

wire v_active = (vline >= (V_START >> 1)) &&
                (vline <  ((V_START + V_ACTIVE) >> 1));

wire de_c = v_active && (hcnt >= H_PRE) && (hcnt < H_PRE + H_ACTIVE);
wire hs_c = (hcnt < H_SYNC);
wire vs_c = (hdmi_line < V_SYNC);

// OSD coordinates, taken at the head of the output pipeline
assign osd_x  = hcnt - H_PRE;
assign osd_y  = hdmi_line - V_START;
assign osd_de = de_c;

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
    if (hcnt == H_PRE - 11'd1)
        acc <= 18'd0;
    else
        acc <= acc + {10'd0, step};

    lb_raddr <= {~bank_sync[2], acc[17:8]};

    // ---- output pipeline (matches the line buffer read latency) ----------
    de_p <= {de_p[0], de_c};
    hs_p <= {hs_p[0], hs_c};
    vs_p <= {vs_p[0], vs_c};

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

    if (!pix_resetn) begin
        hcnt       <= 11'd0;
        vline      <= 10'd0;
        half       <= 1'b0;
        frame_pend <= 1'b0;
        acc        <= 18'd0;
        de_p       <= 2'b00;
        hs_p       <= 2'b00;
        vs_p       <= 2'b00;
        vga_de     <= 1'b0;
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
