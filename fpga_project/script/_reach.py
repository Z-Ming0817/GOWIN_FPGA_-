import io, os, re

SRC = r'E:\FPGA_project\total_project\src'
files = sorted(f[:-2] for f in os.listdir(SRC) if f.endswith('.v'))

# 收集每个文件里"被例化的模块名"：形如  modname #(  或  modname u_xxx (
inst_re = re.compile(r'^\s*([A-Za-z_]\w*)\s*(#\s*\(|\w+\s*\()', re.M)

deps = {}
for f in files:
    s = io.open(os.path.join(SRC, f + '.v'), encoding='utf-8').read()
    # 去掉注释行，避免注释里的模块名干扰
    body = re.sub(r'//.*', '', s)
    found = set()
    for m in inst_re.finditer(body):
        name = m.group(1)
        if name in files and name != f:
            found.add(name)
    deps[f] = found

# 从 total_top 做 BFS
reach = set()
stack = ['total_top']
while stack:
    cur = stack.pop()
    if cur in reach:
        continue
    reach.add(cur)
    for ch in deps.get(cur, ()):
        if ch not in reach:
            stack.append(ch)

unused = [f for f in files if f not in reach]

print('文件总数 :', len(files))
print('可达模块 :', len(reach))
print('不可达   :', len(unused))
print()
print('=== 不可达（可删除）===')
for f in unused:
    # 谁引用了它（若有）
    users = [g for g in files if f in deps.get(g, ())]
    print('  %-16s  被引用处: %s' % (f, users if users else '无'))
print()
print('=== 可达模块清单 ===')
for f in sorted(reach):
    print('  ' + f)