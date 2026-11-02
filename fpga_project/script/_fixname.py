import io
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()
s = s.replace("    ) u_lqr (", "    ) u_lqr_ctrl (")
s = s.replace("    ) u_swing (", "    ) u_swing_ctrl (")
io.open(p, 'w', encoding='utf-8').write(s)
print('例化名已改')
