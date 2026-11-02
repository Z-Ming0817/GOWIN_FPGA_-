import io, os, re

SRC = r'E:\FPGA_project\total_project\src'
GPRJ = r'E:\FPGA_project\total_project\total_project.gprj'

def rd(f):
    return io.open(os.path.join(SRC, f), encoding='utf-8').read()

def wr(f, s):
    io.open(os.path.join(SRC, f), 'w', encoding='utf-8').write(s)

changed = []

# ===================== 1) uart_tx_zzh.v -> uart_tx_8n1.v =====================
old_f, new_f = 'uart_tx_zzh.v', 'uart_tx_8n1.v'
s = rd(old_f)
s = s.replace(
    '// uart_tx_zzh.v  （来自 zzh 工程，硬件已证实可用）  —  参数化 8N1 UART 发送器',
    '// uart_tx_8n1.v  —  参数化 8N1 UART 发送器（遥测帧与参数应答共用）')
s = s.replace('module uart_tx_zzh #(', 'module uart_tx_8n1 #(')
wr(new_f, s)
os.remove(os.path.join(SRC, old_f))
changed.append('%s -> %s（模块名同步）' % (old_f, new_f))

# ===================== 2) uart_frame.v =====================
s = rd('uart_frame.v')
pairs = [
    ('// uart_frame.v — 二进制遥测帧（与 example.txt 的格式一致）',
     '// uart_frame.v — 二进制遥测帧（AA 55，14 字节，大端，XOR 校验）'),
    ('//---------------------- 定点换算（与 zzh 的 uart_scope 完全一致）----------------------',
     '//---------------------- 定点换算 ----------------------'),
    ('//---------------------- UART 发送（用 zzh 的 uart_tx，硬件已验证）----------------------',
     '//---------------------- UART 发送 ----------------------'),
    ('uart_tx_zzh #(', 'uart_tx_8n1 #('),
]
for a, b in pairs:
    if a in s:
        s = s.replace(a, b)
wr('uart_frame.v', s)
changed.append('uart_frame.v（3 处注释 + 例化改名）')

# ===================== 3) param_link.v =====================
s = rd('param_link.v')
for k in ('C1', 'C2', 'C3', 'C4'):
    s = s.replace('// zzh: %s_DEF' % k, '// 默认增益')
s = s.replace('uart_tx_zzh #(', 'uart_tx_8n1 #(')
wr('param_link.v', s)
changed.append('param_link.v（4 处注释 + 例化改名）')

# ===================== 4) total_top.v =====================
s = rd('total_top.v')
pairs = [
    ('//---------------- 观测（与 zzh 严格一致）----------------',
     '//---------------- 状态观测器参数 ----------------'),
    ('// 基准点与显示臂角（与 zzh 的 al_base / pos0+arm_rel 等价）',
     '// 基准点与显示臂角'),
    ('''    //---------------- 显示用臂角（与 zzh 的 pos0/arm_rel 等价）----------------
    //   zzh：定点时 pos0 <= pos_deg，arm_rel 按增量累加并缠绕 ±半圈，
    //        所以“臂角”读数在定点那一刻变成 0，之后从 0 起算。
    //   这里用等价写法：显示臂角 = wrap(al_raw - al_base) 到 ±π。
    //   控制通路仍然用 al_raw 与 al_base（与 zzh 一致，两者互不影响）。''',
     '''    //---------------- 显示用臂角（相对基准点）----------------
    //   定点时记下基准角，读数在定点那一刻变成 0，之后从 0 起算。
    //   实现：显示臂角 = wrap(al_raw - al_base)，缠绕到 ±π。
    //   控制通路仍然用 al_raw 与 al_base，两者互不影响。'''),
    ('// 速度 °/s → Q25 rad/tick：ROT_W = °/s × 292817/1000 ≈ ×293（30 → 8790，与 zzh 一致）',
     '// 速度 °/s → Q25 rad/tick：ROT_W = °/s × 292817/1000 ≈ ×293（30 °/s → 8790）'),
    ('// 角度旋转（逻辑同 Translate_by_fixed_point 的固定角度平移）',
     '// 角度旋转（固定角度平移：限速斜坡参考 + 到位吸附）'),
    ('// Translate 的 lqr 无前馈',
     '// 旋转过程中按无速度前馈处理'),
]
for a, b in pairs:
    if a in s:
        s = s.replace(a, b)
wr('total_top.v', s)
changed.append('total_top.v（6 处注释）')

# ===================== 5) mode_fsm.v =====================
s = rd('mode_fsm.v')
s = s.replace('// 定点只能在停机状态做（与 zzh 的 zero_cmd 条件一致）',
              '// 定点只在停机状态接受（平衡/起摆中改基准会让目标瞬跳）')
wr('mode_fsm.v', s)
changed.append('mode_fsm.v（1 处注释）')

# ===================== 6) gprj =====================
s = io.open(GPRJ, encoding='utf-8').read()
s = s.replace('src/uart_tx_zzh.v', 'src/uart_tx_8n1.v')
io.open(GPRJ, 'w', encoding='utf-8').write(s)
changed.append('total_project.gprj（源文件名同步）')

print('改动清单:')
for c in changed:
    print('  ' + c)

# ===================== 7) 自检 =====================
pat = re.compile(r'zzh|to_zzh|expand_project|Translate|static_balance|pendulum_m2|BOARD\.v|example\.txt|PINMAP|uart_scope|top_pendulum')
left = []
for f in sorted(os.listdir(SRC)):
    if not f.endswith('.v'):
        continue
    body = io.open(os.path.join(SRC, f), encoding='utf-8').read()
    for i, line in enumerate(body.split('\n'), 1):
        if pat.search(line):
            left.append('%s:%d: %s' % (f, i, line.strip()[:80]))
print()
print('残留外部工程字样:', '无 ✓' if not left else '')
for l in left:
    print('  ' + l)