// ---------------------------------------------------------------------------
// Timing constraints for PC Engine on the Tang Nano 20K
//
//   sys_clk    27.00 MHz  board crystal
//   clk_sys    43.20 MHz  console + SDRAM logic   (pll_main CLKOUT)
//   clk_sdram  43.20 MHz  SDRAM pin clock, 180 deg (pll_main CLKOUTP)
//   clk_pix5  129.60 MHz  TMDS serial clock       (pll_hdmi CLKOUT)
//   clk_pix    25.92 MHz  HDMI pixel clock        (CLKDIV /5)
//
// clk_sys and clk_pix are frequency locked (5:3) but come from two different
// PLLs, so all data crossing between them goes through the toggle/level
// synchronisers in video_scandoubler.v and the two domains are declared
// asynchronous for timing analysis.
// ---------------------------------------------------------------------------

create_clock -name sys_clk   -period 37.037 [get_ports {sys_clk}]

create_clock -name clk_sys   -period 23.148 [get_nets {clk_sys}]
//create_clock -name clk_sdram -period 23.148 [get_nets {clk_sdram}]
create_clock -name clk_sdram -period 23.148 [get_pins {u_pll_main/rpll_inst/CLKOUTP}]
create_clock -name clk_pix5  -period 7.716  [get_nets {clk_pix5}]
create_clock -name clk_pix   -period 38.580 [get_nets {clk_pix}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_sys clk_sdram}] -group [get_clocks {clk_pix5 clk_pix}]

// asynchronous inputs
set_false_path -from [get_ports {s1}]
set_false_path -from [get_ports {uart_rx}]
set_false_path -from [get_ports {pad_data}]

// The SD card answers on CMD/DAT0 in its own clock domain (the card retimes
// them to the sd_clk this design generates, so they are not launched by any
// clock the analyser knows about).  sd_file_reader samples them on the rising
// sd_clk edge, i.e. 2 clk_sys cycles = 46 ns after the falling edge on which
// the card drove them, which is the timing the reader was validated with on
// hardware; there is no launch clock to constrain them against.
set_false_path -from [get_ports {sd_cmd}]
set_false_path -from [get_ports {sd_dat0}]

report_timing -setup -max_paths 25 -max_common_paths 1
report_timing -hold  -max_paths 25 -max_common_paths 1
