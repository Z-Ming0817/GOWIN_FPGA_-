// 无硬件时的模拟数据源：按 20Hz 产出与 FPGA 完全同格式的帧。
// 曲线是脚本化的（起摆段用衰减包络模拟甩摆上升），目的是验证
// 「解析 → 三维 → 曲线 → 录制」整条链路，并演示 待机/起摆/平衡 三态。
const { parseLine } = require('./protocol');

const DEG = Math.PI / 180;

const IDLE_UNTIL = 3; // 待机 3s
const SWING_DONE = 11; // 起摆 8s

class Simulator {
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.timer = null;
    this.reset();
  }

  reset() {
    this.t = 0;
    this.mode = 0;
    this.phi = 0;
    this.prevTheta = 178;
  }

  start() {
    if (this.timer) return;
    this.reset();
    this.timer = setInterval(() => this.step(0.05), 50);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  get running() {
    return Boolean(this.timer);
  }

  step(dt) {
    this.t += dt;
    const t = this.t;
    let thetaDeg;
    let phiDeg;
    let u = 0;

    if (t < IDLE_UNTIL) {
      // 待机：摆杆垂在下面轻微晃动
      this.mode = 0;
      thetaDeg = 178 + 3 * Math.sin(2 * Math.PI * 0.25 * t);
      phiDeg = 4 * Math.sin(2 * Math.PI * 0.08 * t);
    } else if (t < SWING_DONE) {
      // 起摆：振幅衰减的摆动，臂跟着来回甩
      this.mode = 3;
      const tau = t - IDLE_UNTIL;
      const env = Math.exp(-0.42 * tau);
      thetaDeg = 174 * env * Math.cos(2 * Math.PI * 0.62 * tau);
      const swing = 220 * (1 - env) + 40;
      phiDeg = swing * Math.sin(2 * Math.PI * 0.62 * tau);
      u = Math.round(2400 * Math.sin(2 * Math.PI * 0.62 * tau));
    } else {
      // 平衡：小幅振荡，臂缓慢漂移
      this.mode = 1;
      const tau = t - SWING_DONE;
      const blend = Math.min(1, tau / 1.2);
      thetaDeg = blend * (2.1 * Math.sin(2 * Math.PI * 0.85 * t) + 0.7 * Math.sin(2 * Math.PI * 2.6 * t));
      phiDeg = 9 * Math.sin(2 * Math.PI * 0.1 * tau);
      this.phi = phiDeg;
    }

    // 加一点 ADC 噪声，更接近实物
    const noise = (Math.random() - 0.5) * 0.3;
    const adc = Math.round(14957 + (thetaDeg + noise) * (10241 / 180)) & 0xffff;
    const aField = this.mode === 3 ? u : Math.round(clamp(phiDeg, -9693, 9693));

    const line =
      `ADC=${String(adc).padStart(5, '0')} ` +
      `A=${aField < 0 ? '-' : '+'}${String(Math.abs(aField)).padStart(4, '0')} ` +
      `I=00${this.mode}`;

    const frame = parseLine(line);
    if (frame) this.onFrame(frame, true);
    this.prevTheta = thetaDeg;
  }
}

function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}

module.exports = { Simulator };