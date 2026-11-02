import io, os

T = r'E:\FPGA_project\total_project'

# ---------------- SDC：50MHz 主时钟 + LCD 输出延时 ----------------
sdc = """#=============================================================================
# total_project.sdc — 50 MHz 主时钟（T7）
#   合并 zzh(pendulum.sdc) 与 expand_project(expand_project.sdc) 的约束
#=============================================================================

//---------------- 主时钟 50MHz ----------------
create_clock -name clk -period 20.000 -waveform {0 10.000} [get_ports {clk}]

//---------------- 异步输入 ----------------
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {adc_drdy_n}]

//---------------- SPI 输入（ADC MISO，2.5MHz SCLK）----------------
set_input_delay -max 10 -clock clk [get_ports {adc_miso}]
set_input_delay -min 0  -clock clk [get_ports {adc_miso}]

//---------------- LCD 输出 ----------------
set_output_delay -clock clk -max 5.000 [get_ports {
   lcd_sclk lcd_mosi lcd_cs_n lcd_dc lcd_reset_n lcd_backlight
}]
set_output_delay -clock clk -min -1.000 [get_ports {
   lcd_sclk lcd_mosi lcd_cs_n lcd_dc lcd_reset_n lcd_backlight
}]
"""
io.open(os.path.join(T, 'constr', 'total_project.sdc'), 'w', encoding='utf-8').write(sdc)
print('sdc 已生成')

# ---------------- gprj 引用约束 ----------------
p = os.path.join(T, 'total_project.gprj')
s = io.open(p, encoding='utf-8').read()
if 'total_project.cst' not in s:
    s = s.replace('    </FileList>',
"""    </FileList>
    <Constraints>
        <File path="constr/total_project.cst" type="file.cst" enable="1"/>
        <File path="constr/total_project.sdc" type="file.sdc" enable="1"/>
    </Constraints>""")
    io.open(p, 'w', encoding='utf-8').write(s)
    print('gprj 已引用 cst/sdc')
else:
    print('gprj 已有约束')
print(io.open(p, encoding='utf-8').read()[-400:])