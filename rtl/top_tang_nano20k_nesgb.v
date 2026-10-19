// Combined NES and DMG Game Boy profile for the Tang Nano 20K.

module top_tang_nano20k_nesgb (
    input  wire        sys_clk,
    input  wire        s1,
    input  wire        s2,
    inout  wire        fpga_reconfig_n,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire [1:0]  led,
    output wire        sd_clk,
    output wire        sd_cmd,
    input  wire        sd_dat0,
    output wire        sd_dat1,
    output wire        sd_dat2,
    output wire        sd_dat3,
    output wire        flash_spi_cs_n,
    input  wire        flash_spi_miso,
    output wire        flash_spi_mosi,
    output wire        flash_spi_clk,
    output wire        flash_spi_wp_n,
    output wire        flash_spi_hold_n,
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
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
    output wire        pa_en,
    output wire        hp_bck,
    output wire        hp_ws,
    output wire        hp_din,
    output wire        pad_clk,
    output wire        pad_latch,
    input  wire        pad_data
);

localparam integer MCLK_HZ = 21_600_000;
localparam [15:0] CORE_ID_NINTENDO8 = 16'd5;

import configPackage::*;

wire mclk;
wire fclk;
wire fclk_p;
wire hclk5;
wire hclk;
wire hdmi_locked;

gowin_pll_nes u_pll_nes (
    .clkin   (sys_clk),
    .clkout  (fclk),
    .clkoutp (fclk_p),
    .clkoutd3(mclk)
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
reg sys_resetn = 1'b0;
wire system_reset;

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
wire [9:0] osd_y;
wire osd_de;
wire osd_on;
wire [23:0] osd_rgb;
wire osd_text;
wire osd_active;
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

wire ld_wr;
wire [22:0] ld_addr;
wire [7:0] ld_data;
wire ld_busy;
wire ld_idle;
wire loading;
wire image_valid;
wire [7:0] rom_sz;
wire [22:0] rom_offset;
wire nes_mode;
wire sgx_mode;
wire cd_mode;
wire rom_pop;
wire [1:0] video_zoom;
wire [1:0] scanline;
wire game_pause;
wire game_reset;
wire pad_mode;
wire pad_mode_sf2;
wire cheat_apply;
wire cheat_reset;
wire [128:0] cheat_code;
wire color_mode;
wire [6:0] nintendo_color;
wire [3:0] audio_volume;
wire [3:0] audio_bass;
wire [3:0] audio_treble;
wire audio_hdmi;
wire audio_cdda_enable;
wire audio_adpcm_enable;
wire vdc_sprites_double;

wire rv_valid;
wire rv_ready;
wire [22:0] rv_addr;
wire [31:0] rv_wdata;
wire [3:0] rv_wstrb;
wire [31:0] rv_rdata;
wire sdram_busy;

iosys #(
    .FREQ                (MCLK_HZ),
    .FIRMWARE_FLASH_ADDR (24'h50_0000),
    .FIRMWARE_SIZE       (128*1024),
    .RV_BASE             (23'h40_0000),
    .ROM_MAX_SIZE        (32'h003e_0000),
    .OSD_CHARACTER_BITS  (7),
    .ROM_CLEAR_ENABLE    (0),
    .CORE_ID             (CORE_ID_NINTENDO8),
    .RECONFIG_ENABLE     (1),
    .RECONFIG_PIN        (8'd29),
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
    .ld_idle             (ld_idle),
    .loading             (loading),
    .image_valid         (image_valid),
    .rom_sz              (rom_sz),
    .rom_offset          (rom_offset),
    .nes_mode            (nes_mode),
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
    .nintendo_color      (nintendo_color),
    .audio_volume        (audio_volume),
    .audio_bass          (audio_bass),
    .audio_treble         (audio_treble),
    .audio_hdmi          (audio_hdmi),
    .audio_cdda_enable   (audio_cdda_enable),
    .audio_adpcm_enable  (audio_adpcm_enable),
    .vdc_sprites_double  (vdc_sprites_double),
    .brm_host_q          (8'd0),
    .brm_host_addr       (),
    .brm_host_data       (),
    .brm_host_we         (),
    .brm_host_access     (),
    .cd_comm             (96'd0),
    .cd_comm_send        (1'b0),
    .cd_dout             (80'd0),
    .cd_dout_send        (1'b0),
    .cd_data_end         (1'b0),
    .cd_reset            (1'b0),
    .cd_fifo_halffull    (1'b0),
    .cd_stat             (),
    .cd_stat_strobe      (),
    .cd_dout_req         (),
    .cd_data             (),
    .cd_wr               (),
    .cd_dm               (),
    .cd_ack              (),
    .cd_audio_hold       (),
    .cd_phase_dbg        (8'd0),
    .cdda_usedw_dbg      (14'd0),
    .adpcm_dbg           (8'd0),
    .refresh_gap_dbg     (8'd0),
    .vid_dcc_dbg         (2'd0),
    .vid_hdw_dbg         (7'd0),
    .vid_hds_dbg         (7'd0),
    .vid_hsw_dbg         (5'd0),
    .vid_hde_dbg         (7'd0),
    .vid_vsw_dbg         (5'd0),
    .vid_vds_dbg         (8'd0),
    .vid_vdw_dbg         (9'd0),
    .vid_vcr_dbg         (8'd0),
    .vid_vce_cr_dbg      (8'd0),
    .vid_vce_wr_dbg      (16'd0),
    .vid_px_dbg          (10'd0),
    .rv_valid            (rv_valid),
    .rv_ready            (rv_ready),
    .rv_addr             (rv_addr),
    .rv_wdata            (rv_wdata),
    .rv_wstrb            (rv_wstrb),
    .rv_rdata            (rv_rdata),
    .rv_capture_dbg      (64'd0),
    .rv_bus_dbg          (128'd0),
    .ram_busy            (sdram_busy),
    .rv_scheduler_dbg    (16'd0),
    .loader_host_dbg     (16'd0),
    .loader_uart_owner   (1'b0),
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

wire [21:0] nes_cpu_addr;
wire nes_cpu_read;
wire nes_cpu_write;
wire [7:0] nes_cpu_dout;
wire [7:0] nes_cpu_din;
wire [21:0] nes_ppu_addr;
wire nes_ppu_read;
wire nes_ppu_write;
wire [7:0] nes_ppu_dout;
wire [7:0] nes_ppu_din;
wire [15:0] nes_sample;
wire [5:0] nes_color;
wire [2:0] joypad_out;
wire [1:0] joypad_clock;
reg [7:0] joypad_bits = 8'hff;
reg [1:0] joypad_clock_r = 2'b00;
// NES data is active high; unused expansion lines must not report presses.
wire [4:0] joypad1_data = {4'b0000, joypad_bits[0]};
wire [4:0] joypad2_data = 5'b0000_0;
wire [8:0] nes_cycle;
wire [8:0] nes_scanline;
wire [63:0] loader_flags;
reg [63:0] mapper_flags = 64'd0;
wire [21:0] nes_loader_addr;
wire [7:0] nes_loader_data;
wire nes_loader_write;
wire loader_busy;
wire loader_done;
wire loader_error;
wire [21:0] nes_mem_addr_a = nes_ppu_addr;
wire [21:0] nes_mem_addr_b;
wire [7:0] nes_mem_dout_a = nes_ppu_dout;
wire [7:0] nes_mem_dout_b;
wire [7:0] nes_mem_din_a;
wire [7:0] nes_mem_din_b;
wire nes_mem_write_a;
wire nes_mem_read_a;
wire nes_mem_write_b;
wire nes_mem_read_b;

reg loading_r = 1'b0;
reg loader_write_r = 1'b0;
reg loader_write_mem = 1'b0;
reg [21:0] loader_addr_mem = 22'd0;
reg [7:0] loader_data_mem = 8'd0;
reg nes_loader_ready = 1'b0;
wire loader_reset = loading && !loading_r;
wire nes_game_active = image_valid && !loading && nes_mode && nes_loader_ready;
wire gb_game_active = image_valid && !loading && !nes_mode;
wire game_active = nes_game_active || gb_game_active;
assign nes_mem_write_a = nes_game_active && nes_ppu_write;
assign nes_mem_read_a = nes_game_active && nes_ppu_read;
reg nes_reset = 1'b1;
reg nes_pause = 1'b0;
reg clkref = 1'b1;

always @(posedge mclk) begin
    loading_r <= loading;
    loader_write_r <= nes_mode ? nes_loader_write : ld_wr;
    loader_write_mem <= (nes_mode ? nes_loader_write : ld_wr) || loader_write_r;

    if (nes_mode ? nes_loader_write : ld_wr) begin
        loader_addr_mem <= nes_mode ? nes_loader_addr : ld_addr[21:0];
        loader_data_mem <= nes_mode ? nes_loader_data : ld_data;
    end

    if (loader_reset)
        mapper_flags <= 64'd0;
    else if (loader_done)
        mapper_flags <= loader_flags;
    if (loader_reset)
        nes_loader_ready <= 1'b0;
    else if (loader_done)
        nes_loader_ready <= 1'b1;

    if (joypad_out[0])
        joypad_bits <= {game_buttons[7:2],
                        game_buttons[1] | game_buttons[9],
                        game_buttons[0] | game_buttons[8]};
    if (!joypad_clock[0] && joypad_clock_r[0])
        joypad_bits <= {1'b1, joypad_bits[7:1]};
    joypad_clock_r <= joypad_clock;
end

NES #(.ENABLE_MMC5(0)) u_nes (
    .clk             (mclk),
    .reset_nes       (nes_reset),
    .cold_reset      (1'b0),
    .pause           (nes_pause),
    .sys_type        (2'b00),
    .nes_div         (),
    .mapper_flags    (mapper_flags),
    .sample          (nes_sample),
    .color           (nes_color),
    .joypad_out      (joypad_out),
    .joypad_clock    (joypad_clock),
    .joypad1_data    (joypad1_data),
    .joypad2_data    (joypad2_data),
    .fds_busy        (1'b0),
    .fds_eject       (1'b0),
    .diskside_req    (),
    .diskside        (2'b00),
    .audio_channels  (5'b11111),
    .cpumem_addr     (nes_cpu_addr),
    .cpumem_read     (nes_cpu_read),
    .cpumem_write    (nes_cpu_write),
    .cpumem_dout     (nes_cpu_dout),
    .cpumem_din      (nes_cpu_din),
    .ppumem_addr     (nes_ppu_addr),
    .ppumem_read     (nes_ppu_read),
    .ppumem_write    (nes_ppu_write),
    .ppumem_dout     (nes_ppu_dout),
    .ppumem_din      (nes_ppu_din),
    .bram_addr       (),
    .bram_din        (8'hff),
    .bram_dout       (),
    .bram_write      (),
    .bram_override   (),
    .cycle           (nes_cycle),
    .scanline        (nes_scanline),
    .int_audio       (1'b1),
    .ext_audio       ((mapper_flags[7:0] == 8'd19) ||
                      (mapper_flags[7:0] == 8'd24) ||
                      (mapper_flags[7:0] == 8'd26)),
    .apu_ce          (),
    .gg              (1'b0),
    .gg_code         (129'd0),
    .gg_avail        (),
    .gg_reset        (1'b0),
    .emphasis        (),
    .save_written    ()
);

GameLoader u_nes_loader (
    .clk              (mclk),
    .reset            (!sys_resetn || loader_reset || !nes_mode),
    .downloading      (loading && nes_mode),
    .filetype         (8'b0000_0010),
    .is_bios          (1'b0),
    .indata           (ld_data),
    .indata_clk       (ld_wr && nes_mode),
    .invert_mirroring (1'b0),
    .mem_addr         (nes_loader_addr),
    .mem_data         (nes_loader_data),
    .mem_write        (nes_loader_write),
    .bios_download    (),
    .mapper_flags     (loader_flags),
    .busy             (loader_busy),
    .done             (loader_done),
    .error            (loader_error),
    .rom_loaded       ()
);

wire [21:0] gb_mem_addr;
wire gb_mem_rd;
wire gb_mem_wr;
wire [7:0] gb_mem_wdata;
wire gb_hs;
wire gb_vs;
wire [5:0] gb_pixel;
wire gb_valid;
wire gb_cgb_mode;
wire gb_pal_wr;
wire [6:0] gb_pal_addr;
wire [7:0] gb_pal_data;
wire [15:0] gb_audio_l;
wire [15:0] gb_audio_r;
// gbc_core order: {Start, Select, B, A, Down, Up, Left, Right}.
// SNES B/A -> GB A, SNES Y/X -> GB B.
wire [7:0] gb_key = {game_buttons[3], game_buttons[2],
                     (game_buttons[1] | game_buttons[9]),
                     (game_buttons[0] | game_buttons[8]),
                     game_buttons[5], game_buttons[4],
                     game_buttons[6], game_buttons[7]};

reg [7:0] gb_cgb_flag = 8'd0;
reg [7:0] gb_mapper_type = 8'd0;
reg [7:0] gb_rom_size_code = 8'd0;
reg [7:0] gb_ram_size_code = 8'd0;

always @(posedge mclk) begin
    if (loader_reset) begin
        gb_cgb_flag <= 8'd0;
        gb_mapper_type <= 8'd0;
        gb_rom_size_code <= 8'd0;
        gb_ram_size_code <= 8'd0;
    end else if (loading && !nes_mode && ld_wr) begin
        if (ld_addr == 23'h143)
            gb_cgb_flag <= ld_data;
        if (ld_addr == 23'h147)
            gb_mapper_type <= ld_data;
        if (ld_addr == 23'h148)
            gb_rom_size_code <= ld_data;
        if (ld_addr == 23'h149)
            gb_ram_size_code <= ld_data;
    end
end

gbc_core #(.MEM_LAT(5)) u_gameboy (
    .clk        (mclk),
    .reset      (!sys_resetn || !gb_game_active || game_reset || button_reset),
    .pause      (game_pause),
    .cgb_enable (gb_cgb_flag[7]),
    .cart_type  (gb_mapper_type),
    .rom_size   (gb_rom_size_code),
    .ram_size   (gb_ram_size_code),
    .buttons    (gb_key),
    .mem_addr   (gb_mem_addr),
    .mem_rd     (gb_mem_rd),
    .mem_wr     (gb_mem_wr),
    .mem_wdata  (gb_mem_wdata),
    .mem_rdata  (sdram_cpu_din),
    .pix_valid  (gb_valid),
    .pix_index  (gb_pixel),
    .hsync      (gb_hs),
    .vsync      (gb_vs),
    .cgb_mode   (gb_cgb_mode),
    .pal_wr     (gb_pal_wr),
    .pal_wr_addr(gb_pal_addr),
    .pal_wr_data(gb_pal_data),
    .audio_l    (gb_audio_l),
    .audio_r    (gb_audio_r)
);

wire [21:0] sdram_cpu_addr = nes_mode ? nes_cpu_addr : gb_mem_addr;
wire [7:0] sdram_cpu_din;
wire [7:0] sdram_ppu_din;
assign nes_cpu_din = sdram_cpu_din;
assign nes_ppu_din = sdram_ppu_din;

assign nes_mem_write_b = nes_game_active && nes_cpu_write;
assign nes_mem_read_b = nes_game_active && nes_cpu_read;
wire sdram_cpu_write = nes_mode ?
                       (nes_mem_write_b && !loading) :
                       (gb_game_active && gb_mem_wr);
wire sdram_cpu_read = nes_mode ?
                      (nes_mem_read_b && !loading) :
                      (gb_game_active && gb_mem_rd);

wire [21:0] sdram_addr_b = loader_write_mem ? loader_addr_mem : sdram_cpu_addr;
wire [7:0] sdram_din_b = loader_write_mem ? loader_data_mem :
                         (nes_mode ? nes_cpu_dout : gb_mem_wdata);
wire sdram_we_b = loader_write_mem || sdram_cpu_write;
wire sdram_oe_b = !loader_write_mem && sdram_cpu_read;

wire [20:1] rv_addr_sdram;
wire [15:0] rv_din_sdram;
wire [1:0] rv_ds_sdram;
wire [15:0] rv_dout_sdram;
wire rv_req_ack;
reg rv_req = 1'b0;
reg rv_we = 1'b0;
reg [1:0] rv_ds = 2'b11;
reg [22:1] rv_addr_word = 22'd0;
reg [15:0] rv_din_word = 16'd0;
reg [31:0] rv_rdata_reg = 32'd0;
reg rv_ready_reg = 1'b0;
reg [2:0] rv_state = 3'd0;
reg [22:0] rv_addr_latched = 23'd0;
reg [31:0] rv_wdata_latched = 32'd0;
reg [3:0] rv_wstrb_latched = 4'd0;
reg [15:0] rv_low_word = 16'd0;

assign rv_ready = rv_ready_reg;
assign rv_rdata = rv_rdata_reg;
assign rv_addr_sdram = rv_addr_word;
assign rv_din_sdram = rv_din_word;
assign rv_ds_sdram = rv_ds;

always @(posedge mclk) begin
    rv_ready_reg <= 1'b0;
    if (!sys_resetn) begin
        rv_state <= 3'd0;
        rv_req <= 1'b0;
        rv_we <= 1'b0;
        rv_ds <= 2'b11;
        rv_addr_word <= 22'd0;
        rv_din_word <= 16'd0;
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
                rv_addr_word <= {rv_addr[22:2], 1'b0};
                rv_din_word <= rv_wdata[15:0];
                rv_ds <= rv_wstrb[1:0];
                rv_we <= |rv_wstrb[1:0];
                rv_req <= ~rv_req;
                rv_state <= 3'd1;
            end
            3'd1: if (rv_req_ack == rv_req)
                rv_state <= 3'd2;
            3'd2: begin
                if (rv_wstrb_latched == 4'd0)
                    rv_low_word <= rv_dout_sdram;
                rv_addr_word <= {rv_addr_latched[22:2], 1'b1};
                rv_din_word <= rv_wdata_latched[31:16];
                rv_ds <= rv_wstrb_latched[3:2];
                rv_we <= |rv_wstrb_latched[3:2];
                rv_req <= ~rv_req;
                rv_state <= 3'd3;
            end
            3'd3: if (rv_req_ack == rv_req)
                rv_state <= 3'd4;
            3'd4: begin
                if (rv_wstrb_latched == 4'd0)
                    rv_rdata_reg <= {rv_dout_sdram, rv_low_word};
                rv_ready_reg <= 1'b1;
                rv_state <= 3'd5;
            end
            3'd5: if (!rv_valid)
                rv_state <= 3'd0;
            default: rv_state <= 3'd0;
        endcase
    end
end

// As in NESTang, the SDRAM CPU/PPU slot phase restarts with the NES. Pause
// changes only every other cycle so the NES keeps the same slot parity.
always @(posedge mclk) begin
    clkref <= ~clkref;
    nes_reset <= !nes_game_active || game_reset || button_reset;
    if (nes_reset && nes_game_active && !game_reset && !button_reset)
        clkref <= 1'b1;
    if (clkref)
        nes_pause <= game_pause;
end

sdram_nes #(.FREQ(64_800_000)) u_sdram (
    .clk          (fclk),
    .resetn       (sys_resetn),
    .clkref       (clkref),
    .busy         (sdram_busy),
    .SDRAM_DQ     (IO_sdram_dq),
    .SDRAM_A      (O_sdram_addr),
    .SDRAM_BA     (O_sdram_ba),
    .SDRAM_nCS    (O_sdram_cs_n),
    .SDRAM_nWE    (O_sdram_wen_n),
    .SDRAM_nRAS   (O_sdram_ras_n),
    .SDRAM_nCAS   (O_sdram_cas_n),
    .SDRAM_CKE    (O_sdram_cke),
    .SDRAM_DQM    (O_sdram_dqm),
    .addrA        (nes_mem_addr_a),
    .weA          (nes_mem_write_a),
    .dinA         (nes_mem_dout_a),
    .oeA          (nes_mem_read_a),
    .doutA        (sdram_ppu_din),
    .addrB        (sdram_addr_b),
    .weB          (sdram_we_b),
    .dinB         (sdram_din_b),
    .oeB          (sdram_oe_b),
    .doutB        (sdram_cpu_din),
    .rv_addr      (rv_addr_sdram),
    .rv_din       (rv_din_sdram),
    .rv_ds        (rv_ds_sdram),
    .rv_dout      (rv_dout_sdram),
    .rv_req       (rv_req),
    .rv_req_ack   (rv_req_ack),
    .rv_we        (rv_we)
);

wire signed [16:0] gb_audio_sum = $signed(gb_audio_l) + $signed(gb_audio_r);
wire signed [15:0] gb_audio_mono = gb_audio_sum[16:1];
wire [15:0] nes_audio_sample = nes_sample >> 1;
wire [15:0] mixed_sample = gb_game_active ? gb_audio_mono : nes_audio_sample;
wire [19:0] audio_scaled = {mixed_sample, 4'b0000};
wire [19:0] audio_filtered_l;
wire [19:0] audio_filtered_r;
wire [15:0] nes2hdmi_sample = mixed_sample;
wire [15:0] overlay_color = {osd_text, osd_rgb[23:19],
                             osd_rgb[15:11], osd_rgb[7:3]};
wire [10:0] overlay_x;
wire [9:0] overlay_y;
// Registered coordinates keep textdisp's three-pixel lead on the HDMI raster.
reg [10:0] osd_x_r = 11'h7ff;
reg [9:0] osd_y_r = 10'h3ff;
reg osd_de_r = 1'b0;
wire [10:0] osd_x_next = overlay_x;
wire [9:0] osd_y_next = overlay_y;
always @(posedge hclk) begin
    osd_x_r <= osd_x_next;
    osd_y_r <= osd_y_next;
    osd_de_r <= osd_x_next < 11'd640 && osd_y_next < 10'd480;
end
assign osd_x = osd_x_r;
assign osd_y = osd_y_r;
assign osd_de = osd_de_r;

nes2hdmi u_nes2hdmi (
    .clk          (mclk),
    .resetn       (sys_resetn),
    .color        (nes_color),
    .cycle        (nes_cycle),
    .scanline     (nes_scanline),
    .sample       (nes2hdmi_sample),
    .aspect_8x7   (1'b1),
    .zoom_mode    (video_zoom),
    .effect_strength(scanline),
    .nintendo_color(nintendo_color),
    .gameboy_mode (!nes_mode),
    .game_active  (game_active),
    .gameboy_pixel(gb_pixel),
    .gameboy_hs   (gb_hs),
    .gameboy_vs   (gb_vs),
    .gameboy_valid(gb_valid),
    .gameboy_color(gb_cgb_mode),
    .gameboy_pal_wr(gb_pal_wr),
    .gameboy_pal_addr(gb_pal_addr),
    .gameboy_pal_data(gb_pal_data),
    .overlay      (osd_on),
    .overlay_x    (overlay_x),
    .overlay_y    (overlay_y),
    .overlay_color(overlay_color),
    .clk_pixel    (hclk),
    .clk_5x_pixel (hclk5),
    .tmds_clk_n   (tmds_clk_n),
    .tmds_clk_p   (tmds_clk_p),
    .tmds_d_n     (tmds_d_n),
    .tmds_d_p     (tmds_d_p)
);

audio_tone #(.TONE_ENABLE(0)) u_audio_tone (
    .clk     (mclk),
    .resetn  (sys_resetn),
    .volume  (audio_volume),
    .bass    (audio_bass),
    .treble  (audio_treble),
    .in_l    (audio_scaled),
    .in_r    (audio_scaled),
    .out_l   (audio_filtered_l),
    .out_r   (audio_filtered_r)
);

i2s_tx #(.BCK_DIV(7)) u_i2s (
    .clk   (mclk),
    .resetn(sys_resetn),
    .left  (audio_filtered_l[19:4]),
    .right (audio_filtered_r[19:4]),
    .sck   (hp_bck),
    .ws    (hp_ws),
    .sd    (hp_din)
);

// The SDRAM detects port B writes on a rising weB, so each loader byte needs a
// write pulse followed by a low gap before IOSys may send the next one.
reg [2:0] ld_gap = 3'd0;
always @(posedge mclk) begin
    if (!sys_resetn)
        ld_gap <= 3'd0;
    else if (ld_wr)
        ld_gap <= 3'd6;
    else if (ld_gap != 3'd0)
        ld_gap <= ld_gap - 3'd1;
end

assign ld_busy = ld_wr || (ld_gap != 3'd0);
assign ld_idle = !ld_busy && !loader_write_mem && !loader_write_r &&
                 !sdram_busy;
assign pa_en = ~audio_hdmi;
assign O_sdram_clk = fclk_p;
assign led[0] = ~(hdmi_locked & ~sdram_busy);
assign led[1] = ~(game_active && !game_pause);

endmodule
