import io

p = r'E:\FPGA_project\total_project\src\total_top.v'
s = io.open(p, encoding='utf-8').read()
orig = s

# 1) 在 al_base 之后插入“显示臂角 = 相对基准、缠绕 ±π”
anchor = """    // 旋转：SW3=逆时针(dir_state=2)，SW4=顺时针(dir_state=1)"""
assert anchor in s
add = """    //---------------- 显示用臂角（与 zzh 的 pos0/arm_rel 等价）----------------
    //   zzh：定点时 pos0 <= pos_deg，arm_rel 按增量累加并缠绕 ±半圈，
    //        所以“臂角”读数在定点那一刻变成 0，之后从 0 起算。
    //   这里用等价写法：显示臂角 = wrap(al_raw - al_base) 到 ±π。
    //   控制通路仍然用 al_raw 与 al_base（与 zzh 一致，两者互不影响）。
    localparam signed [16:0] PI_Q12     =  17'sd12868;   // π  ×4096
    localparam signed [16:0] TWO_PI_Q12 =  17'sd25736;   // 2π ×4096

    wire signed [16:0] al_d17   = {al_raw[15], al_raw} - {al_base[15], al_base};
    wire signed [16:0] al_disp_17 = (al_d17 >=  PI_Q12) ? (al_d17 - TWO_PI_Q12) :
                                    (al_d17 <  -PI_Q12) ? (al_d17 + TWO_PI_Q12) : al_d17;
    wire signed [15:0] al_disp  = al_disp_17[15:0];

"""
s = s.replace(anchor, add + anchor, 1)

# 2) 显示量改成相对臂角（曲线、监测页数值）
s = s.replace("        .th (th), .thd (thd), .al (al_raw), .ald (ald_raw),\n        .v_th (v_th), .v_thd (v_thd), .v_al (v_al), .v_ald (v_ald),",
              "        .th (th), .thd (thd), .al (al_disp), .ald (ald_raw),\n        .v_th (v_th), .v_thd (v_thd), .v_al (v_al), .v_ald (v_ald),")

# 3) 遥测帧的臂角字段也用相对臂角（与显示一致）
s = s.replace("        .th     (th),\n        .thd    (thd),\n        .al     (al_raw),\n        .ald    (ald_raw),\n        .u_duty (u_cmd),",
              "        .th     (th),\n        .thd    (thd),\n        .al     (al_disp),      // 与显示一致：定点后从 0 起算\n        .ald    (ald_raw),\n        .u_duty (u_cmd),")

io.open(p, 'w', encoding='utf-8').write(s)
print('changed =', s != orig)
print('al_disp 出现次数 =', s.count('al_disp'))