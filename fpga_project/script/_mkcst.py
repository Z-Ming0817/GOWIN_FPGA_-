import io, os

T = r'E:\FPGA_project\total_project'

pins = [
    ('clk',        'T7',  'LVCMOS33'),
    ('rst_n',      'F10', 'LVCMOS33'),
    ('adc_sclk',   'R8',  'LVCMOS33'),
    ('adc_cs_n',   'P9',  'LVCMOS33'),
    ('adc_mosi',   'N8',  'LVCMOS33'),
    ('adc_miso',   'T6',  'LVCMOS33'),
    ('adc_drdy_n', 'M8',  'LVCMOS33'),
    ('pwm_out',    'K12', 'LVCMOS33'),
    ('in1_out',    'P16', 'LVCMOS33'),
    ('in2_out',    'R16', 'LVCMOS33'),
    ('enc_a',      'K15', 'LVCMOS33'),
    ('enc_b',      'P8',  'LVCMOS33'),
    ('key[0]',     'E10', 'LVCMOS33'),
    ('key[1]',     'N10', 'LVCMOS33'),
    ('key[2]',     'P12', 'LVCMOS33'),
    ('key[3]',     'T13', 'LVCMOS33'),
    ('key[4]',     'D11', 'LVCMOS33'),
    ('lcd_sclk',      'K16', 'LVCMOS33'),
    ('lcd_mosi',      'J14', 'LVCMOS33'),
    ('lcd_cs_n',      'E16', 'LVCMOS33'),
    ('lcd_dc',        'J13', 'LVCMOS33'),
    ('lcd_reset_n',   'F14', 'LVCMOS33'),
    ('lcd_backlight', 'C16', 'LVCMOS33'),
    ('uart_tx',    'F12', 'LVCMOS33'),
    ('uart_rx',    'F13', 'LVCMOS33'),
]

cst = []
for name, pin, std in pins:
    cst.append('IO_LOC  "%s" %s;' % (name, pin))
    if name == 'key[4]':
        cst.append('IO_PORT "%s" IO_TYPE=%s PULL_MODE=DOWN BANK_VCCIO=3.3;' % (name, std))
    elif name in ('adc_drdy_n', 'uart_tx', 'uart_rx', 'enc_a', 'enc_b'):
        cst.append('IO_PORT "%s" IO_TYPE=%s PULL_MODE=UP BANK_VCCIO=3.3;' % (name, std))
    elif name in ('pwm_out', 'in1_out', 'in2_out'):
        cst.append('IO_PORT "%s" IO_TYPE=%s DRIVE=8 BANK_VCCIO=3.3;' % (name, std))
    else:
        cst.append('IO_PORT "%s" IO_TYPE=%s BANK_VCCIO=3.3;' % (name, std))

io.open(os.path.join(T, 'constr', 'total_project.cst'), 'w', encoding='utf-8').write('\n'.join(cst) + '\n')
print('cst ok, pins =', len(pins))

tcl = """# cd E:\\FPGA_project\\total_project
# D:\\FPGA_Gowin\\Gowin\\Gowin_V1.9.12.03_x64\\IDE\\bin\\gw_sh.exe script/build.tcl
open_project total_project.gprj
set_option -top_module total_top
set_option -use_sspi_as_gpio 1
run syn
run pnr
exit
"""
io.open(os.path.join(T, 'script', 'build.tcl'), 'w', encoding='utf-8').write(tcl)
print('tcl ok')