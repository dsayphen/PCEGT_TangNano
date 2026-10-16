create_clock -name sys_clk -period 37.037 -waveform {0 18.519} [get_ports {sys_clk}]
create_clock -name fclk -period 11.574 -waveform {0 5.787} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 4 [get_nets {mclk}]
create_clock -name hclk5 -period 7.937 -waveform {0 3.968} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -divide_by 5 [get_nets {hclk}]

set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 1 -setup -end -from [get_nets {vram?_req}] -to [get_clocks {fclk}]
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

set_false_path -from [get_ports {s1}]
set_false_path -from [get_ports {s2}]
set_false_path -from [get_ports {uart_rx}]
set_false_path -from [get_ports {pad_data}]
report_timing -setup -max_paths 100 -max_common_paths 1
report_timing -hold -max_paths 25 -max_common_paths 1