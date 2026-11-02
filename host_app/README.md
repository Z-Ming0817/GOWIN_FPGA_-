# 旋转倒立摆上位机（InvertedPendulumMonitor）

面向 `E:\FPGA_project\to_zzh`（已完整跑通「起摆 → 平衡」的那套旋转倒立摆）的实时监视上位机。
**只读**：只用现固件的 115200 / 20 Hz ASCII 报文，不向板子发任何命令。

![界面](docs/screenshot.png)

---

## 1. 直接运行（免安装）

双击：

```
E:\FPGA_project\host_app\release\InvertedPendulumMonitor-win32-x64\InvertedPendulumMonitor.exe
```

整个 `release\InvertedPendulumMonitor-win32-x64\` 目录可整体拷走（U 盘/别的机器都行），不需要 Node、不需要装运行时。
录制文件写在 **exe 同级目录的 `recordings\`**。

> 本机显卡的 Chromium GPU 进程起不来（`gpu_process_host error_code=18` → `FATAL: GPU process isn't usable`，
> 表现为双击后窗口闪一下就没了），所以程序**默认强制软件光栅（SwiftShader）**，3D 一样流畅。
> 想试硬件加速：命令行先 `set PM_GPU=1` 再启动。

## 2. 界面

| 区域 | 内容 |
| --- | --- |
| 顶栏 | 串口下拉（点「刷新」重新枚举）、波特率、`连接`、`模拟数据`；右侧为帧率、累计帧数、录制指示灯 |
| 左上标签 | 当前模式：`空闲 IDLE` / `平衡 BALANCE` / `起摆 SWING` / `故障 FAULT` |
| 中间 3D | **真实比例**的转台 + 旋转臂(r) + 摆杆(L)，鼠标左键拖拽旋转、滚轮缩放、右键平移；摆杆尖端拖出运动轨迹 |
| 右上读数 | 摆角 θ、摆角速度 θ̇、臂角 φ（累计）、臂角速度 φ̇、ADC 原始码值、占空比 u（仅起摆） |
| 原始报文 | 最近收到的原始行（滚动），用来确认「界面上的数确实来自串口」 |
| 本次录制 | 自动保存的 CSV 列表（最近 10 个），点「打开目录」直达 |
| 底部曲线 | θ / θ̇ / φ / φ̇ 四条滚动 20 s 曲线，与读数同源同刻度 |

**模拟数据** 按钮：本机内置一个按真实参数跑的运动学模拟（起摆 ±174° 摆动 → 收幅 → 接手平衡 → 维持 ±3°），
用于**没有硬件时验证整条链路**（3D 姿态、读数、曲线、录制全部照常工作）。

## 3. 报文与解析

现固件每 50 ms 发一行 25 字节定宽 ASCII（`to_zzh/rtl/uart_report2.v`）：

```
ADC=14612 A=+1739 I=003\r\n
```

| 字段 | 含义 | 本机的处理 |
| --- | --- | --- |
| `ADC=` | ADS1120 原始码值（5 位） | 直接显示；`θ = (ADC - ANG_MID) × 360 / ANG_SPAN`，并按 ±180° 缠绕 |
| `A=` | **臂角 φ**，1° 分辨率、±9693°、不缠绕 | 直接显示（4 位 `+`/`-`），速度由差分得到 |
| `I=` | 3 位：`inv_al` `inv_th` `mode` | `mode` 1 位起串口/K1 切换；bit0=inv_al，bit1=inv_th |

θ̇ / φ̇ 由相邻帧做中心差分 + `DERIV_WINDOW` 点滑动平均（默认 5 帧 ≈ 250 ms）。
**注意**：固件给的是**四舍五入整度数**，所以 θ̇ 在 ±3°/s 级别的分辨率噪声是报文本身的极限，不是上位机算错。

## 4. 参数（`config.json`，exe 同级）

```json
{
  "ANG_MID": 14957,        // 摆杆竖直时的 ADC 码值（实测）
  "ANG_SPAN": 10241,       // 摆杆 -180°..+180° 对应的码值跨度（实测）
  "INV_TH": 0,             // 摆角方向取反（串口命令可覆盖）
  "INV_AL": 0,             // 臂角方向取反
  "THETA_WRAP_DEG": 360,   // 摆角显示缠绕范围
  "ARM_LEN_M": 0.156,      // 旋转臂长度 r
  "ROD_LEN_M": 0.135,      // 摆杆长度 L（质心在 L/2）
  "BAUD": 115200,
  "KEEP_RECORDINGS": 10,   // 录制保留个数
  "DERIV_WINDOW": 5
}
```

`ANG_MID / ANG_SPAN` 来自对 `to_zzh` 的实测标定，改机械或改芯片配置后需要重标。

## 5. 录制

- 收到第一帧有效数据即自动开录，断开后停；文件形如 `live_20261029_170040.csv`（时间戳 = 开始时刻）。
- 表头：`t_ms,raw,adc,theta_deg,phi_deg,mode,inv_al,inv_th`（`t_ms` 为解析侧毫秒时间戳，`raw` 为原始行）。
- 只保留最近 `KEEP_RECORDINGS` 个，更早的自动删。

## 6. 开发模式

```powershell
cd E:\FPGA_project\host_app
npm install
npm run start      # = 构建 renderer bundle + 启动 electron
npm run watch      # 改 src/renderer/*.js 后自动重建
pwsh -File pack-build.ps1   # 重新打包到 release\
```

技术栈：Electron 38 + three.js（3D）+ 手写 Canvas 2D 曲线 + `serialport`（Node 端串口）。
渲染进程只做显示，串口/解析/录制全在主进程，通过 IPC 推帧。

## 7. 目录

```
host_app/
├── src/main/      main.js（窗口/串口/IPC）protocol.js（解析）recorder.js（CSV）simulator.js（模拟）
├── src/preload/   渲染进程安全的桥
├── src/renderer/  index.html / style.css / app.js / scene.js（three）/ chart.js（曲线）
├── dist/          renderer.bundle.js（esbuild 产物，运行时需要）
├── docs/          后续固件改进方案.md
├── release/       打包好的免安装 exe
├── config.json    标定与显示参数
└── recordings/    每次运行的 CSV（上限 10 个）
```

## 8. 已知限制（都是**现固件**决定的，不是上位机的问题）

1. **20 Hz、1° 分辨率**：起摆到平衡的快速段落看得清，但 100 Hz 级别的动态、±0.5° 的分辨率做不到 → 见 `docs/后续固件改进方案.md`。
2. **只有 ADC 一路**：臂角是固件在板内自己算好发出来的整数度，主机拿不到「两路独立原始值」。
3. **单向**：上位机不能下发参数/命令（只能看）。
4. 报文无校验、无序号，靠格式严格匹配丢弃噪声行（`st-msg` 会显示「已丢弃 N 行非报文数据」）。