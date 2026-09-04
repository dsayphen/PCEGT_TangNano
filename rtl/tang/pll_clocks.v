//
// Clock generation for the Tang Nano 20K PC Engine port.
//
// Board reference clock is 27 MHz.  Two rPLLs (the GW2AR-18 has two) and one
// CLKDIV are used:
//
//   pll_main : 27 MHz * 8 / 5             = 43.200 MHz  system / SDRAM clock
//              clkoutp is the same clock shifted by 180 degrees and is fed to
//              the SDRAM clock pin so that the memory samples in the middle of
//              the data eye.
//              VCO = 43.2 * 16 = 691.2 MHz, PFD = 27/5 = 5.4 MHz.
//
//   pll_hdmi : 27 MHz * 24 / 5            = 129.600 MHz TMDS serial clock
//              VCO = 129.6 * 8 = 1036.8 MHz, PFD = 5.4 MHz.
//   clkdiv5  : 129.6 / 5                  = 25.920 MHz  HDMI pixel clock
//
// The nominal PC Engine master clock is 21.477 MHz (system clock 42.954 MHz).
// 42.954 MHz cannot be produced from 27 MHz by an rPLL: the exact ratio is
// 35/22 and IDIV = 22 would put the phase detector at 1.23 MHz, far below the
// 3 MHz minimum.  43.2 MHz is the closest usable ratio and runs the console
// 0.57 % fast, which is inaudible/invisible.
//
// 43.2 MHz and 25.92 MHz are in an exact 5:3 relationship, which is what makes
// the genlocked line doubler in video_scandoubler.v possible:  one PCE scan
// line is 2730 system clocks = 1638 pixel clocks = exactly two HDMI lines of
// 819 pixels.
//
// rPLL/CLKDIV instantiation style follows the Sipeed Tang Nano 20K examples
// (https://github.com/sipeed/TangNano-20K-example, GPLv3).
//

module pll_main (
    input  wire clkin,      // 27 MHz
    output wire clkout,     // 43.2 MHz
    output wire clkoutp,    // 43.2 MHz, 180 degrees
    output wire lock
);

wire gw_gnd = 1'b0;
wire clkoutd_o;
wire clkoutd3_o;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.IDIV_SEL = 4;        // /5
defparam rpll_inst.FBDIV_SEL = 7;       // *8
defparam rpll_inst.ODIV_SEL = 16;       // VCO = 691.2 MHz
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.PSDA_SEL = "1000";   // CLKOUTP shifted by 8/16 = 180 deg
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2AR-18C";

endmodule


module pll_hdmi (
    input  wire clkin,      // 27 MHz
    output wire clkout,     // 129.6 MHz (5 x pixel clock)
    output wire lock
);

wire gw_gnd = 1'b0;
wire clkoutp_o;
wire clkoutd_o;
wire clkoutd3_o;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp_o),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.IDIV_SEL = 4;        // /5
defparam rpll_inst.FBDIV_SEL = 23;      // *24
defparam rpll_inst.ODIV_SEL = 8;        // VCO = 1036.8 MHz
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.PSDA_SEL = "0000";
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2AR-18C";

endmodule


module clkdiv5 (
    input  wire hclkin,     // 129.6 MHz
    input  wire resetn,
    output wire clkout      // 25.92 MHz
);

wire gw_gnd = 1'b0;

CLKDIV clkdiv_inst (
    .CLKOUT(clkout),
    .HCLKIN(hclkin),
    .RESETN(resetn),
    .CALIB(gw_gnd)
);

defparam clkdiv_inst.DIV_MODE = "5";
defparam clkdiv_inst.GSREN = "false";

endmodule
