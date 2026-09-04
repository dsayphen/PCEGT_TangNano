//
// PC Engine / TurboGrafx-16 for the Sipeed Tang Nano 20K  (GW2AR-LV18QN88C8/I7)
//
// HuCard-only build:
//   * HuCard ROM in the on-package 64 Mbit SDRAM, loaded over the on-board
//     USB-UART (see rtl/tang/rom_loader.v for the wire protocol)
//   * work RAM, VRAM, palette and sprite buffers in block RAM
//   * genlocked line doubler -> DVI/HDMI on the HDMI connector
//   * PSG -> I2S -> on-board audio amplifier / headphone jack
//   * one SNES style pad on the GPIO header, plus the two on-board buttons
//
// Not built: CD-ROM^2 / Super CD / Arcade Card, SuperGrafx, backup RAM,
// Populous SRAM, multitap, 6-button pads, Game Genie, OSD.
//
// See README.md for the build, load and wiring instructions.
//

module top_tang_nano20k (
    input  wire        sys_clk,        // 27 MHz crystal

    // on-board push button (active high)
    input  wire        s1,

    // on-board USB serial bridge
    input  wire        uart_rx,
    output wire        uart_tx,

    // on-board LEDs (active low)
    output wire [1:0]  led,

    // GW2AR on-package SDRAM (pins are assigned automatically by name)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,

    // HDMI
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

    // on-board I2S amplifier / headphone jack
    output wire        pa_en,
    output wire        hp_bck,
    output wire        hp_ws,
    output wire        hp_din,

    // external SNES style game pad
    output wire        pad_clk,
    output wire        pad_latch,
    input  wire        pad_data
);

// UART baud rate.  115200 works with any host; the BL616 bridge on the board
// also handles 921600, which cuts the load time of a 1 MiB image to ~11 s.
localparam BAUD_RATE  = 115200;
localparam CLK_SYS_HZ = 43_200_000;

// ===========================================================================
// Clocks
// ===========================================================================
wire clk_sys;        // 43.2 MHz
wire clk_sdram;      // 43.2 MHz, 180 degrees
wire clk_pix5;       // 129.6 MHz
wire clk_pix;        // 25.92 MHz
wire lock_main;
wire lock_hdmi;

pll_main u_pll_main (
    .clkin   (sys_clk),
    .clkout  (clk_sys),
    .clkoutp (clk_sdram),
    .lock    (lock_main)
);

pll_hdmi u_pll_hdmi (
    .clkin  (sys_clk),
    .clkout (clk_pix5),
    .lock   (lock_hdmi)
);

clkdiv5 u_clkdiv (
    .hclkin (clk_pix5),
    .resetn (lock_hdmi),
    .clkout (clk_pix)
);

// ===========================================================================
// Resets
// ===========================================================================
// system reset, released a while after both PLLs have locked
reg [7:0] pwr_cnt = 8'd0;
reg       sys_resetn = 1'b0;

always @(posedge clk_sys) begin
    if (!(lock_main && lock_hdmi)) begin
        pwr_cnt    <= 8'd0;
        sys_resetn <= 1'b0;
    end else if (pwr_cnt != 8'hFF) begin
        pwr_cnt <= pwr_cnt + 8'd1;
    end else begin
        sys_resetn <= 1'b1;
    end
end

// pixel domain reset
reg [2:0] pix_rst_sync = 3'b000;
always @(posedge clk_pix)
    pix_rst_sync <= {pix_rst_sync[1:0], lock_hdmi};
wire pix_resetn = pix_rst_sync[2];

// button synchronisers
reg [2:0] s1_sync = 3'b000;
always @(posedge clk_sys) begin
    s1_sync <= {s1_sync[1:0], s1};
end
wire btn_reset = s1_sync[2];

// ===========================================================================
// UART ROM loader + SDRAM
// ===========================================================================
wire        ld_wr;
wire [22:0] ld_addr;
wire [7:0]  ld_data;
wire        ld_busy;
wire        loading;
wire        image_valid;
wire [7:0]  rom_sz;
wire [22:0] rom_offset;
wire        rx_activity;

rom_loader #(
    .CLK_FREQ  (CLK_SYS_HZ),
    .BAUD_RATE (BAUD_RATE)
) u_loader (
    .clk         (clk_sys),
    .resetn      (sys_resetn),
    .rx          (uart_rx),
    .ld_wr       (ld_wr),
    .ld_addr     (ld_addr),
    .ld_data     (ld_data),
    .ld_busy     (ld_busy),
    .loading     (loading),
    .image_valid (image_valid),
    .rom_sz      (rom_sz),
    .rom_offset  (rom_offset),
    .rx_activity (rx_activity)
);

assign uart_tx = 1'b1;   // idle, nothing is sent back

wire        rom_rd;
wire [21:0] rom_a;
wire [7:0]  rom_do;
wire        rom_rdy;
wire        sdram_init_done;

pce_sdram_ctrl #(
    .FREQ (CLK_SYS_HZ)
) u_mem (
    .clk           (clk_sys),
    .clk_sdram     (clk_sdram),
    .resetn        (sys_resetn),

    .O_sdram_clk   (O_sdram_clk),
    .O_sdram_cke   (O_sdram_cke),
    .O_sdram_cs_n  (O_sdram_cs_n),
    .O_sdram_cas_n (O_sdram_cas_n),
    .O_sdram_ras_n (O_sdram_ras_n),
    .O_sdram_wen_n (O_sdram_wen_n),
    .IO_sdram_dq   (IO_sdram_dq),
    .O_sdram_addr  (O_sdram_addr),
    .O_sdram_ba    (O_sdram_ba),
    .O_sdram_dqm   (O_sdram_dqm),

    .ld_wr         (ld_wr),
    .ld_addr       (ld_addr),
    .ld_data       (ld_data),
    .ld_busy       (ld_busy),
    .ld_active     (loading),

    .rom_rd        (rom_rd),
    .rom_a         (rom_a),
    .rom_offset    (rom_offset),
    .rom_do        (rom_do),
    .rom_rdy       (rom_rdy),

    .init_done     (sdram_init_done)
);

// ===========================================================================
// Core reset
//
// The console is held in reset while the SDRAM is initialising, while a ROM
// image is being received, when no image has been loaded yet and for 64k
// clocks (1.5 ms) afterwards, which is long enough for the COLD_RESET memory
// clear inside the core to complete.
// ===========================================================================
wire rst_trigger = !sdram_init_done || loading || !image_valid || btn_reset;

reg [16:0] rst_cnt = 17'd0;
always @(posedge clk_sys) begin
    if (!sys_resetn || rst_trigger)
        rst_cnt <= 17'd0;
    else if (!rst_cnt[16])
        rst_cnt <= rst_cnt + 17'd1;
end

wire core_reset = ~rst_cnt[16];

// ===========================================================================
// The console
// ===========================================================================
wire [1:0]  joy_out;
wire [3:0]  joy_in;
wire [19:0] aud_l;
wire [19:0] aud_r;
wire        vid_ce;
wire [2:0]  vid_r, vid_g, vid_b;
wire        vid_hs, vid_vs, vid_hbl, vid_vbl;
wire [1:0]  vid_dcc;

pce_core u_pce (
    .clk        (clk_sys),
    .reset      (core_reset),
    .cold_reset (core_reset),

    .rom_rd     (rom_rd),
    .rom_rdy    (rom_rdy),
    .rom_a      (rom_a),
    .rom_do     (rom_do),
    .rom_sz     (rom_sz),

    .joy_out    (joy_out),
    .joy_in     (joy_in),

    .aud_l      (aud_l),
    .aud_r      (aud_r),

    .vid_ce     (vid_ce),
    .vid_r      (vid_r),
    .vid_g      (vid_g),
    .vid_b      (vid_b),
    .vid_hs     (vid_hs),
    .vid_vs     (vid_vs),
    .vid_hbl    (vid_hbl),
    .vid_vbl    (vid_vbl),
    .vid_dcc    (vid_dcc)
);

// ===========================================================================
// Game pad
// ===========================================================================
wire [11:0] pad_btn;

snes_gamepad u_pad (
    .clk       (clk_sys),
    .resetn    (sys_resetn),
    .pad_latch (pad_latch),
    .pad_clk   (pad_clk),
    .pad_data  (pad_data),
    .buttons   (pad_btn)
);

// SNES bit order: 0:B 1:Y 2:Select 3:Start 4:Up 5:Down 6:Left 7:Right
//                 8:A 9:X 10:L 11:R
pce_pad u_joy (
    .clk     (clk_sys),
    .joy_out (joy_out),
    .joy_in  (joy_in),
    .up      (pad_btn[4]),
    .down    (pad_btn[5]),
    .left    (pad_btn[6]),
    .right   (pad_btn[7]),
    .btn_i   (pad_btn[8] | pad_btn[9]),      // SNES A / X  -> PCE I
    .btn_ii  (pad_btn[0] | pad_btn[1]),      // SNES B / Y  -> PCE II
    .sel     (pad_btn[2]),                   // SNES Select -> Select
    .run     (pad_btn[3])                    // SNES Start -> Run
);

// ===========================================================================
// Video: genlocked line doubler + DVI transmitter
// ===========================================================================
wire [7:0] vga_r, vga_g, vga_b;
wire       vga_hs, vga_vs, vga_de;

video_scandoubler u_sd (
    .clk_sys    (clk_sys),
    .ce_pix     (vid_ce),
    .r_in       (vid_r),
    .g_in       (vid_g),
    .b_in       (vid_b),
    .hs_in      (vid_hs),
    .vs_in      (vid_vs),
    .hbl_in     (vid_hbl),
    .dcc_in     (vid_dcc),

    .clk_pix    (clk_pix),
    .pix_resetn (pix_resetn),
    .vga_r      (vga_r),
    .vga_g      (vga_g),
    .vga_b      (vga_b),
    .vga_hs     (vga_hs),
    .vga_vs     (vga_vs),
    .vga_de     (vga_de)
);

dvi_tx u_dvi (
    .clk_pix    (clk_pix),
    .clk_pix5   (clk_pix5),
    .resetn     (pix_resetn),
    .r          (vga_r),
    .g          (vga_g),
    .b          (vga_b),
    .de         (vga_de),
    .hsync      (vga_hs),
    .vsync      (vga_vs),
    .tmds_clk_p (tmds_clk_p),
    .tmds_clk_n (tmds_clk_n),
    .tmds_d_p   (tmds_d_p),
    .tmds_d_n   (tmds_d_n)
);

// ===========================================================================
// Audio
// ===========================================================================
i2s_tx #(.BCK_DIV(14)) u_i2s (
    .clk    (clk_sys),
    .resetn (sys_resetn),
    .left   (aud_l[19:4]),
    .right  (aud_r[19:4]),
    .sck    (hp_bck),
    .ws     (hp_ws),
    .sd     (hp_din)
);

assign pa_en = 1'b1;

// ===========================================================================
// Status LEDs (active low)
// ===========================================================================
assign led[0] = ~(lock_main & lock_hdmi & sdram_init_done);
assign led[1] = ~(image_valid & ~loading & ~core_reset);

endmodule
