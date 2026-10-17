create_clock -name sys_clk -period 37.037 -waveform {0 18.519} [get_ports {sys_clk}]
create_clock -name fclk -period 15.432 -waveform {0 7.716} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 3 [get_nets {mclk}]
create_clock -name hclk5 -period 2.694 -waveform {0 1.347} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -divide_by 5 [get_nets {hclk}]
# Game Boy pixel clock: ~gb_clk, gb_clk = mclk / 5 (4.32 MHz).
create_clock -name gb_cpl -period 231.481 -waveform {0 115.741} [get_nets {gb_cpl}]

set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 1 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

set_false_path -from [get_ports {s1}]
set_false_path -from [get_ports {s2}]
set_false_path -from [get_ports {uart_rx}]
set_false_path -from [get_ports {pad_data}]
