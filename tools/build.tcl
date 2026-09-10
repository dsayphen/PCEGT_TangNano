# Gowin EDA batch build for the Tang Nano 20K PC Engine port.
#
# Run from the repository root with the Gowin shell, e.g.
#
#   & "G:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe" tools/build.tcl
#
# Outputs land in impl/gwsynthesis (netlist + resource reports) and impl/pnr
# (place & route reports, timing report and the .fs bitstream).

open_project ./PCE_GT_TangNano.gprj
run all
