import io
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()
s = s.replace("    wire       bal_en, sw_en, sw_ready, zero_pulse;",
              "    wire       bal_en, sw_en, sw_ready;   // zero_pulse 已在前面声明")
io.open(p, 'w', encoding='utf-8').write(s)
print('重复声明已去掉')
