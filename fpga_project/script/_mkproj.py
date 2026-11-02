import io, os

T = r'E:\FPGA_project\total_project'

files = [
    'sys_reset', 'key_debounce', 'ads1120', 'encoder_decoder', 'pos_interp',
    'state_observer', 'cfg_regs', 'mode_fsm', 'swing_ctrl', 'lqr_controller',
    'arm_target', 'tb6612_driver',
    'st7789_spi', 'lcd_init', 'font_cn', 'font_ascii', 'param_rom', 'str_rom',
    'sin_lut', 'gfx', 'ui_core', 'ui_draw', 'boot_anim', 'curve_page',
    'uart_tx', 'uart_tx_zzh', 'uart_rx', 'param_link', 'uart_frame', 'dbg_uart',
    'mon_conv', 'total_top',
]
missing = [f for f in files if not os.path.exists(os.path.join(T, 'src', f + '.v'))]
print('缺少文件:', missing)

lines = []
lines.append('<?xml version="1" encoding="UTF-8"?>')
lines.append('<!DOCTYPE gowin-fpga-project>')
lines.append('<Project>')
lines.append('    <Template>FPGA</Template>')
lines.append('    <Version>5</Version>')
lines.append('    <Device name="GW2A-18C" pn="GW2A-LV18PG256C8/I7">gw2a18c-011</Device>')
lines.append('    <FileList>')
for f in files:
    lines.append('        <File path="src/%s.v" type="file.verilog" enable="1"/>' % f)
lines.append('    </FileList>')
lines.append('</Project>')
io.open(os.path.join(T, 'total_project.gprj'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('total_project.gprj 已生成，文件数', len(files))

# ---------------- 约束文件 ----------------
pins = [
    ('clk',        'T7',  'LVCMOS33'),
    ('rst_n',      'F10', 'LVCMOS33'),
    # ADC (ADS1120)
    ('adc_sclk',   'R8',  'LVCMOS33'),
    ('adc_cs_n',   'P9',  'LVCMOS33'),
    ('adc_mosi',   'N8',  'LVCMOS33'),
    ('adc_miso',   'T6',  'LVCMOS33'),
    ('adc_drdy_n', 'M8',  'LVCMOS33'),
    # 电机 TB6612
    ('pwm_out',    'K12', 'LVCMOS33'),
    ('in1_out',    'P16', 'LVCMOS33'),
    ('in2_out',    'R16', 'LVCMOS33'),
    # 编码器
    ('enc_a',      'K15', 'LVCMOS33'),
    ('enc_b',      'P8',  'LVCMOS33'),
    # 按键
    ('key[0]',     'E10', 'LVCMOS33'),
    ('key[1]',     'N10', 'LVCMOS33'),
    ('key[2]',     'P12', 'LVCMOS33'),
    ('key[3]',     'T13', 'LVCMOS33'),
    ('key[4]',     'D11', 'LVCMOS33'),
    # LCD
    ('lcd_sclk',      'K16', 'LVCMOS33'),
    ('lcd_mosi',      'J14', 'LVCMOS33'),
    ('lcd_cs_n',      'E16', 'LVCMOS33'),
    ('lcd_dc',        'J13', 'LVCMOS33'),
    ('lcd_reset_n',   'F14', 'LVCMOS33'),
    ('lcd_backlight', 'C16', 'LVCMOS33'),
    # 串口
    ('uart_tx',    'F12', 'LVCMOS33'),
    ('uart_rx',    'F13', 'LVCMOS33'),
]
cst = []
for name, pin, io in pins:
    cst.append('IO_LOC  "%s" %s;' % (name, pin))
    if name == 'key[4]':
        cst.append('IO_PORT "%s" IO_TYPE=%s PULL_MODE=DOWN BANK_VCCIO=3.3;' % (name, io))
    elif name in ('adc_drdy_n', 'uart_tx', 'uart_rx', 'enc_a', 'enc_b'):
        cst.append('IO_PORT "%s" IO_TYPE=%s PULL_MODE=UP BANK_VCCIO=3.3;' % (name, io))
    elif name in ('pwm_out', 'in1_out', 'in2_out'):
        cst.append('IO_PORT "%s" IO_TYPE=%s DRIVE=8 BANK_VCCIO=3.3;' % (name, io))
    else:
        cst.append('IO_PORT "%s" IO_TYPE=%s BANK_VCCIO=3.3;' % (name, io))
io.open(os.path.join(T, 'constr', 'total_project.cst'), 'w', encoding='utf-8').write('\n'.join(cst) + '\n')
print('total_project.cst 已生成，引脚数', len(pins))

# ---------------- 构建脚本 ----------------
tcl = """# cd E:\\FPGA_project\\total_project
# D:\\FPGA_Gowin\\Gowin\\Gowin_V1.9.12.03_x64\\IDE\\bin\\gw_sh.exe script/build.tcl
open_project total_project.gprj
set_option -top_module total_top
# adc_drdy_n(M8) 是 SSPI 复用脚，必须当 GPIO 用
set_option -use_sspi_as_gpio 1
run syn
run pnr
exit
"""
io.open(os.path.join(T, 'script', 'build.tcl'), 'w', encoding='utf-8').write(tcl)
print('build.tcl 已生成')