// CSV 录制：收到第一帧就开文件，保留最近 N 个
const fs = require('node:fs');
const path = require('node:path');

const HEADER = [
  'time_ms',
  'adc',
  'theta_deg',
  'theta_dot_dps',
  'phi_deg',
  'phi_dot_dps',
  'u_duty',
  'mode',
  'inv_al',
  'inv_th',
  'raw'
].join(',');

class Recorder {
  /**
   * @param {string} dir 录制目录
   * @param {number} keep 最多保留文件数
   */
  constructor(dir, keep = 10) {
    this.dir = dir;
    this.keep = keep;
    this.stream = null;
    this.filePath = null;
    this.rows = 0;
    this.startedAt = null;
    fs.mkdirSync(dir, { recursive: true });
  }

  get active() {
    return Boolean(this.stream);
  }

  start(now = new Date()) {
    if (this.stream) return this.filePath;
    const stamp = [
      now.getFullYear(),
      String(now.getMonth() + 1).padStart(2, '0'),
      String(now.getDate()).padStart(2, '0')
    ].join('') + '_' + [
      String(now.getHours()).padStart(2, '0'),
      String(now.getMinutes()).padStart(2, '0'),
      String(now.getSeconds()).padStart(2, '0')
    ].join('');

    this.filePath = path.join(this.dir, `live_${stamp}.csv`);
    this.stream = fs.createWriteStream(this.filePath, { flags: 'w' });
    this.stream.write('\uFEFF' + HEADER + '\n');
    this.rows = 0;
    this.startedAt = now.getTime();
    this.prune();
    return this.filePath;
  }

  append(row) {
    if (!this.stream) return;
    const line = [
      row.time_ms,
      row.adc,
      fmt(row.theta_deg, 3),
      fmt(row.theta_dot_dps, 2),
      fmt(row.phi_deg, 2),
      fmt(row.phi_dot_dps, 1),
      fmt(row.u_duty, 0),
      row.mode,
      row.inv_al,
      row.inv_th,
      JSON.stringify(row.raw ?? '')
    ].join(',');
    this.stream.write(line + '\n');
    this.rows += 1;
  }

  stop() {
    if (!this.stream) return null;
    const file = this.filePath;
    this.stream.end();
    this.stream = null;
    this.filePath = null;
    return file;
  }

  prune() {
    try {
      const files = fs
        .readdirSync(this.dir)
        .filter((name) => /^live_.*\.csv$/i.test(name))
        .map((name) => {
          const full = path.join(this.dir, name);
          return { full, mtime: fs.statSync(full).mtimeMs };
        })
        .sort((a, b) => b.mtime - a.mtime);
      for (const item of files.slice(this.keep)) {
        if (this.filePath && item.full === this.filePath) continue;
        fs.unlinkSync(item.full);
      }
    } catch {
      /* 清理失败不影响录制 */
    }
  }
  /** 清空历史录制：删除目录下所有 live_*.csv（正在写的这个也关掉重开） */
  clear() {
    // 先关掉正在写的流，否则 Windows 下删不掉当前文件
    if (this.stream) {
      try { this.stream.end(); } catch { /* ignore */ }
      this.stream = null;
      this.filePath = null;
    }
    this.rows = 0;
    this.startedAt = null;
    let removed = 0;
    try {
      for (const name of fs.readdirSync(this.dir)) {
        if (!/^live_.*\.csv$/.test(name)) continue;
        try { fs.unlinkSync(path.join(this.dir, name)); } catch { /* 占用中，系统会稍后删除 */ }
        removed += 1;
      }
    } catch { /* ignore */ }
    this.seq = 0;
    return removed;
  }


  list() {
    try {
      return fs
        .readdirSync(this.dir)
        .filter((name) => /^live_.*\.csv$/i.test(name))
        .map((name) => {
          const full = path.join(this.dir, name);
          const stat = fs.statSync(full);
          return { name, path: full, size: stat.size, mtime: stat.mtimeMs };
        })
        .sort((a, b) => b.mtime - a.mtime);
    } catch {
      return [];
    }
  }
}

function fmt(value, digits) {
  if (value === null || value === undefined || !Number.isFinite(value)) return '';
  return value.toFixed(digits);
}

module.exports = { Recorder, HEADER };