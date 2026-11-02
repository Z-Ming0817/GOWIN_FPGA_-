import io
# 1) gprj 补上 menu_frame
p = r'total_project.gprj'
s = io.open(p, encoding='utf-8').read()
if 'menu_frame.v' not in s:
    s = s.replace('<File path="src/ui_draw.v"',
                  '<File path="src/menu_frame.v" type="file.verilog" enable="1"/>\n        <File path="src/ui_draw.v"')
    io.open(p, 'w', encoding='utf-8').write(s)
    print('gprj +menu_frame')

# 2) sys_reset 参数名改 HOLD_CYC
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()
s = s.replace("sys_reset #(.CLK_FREQ(CLK_FREQ), .HOLD_MS(20)) u_sys_reset (",
              "sys_reset #(.CLK_FREQ(CLK_FREQ), .HOLD_CYC(CLK_FREQ / 50)) u_sys_reset (")
io.open(p, 'w', encoding='utf-8').write(s)
print('sys_reset 参数已改 HOLD_CYC')
