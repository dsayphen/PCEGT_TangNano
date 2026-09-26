//
// IOSys - PicoRV32 based IO subsystem for the Tang Nano 20K PC Engine port.
//
// Derived from nand2mario's SNESTang `src/iosys/iosys.v`, tag v0.7
// (commit df5acd0104d0a6a2c8c22e8e4857baf61d456aaa), which is distributed
// under the GNU General Public License v3.  The SNES specific parts (ROM
// header parser, BSRAM window, second joypad, core id switching) have been
// removed and the ROM loading interface has been reworked to drive the byte
// oriented SDRAM write port of this project directly, with back pressure.
//
// What it does
// ------------
//   * a PicoRV32 RV32I softcore runs at clk_sys (43.2 MHz) out of SDRAM
//   * at power-on FIRMWARE_SIZE bytes are copied from SPI flash
//     (FIRMWARE_FLASH_ADDR) into the softcore's SDRAM window, then the core
//     is released from reset
//   * the firmware mounts the microSD card with FatFs (SD in SPI mode),
//     draws a menu on the OSD, reads the SNES pad and streams the selected
//     .PCE file into the HuCard ROM area of the SDRAM
//
// Memory map seen by the softcore
// -------------------------------
//   0x0000_0000 .. 0x001A_FFFF   firmware RAM (physically SDRAM 0x400000 + a)
//   0x001B_0000 .. 0x001E_FFFF   CD-ROM² scratch RAM (reserved from firmware)
//   0x001F_0000 .. 0x001F_FFFF   VDC1 VRAM
//   0x0200_0000                  OSD character / overlay control
//   0x0200_0010                  UART clock divider
//   0x0200_0014                  UART data
//   0x0200_0020                  SD SPI: transfer one byte
//   0x0200_0024                  SD SPI: transfer four bytes
//   0x0200_0030                  ROM load control  (1 = start, 0 = finish)
//   0x0200_0034                  ROM load data     (4 bytes, little endian)
//   0x0200_0038                  ROM image size in bytes
//   0x0200_0040                  joypad, read only
//   0x0200_0044                  video zoom mode (0=2x, 1=stretch)
//   0x0200_0048                  scanline strength (0/1/2/3 = 0/25/50/100%)
//   0x0200_0050                  milliseconds since reset, read only
//   0x0200_005C                  color palette (0=raw RGB, 1=composite)
//   0x0200_0060                  core id (bits 15:0), VCE dot clock debug (bits 17:16), VDC0 width debug (bits 24:18), read only
//
// ROM description
// ---------------
// The size register is decoded exactly like the UART loader (rom_loader.v):
//
//   rom_sz     = size >> 16
//   rom_offset = 512 when (size & 0x3FF) == 0x200, else 0
//
// and the image is written to SDRAM from byte 0, copier header included.
// `rom_loading` stays high until the last byte has really reached the memory
// array (ld_idle), so the top level cannot start the console too early.
//

`ifndef PICORV32_REGS
`ifdef PICORV32_V
`error "iosys.v must be read before picorv32.v!"
`endif
`define PICORV32_REGS picosoc_regs
`endif

module iosys #(
    parameter        FREQ                = 43_200_000,
    parameter [23:0] FIRMWARE_FLASH_ADDR = 24'h50_0000,
    parameter        FIRMWARE_SIZE       = 128*1024,
    // base of the softcore's 2 MiB RAM window inside the 8 MiB SDRAM
    parameter [22:0] RV_BASE             = 23'h40_0000,
    parameter [31:0] ROM_MAX_SIZE        = 32'h0040_0000,
    parameter [15:0] CORE_ID             = 16'd3          // 3 = pcetang
) (
    input  wire        clk,               // clk_sys, 43.2 MHz
    input  wire        resetn,

    // ---- OSD, pixel clock domain -----------------------------------------
    input  wire        clk_pix,
    input  wire        pix_resetn,
    input  wire [10:0] osd_x,
    input  wire [9:0]  osd_y,
    input  wire        osd_de,
    output wire        osd_on,
    output wire [23:0] osd_rgb,
    output wire        osd_text,
    output wire        osd_active,        // clk domain copy of the overlay flag

    // ---- controller -------------------------------------------------------
    // SNES bit order: 0:B 1:Y 2:Select 3:Start 4:Up 5:Down 6:Left 7:Right
    //                 8:A 9:X 10:L 11:R
    input  wire [11:0] joy1,

    // ---- HuCard ROM write port (same shape as rom_loader.v) --------------
    output reg         ld_wr,
    output reg  [22:0] ld_addr,
    output reg  [7:0]  ld_data,
    input  wire        ld_busy,
    input  wire        ld_idle,
    output reg         loading,
    output reg         image_valid,
    output reg  [7:0]  rom_sz,
    output reg  [22:0] rom_offset,
    output reg         sgx_mode,
    output reg         cd_mode,
    output reg         rom_pop,

    // ---- video scaler control ---------------------------------------------
    // 0 = 2x integer, 1 = stretch, 2 = bilinear stretch
    output reg  [1:0]  video_zoom,
    // 0/1/2/3 = 0/25/50/100% scanline darkening on the duplicated line
    output reg  [1:0]  scanline,
    output reg         color_mode,

    // ---- audio tone controls, all 0..10, biased by +5 for bass/treble -----
    output reg  [3:0]  audio_volume,
    output reg  [3:0]  audio_bass,
    output reg  [3:0]  audio_treble,

    // Save-RAM service port. The CPU is paused while firmware accesses BRAM.
    input  wire [7:0]  brm_host_q,
    output reg  [10:0] brm_host_addr,
    output reg  [7:0]  brm_host_data,
    output reg         brm_host_we,
    output reg         brm_host_access,

    // ---- CD host bridge --------------------------------------------------
    input  wire [95:0] cd_comm,
    input  wire        cd_comm_send,
    input  wire [79:0] cd_dout,
    input  wire        cd_dout_send,
    input  wire        cd_data_end,
    input  wire        cd_reset,
    input  wire        cd_fifo_halffull,
    output reg  [15:0] cd_stat,
    output reg         cd_stat_strobe,
    output reg         cd_dout_req,
    output reg  [7:0]  cd_data,
    output reg         cd_wr,
    output reg         cd_dm,
    output reg         cd_ack,
    output reg         cd_audio_hold,
    input  wire [7:0]  cd_phase_dbg,
    input  wire [12:0] cdda_usedw_dbg,
    input  wire [7:0]  adpcm_dbg,

    // ---- read-only debug: VCE dot clock select (VIDEO_DCC), see huc6260;
    // piggybacked onto reg_core_id's unused bits 17:16, no new address decode
    input  wire [1:0]  vid_dcc_dbg,
    // ---- read-only debug: VDC0 active display width in 8px chars, see
    // huc6270's HDW register; piggybacked onto reg_core_id bits 24:18
    input  wire [6:0]  vid_hdw_dbg,
    // ---- read-only debug: VDC0 horizontal display start in 8px chars,
    // piggybacked onto reg_core_id bits 31:25
    input  wire [6:0]  vid_hds_dbg,

    // ---- in-game controls -------------------------------------------------
    output reg         game_pause,
    output reg         game_reset,
    output reg         system_reset,
    output reg         pad_mode,

    // ---- 32 bit SDRAM port for the softcore ------------------------------
    output wire        rv_valid,
    input  wire        rv_ready,
    output wire [22:0] rv_addr,
    output wire [31:0] rv_wdata,
    output wire [3:0]  rv_wstrb,
    input  wire [31:0] rv_rdata,
    input  wire        ram_busy,          // high until the SDRAM is initialised

    // ---- SPI flash holding the firmware ----------------------------------
    output wire        flash_spi_cs_n,
    input  wire        flash_spi_miso,
    output wire        flash_spi_mosi,
    output wire        flash_spi_clk,
    output wire        flash_spi_wp_n,
    output wire        flash_spi_hold_n,

    // ---- debug UART -------------------------------------------------------
    input  wire        uart_rx,
    output wire        uart_tx,

    // ---- microSD, SPI mode ------------------------------------------------
    output wire        sd_clk,
    output wire        sd_mosi,           // card CMD
    input  wire        sd_miso,           // card DAT0
    output wire        sd_cs_n            // card DAT3
);

/* verilator lint_off PINMISSING */
/* verilator lint_off WIDTHTRUNC */

// ===========================================================================
// Firmware fetch from SPI flash into the softcore's SDRAM window
// ===========================================================================
localparam FW_AW = 21;      // enough for the 2 MiB window

localparam [1:0] FS_IDLE  = 2'd0;
localparam [1:0] FS_LOAD  = 2'd1;
localparam [1:0] FS_DRAIN = 2'd2;
localparam [1:0] FS_DONE  = 2'd3;

reg [1:0]        flash_st;
reg [FW_AW-1:0]  flash_addr;
reg [FW_AW-1:0]  flash_wr_addr;
reg              flash_start;
reg [7:0]        flash_d;
reg [3:0]        flash_wstrb;
reg              flash_wr;

wire flash_loading = (flash_st == FS_LOAD) || (flash_st == FS_DRAIN);
wire flash_loaded  = (flash_st == FS_DONE);

wire [7:0] flash_dout;
wire       flash_out_strb;

assign flash_spi_hold_n = 1'b1;
assign flash_spi_wp_n   = 1'b0;     // read only access, keep write protect on

spiflash #(
    .ADDR (FIRMWARE_FLASH_ADDR),
    .LEN  (FIRMWARE_SIZE)
) u_flash (
    .clk       (clk),
    .resetn    (resetn),
    .ncs       (flash_spi_cs_n),
    .miso      (flash_spi_miso),
    .mosi      (flash_spi_mosi),
    .sck       (flash_spi_clk),
    .start     (flash_start),
    .dout      (flash_dout),
    .dout_strb (flash_out_strb),
    .busy      ()
);

// One SPI byte takes 32 clocks and an SDRAM write about 7, so a write can
// never be overrun.  flash_wr is nevertheless held until rv_ready so that the
// handshake stays correct while the memory is busy with a refresh, and the
// last byte is drained before the softcore is released from reset.
always @(posedge clk) begin
    if (!resetn) begin
        flash_st    <= FS_IDLE;
        flash_addr  <= {FW_AW{1'b0}};
        flash_wr_addr <= {FW_AW{1'b0}};
        flash_start <= 1'b0;
        flash_wr    <= 1'b0;
        flash_wstrb <= 4'b0000;
    end else begin
        flash_start <= 1'b0;

        case (flash_st)
            FS_IDLE: if (!ram_busy) begin
                flash_start <= 1'b1;
                flash_addr  <= {FW_AW{1'b0}};
                flash_st    <= FS_LOAD;
            end

            FS_LOAD: begin
                if (flash_wr && rv_ready)
                    flash_wr <= 1'b0;
                if (flash_out_strb) begin
                    flash_d       <= flash_dout;
                    flash_wr_addr <= flash_addr;
                    flash_wr      <= 1'b1;
                    case (flash_addr[1:0])
                        2'd0: flash_wstrb <= 4'b0001;
                        2'd1: flash_wstrb <= 4'b0010;
                        2'd2: flash_wstrb <= 4'b0100;
                        2'd3: flash_wstrb <= 4'b1000;
                    endcase
                    if (flash_addr == FIRMWARE_SIZE-1)
                        flash_st <= FS_DRAIN;
                    else
                        flash_addr <= flash_addr + 1'b1;
                end
            end

            FS_DRAIN: begin
                if (flash_wr && rv_ready)
                    flash_wr <= 1'b0;
                else if (!flash_wr)
                    flash_st <= FS_DONE;
            end

            default: ;      // FS_DONE
        endcase
    end
end

// ===========================================================================
// PicoRV32
// ===========================================================================
wire        mem_valid;
wire        mem_ready;
wire [31:0] mem_addr;
wire [31:0] mem_wdata;
wire [3:0]  mem_wstrb;
wire [31:0] mem_rdata;

wire ram_sel = mem_valid && (mem_addr[31:21] == 11'd0);

wire textdisp_sel  = mem_valid && (mem_addr == 32'h0200_0000);
wire uart_div_sel  = mem_valid && (mem_addr == 32'h0200_0010);
wire uart_dat_sel  = mem_valid && (mem_addr == 32'h0200_0014);
wire spi_byte_sel  = mem_valid && (mem_addr == 32'h0200_0020);
wire spi_word_sel  = mem_valid && (mem_addr == 32'h0200_0024);
wire rl_ctrl_sel   = mem_valid && (mem_addr == 32'h0200_0030);
wire rl_data_sel   = mem_valid && (mem_addr == 32'h0200_0034);
wire rl_size_sel   = mem_valid && (mem_addr == 32'h0200_0038);
wire joy_sel       = mem_valid && (mem_addr == 32'h0200_0040);
wire zoom_sel      = mem_valid && (mem_addr == 32'h0200_0044);
wire scan_sel      = mem_valid && (mem_addr == 32'h0200_0048);
wire game_ctrl_sel = mem_valid && (mem_addr == 32'h0200_004c);
wire time_sel      = mem_valid && (mem_addr == 32'h0200_0050);
wire pad_mode_sel  = mem_valid && (mem_addr == 32'h0200_0058);
wire color_mode_sel= mem_valid && (mem_addr == 32'h0200_005c);
wire id_sel        = mem_valid && (mem_addr == 32'h0200_0060);
wire audio_sel     = mem_valid && (mem_addr == 32'h0200_0064);
wire cd_event_sel  = mem_valid && (mem_addr == 32'h0200_0070);
wire cd_stat_sel   = mem_valid && (mem_addr == 32'h0200_0074);
wire cd_cmd0_sel   = mem_valid && (mem_addr == 32'h0200_0078);
wire cd_cmd1_sel   = mem_valid && (mem_addr == 32'h0200_007c);
wire cd_cmd2_sel   = mem_valid && (mem_addr == 32'h0200_0080);
wire cd_data0_sel  = mem_valid && (mem_addr == 32'h0200_0084);
wire cd_data1_sel  = mem_valid && (mem_addr == 32'h0200_0088);
wire cd_data2_sel  = mem_valid && (mem_addr == 32'h0200_008c);
wire cd_feed_sel   = mem_valid && (mem_addr == 32'h0200_0090);
wire cd_ack_sel    = mem_valid && (mem_addr == 32'h0200_0094);
wire cd_phase_sel  = mem_valid && (mem_addr == 32'h0200_0098);
wire cd_usedw_sel  = mem_valid && (mem_addr == 32'h0200_009c);
wire cd_adpcm_sel  = mem_valid && (mem_addr == 32'h0200_00a0);
wire rom_pop_sel   = mem_valid && (mem_addr == 32'h0200_00a4);
wire brm_addr_sel  = mem_valid && (mem_addr == 32'h0200_00a8);
wire brm_data_sel  = mem_valid && (mem_addr == 32'h0200_00ac);
wire brm_access_sel= mem_valid && (mem_addr == 32'h0200_00b0);
wire cd_hold_sel   = mem_valid && (mem_addr == 32'h0200_00b4);

wire [31:0] uart_div_do;
wire [31:0] uart_dat_do;
wire        uart_dat_wait;
wire [31:0] spi_do;
wire        spi_wait;

reg  [31:0] time_reg;
reg  [7:0]  cd_events;
reg  [95:0] cd_comm_reg;
reg  [79:0] cd_dout_reg;

// ROM streaming state, declared here because mem_ready depends on it
reg  [31:0] rl_buf;
reg  [2:0]  rl_cnt;         // bytes still to be pushed out of rl_buf
reg  [22:0] rl_addr;
reg  [31:0] rl_size;
reg         rl_finishing;
reg  [19:0] rl_timeout;

// Cleared automatically at the start of every load (see below) so that a
// smaller/different ROM never inherits stray bytes left over in the HuCard
// area by the previous image, and so that the VDC0 VRAM never starts a new
// game holding the previous game's tiles, BAT and sprite attribute table.
reg         rl_clearing;
reg  [22:0] rl_clear_addr;
reg         rl_clear_phase;
reg         rl_reboot_pending;

// Physical byte window VDC0 VRAM occupies inside the 8 MiB SDRAM (bank 3),
// derived from the RAS/CAS mapping in rtl/tang/pce_sdram_ctrl_3ch.v:
//   VDC0 -> bank 3, {2'b11, 5'b11111, vram_addr[14:1],  2'b00} = 0x7f0000
// 32K words of 16 bits = 64 KiB.
// Note: We do NOT clear VDC1 (0x5f0000) here because the existing firmware
// in SPI flash places its stack top at 0x200000 (0x5fffff), which would be
// clobbered while the softcore is running FatFs.
localparam [22:0] VRAM0_CLEAR_BASE = 23'h7f_0000;
localparam [22:0] VRAM_CLEAR_SPAN  = 23'h01_0000;

// the ROM data register stalls the softcore while the previous word is being
// pushed into the SDRAM, and while the HuCard area is being cleared at the
// start of a new load
wire rl_data_ready = (rl_cnt == 3'd0) && !rl_clearing;

assign mem_ready = (ram_sel && rv_ready) || textdisp_sel || uart_div_sel ||
                   rl_ctrl_sel || rl_size_sel || joy_sel || zoom_sel || scan_sel ||
                   game_ctrl_sel ||
                   time_sel || pad_mode_sel || color_mode_sel || id_sel || audio_sel ||
                   cd_event_sel || cd_stat_sel || cd_cmd0_sel || cd_cmd1_sel || cd_cmd2_sel ||
                   cd_data0_sel || cd_data1_sel || cd_data2_sel || cd_feed_sel || cd_ack_sel ||
                   cd_phase_sel ||
                   cd_usedw_sel ||
                   cd_adpcm_sel ||
                   rom_pop_sel || brm_addr_sel || brm_data_sel || brm_access_sel ||
                   cd_hold_sel ||
                   (rl_data_sel && rl_data_ready) ||
                   (uart_dat_sel && !uart_dat_wait) ||
                   ((spi_byte_sel || spi_word_sel) && !spi_wait);

assign mem_rdata = ram_sel      ? rv_rdata :
                   joy_sel      ? {20'b0, joy1} :
                   zoom_sel     ? {30'b0, video_zoom} :
                   scan_sel     ? {30'b0, scanline} :
                   uart_div_sel ? uart_div_do :
                   uart_dat_sel ? uart_dat_do :
                   time_sel     ? time_reg :
                   pad_mode_sel ? {31'd0, pad_mode} :
                   color_mode_sel ? {31'd0, color_mode} :
                   id_sel       ? {vid_hds_dbg, vid_hdw_dbg, vid_dcc_dbg, CORE_ID} :
                   audio_sel    ? {20'b0, audio_treble, audio_bass, audio_volume} :
                   cd_event_sel ? {24'b0, cd_events} :
                   cd_cmd0_sel ? cd_comm_reg[31:0] :
                   cd_cmd1_sel ? cd_comm_reg[63:32] :
                   cd_cmd2_sel ? cd_comm_reg[95:64] :
                   cd_data0_sel ? cd_dout_reg[31:0] :
                   cd_data1_sel ? cd_dout_reg[63:32] :
                   cd_data2_sel ? {16'b0, cd_dout_reg[79:64]} :
                   cd_phase_sel ? {24'b0, cd_phase_dbg} :
                   cd_usedw_sel ? {19'b0, cdda_usedw_dbg} :
                   cd_adpcm_sel ? {24'b0, adpcm_dbg} :
                   rom_pop_sel  ? {31'b0, rom_pop} :
                   brm_data_sel ? {24'b0, brm_host_q} :
                   (spi_byte_sel || spi_word_sel) ? spi_do :
                   32'h0000_0000;

picorv32 #(
    .ENABLE_COUNTERS   (0),
    .ENABLE_COUNTERS64 (0),
    .CATCH_MISALIGN    (0),
    .CATCH_ILLINSN     (0),
    .TWO_STAGE_SHIFT   (0),
    .BARREL_SHIFTER    (0),
    .COMPRESSED_ISA    (0),
    .ENABLE_MUL        (0),
    .ENABLE_DIV        (0)
) u_rv32 (
    .clk       (clk),
    .resetn    (resetn & flash_loaded),
    .mem_valid (mem_valid),
    .mem_ready (mem_ready),
    .mem_addr  (mem_addr),
    .mem_wdata (mem_wdata),
    .mem_wstrb (mem_wstrb),
    .mem_rdata (mem_rdata)
);

// ===========================================================================
// Peripherals
// ===========================================================================
textdisp u_disp (
    .clk         (clk),
    .resetn      (resetn),
    .reg_char_we (textdisp_sel ? mem_wstrb : 4'b0000),
    .reg_char_di (mem_wdata),
    .overlay     (osd_active),

    .clk_pix     (clk_pix),
    .pix_resetn  (pix_resetn),
    .osd_x       (osd_x),
    .osd_y       (osd_y),
    .osd_de      (osd_de),
    .osd_on      (osd_on),
    .osd_rgb     (osd_rgb),
    .osd_text    (osd_text)
);

simpleuart u_uart (
    .clk          (clk),
    .resetn       (resetn),
    .ser_tx       (uart_tx),
    .ser_rx       (uart_rx),
    .reg_div_we   (uart_div_sel ? mem_wstrb : 4'b0000),
    .reg_div_di   (mem_wdata),
    .reg_div_do   (uart_div_do),
    .reg_dat_we   (uart_dat_sel ? mem_wstrb[0] : 1'b0),
    .reg_dat_re   (uart_dat_sel && !mem_wstrb),
    .reg_dat_di   (mem_wdata),
    .reg_dat_do   (uart_dat_do),
    .reg_dat_wait (uart_dat_wait)
);

simplespimaster u_spi (
    .clk         (clk),
    .resetn      (resetn),
    .sck         (sd_clk),
    .mosi        (sd_mosi),
    .miso        (sd_miso),
    .reg_byte_we (spi_byte_sel ? mem_wstrb[0] : 1'b0),
    .reg_word_we (spi_word_sel ? mem_wstrb[0] : 1'b0),
    .reg_di      (mem_wdata),
    .reg_do      (spi_do),
    .reg_wait    (spi_wait)
);

// the card is kept selected for the whole session, like SNESTang does
assign sd_cs_n = 1'b0;

// ===========================================================================
// ROM streaming into the HuCard area of the SDRAM
// ===========================================================================
wire rl_size_ok = (rl_size != 32'd0) && (rl_size <= ROM_MAX_SIZE);

always @(posedge clk) begin
    ld_wr <= 1'b0;
    game_reset <= 1'b0;
    cd_stat_strobe <= 1'b0;
    cd_dout_req <= 1'b0;
    cd_wr <= 1'b0;
    cd_ack <= 1'b0;
    brm_host_we <= 1'b0;

    if (cd_comm_send) begin
        cd_events[0] <= 1'b1;
        cd_comm_reg <= cd_comm;
    end
    if (cd_dout_send) begin
        cd_events[1] <= 1'b1;
        cd_dout_reg <= cd_dout;
    end
    if (cd_data_end)
        cd_events[2] <= 1'b1;
    if (cd_reset)
        cd_events[4] <= 1'b1;
    cd_events[5] <= cd_fifo_halffull;

    if (cd_stat_sel && (mem_wstrb != 4'b0)) begin
        cd_stat <= mem_wdata[15:0];
        cd_stat_strobe <= 1'b1;
    end
    if (cd_feed_sel && (mem_wstrb != 4'b0)) begin
        cd_data <= mem_wdata[7:0];
        cd_dm <= mem_wdata[8];
        cd_wr <= 1'b1;
    end
    if (cd_ack_sel && (mem_wstrb != 4'b0)) begin
        cd_events <= cd_events & ~mem_wdata[7:0];
        cd_ack <= 1'b1;
    end

    // ---- clear the HuCard area and VDC0 VRAM before a new load ----------
    // Runs before any real data is accepted (rl_data_ready is held low, see
    // above), so the softcore's pce_load_word() calls simply stall on
    // mem_ready until this finishes.  Without this, a ROM smaller than (or
    // differently shaped from) the previous one would leave the old game's
    // bytes readable past its own end, which HuCard mirroring can expose as
    // corruption specific to "reload a different/smaller game" scenarios.
    //
    // The VDC0 VRAM window matters for the same reason: nothing else ever zeroes
    // it, so on a reload the newly started game inherits the previous
    // game's tiles, BAT and SATB. A game only uploads the VRAM it actually
    // uses, so whatever it leaves untouched still reads back as the previous
    // game's data - which shows up as shifted tiles and mispositioned
    // sprites that a first (cold) load never exhibits.
    if (rl_clearing) begin
        if (!ld_busy && !ld_wr) begin
            ld_wr         <= 1'b1;
            ld_addr       <= rl_clear_addr;
            ld_data       <= 8'h00;
            rl_clear_addr <= rl_clear_addr + 23'd1;
            if (!rl_clear_phase) begin
                if (rl_clear_addr == ROM_MAX_SIZE[22:0] - 23'd1) begin
                    rl_clear_phase <= 1'b1;
                    rl_clear_addr  <= VRAM0_CLEAR_BASE;
                end
            end else begin
                if (rl_clear_addr ==
                    VRAM0_CLEAR_BASE + VRAM_CLEAR_SPAN - 23'd1)
                    rl_clearing <= 1'b0;
            end
        end
    end else begin

    // ---- accept a word from the softcore ---------------------------------
    if (rl_data_sel && (mem_wstrb != 4'b0) && rl_data_ready) begin
        rl_buf <= mem_wdata;
        rl_cnt <= 3'd4;
    end

    // ---- push one byte at a time into the SDRAM --------------------------
    // Addresses beyond the HuCard area are swallowed so that an oversized
    // file can never reach the softcore's own RAM window.
    else if (rl_cnt != 3'd0 && !ld_busy && !ld_wr) begin
        ld_wr   <= (rl_addr < ROM_MAX_SIZE[22:0]);
        ld_addr <= rl_addr;
        ld_data <= rl_buf[7:0];
        rl_buf  <= {8'h00, rl_buf[31:8]};
        rl_cnt  <= rl_cnt - 3'd1;
        rl_addr <= rl_addr + 23'd1;
    end

    end

    // ---- control register -------------------------------------------------
    if (rl_ctrl_sel && (mem_wstrb != 4'b0)) begin
        if (mem_wdata[0]) begin
            loading       <= 1'b1;
            image_valid   <= 1'b0;
            cd_mode       <= 1'b0;
            sgx_mode      <= mem_wdata[1];
            rl_addr       <= 23'd0;
            rl_cnt        <= 3'd0;
            rl_finishing  <= 1'b0;
            rl_timeout    <= 20'd0;
            rl_clearing   <= 1'b1;
            rl_clear_addr <= 23'd0;
            rl_clear_phase<= 1'b0;
        end else if (mem_wdata[7:0] == 8'd0) begin
            rl_finishing <= 1'b1;
            rl_timeout   <= 20'd0;
        end
    end

    if (rl_size_sel && (mem_wstrb != 4'b0))
        rl_size <= mem_wdata;

    if (zoom_sel && (mem_wstrb != 4'b0))
        video_zoom <= mem_wdata[1:0];

    if (scan_sel && (mem_wstrb != 4'b0))
        scanline <= mem_wdata[1:0];

    if (game_ctrl_sel && (mem_wstrb != 4'b0)) begin
        game_pause <= mem_wdata[0];
        game_reset <= mem_wdata[1];
        if (mem_wdata[3]) begin
            // Return to browser: purge the previous ROM and VDC0 VRAM before
            // rebooting, so no old SDRAM transaction survives the reset.
            game_pause       <= 1'b0;
            loading          <= 1'b1;
            image_valid      <= 1'b0;
            rl_cnt           <= 3'd0;
            rl_finishing     <= 1'b0;
            rl_clearing      <= 1'b1;
            rl_clear_addr    <= 23'd0;
            rl_clear_phase   <= 1'b0;
            rl_reboot_pending <= 1'b1;
            cd_mode           <= 1'b0;
        end
        if (mem_wdata[4]) begin
            loading      <= 1'b0;
            cd_mode      <= 1'b1;
        end
    end

    if (pad_mode_sel && (mem_wstrb != 4'b0))
        pad_mode <= mem_wdata[0];

    if (color_mode_sel && (mem_wstrb != 4'b0))
        color_mode <= mem_wdata[0];

    if (rom_pop_sel && (mem_wstrb != 4'b0))
        rom_pop <= mem_wdata[0];

    if (brm_addr_sel && (mem_wstrb != 4'b0))
        brm_host_addr <= mem_wdata[10:0];

    if (brm_data_sel && (mem_wstrb != 4'b0)) begin
        brm_host_data <= mem_wdata[7:0];
        brm_host_we <= 1'b1;
    end

    if (brm_access_sel && (mem_wstrb != 4'b0))
        brm_host_access <= mem_wdata[0];

    if (cd_hold_sel && (mem_wstrb != 4'b0))
        cd_audio_hold <= mem_wdata[0];

    if (audio_sel && (mem_wstrb != 4'b0)) begin
        audio_volume <= mem_wdata[3:0];
        audio_bass   <= mem_wdata[7:4];
        audio_treble <= mem_wdata[11:8];
    end

    // ---- end of transfer: wait for the SDRAM to really drain -------------
    if (rl_finishing) begin
        rl_timeout <= rl_timeout + 20'd1;
        if ((rl_cnt == 3'd0 && !rl_clearing && !ld_wr && ld_idle) || (&rl_timeout)) begin
            rl_finishing <= 1'b0;
            loading      <= 1'b0;
            rom_sz       <= rl_size[23:16];
            rom_offset   <= (rl_size[9:0] == 10'h200) ? 23'd512 : 23'd0;
            image_valid  <= rl_size_ok;
        end
    end

    // The final clear write is still pending when rl_clearing drops. Wait
    // until the SDRAM controller has drained it before resetting the system.
    if (rl_reboot_pending && !rl_clearing && !ld_wr && ld_idle)
        system_reset <= 1'b1;

    if (!resetn) begin
        ld_wr        <= 1'b0;
        ld_addr      <= 23'd0;
        ld_data      <= 8'd0;
        loading      <= 1'b0;
        image_valid  <= 1'b0;
        rom_sz       <= 8'd0;
        rom_offset   <= 23'd0;
        sgx_mode     <= 1'b0;
        cd_mode      <= 1'b0;
        rom_pop      <= 1'b0;
        video_zoom   <= 2'd1;      // stretch, matches the previous fixed behaviour
        scanline     <= 2'd0;      // off, matches the previous fixed behaviour
        game_pause   <= 1'b0;
        game_reset   <= 1'b0;
        system_reset <= 1'b0;
        pad_mode     <= 1'b0;
        color_mode   <= 1'b0;
        audio_volume <= 4'd10;     // unity gain
        audio_bass   <= 4'd5;      // flat (offset by +5)
        audio_treble <= 4'd5;      // flat (offset by +5)
        brm_host_addr <= 11'd0;
        brm_host_data <= 8'd0;
        brm_host_we   <= 1'b0;
        brm_host_access <= 1'b0;
        cd_stat      <= 16'd0;
        cd_stat_strobe <= 1'b0;
        cd_dout_req  <= 1'b0;
        cd_data      <= 8'd0;
        cd_wr        <= 1'b0;
        cd_dm        <= 1'b0;
        cd_audio_hold <= 1'b0;
        cd_ack       <= 1'b0;
        cd_events    <= 8'd0;
        cd_comm_reg  <= 96'd0;
        cd_dout_reg  <= 80'd0;
        rl_buf       <= 32'd0;
        rl_cnt       <= 3'd0;
        rl_addr      <= 23'd0;
        rl_size      <= 32'd0;
        rl_finishing <= 1'b0;
        rl_timeout   <= 20'd0;
        rl_clearing  <= 1'b0;
        rl_clear_addr<= 23'd0;
        rl_clear_phase <= 1'b0;
        rl_reboot_pending <= 1'b0;
    end
end

// ===========================================================================
// SDRAM port multiplexing: flash loader first, then the softcore
// ===========================================================================
assign rv_valid = flash_loading ? flash_wr : (mem_valid & ram_sel);
assign rv_addr  = flash_loading ? (RV_BASE | {2'b00, flash_wr_addr})
                                : (RV_BASE | {2'b00, mem_addr[20:0]});
assign rv_wdata = flash_loading ? {flash_d, flash_d, flash_d, flash_d} : mem_wdata;
assign rv_wstrb = flash_loading ? flash_wstrb : mem_wstrb;

// ===========================================================================
// Millisecond counter
// ===========================================================================
localparam MS_DIV = FREQ/1000;
reg [$clog2(MS_DIV)-1:0] time_cnt;

always @(posedge clk) begin
    if (!resetn) begin
        time_reg <= 32'd0;
        time_cnt <= 0;
    end else begin
        time_cnt <= time_cnt + 1'b1;
        if (time_cnt == MS_DIV-1) begin
            time_cnt <= 0;
            time_reg <= time_reg + 32'd1;
        end
    end
end

endmodule


// ---------------------------------------------------------------------------
// PicoRV32 register file.  Two asynchronous read ports, one write port, which
// GowinSynthesis maps onto LUT based distributed RAM.
// ---------------------------------------------------------------------------
module picosoc_regs (
    input  wire        clk,
    input  wire        wen,
    input  wire [5:0]  waddr,
    input  wire [5:0]  raddr1,
    input  wire [5:0]  raddr2,
    input  wire [31:0] wdata,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);

(* syn_ramstyle = "distributed_ram" *)
reg [31:0] regs [0:31];

always @(posedge clk)
    if (wen) regs[waddr[4:0]] <= wdata;

assign rdata1 = regs[raddr1[4:0]];
assign rdata2 = regs[raddr2[4:0]];

endmodule
