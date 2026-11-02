import io, os, re

SRC = r'E:\FPGA_project\total_project\src'
DOC = r'E:\FPGA_project\report\total_project_技术总结.md'

# ============ 1) 清掉内部工单编号（A7 / A13），保留其后的说明 ============
rules = [
    ('// ★ A7（2026-10-31）：', '// '),
    ('// ★ A7：', '// '),
    ('//---------------- A13：四个增益改为输入（原来是不带位宽的 parameter）----------------',
     '//---------------- 四个增益由寄存器输入（默认值见 param_link）----------------'),
    ('// pos_interp.v  —  A7：编码器位置「边沿间插值」（亚计数 α）',
     '// pos_interp.v  —  编码器位置「边沿间插值」（亚计数位置）'),
    ('// A13：交棒角度窗，Q12（可串口写 0x14）', '// 交棒角度窗，Q12（可串口写 0x14）'),
    ('// ★ A13：TH_CATCH 变成端口后不能再做 localparam，改为 wire（值每拍跟着寄存器走）',
     '// TH_CATCH 是端口（每拍跟着参数寄存器走），不能再当 localparam'),
]
files = [f for f in os.listdir(SRC) if f.endswith('.v')]
n = 0
for f in files:
    p = os.path.join(SRC, f)
    s = io.open(p, encoding='utf-8').read()
    o = s
    for a, b in rules:
        s = s.replace(a, b)
    if s != o:
        io.open(p, 'w', encoding='utf-8').write(s)
        n += 1
print('工单编号清理：修改', n, '个文件')

# ============ 2) 文档同步改名 ============
s = io.open(DOC, encoding='utf-8').read()
o = s
s = s.replace('uart_tx_zzh', 'uart_tx_8n1')
io.open(DOC, 'w', encoding='utf-8').write(s)
print('文档同步:', '已更新' if s != o else '无需改动')

# ============ 3) 全量自检 ============
pat_bad = re.compile(r'zzh|to_zzh|expand_project|Translate|static_balance|pendulum_m2|BOARD\.v|'
                     r'example\.txt|PINMAP|uart_scope|top_pendulum|★ A\d+|A13：')
bad = []
for f in sorted(files):
    for i, line in enumerate(io.open(os.path.join(SRC, f), encoding='utf-8').read().split('\n'), 1):
        if pat_bad.search(line):
            bad.append('%s:%d: %s' % (f, i, line.strip()[:80]))
print('RTL 残留（外部引用 + 工单号）:', len(bad))
for b in bad:
    print('  ' + b)

docleft = [w for w in ['zzh', 'expand_project', 'Translate', 'boot_anim', 'ui_draw', 'gfx'] if w in s]
print('文档残留:', docleft if docleft else 'none')