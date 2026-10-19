// Console, SDRAM and resident menu subsystem; also used as a resource probe.
module megadrive_menu_probe #(
    parameter FREQ = 53_693_175
) (
    input wire mclk, clk_z80, clk_sdram, reset_n, clk_pix, pix_resetn, button_reset,
    input wire [11:0] joy1, joy2,
    input wire [10:0] osd_x,
    input wire [9:0] osd_y,
    input wire osd_de,
    output wire osd_on, osd_text, osd_active,
    output wire [23:0] osd_rgb,
    input wire reconfig_pin_high,
    output wire reconfig_pull_low,
    input wire flash_spi_miso, uart_rx, sd_miso,
    output wire flash_spi_cs_n, flash_spi_mosi, flash_spi_clk,
    output wire flash_spi_wp_n, flash_spi_hold_n, uart_tx, sd_clk, sd_mosi, sd_cs_n,
    inout wire [31:0] SDRAM_DQ,
    output wire [10:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire [3:0] SDRAM_DQM,
    output wire SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CLK, SDRAM_CKE,
    output wire [3:0] red, green, blue,
    output wire hs, vs, hblank, vblank, ce_pix, interlace, field,
    output wire [1:0] resolution,
    output wire [15:0] audio_left, audio_right,
    output wire address_fault, init_done, system_reset,
    output wire [1:0] video_zoom, scanline,
    output wire [3:0] audio_volume, audio_bass, audio_treble,
    output wire audio_hdmi,
    output wire [1:0] console_region
);
    wire ld_wr, ld_busy, ld_idle, loading, image_valid, game_pause, game_reset;
    wire [22:0] ld_addr, rv_addr;
    wire [7:0] ld_data;
    wire rv_valid, rv_ready;
    wire [31:0] rv_wdata, rv_rdata;
    wire [3:0] rv_wstrb;
    wire [22:2] host_addr;
    wire [31:0] host_wdata, host_rdata;
    wire [3:0] host_be;
    wire host_we, host_req, host_ack, ram_initializing, protocol_fault, memory_fault;
    // SNES {R,L,X,A,Right,Left,Down,Up,Start,Select,Y,B} to MD {Z,Y,X,Mode,Start,C,B,A,U,D,L,R}.
    wire [11:0] md_joy1 = osd_active ? 12'b0 :
        {joy1[11:9], joy1[2], joy1[3], joy1[8], joy1[0], joy1[1],
         joy1[4], joy1[5], joy1[6], joy1[7]};
    wire [11:0] md_joy2 = osd_active ? 12'b0 :
        {joy2[11:9], joy2[2], joy2[3], joy2[8], joy2[0], joy2[1],
         joy2[4], joy2[5], joy2[6], joy2[7]};
    reg [24:1] rom_words;
    always @(posedge mclk) begin
        if (!reset_n) rom_words <= 0;
        else if (loading && ld_wr) rom_words <= ({1'b0, ld_addr} + 24'd2) >> 1;
    end
    assign address_fault = protocol_fault || memory_fault;

    iosys #(
        .FREQ(FREQ), .RV_BASE(23'h600000), .ROM_MAX_SIZE(32'h600000),
        .ROM_CLEAR_ENABLE(0), .OSD_CHARACTER_BITS(7), .OSD_RAM_STYLE("block_ram"),
        .CORE_ID(16'd6), .RECONFIG_ENABLE(1), .UART_ENABLE(0)
    ) menu (
        .clk(mclk), .resetn(reset_n && init_done),
        .reconfig_pin_high(reconfig_pin_high), .reconfig_pull_low(reconfig_pull_low),
        .clk_pix(clk_pix), .pix_resetn(pix_resetn), .osd_x(osd_x), .osd_y(osd_y),
        .osd_de(osd_de), .osd_on(osd_on), .osd_rgb(osd_rgb),
        .osd_text(osd_text), .osd_active(osd_active), .joy1(joy1),
        .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data),
        .ld_busy(ld_busy), .ld_idle(ld_idle), .loading(loading), .image_valid(image_valid),
        .rom_sz(), .rom_offset(), .nes_mode(), .sgx_mode(), .cd_mode(), .rom_pop(),
        .video_zoom(video_zoom), .scanline(scanline), .game_pause(game_pause),
        .game_reset(game_reset), .system_reset(system_reset), .pad_mode(), .pad_mode_sf2(),
        .cheat_apply(), .cheat_reset(), .cheat_code(), .color_mode(), .nintendo_color(),
        .audio_volume(audio_volume), .audio_bass(audio_bass), .audio_treble(audio_treble),
        .audio_hdmi(audio_hdmi), .audio_cdda_enable(), .audio_adpcm_enable(),
        .vdc_sprites_double(), .console_region(console_region),
        .brm_host_q(8'b0), .brm_host_addr(),
        .brm_host_data(), .brm_host_we(), .brm_host_access(),
        .cd_comm(96'b0), .cd_comm_send(1'b0), .cd_dout(80'b0), .cd_dout_send(1'b0),
        .cd_data_end(1'b0), .cd_reset(1'b0), .cd_fifo_halffull(1'b0),
        .cd_stat(), .cd_stat_strobe(), .cd_dout_req(), .cd_data(), .cd_wr(), .cd_dm(),
        .cd_ack(), .cd_audio_hold(), .cd_phase_dbg(8'b0), .cdda_usedw_dbg(14'b0),
        .adpcm_dbg(8'b0), .refresh_gap_dbg(8'b0), .vid_dcc_dbg(2'b0),
        .vid_hdw_dbg(7'b0), .vid_hds_dbg(7'b0), .vid_hsw_dbg(5'b0),
        .vid_hde_dbg(7'b0), .vid_vsw_dbg(5'b0), .vid_vds_dbg(8'b0),
        .vid_vdw_dbg(9'b0), .vid_vcr_dbg(8'b0), .vid_vce_cr_dbg(8'b0),
        .vid_vce_wr_dbg(16'b0), .vid_px_dbg(10'b0),
        .rv_valid(rv_valid), .rv_ready(rv_ready), .rv_addr(rv_addr),
        .rv_wdata(rv_wdata), .rv_wstrb(rv_wstrb), .rv_rdata(rv_rdata),
        .rv_capture_dbg(64'b0), .rv_bus_dbg(128'b0), .ram_busy(!init_done),
        .rv_scheduler_dbg(16'b0), .loader_host_dbg(16'b0), .loader_uart_owner(1'b0),
        .flash_spi_cs_n(flash_spi_cs_n), .flash_spi_miso(flash_spi_miso),
        .flash_spi_mosi(flash_spi_mosi), .flash_spi_clk(flash_spi_clk),
        .flash_spi_wp_n(flash_spi_wp_n), .flash_spi_hold_n(flash_spi_hold_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .sd_clk(sd_clk), .sd_mosi(sd_mosi),
        .sd_miso(sd_miso), .sd_cs_n(sd_cs_n)
    );
    megadrive_host_bridge bridge (
        .clk(mclk), .resetn(reset_n), .loading(loading),
        .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(ld_busy), .ld_idle(ld_idle),
        .rv_valid(rv_valid), .rv_ready(rv_ready), .rv_addr(rv_addr),
        .rv_wdata(rv_wdata), .rv_wstrb(rv_wstrb), .rv_rdata(rv_rdata),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_be(host_be),
        .host_we(host_we), .host_req(host_req), .host_ack(host_ack), .host_rdata(host_rdata),
        .ram_initializing(ram_initializing), .protocol_fault(protocol_fault)
    );
    megadrive_sdram_probe #(.FREQ(FREQ), .WORK_RAM_BASE(23'h7a0000), .CART_RAM_BASE(23'h7c0000)) console (
        .mclk(mclk), .clk_z80(clk_z80), .clk_sdram(clk_sdram), .reset_n(reset_n),
        .loading(loading || !image_valid || ram_initializing || protocol_fault),
        .console_reset(game_reset || button_reset),
        .pause(game_pause), .joy1(md_joy1), .joy2(md_joy2), .rom_size(rom_words),
        .console_region(console_region),
        .host_addr(host_addr), .host_wdata(host_wdata), .host_be(host_be),
        .host_we(host_we), .host_req(host_req), .host_ack(host_ack), .host_rdata(host_rdata),
        .init_done(init_done), .address_fault(memory_fault), .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_nWE(SDRAM_nWE), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .red(red), .green(green), .blue(blue), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix), .interlace(interlace), .field(field), .resolution(resolution),
        .audio_left(audio_left), .audio_right(audio_right)
    );
endmodule
