// Experimental NTSC Mega Drive board profile with selectable HDMI/I2S audio.
module top_tang_nano20k_megadrive (
    input wire sys_clk, s1, s2, uart_rx,
    inout wire fpga_reconfig_n,
    output wire uart_tx,
    output wire [1:0] led,
    output wire sd_clk, sd_cmd, sd_dat1, sd_dat2, sd_dat3,
    input wire sd_dat0,
    output wire flash_spi_cs_n, flash_spi_mosi, flash_spi_clk, flash_spi_wp_n, flash_spi_hold_n,
    input wire flash_spi_miso,
    output wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
    inout wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0] O_sdram_ba,
    output wire [3:0] O_sdram_dqm,
    output wire tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n,
    output wire pa_en, hp_bck, hp_ws, hp_din, pad_clk, pad_latch,
    input wire pad_data
);
    wire mclk, clk_sdram, clk_z80, clk_pixel, clk_serial, locked, video_locked;
    megadrive_pll clocks (.*,.clkin(sys_clk));
    reg [15:0] reset_count = 16'hffff;
    reg resetn = 0;
    wire system_reset;
    always @(posedge mclk) begin
        if (!locked || system_reset) begin
            reset_count <= 16'hffff;
            resetn <= 0;
        end else if (reset_count != 0) reset_count <= reset_count - 1'b1;
        else resetn <= 1;
    end
    reg [2:0] pix_reset = 0, button1 = 0, button2 = 0;
    always @(posedge clk_pixel) pix_reset <= {pix_reset[1:0], resetn && locked};
    // HDMI raster depends only on the video PLL, so it keeps a signal through
    // console resets (and a black screen shows a dead console clock).
    reg [2:0] hdmi_reset = 0;
    always @(posedge clk_pixel) hdmi_reset <= {hdmi_reset[1:0], video_locked};
    always @(posedge mclk) begin
        button1 <= {button1[1:0], s1};
        button2 <= {button2[1:0], s2};
    end
    wire [11:0] buttons;
    wire [11:0] joy1 = buttons | {9'b0, button2[2], 2'b0};
    snes_gamepad #(.TICK_DIV(324)) pad (
        .clk(mclk), .resetn(resetn), .pad_clk(pad_clk),
        .pad_latch(pad_latch), .pad_data(pad_data), .buttons(buttons)
    );
    wire reconfig_pin_high, reconfig_pull_low;
    IOBUF reload (.I(1'b0), .OEN(~reconfig_pull_low), .O(reconfig_pin_high), .IO(fpga_reconfig_n));
    wire [10:0] osd_x;
    wire [9:0] osd_y;
    wire osd_de, osd_on, osd_text, osd_active;
    wire [23:0] osd_rgb;
    wire [3:0] red, green, blue;
    wire hs, vs, hblank, vblank, ce_pix, interlace, field;
    wire [1:0] resolution, video_zoom, scanline;
    wire [15:0] audio_left, audio_right;
    wire [3:0] audio_volume;
    wire audio_hdmi;
    wire [1:0] console_region;
    wire fault, ready;
    megadrive_menu_probe #(.FREQ(53_740_385)) core (
        .mclk(mclk), .clk_z80(clk_z80), .clk_sdram(clk_sdram), .reset_n(resetn),
        .clk_pix(clk_pixel), .pix_resetn(pix_reset[2]), .button_reset(button1[2]),
        .joy1(joy1), .joy2(12'b0), .osd_x(osd_x), .osd_y(osd_y), .osd_de(osd_de),
        .osd_on(osd_on), .osd_text(osd_text), .osd_active(osd_active), .osd_rgb(osd_rgb),
        .reconfig_pin_high(reconfig_pin_high), .reconfig_pull_low(reconfig_pull_low),
        .flash_spi_miso(flash_spi_miso), .uart_rx(uart_rx), .sd_miso(sd_dat0),
        .flash_spi_cs_n(flash_spi_cs_n), .flash_spi_mosi(flash_spi_mosi), .flash_spi_clk(flash_spi_clk),
        .flash_spi_wp_n(flash_spi_wp_n), .flash_spi_hold_n(flash_spi_hold_n), .uart_tx(uart_tx),
        .sd_clk(sd_clk), .sd_mosi(sd_cmd), .sd_cs_n(sd_dat3),
        .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), .SDRAM_DQM(O_sdram_dqm),
        .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
        .SDRAM_nWE(O_sdram_wen_n), .SDRAM_CLK(O_sdram_clk), .SDRAM_CKE(O_sdram_cke),
        .red(red), .green(green), .blue(blue), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix), .interlace(interlace), .field(field), .resolution(resolution),
        .audio_left(audio_left), .audio_right(audio_right), .address_fault(fault),
        .init_done(ready), .system_reset(system_reset), .video_zoom(video_zoom), .scanline(scanline),
        .audio_volume(audio_volume), .audio_bass(), .audio_treble(), .audio_hdmi(audio_hdmi),
        .console_region(console_region)
    );
    wire [23:0] rgb;
    wire out_hs, out_vs, out_de;
    wire [10:0] pixel_x;
    wire [9:0] pixel_y;
    wire [9:0] frame_height;
    megadrive_video scaler (
        .clk(mclk), .resetn(resetn), .ce(ce_pix), .hblank(hblank), .vblank(vblank),
        .rgb({red,green,blue}), .clk_pixel(clk_pixel), .pixel_resetn(hdmi_reset[2]),
        .v30(resolution[1]),
        .pal(console_region[1]),
        .zoom(video_zoom), .scanline(scanline), .overlay(osd_on), .overlay_rgb(osd_rgb),
        .osd_x(osd_x), .osd_y(osd_y), .osd_de(osd_de),
        .out_rgb(rgb), .hs(out_hs), .vs(out_vs), .de(out_de), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .frame_height(frame_height)
    );
    wire clk_audio;
    wire [15:0] hdmi_left, hdmi_right;
    dvi_tx #(.HDMI_AUDIO(1), .SERIAL_RESET_SYNC(1), .H_TOTAL(988),
             .ACTIVE_X(0), .ACTIVE_Y(0), .AUDIO_SAMPLES_PER_PACKET(1),
             .PREAMBLE_NEXT_LINE(1), .AUDIO_ACR_COUNTER_BITS(15)) video (
        .clk_pix(clk_pixel), .clk_pix5(clk_serial), .resetn(hdmi_reset[2]),
        .r(rgb[23:16]), .g(rgb[15:8]), .b(rgb[7:0]), .de(out_de),
        .hsync(out_hs), .vsync(out_vs), .pix_x(pixel_x), .pix_y(pixel_y),
        .frame_height(frame_height),
        .audio_enable(audio_hdmi), .clk_audio(clk_audio), .audio_left(hdmi_left), .audio_right(hdmi_right),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );
    wire [19:0] gained_left, gained_right;
    audio_tone #(.TONE_ENABLE(0)) volume (
        .clk(mclk), .resetn(resetn), .volume(audio_volume), .bass(4'd5), .treble(4'd5),
        .in_l({audio_left,4'b0}), .in_r({audio_right,4'b0}),
        .out_l(gained_left), .out_r(gained_right)
    );
    wire [15:0] sample_left = (osd_active || fault) ? 16'b0 : gained_left[19:4];
    wire [15:0] sample_right = (osd_active || fault) ? 16'b0 : gained_right[19:4];
    audio_sampler_48k #(.CLOCK_HZ(53_740_385)) hdmi_sampler (
        .clk_sys(mclk), .resetn(resetn && ready),
        .audio_left({sample_left, 4'b0}), .audio_right({sample_right, 4'b0}),
        .clk_audio(clk_audio), .sample_left(hdmi_left), .sample_right(hdmi_right)
    );
    i2s_tx #(.BCK_DIV(18)) audio (
        .clk(mclk), .resetn(resetn && ready), .left(sample_left), .right(sample_right),
        .sck(hp_bck), .ws(hp_ws), .sd(hp_din)
    );
    assign pa_en = resetn && ready && !audio_hdmi;
    assign sd_dat1 = 1;
    assign sd_dat2 = 1;
    assign led = {~fault, ~ready};
endmodule
