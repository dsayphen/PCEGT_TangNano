create_clock -name sys_clk -period 37.037 [get_ports {sys_clk}]
// mclk = 27 MHz * 23/4 (video PLL) * 9/26 (main PLL fed by clk_serial).
create_generated_clock -name mclk -source [get_ports {sys_clk}] -multiply_by 207 -divide_by 104 [get_pins {clocks/main/CLKOUT}]
create_generated_clock -name clk_z80 -source [get_ports {sys_clk}] -multiply_by 207 -divide_by 208 [get_pins {clocks/main/CLKOUTD}]
create_generated_clock -name clk_sdram -source [get_pins {clocks/main/CLKOUT}] -edges {1 2 3} -edge_shift {11.630 11.630 11.630} [get_pins {clocks/main/CLKOUTP}]
create_generated_clock -name clk_serial -source [get_ports {sys_clk}] -multiply_by 23 -divide_by 4 [get_pins {clocks/video/CLKOUT}]
create_generated_clock -name clk_pixel -source [get_pins {clocks/video/CLKOUT}] -divide_by 5 [get_pins {clocks/pixels/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {mclk clk_z80 clk_sdram}] -group [get_clocks {clk_serial clk_pixel}]
set_false_path -from [get_ports {s1 s2 uart_rx pad_data fpga_reconfig_n}]
// Conservative external budgets; verify against the fitted SDRAM's AC table.
set_input_delay -clock clk_sdram -max 5.5 [get_ports {IO_sdram_dq[*]}]
set_input_delay -clock clk_sdram -min 1.5 [get_ports {IO_sdram_dq[*]}]
set_output_delay -clock clk_sdram -max 2.0 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_cas_n O_sdram_ras_n O_sdram_wen_n}]
set_output_delay -clock clk_sdram -min -1.0 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_cas_n O_sdram_ras_n O_sdram_wen_n}]
set_input_delay -clock mclk -max 10.0 [get_ports {sd_dat0 flash_spi_miso}]
set_input_delay -clock mclk -min 0.0 [get_ports {sd_dat0 flash_spi_miso}]
// These endpoint pairs share the same sparse clock enable, not arbitrary logic.
// JT12 cur_ch/cur_op and phinc_II all advance on clk_en (>=14 MCLKs here).
set_multicycle_path 2 -setup -from [get_pins {core/console/console_0/u_console/fm/u_jt12/u_mmr/u_reg/cur_ch*/Q core/console/console_0/u_console/fm/u_jt12/u_mmr/u_reg/cur_op*/Q}] -to [get_pins {core/console/console_0/u_console/fm/u_jt12/u_pg/phinc_II*/D}]
set_multicycle_path 1 -hold -from [get_pins {core/console/console_0/u_console/fm/u_jt12/u_mmr/u_reg/cur_ch*/Q core/console/console_0/u_console/fm/u_jt12/u_mmr/u_reg/cur_op*/Q}] -to [get_pins {core/console/console_0/u_console/fm/u_jt12/u_pg/phinc_II*/D}]
// LFO output and phase-increment registers share clk_en. LFO advances only
// on clk_en; the phase increment consumes the previous value at the next
// clk_en (at least two MCLKs later, normally fourteen or more).
set_multicycle_path 2 -setup -from [get_pins {core/console/console_0/u_console/fm/u_jt12/gen_lfo.u_lfo/lfo_mod*/Q}] -to [get_pins {core/console/console_0/u_console/fm/u_jt12/u_pg/phinc_II*/D}]
set_multicycle_path 1 -hold -from [get_pins {core/console/console_0/u_console/fm/u_jt12/gen_lfo.u_lfo/lfo_mod*/Q}] -to [get_pins {core/console/console_0/u_console/fm/u_jt12/u_pg/phinc_II*/D}]
// CCR feedback registers capture on enT3, a subset of enPhi1 (every 7 MCLKs,
// TURBO=0). pwrUp overrides the feedback with zero, so it cannot launch it.
set_multicycle_path 2 -setup -from [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/D core/console/console_0/u_console/M68K/excUnit/alu/ccrCore*/D}]
set_multicycle_path 1 -hold -from [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/D core/console/console_0/u_console/M68K/excUnit/alu/ccrCore*/D}]
// IR and both ROM address registers capture only on enT1. The nano address
// register is absorbed into the BSRAM's enabled address port by synthesis.
set_multicycle_path 2 -setup -from [get_pins {core/console/console_0/u_console/M68K/Ir_*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/microAddr*/D core/console/console_0/u_console/M68K/nanoAddr*/AD*}]
set_multicycle_path 1 -hold -from [get_pins {core/console/console_0/u_console/M68K/Ir_*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/microAddr*/D core/console/console_0/u_console/M68K/nanoAddr*/AD*}]
// ALU operation is latched on enT4; CCR captures on the subsequent enT3.
// With TURBO=0, even adjacent phi2/phi1 enables are at least 3 MCLKs apart.
set_multicycle_path 2 -setup -from [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/oper_*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/D core/console/console_0/u_console/M68K/excUnit/alu/ccrCore*/D}]
set_multicycle_path 1 -hold -from [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/oper_*/Q}] -to [get_pins {core/console/console_0/u_console/M68K/excUnit/alu/pswCcr*/D core/console/console_0/u_console/M68K/excUnit/alu/ccrCore*/D}]
// Z80 output shadows load only after the T80 outputs have been stable for
// at least two MCLKs (see z80_shadow_hold in system.sv).
set_multicycle_path 2 -setup -from [get_clocks {clk_z80}] -to [get_pins {core/console/console_0/u_console/Z80_BUSAK_N*/D core/console/console_0/u_console/Z80_MREQ_N*/D core/console/console_0/u_console/Z80_RD_N*/D core/console/console_0/u_console/Z80_WR_N*/D core/console/console_0/u_console/Z80_A_*/D core/console/console_0/u_console/MBUS_DO_*/D core/console/console_0/u_console/ZBUS_DO_*/D}]
set_multicycle_path 1 -hold -from [get_clocks {clk_z80}] -to [get_pins {core/console/console_0/u_console/Z80_BUSAK_N*/D core/console/console_0/u_console/Z80_MREQ_N*/D core/console/console_0/u_console/Z80_RD_N*/D core/console/console_0/u_console/Z80_WR_N*/D core/console/console_0/u_console/Z80_A_*/D core/console/console_0/u_console/MBUS_DO_*/D core/console/console_0/u_console/ZBUS_DO_*/D}]
// Asynchronous assertion; release propagates through both serial-clock stages.
set_false_path -from [get_pins {hdmi_reset_2_s0/Q}] -to [get_clocks {clk_serial}]
report_timing -setup -max_paths 50 -max_common_paths 1
report_timing -hold -max_paths 25 -max_common_paths 1
