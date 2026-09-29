// ---------------------------------------------------------------------------
// Timing constraints for PC Engine on the Tang Nano 20K
//
//   sys_clk    27.00 MHz  board crystal
//   clk_mem    86.40 MHz  SDRAM controller        (pll_main CLKOUT)
//   clk_sys    43.20 MHz  console logic           (pll_main CLKOUTD /2)
//   clk_sdram  86.40 MHz  SDRAM pin clock, 180 deg (pll_main CLKOUTP)
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
create_clock -name clk_mem   -period 11.574 [get_nets {clk_mem}]
create_clock -name clk_sdram -period 11.574 [get_pins {u_pll_main/rpll_inst/CLKOUTP}]
create_clock -name clk_pix5  -period 7.716  [get_nets {clk_pix5}]
create_clock -name clk_pix   -period 38.580 [get_nets {clk_pix}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_sys clk_mem clk_sdram}] -group [get_clocks {clk_pix5 clk_pix}]

// asynchronous inputs
set_false_path -from [get_ports {s1}]
set_false_path -from [get_ports {s2}]
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

// ---------------------------------------------------------------------------
// HuC6280 core -> CPU_DI is a multicycle path
//
// Every register of HUC6280_CPU and of its MCODE / ALU / AG sub-blocks only
// moves on EN = CPU_CE and CPU_RDY, and CPU_CE is one clk_sys in six at best
// (CPU_CLK_CNT counts 0..5 in high speed, 0..23 in low speed - see the clock
// enable process in rtl/HUC6280/HUC6280.vhd).
//
// The destination, CPU_DI, does reload on every clk_sys, but its only two
// consumers - the CPU core itself and IO_BUF - are both EN gated, so the
// value that has to be right is the one standing at the next CPU_CE, six
// cycles after the address was launched. Four cycles is a conservative bound.
//
// Only the CPU-core-launched paths are relaxed. CPU_DI's other source, the DI
// memory bus, is not clock enabled and stays a genuine single cycle path, so
// -from must stay restricted to the core's registers.
//
// Without this the cone below holds the hundred worst endpoints of the whole
// design (worst setup slack -6.26 ns through
// MCODE -> ADDR_BUS -> rom_a -> the Game Genie comparators -> CPU_DI), which
// is where the placer spends its effort instead of on the paths that really
// are single cycle - starting with the softcore's mem_rdata load path.
// One exact prefix per constraint: the wildcard does not cross a hierarchy
// separator, and several patterns inside a single get_regs brace are ignored
// past the first.
//
// The microcode itself is synthesised into ROM primitives, whose DO pins
// get_regs does not select, so they need a get_pins line of their own. Only
// the _sNN replica suffix is tool generated, MI.ALUCtrl_0 is the VHDL name.
set_multicycle_path -setup 4 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]

report_timing -setup -max_paths 100 -max_common_paths 1
report_timing -hold  -max_paths 25 -max_common_paths 1
