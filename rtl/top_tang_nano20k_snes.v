// SNES profile for the Tang Nano 20K, using the shared PCE PicoRV32 IOSys.
// The SNESTang core sources and license are kept under rtl/snestang/src.

module top_tang_nano20k_snes #(
    parameter SNES_SDRAM_PHASE = "1010",
    parameter SNES_MEMORY_DIAGNOSTIC = 0,
    parameter SNES_UPSTREAM_RAM_LAYOUT = 1,
    parameter SNES_VIDEO_RAM_LAYOUT = 0,
    parameter SNES_WRAM_WAIT = 0
) (
    input  wire       sys_clk,
    input  wire       s1,
    input  wire       s2,
    inout  wire       fpga_reconfig_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [1:0] led,
    output wire       sd_clk,
    output wire       sd_cmd,
    input  wire       sd_dat0,
    output wire       sd_dat1,
    output wire       sd_dat2,
    output wire       sd_dat3,
    output wire       flash_spi_cs_n,
    input  wire       flash_spi_miso,
    output wire       flash_spi_mosi,
    output wire       flash_spi_clk,
    output wire       flash_spi_wp_n,
    output wire       flash_spi_hold_n,
    output wire       O_sdram_clk,
    output wire       O_sdram_cke,
    output wire       O_sdram_cs_n,
    output wire       O_sdram_cas_n,
    output wire       O_sdram_ras_n,
    output wire       O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    output wire [3:0] O_sdram_dqm,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,
    output wire       pa_en,
    output wire       hp_bck,
    output wire       hp_ws,
    output wire       hp_din,
    output wire       pad_clk,
    output wire       pad_latch,
    input  wire       pad_data
);

localparam integer MCLK_HZ = 21_600_000;
localparam [15:0] CORE_ID_SNES = 16'd4;

wire mclk;
wire fclk;
wire fclk_p;
wire hclk5;
wire hclk;
wire hdmi_locked;

gowin_pll_snes #(.SDRAM_PHASE(SNES_SDRAM_PHASE)) u_pll_snes (
    .clkin  (sys_clk),
    .clkout (fclk),
    .clkoutp(fclk_p),
    .clkoutd(mclk)
);

gowin_pll_hdmi u_pll_hdmi (
    .clkin (sys_clk),
    .clkout(hclk5),
    .lock  (hdmi_locked)
);

CLKDIV #(.DIV_MODE(5)) u_div5 (
    .HCLKIN(hclk5),
    .CLKOUT(hclk),
    .RESETN(hdmi_locked),
    .CALIB (1'b0)
);

reg [15:0] reset_count = 16'hffff;
reg        sys_resetn = 1'b0;
wire       system_reset;

always @(posedge mclk) begin
    if (!hdmi_locked || system_reset) begin
        reset_count <= 16'hffff;
        sys_resetn <= 1'b0;
    end else if (reset_count != 0) begin
        reset_count <= reset_count - 16'd1;
    end else begin
        sys_resetn <= 1'b1;
    end
end

reg [2:0] pix_reset_sync = 3'b000;
always @(posedge hclk)
    pix_reset_sync <= {pix_reset_sync[1:0], sys_resetn & hdmi_locked};
wire pix_resetn = pix_reset_sync[2];

reg [2:0] s1_sync = 3'b000;
reg [2:0] s2_sync = 3'b000;
always @(posedge mclk) begin
    s1_sync <= {s1_sync[1:0], s1};
    s2_sync <= {s2_sync[1:0], s2};
end
wire button_reset = s1_sync[2];
wire button_select = s2_sync[2];

wire reconfig_pull_low;
wire reconfig_pin_high;
IOBUF u_reconfig_iobuf (
    .I   (1'b0),
    .OEN (~reconfig_pull_low),
    .O   (reconfig_pin_high),
    .IO  (fpga_reconfig_n)
);

wire [10:0] osd_x;
wire [9:0]  osd_y;
wire        osd_de;
wire        osd_on;
wire [23:0] osd_rgb;
wire        osd_text;
wire        osd_active;
wire [11:0] pad_buttons;
wire [11:0] menu_buttons = pad_buttons |
                           {3'b000, button_select, 8'b0000_0000};
wire [11:0] game_buttons = osd_active ? 12'd0 : pad_buttons;

snes_gamepad u_pad (
    .clk      (mclk),
    .resetn   (sys_resetn),
    .pad_latch(pad_latch),
    .pad_clk  (pad_clk),
    .pad_data (pad_data),
    .buttons  (pad_buttons)
);

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
wire        cd_mode;
wire        rom_pop;
wire [1:0]  video_zoom;
wire [1:0]  scanline;
wire        game_pause;
wire        game_reset;
wire        pad_mode;
wire        pad_mode_sf2;
wire        cheat_apply;
wire        cheat_reset;
wire [128:0] cheat_code;
wire        color_mode;
wire [3:0]  audio_volume;
wire [3:0]  audio_bass;
wire [3:0]  audio_treble;
wire        audio_hdmi;
wire        audio_cdda_enable;
wire        audio_adpcm_enable;
wire        vdc_sprites_double;

wire        rv_valid;
wire        rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0]  rv_wstrb;
wire [31:0] rv_rdata;
wire [7:0]  brm_host_q;
wire [10:0] brm_host_addr;
wire [7:0]  brm_host_data;
wire        brm_host_we;
wire        brm_host_access;
wire        sdram_busy;
wire [1:0] vram1_diag_errors, vram2_diag_errors;
wire [7:0] vram1_diag_writes, vram2_diag_writes;
wire vram1_diag_not_ready;
wire [15:0] vram1_diag_first;
wire [15:0] diag_frame_samples, diag_frame_late;
wire vram_diag_reset = loading || game_reset || !image_valid;
assign brm_host_q = 8'd0;

iosys #(
    .FREQ                (MCLK_HZ),
    .FIRMWARE_FLASH_ADDR (24'h50_0000),
    .FIRMWARE_SIZE       (128*1024),
    .RV_BASE             (23'h40_0000),
    .ROM_MAX_SIZE        (SNES_UPSTREAM_RAM_LAYOUT ? 32'h003c_0040 : 32'h0040_0040),
    .OSD_CHARACTER_BITS  (7),
    .ROM_CLEAR_ENABLE    (0),
    .CORE_ID             (CORE_ID_SNES),
    .RECONFIG_ENABLE     (1),
    .RECONFIG_PIN        (8'd29),
    // No serial debug in the SNES build: the FPGA is full with the frozen pause frame.
    .UART_ENABLE         (0)
) u_iosys (
    .clk                 (mclk),
    .resetn              (sys_resetn),
    .reconfig_pull_low   (reconfig_pull_low),
    .reconfig_pin_high   (reconfig_pin_high),
    .clk_pix             (hclk),
    .pix_resetn          (pix_resetn),
    .osd_x               (osd_x),
    .osd_y               (osd_y),
    .osd_de              (osd_de),
    .osd_on              (osd_on),
    .osd_rgb             (osd_rgb),
    .osd_text            (osd_text),
    .osd_active          (osd_active),
    .joy1                (menu_buttons),
    .ld_wr               (ld_wr),
    .ld_addr             (ld_addr),
    .ld_data             (ld_data),
    .ld_busy             (ld_busy),
    .ld_idle              (ld_idle),
    .loading             (loading),
    .image_valid         (image_valid),
    .rom_sz              (rom_sz),
    .rom_offset          (rom_offset),
    .sgx_mode            (sgx_mode),
    .cd_mode             (cd_mode),
    .rom_pop             (rom_pop),
    .video_zoom          (video_zoom),
    .scanline            (scanline),
    .game_pause          (game_pause),
    .game_reset          (game_reset),
    .system_reset        (system_reset),
    .pad_mode            (pad_mode),
    .pad_mode_sf2        (pad_mode_sf2),
    .cheat_apply         (cheat_apply),
    .cheat_reset         (cheat_reset),
    .cheat_code          (cheat_code),
    .color_mode          (color_mode),
    .audio_volume        (audio_volume),
    .audio_bass          (audio_bass),
    .audio_treble        (audio_treble),
    .audio_hdmi           (audio_hdmi),
    .audio_cdda_enable   (audio_cdda_enable),
    .audio_adpcm_enable  (audio_adpcm_enable),
    .vdc_sprites_double  (vdc_sprites_double),
    .brm_host_q          (brm_host_q),
    .brm_host_addr       (brm_host_addr),
    .brm_host_data       (brm_host_data),
    .brm_host_we         (brm_host_we),
    .brm_host_access     (brm_host_access),
    .rv_valid            (rv_valid),
    .rv_ready            (rv_ready),
    .rv_addr             (rv_addr),
    .rv_wdata            (rv_wdata),
    .rv_wstrb            (rv_wstrb),
    .rv_rdata            (rv_rdata),
    .ram_busy            (sdram_busy),
    .rv_capture_dbg      (64'd0),
    .rv_bus_dbg          (128'd0),
    .rv_scheduler_dbg    (16'd0),
    .loader_host_dbg     (16'd0),
    .loader_uart_owner   (1'b0),
    .cd_comm             (96'd0),
    .cd_comm_send        (1'b0),
    .cd_dout             (80'd0),
    .cd_dout_send        (1'b0),
    .cd_data_end         (1'b0),
    .cd_reset             (1'b0),
    .cd_fifo_halffull    (1'b0),
    .cd_phase_dbg        (SNES_MEMORY_DIAGNOSTIC ? diag_frame_samples[15:8] : 8'd0),
    .cdda_usedw_dbg      (SNES_MEMORY_DIAGNOSTIC ? diag_frame_late[15:2] : 14'd0),
    .adpcm_dbg           (SNES_MEMORY_DIAGNOSTIC ? 8'hd6 : 8'd0),
    .refresh_gap_dbg     (SNES_MEMORY_DIAGNOSTIC ? {4'd0, vram2_diag_errors, vram1_diag_errors} : 8'd0),
    .vid_dcc_dbg         (SNES_MEMORY_DIAGNOSTIC ? vram1_diag_first[15:14] : 2'd0),
    .vid_hdw_dbg         (SNES_MEMORY_DIAGNOSTIC ? vram1_diag_first[13:7] : 7'd0),
    .vid_hds_dbg         (SNES_MEMORY_DIAGNOSTIC ? vram1_diag_first[6:0] : 7'd0),
    .vid_hsw_dbg         (5'd0),
    .vid_hde_dbg         (7'd0),
    .vid_vsw_dbg         (5'd0),
    .vid_vds_dbg         (8'd0),
    .vid_vdw_dbg         (9'd0),
    .vid_vcr_dbg         (8'd0),
    .vid_vce_cr_dbg      (8'd0),
    .vid_vce_wr_dbg      (16'd0),
    .vid_px_dbg          (10'd0),
    .flash_spi_cs_n      (flash_spi_cs_n),
    .flash_spi_miso      (flash_spi_miso),
    .flash_spi_mosi      (flash_spi_mosi),
    .flash_spi_clk       (flash_spi_clk),
    .flash_spi_wp_n      (flash_spi_wp_n),
    .flash_spi_hold_n    (flash_spi_hold_n),
    .uart_rx             (uart_rx),
    .uart_tx             (uart_tx),
    .sd_clk              (sd_clk),
    .sd_mosi             (sd_cmd),
    .sd_miso             (sd_dat0),
    .sd_cs_n             (sd_dat3)
);

assign sd_dat1 = 1'b1;
assign sd_dat2 = 1'b1;

wire [7:0] loader_do = ld_data;
wire       loader_do_valid = ld_wr;
wire [7:0] rom_type;
wire [3:0] rom_size;
wire [3:0] ram_size;
wire [23:0] rom_mask;
wire [23:0] ram_mask;
wire       header_finished;
reg [7:0]  loader_do_r;
reg [22:0] loader_addr = 23'd0;
reg        loading_r = 1'b0;
reg        loaded = 1'b0;

smc_parser u_smc_parser (
    .clk             (mclk),
    .resetn          (sys_resetn & ~(loading & ~loading_r)),
    .rom_d           (loader_do),
    .rom_strb        (loader_do_valid),
    .rom_type        (rom_type),
    .rom_mask        (rom_mask),
    .ram_mask        (ram_mask),
    .rom_size        (rom_size),
    .ram_size        (ram_size),
    .header_finished (header_finished)
);

always @(posedge mclk) begin
    if (!sys_resetn) begin
        loading_r <= 1'b0;
        loaded <= 1'b0;
        loader_addr <= 23'd0;
        loader_do_r <= 8'd0;
    end else begin
        loading_r <= loading;
        if (loading && !loading_r) begin
            loader_addr <= 23'd0;
            loaded <= 1'b0;
        end
        if (loader_do_valid && header_finished) begin
            loader_addr <= loader_addr + 23'd1;
            loader_do_r <= loader_do;
        end
        if (!loading && loading_r)
            loaded <= 1'b1;
    end
end

wire [23:0] ROM_ADDR;
wire [15:0] ROM_D;
wire [15:0] ROM_Q;
wire        ROM_CE_N;
wire        ROM_OE_N;
wire        ROM_WE_N;
wire        ROM_WORD;
wire [19:0] BSRAM_ADDR;
wire [7:0]  BSRAM_D;
wire [7:0]  BSRAM_Q;
wire        BSRAM_CE_N;
wire        BSRAM_OE_N;
wire        BSRAM_WE_N;
wire        BSRAM_RD_N;
wire [16:0] WRAM_ADDR;
wire [7:0]  WRAM_D;
wire [7:0]  WRAM_Q;
wire        WRAM_CE_N;
wire        WRAM_OE_N;
wire        WRAM_WE_N;
wire        WRAM_RD_N;
wire [15:0] VRAM1_ADDR;
wire [7:0]  VRAM1_DI;
wire [7:0]  VRAM1_DO;
wire        VRAM1_WE_N;
wire [15:0] VRAM2_ADDR;
wire [7:0]  VRAM2_DI;
wire [7:0]  VRAM2_DO;
wire        VRAM2_WE_N;
wire        VRAM_OE_N;
wire [15:0] ARAM_ADDR;
wire [7:0]  ARAM_D;
wire [7:0]  ARAM_Q;
wire        ARAM_CE_N;
wire        ARAM_OE_N;
wire        ARAM_WE_N;
wire [15:0] aram_dout;
wire        aram_16 = 1'b0;
wire        dot_clk_ce;
wire        dotclk;
wire        ppu_read_ce;
wire        hblankn;
wire        vblankn;
wire [8:0]  x_out;
wire [8:0]  y_out;
wire [14:0] rgb_out;
wire [15:0] audio_l;
wire [15:0] audio_r;
wire        audio_ready;
wire        audio_en_unused;
wire        refresh;
wire        snes_refresh_req;
wire        pause_snes_for_frame_sync;
wire        snes_joy_strb;
wire        snes_joy1_clk;
wire        snes_joy2_clk;
wire [1:0]  snes_joy1_di;
wire [1:0]  snes_joy2_di;
wire [11:0] game_pad = game_buttons;

wire [15:0] cpu_port0;
wire [15:0] cpu_port1;
wire [7:0]  wram_sd_q = WRAM_ADDR[0] ? cpu_port1[15:8] : cpu_port1[7:0];
reg         cpu_port = 1'b0;
reg         cpu_req = 1'b0;
wire        cpu_req_ack;
reg  [1:0]  cpu_ds = 2'b11;
reg [15:0]  cpu_din = 16'd0;
reg [22:0]  cpu_addr = 23'd0;
reg         cpu_we = 1'b0;
wire [22:0] rom_addr = loading ? loader_addr : ROM_ADDR[22:0];
reg [22:0] rom_addr_sd = 23'h7fffff;
wire [16:0] wram_addr_sd;
wire [7:0] wram_data_sd;
wire wram_request;
wire wram_ack;
wire wram_write;
reg wram_ack_settled = 0;
always @(posedge mclk) begin
    if (!sys_resetn)
        wram_ack_settled <= 0;
    else
        wram_ack_settled <= wram_ack;
end
wire wram_wait = SNES_WRAM_WAIT && (wram_request != wram_ack_settled);
wire       wram_rd = ~WRAM_CE_N & ~WRAM_RD_N;
wire       wram_wr = ~WRAM_CE_N & ~WRAM_WE_N;
reg        bsram_req = 1'b0;
wire       bsram_req_ack;
reg        bsram_we = 1'b0;
reg [19:0] bsram_addr = 20'd0;
reg [7:0]  bsram_din = 8'd0;
wire       bsram_rd = ~BSRAM_CE_N & (~BSRAM_RD_N || rom_type[7:4] == 4'hc);
wire       bsram_wr = ~BSRAM_CE_N & ~BSRAM_WE_N;
reg        bsram_rd_r = 1'b0;
reg        bsram_wr_r = 1'b0;
wire       aram_rd = ~ARAM_CE_N & ~ARAM_OE_N;
wire       aram_wr = ~ARAM_CE_N & ~ARAM_WE_N;
reg [15:0] aram_addr_sd = 16'hffff;
reg        aram_rd_r = 1'b0;
reg        aram_wr_r = 1'b0;
reg        aram_req = 1'b0;
wire       aram_req_ack;
wire [14:0] vram1_addr_sd;
wire [14:0] vram2_addr_sd;
wire        vram1_req;
wire        vram2_req;
wire       vram1_ack;
wire       vram2_ack;
wire [7:0] vram1_din;
wire [7:0] vram2_din;
wire vram1_write;
wire vram2_write;

always @(posedge mclk) begin
    if (!sys_resetn) begin
        cpu_req <= 1'b0;
        cpu_we <= 1'b0;
        cpu_addr <= 23'd0;
        cpu_din <= 16'd0;
        cpu_ds <= 2'b11;
        cpu_port <= 1'b0;
        rom_addr_sd <= 23'h7fffff;
        bsram_req <= 1'b0;
        bsram_we <= 1'b0;
        bsram_addr <= 20'd0;
        bsram_din <= 8'd0;
        bsram_rd_r <= 1'b0;
        bsram_wr_r <= 1'b0;
        aram_req <= 1'b0;
        aram_addr_sd <= 16'hffff;
        aram_rd_r <= 1'b0;
        aram_wr_r <= 1'b0;
    end else begin
        if ((loading && loader_do_valid && header_finished && loader_addr[0] &&
             cpu_req == cpu_req_ack) ||
            (!loading && !ROM_CE_N && rom_addr_sd != rom_addr &&
             cpu_req == cpu_req_ack)) begin
            rom_addr_sd <= loading ? 23'h7fffff : rom_addr;
            cpu_addr <= rom_addr;
            cpu_req <= ~cpu_req;
            cpu_we <= loading;
            cpu_din <= {loader_do, loader_do_r};
            cpu_ds <= 2'b11;
            cpu_port <= 1'b0;
        end

        bsram_rd_r <= bsram_rd;
        bsram_wr_r <= bsram_wr;
        if ((bsram_rd && BSRAM_ADDR != bsram_addr) ||
            (bsram_wr && !bsram_wr_r) || (bsram_rd && !bsram_rd_r)) begin
            bsram_addr <= BSRAM_ADDR;
            bsram_req <= ~bsram_req;
            bsram_din <= BSRAM_D;
            bsram_we <= bsram_wr;
        end

        aram_rd_r <= aram_rd;
        aram_wr_r <= aram_wr;
        if ((aram_rd && aram_addr_sd != ARAM_ADDR) ||
            (aram_wr && aram_addr_sd != ARAM_ADDR) ||
            (aram_rd && !aram_rd_r) || (aram_wr && !aram_wr_r)) begin
            aram_req <= ~aram_req;
            aram_addr_sd <= ARAM_ADDR;
        end

    end
end

snes_vram_port #(.ADDRESS_WIDTH(17), .READ_IGNORE_LOW_BITS(1)) u_wram_port (
    .clk(mclk), .resetn(sys_resetn), .address(WRAM_ADDR), .data(WRAM_D),
    .read_n(~(wram_rd && !loading)), .write_n(~(wram_wr && !loading)), .ack(wram_ack),
    .request(wram_request), .memory_address(wram_addr_sd), .memory_data(wram_data_sd),
    .memory_write(wram_write)
);

snes_vram_port #(.DIAGNOSTIC(SNES_MEMORY_DIAGNOSTIC)) u_vram_port1 (
    .clk(mclk), .resetn(sys_resetn), .address(VRAM1_ADDR[14:0]), .data(VRAM1_DO),
    .read_n(VRAM_OE_N), .write_n(VRAM1_WE_N), .ack(vram1_ack),
    .request(vram1_req), .memory_address(vram1_addr_sd), .memory_data(vram1_din),
    .memory_write(vram1_write),
    .diagnostic_reset(vram_diag_reset),
    .sample_read(ppu_read_ce && hblankn && vblankn && !VRAM_OE_N),
    .diagnostic_errors(vram1_diag_errors), .diagnostic_writes(vram1_diag_writes),
    .diagnostic_not_ready(vram1_diag_not_ready), .diagnostic_first(vram1_diag_first)
);

generate
    if (SNES_MEMORY_DIAGNOSTIC) begin : g_frame_diagnostic
        snes_diag_frame_counter u_counter (
            .clk(mclk), .resetn(sys_resetn), .clear(vram_diag_reset), .frame_active(vblankn),
            .sample(ppu_read_ce && hblankn && vblankn && !VRAM_OE_N),
            .not_ready(vram1_diag_not_ready),
            .last_samples(diag_frame_samples), .last_not_ready(diag_frame_late)
        );
    end else begin : g_no_frame_diagnostic
        assign diag_frame_samples = 0;
        assign diag_frame_late = 0;
    end
endgenerate
snes_vram_port #(.DIAGNOSTIC(SNES_MEMORY_DIAGNOSTIC)) u_vram_port2 (
    .clk(mclk), .resetn(sys_resetn), .address(VRAM2_ADDR[14:0]), .data(VRAM2_DO),
    .read_n(VRAM_OE_N), .write_n(VRAM2_WE_N), .ack(vram2_ack),
    .request(vram2_req), .memory_address(vram2_addr_sd), .memory_data(vram2_din),
    .memory_write(vram2_write),
    .diagnostic_reset(vram_diag_reset),
    .sample_read(ppu_read_ce && hblankn && vblankn && !VRAM_OE_N),
    .diagnostic_errors(vram2_diag_errors), .diagnostic_writes(vram2_diag_writes)
);

wire        rv_req_ack;
wire [15:0] rv_dout;
reg         rv_req = 1'b0;
reg         rv_we = 1'b0;
reg  [1:0]  rv_ds = 2'b11;
reg  [22:1] rv_addr_sdram = 22'd0;
reg [15:0]  rv_din_sdram = 16'd0;
reg [31:0]  rv_rdata_reg = 32'd0;
reg         rv_ready_reg = 1'b0;
reg [2:0]   rv_state = 3'd0;
reg [22:0]  rv_addr_latched = 23'd0;
reg [31:0]  rv_wdata_latched = 32'd0;
reg [3:0]   rv_wstrb_latched = 4'd0;
reg [15:0]  rv_low_word = 16'd0;

assign rv_ready = rv_ready_reg;
assign rv_rdata = rv_rdata_reg;

always @(posedge mclk) begin
    rv_ready_reg <= 1'b0;
    if (!sys_resetn) begin
        rv_state <= 3'd0;
        rv_req <= 1'b0;
        rv_we <= 1'b0;
        rv_ds <= 2'b11;
        rv_addr_sdram <= 22'd0;
        rv_din_sdram <= 16'd0;
        rv_rdata_reg <= 32'd0;
        rv_addr_latched <= 23'd0;
        rv_wdata_latched <= 32'd0;
        rv_wstrb_latched <= 4'd0;
        rv_low_word <= 16'd0;
    end else begin
        case (rv_state)
            3'd0: if (rv_valid) begin
                rv_addr_latched <= rv_addr;
                rv_wdata_latched <= rv_wdata;
                rv_wstrb_latched <= rv_wstrb;
                rv_addr_sdram <= {rv_addr[22:2], 1'b0};
                rv_din_sdram <= rv_wdata[15:0];
                rv_ds <= rv_wstrb[1:0];
                rv_we <= |rv_wstrb[1:0];
                rv_req <= ~rv_req;
                rv_state <= 3'd1;
            end
            3'd1: if (rv_req_ack == rv_req)
                rv_state <= 3'd2;
            3'd2: begin
                if (rv_wstrb_latched == 4'd0)
                    rv_low_word <= rv_dout;
                rv_addr_sdram <= {rv_addr_latched[22:2], 1'b1};
                rv_din_sdram <= rv_wdata_latched[31:16];
                rv_ds <= rv_wstrb_latched[3:2];
                rv_we <= |rv_wstrb_latched[3:2];
                rv_req <= ~rv_req;
                rv_state <= 3'd3;
            end
            3'd3: if (rv_req_ack == rv_req)
                rv_state <= 3'd4;
            3'd4: begin
                if (rv_wstrb_latched == 4'd0)
                    rv_rdata_reg <= {rv_dout, rv_low_word};
                rv_ready_reg <= 1'b1;
                rv_state <= 3'd5;
            end
            3'd5: if (!rv_valid)
                rv_state <= 3'd0;
            default: rv_state <= 3'd0;
        endcase
    end
end

wire        core_resetn = sys_resetn & image_valid & ~loading & ~game_reset &
                          ~button_reset;
wire        enable = core_resetn & ~sdram_busy & loaded & ~game_pause &
                     ~pause_snes_for_frame_sync & ~wram_wait;
wire [19:0] audio_l_scaled = {audio_l, 4'd0};
wire [19:0] audio_r_scaled = {audio_r, 4'd0};
wire [19:0] audio_l_filtered;
wire [19:0] audio_r_filtered;

main #(.USE_DSPn(1'b1)) u_snes (
    .MCLK(mclk), .RESET_N(core_resetn), .ENABLE(enable),
    .SYSCLKF_CE(), .SYSCLKR_CE(), .REFRESH(snes_refresh_req),
    .ROM_TYPE(rom_type), .ROM_MASK(rom_mask), .RAM_MASK(ram_mask),
    .ROM_ADDR(ROM_ADDR), .ROM_D(ROM_D), .ROM_Q(ROM_Q),
    .ROM_CE_N(ROM_CE_N), .ROM_OE_N(ROM_OE_N), .ROM_WE_N(ROM_WE_N), .ROM_WORD(ROM_WORD),
    .BSRAM_ADDR(BSRAM_ADDR), .BSRAM_D(BSRAM_D), .BSRAM_Q(BSRAM_Q),
    .BSRAM_CE_N(BSRAM_CE_N), .BSRAM_OE_N(BSRAM_OE_N), .BSRAM_WE_N(BSRAM_WE_N), .BSRAM_RD_N(BSRAM_RD_N),
    .WRAM_ADDR(WRAM_ADDR), .WRAM_D(WRAM_D), .WRAM_Q(wram_sd_q),
    .WRAM_CE_N(WRAM_CE_N), .WRAM_OE_N(WRAM_OE_N), .WRAM_WE_N(WRAM_WE_N), .WRAM_RD_N(WRAM_RD_N),
    .VRAM1_ADDR(VRAM1_ADDR), .VRAM1_DI(VRAM1_DI), .VRAM1_DO(VRAM1_DO), .VRAM1_WE_N(VRAM1_WE_N),
    .VRAM2_ADDR(VRAM2_ADDR), .VRAM2_DI(VRAM2_DI), .VRAM2_DO(VRAM2_DO), .VRAM2_WE_N(VRAM2_WE_N), .VRAM_OE_N(VRAM_OE_N),
    .ARAM_ADDR(ARAM_ADDR), .ARAM_Q(ARAM_Q), .ARAM_D(ARAM_D), .ARAM_CE_N(ARAM_CE_N), .ARAM_OE_N(ARAM_OE_N), .ARAM_WE_N(ARAM_WE_N),
    .BLEND(1'b0), .PAL(1'b0), .DIS_SHORTLINE(1'b0), .HIGH_RES(), .FIELD(), .INTERLACE(),
    .DOTCLK(dotclk), .RGB_OUT(rgb_out), .HBLANKn(hblankn), .VBLANKn(vblankn), .X_OUT(x_out), .Y_OUT(y_out),
    .VRAM_READ_CE(ppu_read_ce),
    .JOY1_DI(snes_joy1_di), .JOY2_DI(snes_joy2_di), .JOY_STRB(snes_joy_strb),
    .JOY1_CLK(snes_joy1_clk), .JOY2_CLK(snes_joy2_clk), .JOY1_P6(), .JOY2_P6(), .JOY2_P6_in(1'b1),
    .AUDIO_L(audio_l), .AUDIO_R(audio_r), .AUDIO_READY(audio_ready), .AUDIO_EN(1'b1),
    .DOT_CLK_CE(dot_clk_ce), .EXT_RTC(65'd0), .SPC_MODE(1'b0), .IO_ADDR(17'd0), .IO_DAT(16'd0), .IO_WR(1'b0),
    .DBG_SEL(8'd0), .DBG_REG(8'd0), .DBG_REG_WR(1'b0), .DBG_DAT_IN(8'd0), .DBG_DAT_OUT(), .DBG_BREAK()
);

assign ROM_Q = (ROM_WORD || ~ROM_ADDR[0]) ? cpu_port0 : {cpu_port0[7:0], cpu_port0[15:8]};
assign BSRAM_Q = bsram_dout;
assign ARAM_Q = ARAM_ADDR[0] ? aram_dout[15:8] : aram_dout[7:0];

wire [7:0] bsram_dout;
wire [7:0] vram1_dout;
wire [7:0] vram2_dout;

sdram_snes #(.SHARED_IOSYS(1), .SPLIT_WRAM(1),
             .UPSTREAM_RAM_LAYOUT(SNES_UPSTREAM_RAM_LAYOUT),
             .VIDEO_RAM_LAYOUT(SNES_VIDEO_RAM_LAYOUT)) u_sdram (
    .clk(fclk), .mclk(mclk), .clkref(dot_clk_ce), .resetn(sys_resetn), .busy(sdram_busy),
    .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba),
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n),
    .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm),
    .cpu_addr(cpu_addr[22:1]), .cpu_din(cpu_din), .cpu_port(cpu_port),
    .cpu_port0(cpu_port0), .cpu_port1(cpu_port1), .cpu_req(cpu_req), .cpu_req_ack(cpu_req_ack),
    .cpu_we(cpu_we), .cpu_ds(cpu_ds),
    .wram_addr(wram_addr_sd), .wram_din(wram_data_sd), .wram_req(wram_request),
    .wram_ack(wram_ack), .wram_we(wram_write),
    .bsram_addr(bsram_addr), .bsram_dout(bsram_dout), .bsram_din(bsram_din),
    .bsram_req(bsram_req), .bsram_req_ack(bsram_req_ack), .bsram_we(bsram_we),
    .aram_16(aram_16), .aram_addr(ARAM_ADDR), .aram_din({ARAM_D, ARAM_D}), .aram_dout(aram_dout),
    .aram_req(aram_req), .aram_req_ack(aram_req_ack), .aram_we(aram_wr),
    .vram1_addr(vram1_addr_sd), .vram1_din(vram1_din), .vram1_dout(vram1_dout),
    .vram1_req(vram1_req), .vram1_ack(vram1_ack), .vram1_we(vram1_write),
    .vram2_addr(vram2_addr_sd), .vram2_din(vram2_din), .vram2_dout(vram2_dout),
    .vram2_req(vram2_req), .vram2_ack(vram2_ack), .vram2_we(vram2_write),
    .rv_addr(rv_addr_sdram), .rv_din(rv_din_sdram), .rv_ds(rv_ds), .rv_dout(rv_dout),
    .rv_req(rv_req), .rv_req_ack(rv_req_ack), .rv_we(rv_we), .refreshing(refresh),
    .total_refresh()
);

assign VRAM1_DI = vram1_dout;
assign VRAM2_DI = vram2_dout;
assign ld_busy = loading && (cpu_req != cpu_req_ack);
assign ld_idle = !ld_wr && (cpu_req == cpu_req_ack);

controller_adapter u_controller1 (
    .clk(mclk), .snes_joy_strb(snes_joy_strb), .snes_buttons({4'd0, game_pad}),
    .snes_joy_clk(snes_joy1_clk), .snes_joy_di(snes_joy1_di[0])
);
controller_adapter u_controller2 (
    .clk(mclk), .snes_joy_strb(snes_joy_strb), .snes_buttons(16'd0),
    .snes_joy_clk(snes_joy2_clk), .snes_joy_di(snes_joy2_di[0])
);
assign snes_joy1_di[1] = 1'b1;
assign snes_joy2_di[1] = 1'b1;

snes_video_640 u_snes2hdmi (
    .clk(mclk), .resetn(sys_resetn), .snes_refresh(snes_refresh_req),
    .pause_snes_for_frame_sync(pause_snes_for_frame_sync),
    .dotclk(dotclk), .hblank(~hblankn), .vblank(~vblankn), .rgb5(rgb_out),
    .xs(x_out), .ys(y_out), .zoom(video_zoom), .scanline(scanline),
    .game_active(image_valid && !loading && loaded),
    .overlay(osd_on), .overlay_text(osd_text),
    .overlay_x(osd_x), .overlay_y(osd_y), .overlay_de(osd_de),
    .overlay_color(osd_rgb),
    .audio_l(audio_hdmi ? audio_l_filtered[19:4] : 16'd0),
    .audio_r(audio_hdmi ? audio_r_filtered[19:4] : 16'd0),
    .audio_ready(audio_ready), .clk_pixel(hclk), .clk_5x_pixel(hclk5), .locked(hdmi_locked),
    .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
);

audio_tone #(.TONE_ENABLE(0)) u_audio_tone (
    .clk(mclk), .resetn(sys_resetn), .volume(audio_volume), .bass(audio_bass), .treble(audio_treble),
    .in_l(audio_l_scaled), .in_r(audio_r_scaled), .out_l(audio_l_filtered), .out_r(audio_r_filtered)
);

i2s_tx #(.BCK_DIV(7)) u_i2s (
    .clk(mclk), .resetn(sys_resetn), .left(audio_l_filtered[19:4]), .right(audio_r_filtered[19:4]),
    .sck(hp_bck), .ws(hp_ws), .sd(hp_din)
);

assign pa_en = ~audio_hdmi;
assign O_sdram_clk = fclk_p;
assign led[0] = ~(hdmi_locked & ~sdram_busy);
assign led[1] = ~(image_valid & ~loading & loaded);

endmodule

module snes_vram_port #(
    parameter ADDRESS_WIDTH = 15,
    parameter READ_IGNORE_LOW_BITS = 0,
    parameter DIAGNOSTIC = 0
) (
    input wire clk,
    input wire resetn,
    input wire [ADDRESS_WIDTH-1:0] address,
    input wire [7:0] data,
    input wire read_n,
    input wire write_n,
    input wire ack,
    output reg request = 0,
    output reg [ADDRESS_WIDTH-1:0] memory_address = 0,
    output reg [7:0] memory_data = 0,
    output reg memory_write = 0,
    input wire diagnostic_reset,
    input wire sample_read,
    output wire [1:0] diagnostic_errors,
    output wire [7:0] diagnostic_writes,
    output wire diagnostic_not_ready,
    output wire [15:0] diagnostic_first
);
reg write_previous = 1;
reg valid = 0;
reg write_pending = 0;
reg [ADDRESS_WIDTH-1:0] pending_address = 0;
reg [7:0] pending_data = 0;
wire new_write = !write_n && write_previous;
wire read_not_ready = sample_read && (!valid || memory_write || request != ack ||
    (memory_address >> READ_IGNORE_LOW_BITS) != (address >> READ_IGNORE_LOW_BITS));
generate
    if (DIAGNOSTIC) begin : g_diagnostic
        reg [1:0] errors = 0;
        reg [7:0] writes = 0;
        reg [15:0] first_failure = 0;
        assign diagnostic_errors = errors;
        assign diagnostic_writes = writes;
        assign diagnostic_not_ready = read_not_ready;
        assign diagnostic_first = first_failure;
        always @(posedge clk) begin
            if (!resetn || diagnostic_reset) begin
                errors <= 0;
                writes <= 0;
                first_failure <= 0;
            end else begin
                if (read_not_ready) begin
                    errors[0] <= 1;
                    if (!errors[0])
                        first_failure <= {request, ack, address[6:0], memory_address[6:0]};
                end
                if (new_write && write_pending && request != ack)
                    errors[1] <= 1;
                if (new_write)
                    writes <= writes + 1'b1;
            end
        end
    end else begin : g_no_diagnostic
        assign diagnostic_errors = 0;
        assign diagnostic_writes = 0;
        assign diagnostic_not_ready = 0;
        assign diagnostic_first = 0;
    end
endgenerate
always @(posedge clk) begin
    if (!resetn) begin
        request <= 0;
        memory_address <= 0;
        memory_data <= 0;
        memory_write <= 0;
        write_previous <= 1;
        valid <= 0;
        write_pending <= 0;
        pending_address <= 0;
        pending_data <= 0;
    end else begin
        write_previous <= write_n;
        if (new_write) begin
            pending_address <= address;
            pending_data <= data;
            write_pending <= 1;
        end
        if (request == ack) begin
            if (write_pending) begin
                memory_address <= pending_address;
                memory_data <= pending_data;
                memory_write <= 1;
                valid <= 1;
                request <= ~request;
                write_pending <= new_write;
            end else if (new_write) begin
                memory_address <= address;
                memory_data <= data;
                memory_write <= 1;
                valid <= 1;
                request <= ~request;
                write_pending <= 0;
            end else if (!read_n && (!valid || memory_write ||
                (memory_address >> READ_IGNORE_LOW_BITS) != (address >> READ_IGNORE_LOW_BITS))) begin
                memory_address <= address;
                memory_data <= 0;
                memory_write <= 0;
                valid <= 1;
                request <= ~request;
            end
        end
    end
end
endmodule

module snes_diag_frame_counter (
    input wire clk,
    input wire resetn,
    input wire clear,
    input wire frame_active,
    input wire sample,
    input wire not_ready,
    output reg [15:0] last_samples = 0,
    output reg [15:0] last_not_ready = 0
);
reg active_previous = 0;
reg [15:0] samples = 0;
reg [15:0] failures = 0;
always @(posedge clk) begin
    if (!resetn || clear) begin
        active_previous <= 0;
        samples <= 0;
        failures <= 0;
        last_samples <= 0;
        last_not_ready <= 0;
    end else begin
        active_previous <= frame_active;
        if (active_previous && !frame_active) begin
            last_samples <= samples;
            last_not_ready <= failures;
            samples <= 0;
            failures <= 0;
        end else if (frame_active && sample) begin
            if (samples != 16'hffff)
                samples <= samples + 1'b1;
            if (not_ready && failures != 16'hffff)
                failures <= failures + 1'b1;
        end
    end
end
endmodule