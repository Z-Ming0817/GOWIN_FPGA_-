import io, re
p = r'total_project.gprj'
s = io.open(p, encoding='utf-8').read()
dead = ['boot_anim','cfg_regs','curve_page','dbg_uart','gfx','sin_lut','uart_tx','ui_draw']
before = len(re.findall(r'<File path="src/', s))
for m in dead:
    s = re.sub(r'\s*<File path="src/%s\.v"[^/]*/>' % m, '', s)
after = len(re.findall(r'<File path="src/', s))
io.open(p, 'w', encoding='utf-8').write(s)
print('gprj: %d -> %d 个源文件条目' % (before, after))
