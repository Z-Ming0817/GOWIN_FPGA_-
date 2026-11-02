# cd E:\FPGA_project\total_project
# D:\FPGA_Gowin\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe script/build.tcl
open_project total_project.gprj
set_option -top_module total_top
set_option -use_sspi_as_gpio 1
run syn
run pnr
exit
