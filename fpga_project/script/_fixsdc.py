import io
p = r'constr\total_project.sdc'
s = io.open(p, encoding='utf-8').read()
s = s.replace('//', '#')
io.open(p, 'w', encoding='utf-8').write(s)
print('注释已改为 #')
