//
// PC Engine / TurboGrafx-16 for the Sipeed Tang Nano 20K  (GW2AR-LV18QN88C8/I7)
//
// HuCard-only build:
//   * HuCard ROM in the on-package 64 Mbit SDRAM.  A PicoRV32 IO subsystem
//     (rtl/tang/iosys/, SNESTang style) boots its firmware from the on-board
//     SPI flash, mounts the microSD card with FatFs, shows an on-screen menu
//     over the DVI output and streams the .PCE file the user selects with the
//     SNES pad into the SDRAM.  The on-board USB-UART remains available as a
//     fallback / replacement path (see rtl/tang/rom_loader.v).
//   * both VDC VRAMs in SDRAM; work RAM, palette and sprite buffers in BSRAM
//   * genlocked line doubler -> DVI/HDMI on the HDMI connector
//   * PSG -> I2S -> on-board audio amplifier / headphone jack
//   * one SNES style pad on the GPIO header, plus the two on-board buttons
//
// Not built: CD-ROM^2 / Super CD / Arcade Card, backup RAM, Populous SRAM,
// multitap, 6-button pads, Game Genie.
//
// See README.md for the build, flash, load and wiring instructions.
//

module top_tang_nano20k (
    input  wire        sys_clk,        // 27 MHz crystal

    // on-board push buttons (active high)
    input  wire        s1,
    input  wire        s2,

    // on-board USB serial bridge
    input  wire        uart_rx,
    output wire        uart_tx,

    // on-board LEDs (active low)
    output wire [1:0]  led,

    // on-board microSD socket, driven in SPI mode
    output wire        sd_clk,         // SCK
    output wire        sd_cmd,         // MOSI
    input  wire        sd_dat0,        // MISO
    output wire        sd_dat1,        // held high
    output wire        sd_dat2,        // held high
    output wire        sd_dat3,        // CS, held low

    // on-board SPI NOR flash (MSPI pins, released after configuration)
    output wire        flash_spi_cs_n,
    input  wire        flash_spi_miso,
    output wire        flash_spi_mosi,
    output wire        flash_spi_clk,
    output wire        flash_spi_wp_n,
    output wire        flash_spi_hold_n,

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

// Firmware image location in the on-board SPI NOR flash.  The Tang Nano 20K
// carries a 64 Mbit (8 MiB) part and the GW2AR-18 bitstream is well under
// 1 MiB, so 0x500000 is far past it - the same offset SNESTang uses.
localparam [23:0] FIRMWARE_FLASH_ADDR = 24'h50_0000;
localparam        FIRMWARE_SIZE       = 128*1024;

// ===========================================================================
// Clocks
// ===========================================================================
wire clk_sys;        // 43.2 MHz
wire clk_mem;        // 86.4 MHz SDRAM controller
wire clk_sdram;      // 86.4 MHz, 180 degrees
wire clk_pix5;       // 129.6 MHz
wire clk_pix;        // 25.92 MHz
wire lock_main;
wire lock_hdmi;

pll_main u_pll_main (
    .clkin   (sys_clk),
    .clkout  (clk_mem),
    .clkoutp (clk_sdram),
    .clkoutd (clk_sys),
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
wire      system_reset;

always @(posedge clk_sys) begin
    if (!(lock_main && lock_hdmi) || system_reset) begin
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
reg [2:0] s2_sync = 3'b000;
always @(posedge clk_sys) begin
    s1_sync <= {s1_sync[1:0], s1};
    s2_sync <= {s2_sync[1:0], s2};
end
wire btn_reset = s1_sync[2];
wire btn_select = s2_sync[2];

// ===========================================================================
// ROM loaders (menu softcore + UART fallback) and SDRAM
//
// rom_source_arb multiplexes - never ORs - the two write ports and the two
// ROM descriptions, so only one source can ever reach the memory.
// ===========================================================================
wire        ld_wr;
wire [22:0] ld_addr;
wire [7:0]  ld_data;
wire        ld_busy;
wire        ld_idle;
wire        loading;
wire        image_valid;
wire [7:0]  rom_sz;
wire [22:0] rom_offset;
wire        sgx_mode;
wire [1:0]  video_zoom;
wire [1:0]  scanline;
wire        game_pause;
wire        game_reset;
wire        pad_mode;
wire        color_mode;
wire [3:0]  audio_volume;
wire [3:0]  audio_bass;
wire [3:0]  audio_treble;

// ---- softcore / menu ------------------------------------------------------
wire        rv_ld_wr;
wire [22:0] rv_ld_addr;
wire [7:0]  rv_ld_data;
wire        rv_ld_busy;
wire        rv_loading;
wire        rv_image_valid;
wire [7:0]  rv_rom_sz;
wire [22:0] rv_rom_offset;
wire        rv_sgx_mode;
wire        rv_cd_mode;

wire        rv_valid;
wire        rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0]  rv_wstrb;
wire [31:0] rv_rdata;

wire [15:0] cd_stat;
wire        cd_stat_get;
wire [95:0] cd_comm;
wire        cd_comm_send;
wire        cd_dout_req;
wire [79:0] cd_dout;
wire        cd_dout_send;
wire        cd_reset_req;
wire [7:0]  cd_data;
wire        cd_wr;
wire        cd_data_end;
wire        cd_dm;
wire        cd_fifo_halffull;
wire [7:0]  cd_phase_dbg;

wire        osd_on;
wire [23:0] osd_rgb;
wire        osd_text;
wire        osd_active;
wire [10:0] osd_x;
wire [9:0]  osd_y;
wire        osd_de;

wire [11:0] pad_btn;
wire [11:0] menu_btn = pad_btn | {3'b000, btn_select, 8'b0000_0000};
wire        sdram_init_done;

// DAT1 / DAT2 are unused in SPI mode and must be held high, DAT3 is the chip
// select and is driven by the IO subsystem.
assign sd_dat1 = 1'b1;
assign sd_dat2 = 1'b1;

iosys #(
    .FREQ                (CLK_SYS_HZ),
    .FIRMWARE_FLASH_ADDR (FIRMWARE_FLASH_ADDR),
    .FIRMWARE_SIZE       (FIRMWARE_SIZE),
    .RV_BASE             (23'h40_0000)
) u_iosys (
    .clk              (clk_sys),
    .resetn           (sys_resetn),

    .clk_pix          (clk_pix),
    .pix_resetn       (pix_resetn),
    .osd_x            (osd_x),
    .osd_y            (osd_y),
    .osd_de           (osd_de),
    .osd_on           (osd_on),
    .osd_rgb          (osd_rgb),
    .osd_text         (osd_text),
    .osd_active       (osd_active),

    .joy1             (menu_btn),

    .ld_wr            (rv_ld_wr),
    .ld_addr          (rv_ld_addr),
    .ld_data          (rv_ld_data),
    .ld_busy          (rv_ld_busy),
    .ld_idle          (ld_idle),
    .loading          (rv_loading),
    .image_valid      (rv_image_valid),
    .rom_sz           (rv_rom_sz),
    .rom_offset       (rv_rom_offset),
    .sgx_mode         (rv_sgx_mode),
    .cd_mode          (rv_cd_mode),
    .video_zoom       (video_zoom),
    .scanline         (scanline),
    .game_pause       (game_pause),
    .game_reset       (game_reset),
    .system_reset     (system_reset),
    .pad_mode         (pad_mode),
    .color_mode       (color_mode),
    .audio_volume     (audio_volume),
    .audio_bass       (audio_bass),
    .audio_treble     (audio_treble),
    .cd_comm          (cd_comm),
    .cd_comm_send     (cd_comm_send),
    .cd_dout          (cd_dout),
    .cd_dout_send     (cd_dout_send),
    .cd_data_end      (cd_data_end),
    .cd_reset         (cd_reset_req),
    .cd_fifo_halffull (cd_fifo_halffull),
    .cd_stat          (cd_stat),
    .cd_stat_strobe   (cd_stat_get),
    .cd_dout_req      (cd_dout_req),
    .cd_data          (cd_data),
    .cd_wr            (cd_wr),
    .cd_dm            (cd_dm),
    .cd_ack           (),
    .vid_dcc_dbg      (vid_dcc),
    .vid_hdw_dbg      (vid_hdw_dbg),
    .vid_hds_dbg      (vid_hds_dbg),
    .cd_phase_dbg     (cd_phase_dbg),

    .rv_valid         (rv_valid),
    .rv_ready         (rv_ready),
    .rv_addr          (rv_addr),
    .rv_wdata         (rv_wdata),
    .rv_wstrb         (rv_wstrb),
    .rv_rdata         (rv_rdata),
    .ram_busy         (~sdram_init_done),

    .flash_spi_cs_n   (flash_spi_cs_n),
    .flash_spi_miso   (flash_spi_miso),
    .flash_spi_mosi   (flash_spi_mosi),
    .flash_spi_clk    (flash_spi_clk),
    .flash_spi_wp_n   (flash_spi_wp_n),
    .flash_spi_hold_n (flash_spi_hold_n),

    .uart_rx          (uart_rx),
    .uart_tx          (uart_tx),

    .sd_clk           (sd_clk),
    .sd_mosi          (sd_cmd),
    .sd_miso          (sd_dat0),
    .sd_cs_n          (sd_dat3)
);

// ---- UART loader ----------------------------------------------------------
wire        ua_ld_wr;
wire [22:0] ua_ld_addr;
wire [7:0]  ua_ld_data;
wire        ua_ld_busy;
wire        ua_loading;
wire        ua_image_valid;
wire [7:0]  ua_rom_sz;
wire [22:0] ua_rom_offset;
wire        ua_sgx_mode;

rom_loader #(
    .CLK_FREQ  (CLK_SYS_HZ),
    .BAUD_RATE (BAUD_RATE)
) u_loader (
    .clk         (clk_sys),
    .resetn      (sys_resetn),
    .rx          (uart_rx),
    .ld_wr       (ua_ld_wr),
    .ld_addr     (ua_ld_addr),
    .ld_data     (ua_ld_data),
    .ld_busy     (ua_ld_busy),
    .loading     (ua_loading),
    .image_valid (ua_image_valid),
    .rom_sz      (ua_rom_sz),
    .rom_offset  (ua_rom_offset),
    .sgx_mode    (ua_sgx_mode),
    .rx_activity ()
);

// ---- source arbitration ---------------------------------------------------
rom_source_arb u_arb (
    .clk            (clk_sys),
    .resetn         (sys_resetn),

    .rv_ld_wr       (rv_ld_wr),
    .rv_ld_addr     (rv_ld_addr),
    .rv_ld_data     (rv_ld_data),
    .rv_loading     (rv_loading),
    .rv_image_valid (rv_image_valid),
    .rv_rom_sz      (rv_rom_sz),
    .rv_rom_offset  (rv_rom_offset),
    .rv_sgx_mode    (rv_sgx_mode),
    .rv_ld_busy     (rv_ld_busy),

    .ua_ld_wr       (ua_ld_wr),
    .ua_ld_addr     (ua_ld_addr),
    .ua_ld_data     (ua_ld_data),
    .ua_loading     (ua_loading),
    .ua_image_valid (ua_image_valid),
    .ua_rom_sz      (ua_rom_sz),
    .ua_rom_offset  (ua_rom_offset),
    .ua_sgx_mode    (ua_sgx_mode),
    .ua_ld_busy     (ua_ld_busy),

    .ld_wr          (ld_wr),
    .ld_addr        (ld_addr),
    .ld_data        (ld_data),
    .ld_busy        (ld_busy),
    .loading        (loading),
    .image_valid    (image_valid),
    .rom_sz         (rom_sz),
    .rom_offset     (rom_offset),
    .sgx_mode       (sgx_mode),
    .own_uart_o     ()
);

wire        rom_rd;
wire [21:0] rom_a;
wire [7:0]  rom_do;
wire        rom_rdy;
wire [15:0] vram0_a;
wire [15:0] vram0_do;
wire [15:0] vram0_di;
wire        vram0_rd;
wire        vram0_we;
wire [15:0] vram1_a;
wire [15:0] vram1_do;
wire [15:0] vram1_di;
wire        vram1_rd;
wire        vram1_we;
wire        vid_ce;
wire        vid_vbl;
wire        vram_refresh_window;

pce_sdram_ctrl_3ch #(
    .FREQ (86_400_000)
) u_mem (
    .clk           (clk_sys),
    .clk_mem       (clk_mem),
    .clk_sdram     (clk_sdram),
    .clkref        (vid_ce),
    .refresh_window(vram_refresh_window),
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
    .ld_idle       (ld_idle),
    .ld_active     (loading),

    .rom_rd        (rom_rd),
    .rom_a         (rom_a),
    .rom_offset    (rom_offset),
    .rom_do        (rom_do),
    .rom_rdy       (rom_rdy),

    .vram_addr     (vram0_a),
    .vram_din      (vram0_do),
    .vram_dout     (vram0_di),
    .vram_rd       (vram0_rd),
    .vram_we       (vram0_we),

    .vram1_addr    (vram1_a),
    .vram1_din     (vram1_do),
    .vram1_dout    (vram1_di),
    .vram1_rd      (vram1_rd),
    .vram1_we      (vram1_we),

    .rv_valid      (rv_valid),
    .rv_ready      (rv_ready),
    .rv_addr       (rv_addr),
    .rv_wdata      (rv_wdata),
    .rv_wstrb      (rv_wstrb),
    .rv_rdata      (rv_rdata),

    .init_done     (sdram_init_done)
);

// ===========================================================================
// Core reset
//
// The console is held in reset while the SDRAM is initialising, while a ROM
// image is being streamed from the card or received over the UART, when no
// image has been loaded yet and for 64k clocks (1.5 ms) afterwards, which is
// long enough for the COLD_RESET memory clear inside the core to complete.
//
// `loading` is high for the whole of any transfer, from the moment the menu
// firmware (or the UART loader) announces it until the last byte has really
// reached the memory array, so the core can never run while the ROM area of
// the SDRAM is being written - including when the user reopens the menu and
// picks a different game.
// ===========================================================================
wire rst_trigger = !sdram_init_done || loading || !image_valid || btn_reset || game_reset;

// Cycles to hold reset after `rst_trigger` clears: 64k (65536) clocks for the
// core's internal COLD_RESET memory clear, plus RST_EXTRA_CYCLES on top if
// more settle time is needed. Bump RST_EXTRA_CYCLES (and widen rst_cnt if the
// total exceeds 17 bits) to add more delay. max 131071 (1,5 ms) - 65536 = 65535

// 17'd4320 → +100 µs
// 17'd21600 → +500 µs
// 17'd43200 → +1 ms

localparam RST_EXTRA_CYCLES = 17'd65535;
localparam RST_TOTAL_CYCLES = 17'd65536 + RST_EXTRA_CYCLES;

reg [16:0] rst_cnt = 17'd0;
always @(posedge clk_sys) begin
    if (!sys_resetn || rst_trigger)
        rst_cnt <= 17'd0;
    else if (rst_cnt < RST_TOTAL_CYCLES)
        rst_cnt <= rst_cnt + 17'd1;
end

wire core_reset = ~rst_cnt[16];
// refresh may ignore the VDCs only while the core (and so both VDCs) is held in reset
assign vram_refresh_window = core_reset;

// ===========================================================================
// The console
// ===========================================================================
wire [1:0]  joy_out;
wire [3:0]  joy_in;
wire [19:0] aud_l_raw;
wire [19:0] aud_r_raw;
wire [19:0] aud_l;
wire [19:0] aud_r;
wire [2:0]  vid_r, vid_g, vid_b;
wire        vid_hs, vid_vs, vid_hbl;
wire [1:0]  vid_dcc;
wire [6:0]  vid_hdw_dbg;
wire [6:0]  vid_hds_dbg;

pce_core #(
    .SGX_SUPPORT (1)
) u_pce (
    .clk        (clk_sys),
    .reset      (core_reset),
    .cold_reset (core_reset),
    .cpu_pause  (game_pause),

    .rom_rd     (rom_rd),
    .rom_rdy    (rom_rdy),
    .rom_a      (rom_a),
    .rom_do     (rom_do),
    .rom_sz     (rom_sz),
    .sgx_mode   (sgx_mode),
    .cd_enable  (rv_cd_mode),

    .vram0_a    (vram0_a),
    .vram0_do   (vram0_do),
    .vram0_di   (vram0_di),
    .vram0_rd   (vram0_rd),
    .vram0_we   (vram0_we),

    .vram1_a    (vram1_a),
    .vram1_do   (vram1_do),
    .vram1_di   (vram1_di),
    .vram1_rd   (vram1_rd),
    .vram1_we   (vram1_we),

    .joy_out    (joy_out),
    .joy_in     (joy_in),

    .aud_l      (aud_l_raw),
    .aud_r      (aud_r_raw),

    .vid_ce     (vid_ce),
    .vid_r      (vid_r),
    .vid_g      (vid_g),
    .vid_b      (vid_b),
    .vid_hs     (vid_hs),
    .vid_vs     (vid_vs),
    .vid_hbl    (vid_hbl),
    .vid_vbl    (vid_vbl),
    .vid_dcc    (vid_dcc),
    .vid_hdw_dbg (vid_hdw_dbg),
    .vid_hds_dbg (vid_hds_dbg)
    ,.cd_stat       (cd_stat)
    ,.cd_stat_get   (cd_stat_get)
    ,.cd_comm       (cd_comm)
    ,.cd_comm_send  (cd_comm_send)
    ,.cd_dout_req   (cd_dout_req)
    ,.cd_dout       (cd_dout)
    ,.cd_dout_send  (cd_dout_send)
    ,.cd_reset      (cd_reset_req)
    ,.cd_data       (cd_data)
    ,.cd_wr         (cd_wr)
    ,.cd_data_end   (cd_data_end)
    ,.cd_dm         (cd_dm)
    ,.cd_fifo_halffull (cd_fifo_halffull)
    ,.cd_phase_dbg  (cd_phase_dbg)
);

// ===========================================================================
// Game pad
//
// While the menu is on screen the pad drives the menu only, so a game that is
// already running does not see the button presses used to navigate it.
// ===========================================================================
snes_gamepad u_pad (
    .clk       (clk_sys),
    .resetn    (sys_resetn),
    .pad_latch (pad_latch),
    .pad_clk   (pad_clk),
    .pad_data  (pad_data),
    .buttons   (pad_btn)
);

wire [11:0] game_btn = osd_active ? 12'd0 : pad_btn;

// SNES bit order: 0:B 1:Y 2:Select 3:Start 4:Up 5:Down 6:Left 7:Right
//                 8:A 9:X 10:L 11:R
pce_pad u_joy (
    .clk      (clk_sys),
    .joy_out  (joy_out),
    .joy_in   (joy_in),
    .pad_mode (pad_mode),
    .up       (game_btn[4]),
    .down     (game_btn[5]),
    .left     (game_btn[6]),
    .right    (game_btn[7]),
    .btn_i    (game_btn[8]),                 // SNES A -> PCE I
    .btn_ii   (game_btn[0]),                 // SNES B -> PCE II
    .btn_iii  (game_btn[9]),                 // SNES X -> PCE III
    .btn_iv   (game_btn[1]),                 // SNES Y -> PCE IV
    .btn_v    (game_btn[10]),                // SNES L -> PCE V
    .btn_vi   (game_btn[11]),                // SNES R -> PCE VI
    .sel      (game_btn[2]),                 // SNES Select -> Select
    .run      (game_btn[3])                  // SNES Start -> Run
);

// ===========================================================================
// Video: genlocked line doubler + composite color matrix + OSD overlay + HDMI
// ===========================================================================
wire [7:0] vga_r_raw, vga_g_raw, vga_b_raw;
wire       vga_hs_raw, vga_vs_raw, vga_de_raw;
wire [7:0] vga_r, vga_g, vga_b;
wire       vga_hs, vga_vs, vga_de;

video_scandoubler u_scandoubler (
    .clk_sys    (clk_sys),
    .ce_pix     (vid_ce),
    .r_in       (vid_r),
    .g_in       (vid_g),
    .b_in       (vid_b),
    .hs_in      (vid_hs),
    .vs_in      (vid_vs),
    .hbl_in     (vid_hbl),
    .dcc_in     (vid_dcc),
    .hdw_in     (vid_hdw_dbg),
    .hds_in     (vid_hds_dbg),
    .zoom_in    (video_zoom),
    .scan_in    (scanline),

    .clk_pix    (clk_pix),
    .pix_resetn (pix_resetn),
    .vga_r      (vga_r_raw),
    .vga_g      (vga_g_raw),
    .vga_b      (vga_b_raw),
    .vga_hs     (vga_hs_raw),
    .vga_vs     (vga_vs_raw),
    .vga_de     (vga_de_raw),
    .osd_x      (osd_x),
    .osd_y      (osd_y),
    .osd_de     (osd_de)
);

// Composite/monochrome color matrix (mix = 0..5, see rtl/color_mix.sv);
// sync/de pass straight through, unaffected by the horizontal blur filter.
color_mix u_color_mix (
    .clk_vid    (clk_pix),
    .ce_pix     (1'b1),
    .mix        ({2'b00, color_mode}),
    .R_in       (vga_r_raw),
    .G_in       (vga_g_raw),
    .B_in       (vga_b_raw),
    .HSync_in   (vga_hs_raw),
    .VSync_in   (vga_vs_raw),
    .HBlank_in  (~vga_de_raw),
    .VBlank_in  (1'b0),
    .R_out      (vga_r),
    .G_out      (vga_g),
    .B_out      (vga_b),
    .HSync_out  (vga_hs),
    .VSync_out  (vga_vs),
    .HBlank_out (),
    .VBlank_out ()
);
assign vga_de = vga_de_raw;

// Keep the paused frame visible beneath the OSD at 50% opacity, but render
// menu glyphs fully opaque. osd_rgb is aligned with vga_*.
wire [7:0] out_r = osd_on ? (osd_text ? osd_rgb[23:16] :
                             ({1'b0, osd_rgb[23:16]} + {1'b0, vga_r}) >> 1) : vga_r;
wire [7:0] out_g = osd_on ? (osd_text ? osd_rgb[15:8] :
                             ({1'b0, osd_rgb[15:8]} + {1'b0, vga_g}) >> 1) : vga_g;
wire [7:0] out_b = osd_on ? (osd_text ? osd_rgb[7:0] :
                             ({1'b0, osd_rgb[7:0]} + {1'b0, vga_b}) >> 1) : vga_b;

dvi_tx u_dvi (
    .clk_pix    (clk_pix),
    .clk_pix5   (clk_pix5),
    .resetn     (pix_resetn),
    .r          (out_r),
    .g          (out_g),
    .b          (out_b),
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
audio_tone u_audio_tone (
    .clk     (clk_sys),
    .resetn  (sys_resetn),
    .volume  (audio_volume),
    .bass    (audio_bass),
    .treble  (audio_treble),
    .in_l    (aud_l_raw),
    .in_r    (aud_r_raw),
    .out_l   (aud_l),
    .out_r   (aud_r)
);

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
//
//   led[0]  PLLs locked and SDRAM initialised
//   led[1]  a ROM image is loaded and the console is running.  It stays off
//           while the menu is up before a game has been picked and for the
//           whole of any ROM transfer.
// ===========================================================================
assign led[0] = ~(lock_main & lock_hdmi & sdram_init_done);
assign led[1] = ~(image_valid & ~loading & ~core_reset);

endmodule