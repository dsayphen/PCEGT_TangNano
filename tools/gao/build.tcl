open_project ./PCE_GT_TangNano_GAO.gprj
set_option -top_module top_tang_nano20k
set_option -include_path .
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2019
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
run all