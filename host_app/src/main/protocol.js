// FPGA 遥测帧解析
//
// 【v3 二进制帧】static_balance / Translate_by_fixed_point / Balancing_circles /
//                expand_project（uart_frame.v），每 50ms 一帧 14 字节，大端：
//
//   偏移  内容          格式   说明
//   0-1   AA 55         帧头
//   2     status        u8     bit0=平衡中 bit1=ZERO已锁存 bit2=故障 bit7:4=mode
//   3-4   臂角          u16    0.01°，0~35999
//   5-6   摆杆角        u16    0.01°，0~35999（底部 = 0）
//   7-8   臂速          s16    0.1°/s
//   9-10  杆速          s16    0.1°/s
//   11-12 占空比 u      s16    ±2500（矩形方波占空比）
//   13    XOR           校验   字节 0~12 异或
//
// 【v1 ASCII 帧】to_zzh 的 uart_report2.v（保留兼容）：
//   "ADC=14920 A=+0045 I=001\r\n"

const V3_LEN = 14;
const V3_HEAD0 = 0xaa;
const V3_HEAD1 = 0x55;

const V2_RE = /ADC=(\d{1,5})\s+T=([+-])(\d{1,4})\s+W=([+-])(\d{1,4})\s+A=([+-])(\d{1,4})\s+V=([+-])(\d{1,4})(?:\s+P=(\d))?/;
const V4_RE = /^T=([+-])(\d{1,4})\s+W=([+-])(\d{1,4})\s+A=([+-])(\d{1,4})\s+V=([+-])(\d{1,4})(?:\s+U=([+-])(\d{1,4}))?/;
const V1_RE = /ADC=(\d{1,5})\s+A=([+-])(\d{1,4})(?:\s+U=([+-])(\d{1,4}))?\s+I=([01])([01])(\d)/;

const MODE_NAMES = { 0: 'IDLE', 1: 'BALANCE', 2: 'FAULT', 3: 'SWING' };

function sgn(s) {
  return s === '-' ? -1 : 1;
}

/** 有符号 16 位 */
function s16(hi, lo) {
  const v = (hi << 8) | lo;
  return v >= 0x8000 ? v - 0x10000 : v;
}

/**
 * 从字节流里切出完整的二进制帧。
 * 返回 { frames: Buffer[], rest: Buffer }
 */
function splitFrames(buffer) {
  const frames = [];
  let i = 0;
  while (i < buffer.length) {
    // 找帧头 0xAA55
    if (buffer[i] !== V3_HEAD0) { i++; continue; }
    if (i + 1 >= buffer.length) break;              // 等下一字节
    if (buffer[i + 1] !== V3_HEAD1) { i++; continue; }

    if (i + V3_LEN > buffer.length) break;          // 帧还没收全

    let x = 0;
    for (let k = 0; k < V3_LEN - 1; k++) x ^= buffer[i + k];
    if (x !== buffer[i + V3_LEN - 1]) { i++; continue; }   // 校验错，往前挪一位

    frames.push(buffer.subarray(i, i + V3_LEN));
    i += V3_LEN;
  }
  return { frames, rest: buffer.subarray(i) };
}

/** 解析一帧二进制数据 */
function parseBinaryFrame(b) {
  const status = b[2];
  const arm = (b[3] << 8) | b[4];
  const pend = (b[5] << 8) | b[6];
  const armSpd = s16(b[7], b[8]);
  const rodSpd = s16(b[9], b[10]);
  const u = s16(b[11], b[12]);

  const hex = Array.from(b, (v) => v.toString(16).padStart(2, '0').toUpperCase()).join(' ');

  return {
    fmt: 'v3',
    status,
    balanced: !!(status & 0x01),      // bit0 平衡中
    swinging: !!(status & 0x02),      // bit1 起摆中
    zeroLatched: !!(status & 0x08),   // bit3 已 ZERO
    fault: !!(status & 0x04),         // bit2 故障
    mode: (status >> 4) & 0x0f,
    modeName: MODE_NAMES[(status >> 4) & 0x0f] ?? null,
    arm,          // 0.01°，0~35999
    pend,         // 0.01°，底部=0
    armSpd,       // 0.1°/s
    rodSpd,       // 0.1°/s
    u,            // 占空比 ±2500
    raw: hex
  };
}

/** 解析一行 ASCII（v1 / v2）。失败返回 null。 */
function parseLine(line) {
  const text = String(line).trim();
  if (!text) return null;

  let m = V4_RE.exec(text);
  if (m) {
    const alv = sgn(m[5]) * Number(m[6]);
    return {
      fmt: 'v4',
      adc: null,
      th: sgn(m[1]) * Number(m[2]),
      thd: sgn(m[3]) * Number(m[4]),
      al: alv,
      ald: sgn(m[7]) * Number(m[8]),
      u: m[9] ? sgn(m[9]) * Number(m[10]) : 0,
      page: null,
      aField: alv / 10,
      mode: null,
      modeName: null,
      raw: text
    };
  }

  m = V2_RE.exec(text);
  if (m) {
    const adc = Number(m[1]);
    if (adc > 32767) return null;
    const alv2 = sgn(m[6]) * Number(m[7]);
    return {
      fmt: 'v2',
      adc,
      th: sgn(m[2]) * Number(m[3]),
      thd: sgn(m[4]) * Number(m[5]),
      al: alv2,
      ald: sgn(m[8]) * Number(m[9]),
      page: m[10] ? Number(m[10]) : null,
      aField: alv2 / 10,
      mode: null,
      modeName: null,
      raw: text
    };
  }

  m = V1_RE.exec(text);
  if (m) {
    const adc = Number(m[1]);
    if (adc > 32767) return null;
    const uV1 = m[4] ? sgn(m[4]) * Number(m[5]) : null;
    const mode = Number(m[8]);
    return {
      fmt: 'v1',
      adc,
      th: null, thd: null, al: null, ald: null, page: null,
      aField: sgn(m[2]) * Number(m[3]),
      invAl: Number(m[6]),
      invTh: Number(m[7]),
      u: uV1,
      mode,
      modeName: MODE_NAMES[mode] ?? 'UNKNOWN',
      raw: text
    };
  }

  return null;
}

/** 把 ASCII 流切成行。返回值 { lines, rest }。 */
function splitLines(buffer) {
  const text = buffer.toString('latin1');
  const parts = text.split('\n');
  const rest = parts.pop() ?? '';
  const lines = parts.map((p) => p.replace(/\r$/, ''));
  return { lines, rest };
}


// ===================== 参数协议（A5 5A，CRC8 多项式 0x07）=====================

const PARAM_H0 = 0xa5;
const PARAM_H1 = 0x5a;
const PARAM_LEN = 10;

/** CRC8，多项式 0x07，初值 0x00 */
function crc8(buf) {
  let crc = 0;
  for (const b of buf) {
    crc ^= b;
    for (let i = 0; i < 8; i++) {
      crc = (crc & 0x80) ? (((crc << 1) ^ 0x07) & 0xff) : ((crc << 1) & 0xff);
    }
  }
  return crc;
}

/** 10 个参数（顺序即文档表格） */
const PARAMS = [
  { idx: 0x01, name: 'CLK_FREQ',       writable: false, def: 50000000, min: 0,       max: 50000000, note: '主时钟' },
  { idx: 0x02, name: 'BAUD',           writable: false, def: 115200,   min: 0,       max: 4000000,  note: '波特率' },
  { idx: 0x03, name: 'PWM_HZ',         writable: false, def: 80000,    min: 0,       max: 500000,   note: 'PWM 载波' },
  { idx: 0x04, name: 'SCOPE_DIV',      writable: true,  def: 500000,   min: 50000,   max: 5000000,  note: '示波分频' },
  { idx: 0x05, name: 'COUNTS_PER_REV', writable: false, def: 1064,     min: 0,       max: 65535,    note: '编码器每圈' },
  { idx: 0x10, name: 'LQR_C1',         writable: true,  def: -1011,    min: -8191,   max: 8191,     note: '臂角增益' },
  { idx: 0x11, name: 'LQR_C2',         writable: true,  def: -1770,    min: -8191,   max: 8191,     note: '臂角速度增益' },
  { idx: 0x12, name: 'LQR_C3',         writable: true,  def: 7050,     min: -8191,   max: 8191,     note: '摆杆角增益' },
  { idx: 0x13, name: 'LQR_C4',         writable: true,  def: 1950,     min: -8191,   max: 8191,     note: '摆杆角速度增益' },
  { idx: 0x14, name: 'TH_CATCH',       writable: true,  def: 1650,     min: 0,       max: 8191,     note: '起摆交棒角' }
];

function paramByIndex(idx) {
  return PARAMS.find((p) => p.idx === idx) || null;
}

/** 读参数请求：A5 5A 01 idx CRC（5 字节） */
function buildRead(idx) {
  const b = Buffer.from([PARAM_H0, PARAM_H1, 0x01, idx & 0xff]);
  return Buffer.concat([b, Buffer.from([crc8(b.subarray(2))])]);   // CRC 只覆盖 A5 5A 之后
}

/** 写参数请求：A5 5A 02 idx v0 v1 v2 v3 CRC（9 字节，数值低字节在前） */
function buildWrite(idx, value) {
  const b = Buffer.alloc(8);
  b[0] = PARAM_H0; b[1] = PARAM_H1; b[2] = 0x02; b[3] = idx & 0xff;
  b.writeInt32LE(value | 0, 4);
  return Buffer.concat([b, Buffer.from([crc8(b.subarray(2))])]);
}

/** 全读请求：A5 5A 03 CRC（4 字节） */
function buildReadAll() {
  const b = Buffer.from([PARAM_H0, PARAM_H1, 0x03]);
  return Buffer.concat([b, Buffer.from([crc8(b.subarray(2))])]);
}

function hexOf(buf) {
  return Array.from(buf, (v) => v.toString(16).padStart(2, '0').toUpperCase()).join(' ');
}

/** 解析 10 字节应答 */
function parseParam(buf) {
  if (buf.length !== PARAM_LEN) return null;
  if (buf[0] !== PARAM_H0 || buf[1] !== PARAM_H1) return null;
  if (crc8(buf.subarray(2, 9)) !== buf[9]) return null;   // CRC 只覆盖 A5 5A 之后
  return {
    fmt: 'param',
    cmd: buf[2] & 0x7f,
    ok: buf[3] === 0x00,
    code: buf[3],
    idx: buf[4],
    value: buf.readInt32LE(5),
    raw: hexOf(buf)
  };
}

/**
 * 混合流切帧：AA 55（示波，14B）与 A5 5A（参数，10B）并存。
 * 返回 { scopes, params, rest }
 */
function splitMixed(buffer) {
  const scopes = [];
  const params = [];
  const n = buffer.length;
  let i = 0;
  while (i < n) {
    const b0 = buffer[i];
    if (b0 === 0xaa) {
      if (i + 1 >= n) break;
      if (buffer[i + 1] === 0x55) {
        if (i + V3_LEN > n) break;
        let x = 0;
        for (let k = 0; k < V3_LEN - 1; k++) x ^= buffer[i + k];
        if (x === buffer[i + V3_LEN - 1]) { scopes.push(buffer.subarray(i, i + V3_LEN)); i += V3_LEN; continue; }
      }
      i++; continue;
    }
    if (b0 === PARAM_H0) {
      if (i + 1 >= n) break;
      if (buffer[i + 1] === PARAM_H1) {
        if (i + PARAM_LEN > n) break;
        if (crc8(buffer.subarray(i + 2, i + 9)) === buffer[i + 9]) { params.push(buffer.subarray(i, i + PARAM_LEN)); i += PARAM_LEN; continue; }
      }
      i++; continue;
    }
    i++;
  }
  return { scopes, params, rest: buffer.subarray(i) };
}

module.exports = {
  parseLine, splitLines, splitFrames, parseBinaryFrame,
  MODE_NAMES, V2_RE, V4_RE, V1_RE, V3_LEN,
  crc8, PARAMS, paramByIndex, buildRead, buildWrite, buildReadAll,
  parseParam, splitMixed, hexOf, PARAM_LEN
};