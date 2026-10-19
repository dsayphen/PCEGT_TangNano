// 27 MHz reference. The video PLL makes 155.25 MHz TMDS (27*23/4) and CLKDIV5
// gives 31.05 MHz pixels. The main PLL multiplies TMDS by 9/26 for a
// 53.740 MHz console/SDRAM clock (225-degree SDRAM pin clock, /2 Z80 clock).
// Pixel/console ratio is exactly 494/855: one 3420-MCLK console line lasts
// 1976 pixel clocks, i.e. two fixed 988-pixel HDMI lines and 59.975 Hz for
// 262-line NTSC frames (real hardware: 59.92 Hz).
module megadrive_pll (
    input wire clkin,
    output wire mclk, clk_sdram, clk_z80, clk_pixel, clk_serial, locked, video_locked
);
    wire main_lock, video_lock;
    wire unused_main, unused_p, unused_d, unused_d3;
    rPLL #(
        .FCLKIN("27"), .IDIV_SEL(3), .FBDIV_SEL(22), .ODIV_SEL(4),
        .CLKFB_SEL("internal"), .DEVICE("GW2AR-18C")
    ) video (
        .CLKIN(clkin), .CLKOUT(clk_serial), .CLKOUTP(unused_p), .CLKOUTD(unused_d),
        .CLKOUTD3(unused_d3), .LOCK(video_lock), .RESET(1'b0), .RESET_P(1'b0),
        .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    rPLL #(
        .FCLKIN("155.25"), .IDIV_SEL(25), .FBDIV_SEL(8), .ODIV_SEL(16),
        .PSDA_SEL("1010"), .DUTYDA_SEL("1000"), .DYN_SDIV_SEL(2),
        .CLKFB_SEL("internal"), .CLKOUTD_SRC("CLKOUT"), .DEVICE("GW2AR-18C")
    ) main (
        .CLKIN(clk_serial), .CLKOUT(mclk), .CLKOUTP(clk_sdram), .CLKOUTD(clk_z80),
        .CLKOUTD3(unused_main), .LOCK(main_lock), .RESET(!video_lock), .RESET_P(1'b0),
        .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    CLKDIV #(.DIV_MODE("5")) pixels (
        .HCLKIN(clk_serial), .CLKOUT(clk_pixel), .RESETN(video_lock), .CALIB(1'b0)
    );
    assign locked = main_lock && video_lock;
    assign video_locked = video_lock;
endmodule
