// 极简滚动曲线：Canvas 2D，20Hz 数据下比 SVG 更省
const DPR = Math.min(window.devicePixelRatio || 1, 2);

function niceStep(raw) {
  const exp = Math.floor(Math.log10(raw || 1));
  const base = Math.pow(10, exp);
  const n = raw / base;
  const mult = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
  return mult * base;
}

export class StripChart {
  /**
   * @param {HTMLCanvasElement} canvas
   * @param {{label:string, unit:string, color:string, windowMs?:number, minSpan?:number, fixed?:[number,number]}} opts
   */
  constructor(canvas, opts) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.opts = Object.assign(
      { windowMs: 20000, minSpan: 1, color: '#4cc9f0', label: '', unit: '', fixed: null },
      opts
    );
    this.points = [];
    this.range = null;
    this.resize();
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    const w = Math.max(120, Math.round(rect.width));
    const h = Math.max(80, Math.round(rect.height));
    this.canvas.width = w * DPR;
    this.canvas.height = h * DPR;
    this.w = w;
    this.h = h;
  }

  push(t, v) {
    const valid = v !== null && v !== undefined && Number.isFinite(v);
    this.points.push({ t, v: valid ? v : null });
    const cutoff = t - this.opts.windowMs;
    while (this.points.length && this.points[0].t < cutoff) this.points.shift();
    if (this.points.length > 4000) this.points.splice(0, this.points.length - 4000);
  }

  clear() {
    this.points.length = 0;
    this.range = null;
  }

  get latest() {
    for (let i = this.points.length - 1; i >= 0; i -= 1) {
      if (this.points[i].v !== null) return this.points[i].v;
    }
    return null;
  }

  autoRange() {
    if (this.opts.fixed) return this.opts.fixed;
    let lo = Infinity;
    let hi = -Infinity;
    for (const p of this.points) {
      if (p.v === null) continue;
      if (p.v < lo) lo = p.v;
      if (p.v > hi) hi = p.v;
    }
    if (!Number.isFinite(lo)) return this.range || [-1, 1];
    if (hi - lo < this.opts.minSpan) {
      const mid = (hi + lo) / 2;
      const half = this.opts.minSpan / 2;
      lo = mid - half;
      hi = mid + half;
    }
    const pad = (hi - lo) * 0.15;
    return [lo - pad, hi + pad];
  }

  render(now) {
    const { ctx, w, h } = this;
    if (!w || !h) return;
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const padL = 44;
    const padR = 10;
    const padT = 22;
    const padB = 16;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;
    if (plotW <= 10 || plotH <= 10) return;

    const target = this.autoRange();
    if (!this.range) this.range = [...target];
    else {
      this.range[0] += (target[0] - this.range[0]) * 0.12;
      this.range[1] += (target[1] - this.range[1]) * 0.12;
    }
    const [lo, hi] = this.range;
    const span = hi - lo || 1;

    ctx.strokeStyle = 'rgba(255,255,255,0.10)';
    ctx.fillStyle = 'rgba(180,197,214,0.75)';
    ctx.lineWidth = 1;
    ctx.font = '10px ui-monospace, Consolas, monospace';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';

    const step = Math.max(1e-6, niceStep(span / 4) || 1);   // 防止 step=0 死循环
    const first = Math.ceil(lo / step) * step;
    for (let v = first; v <= hi + 1e-9; v += step) {
      const y = padT + plotH - ((v - lo) / span) * plotH;
      ctx.beginPath();
      ctx.moveTo(padL, y + 0.5);
      ctx.lineTo(w - padR, y + 0.5);
      ctx.stroke();
      const dec = step >= 1 ? 0 : step >= 0.1 ? 1 : 2;
      ctx.fillText(v.toFixed(dec), padL - 6, y);
    }

    const tEnd = now || Date.now();
    const tStart = tEnd - this.opts.windowMs;
    const xOf = (t) => padL + ((t - tStart) / this.opts.windowMs) * plotW;
    const yOf = (v) => padT + plotH - ((v - lo) / span) * plotH;

    // 零线
    if (lo < 0 && hi > 0) {
      ctx.strokeStyle = 'rgba(255,255,255,0.22)';
      ctx.beginPath();
      ctx.moveTo(padL, yOf(0));
      ctx.lineTo(w - padR, yOf(0));
      ctx.stroke();
    }

    // 曲线（遇到 null 断开）
    if (this.points.length > 1) {
      ctx.strokeStyle = this.opts.color;
      ctx.lineWidth = 1.6;
      ctx.lineJoin = 'round';
      ctx.beginPath();
      let started = false;
      for (const p of this.points) {
        if (p.v === null) {
          started = false;
          continue;
        }
        const x = xOf(p.t);
        if (x < padL - 2) continue;
        const y = yOf(p.v);
        if (!started) {
          ctx.moveTo(x, y);
          started = true;
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.stroke();

      for (let i = this.points.length - 1; i >= 0; i -= 1) {
        const p = this.points[i];
        if (p.v === null) continue;
        ctx.fillStyle = this.opts.color;
        ctx.beginPath();
        ctx.arc(xOf(p.t), yOf(p.v), 2.6, 0, Math.PI * 2);
        ctx.fill();
        break;
      }
    }

    // 标题
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    ctx.fillStyle = 'rgba(226,234,243,0.92)';
    ctx.font = '11px ui-monospace, Consolas, monospace';
    const cur = this.latest;
    const text = `${this.opts.label}  ${cur === null ? '--' : cur.toFixed(Math.abs(cur) >= 100 ? 0 : 1)}${this.opts.unit}`;
    ctx.fillText(text, padL, 4);
  }
}