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

// HuC6280 core -> CPU_DI is a multicycle path. The CPU core and its
// microcode/ALU registers only advance on CPU_CE, while CPU_DI reloads every
// clk_sys. Keep the actual PicoRV32 memory path single-cycle.
set_multicycle_path -setup 4 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]

// Same CPU_CE argument for the two other CPU-launched endpoints. PSG writes are
// gated by EN = CPU_CE and CPU_RDY, so they land at the next CPU_CE (>= 6 clk).
// The Arcade Card registers capture on the rising edge of RD_N/WR_N, which the
// CPU raises 3 clk after the core advanced, i.e. on the 4th edge: no margin.
set_multicycle_path -setup 4 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -hold 3 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/CPU/PSG/*}]
set_multicycle_path -setup 4 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -hold 3 -from [get_pins {u_pce/CORE/CPU/CORE/MCODE/MI.ALUCtrl_0_*/DO[*]}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/MCODE/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/CPU/CORE/AG/*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]

// RESET_N only changes on reset transitions and the first CPU_CE follows by 6 clk.
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/RESET_N*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/RESET_N*}] -to [get_regs {u_pce/CORE/CPU/CPU_DI*}]
set_multicycle_path -setup 4 -from [get_regs {u_pce/CORE/RESET_N*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]
set_multicycle_path -hold 3 -from [get_regs {u_pce/CORE/RESET_N*}] -to [get_regs {u_pce/CORE/generate_AC.AC/port_*}]

report_timing -setup -max_paths 100 -max_common_paths 1
report_timing -hold  -max_paths 25 -max_common_paths 1
