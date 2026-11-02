import io
p = r'src\total_top.v'
s = io.open(p, encoding='utf-8').read()

old = """    wire signed [15:0] al_ref_rot;

    ref_gen #(.STEP_Q12(16'sd2)) u_ref_gen ("""
new = """    wire signed [15:0] al_ref_rot;

    // ★ step_active / step_arrived 必须在 ref_gen 例化【之前】声明：
    //   438 行的 .en(bal_en & step_active) 用到了它，先声明后使用
    reg  step_active;
    wire step_arrived = (al_ref_rot == ref_rot);
    wire step_done    = step_active & step_arrived;

    ref_gen #(.STEP_Q12(16'sd2)) u_ref_gen ("""
assert old in s, 'ref_gen 例化前的位置没找到'
s = s.replace(old, new, 1)

# 删掉后面重复的那三行
dup = """
    wire step_arrived = (al_ref_rot == ref_rot);
    reg  step_active;
    wire step_done    = step_active & step_arrived;
"""
assert dup in s, '重复声明块没找到'
s = s.replace(dup, "\n", 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('声明顺序已修正')
