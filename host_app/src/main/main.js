const path = require('node:path');
const fs = require('node:fs');
const { app, BrowserWindow, ipcMain, shell } = require('electron');

// ★ 本机环境（Windows 11 build 26200）Chromium 沙箱初始化失败，
//   不加此开关进程会在启动瞬间以 0x80000003 退出，窗口根本不出现。
//   这是本机环境的规避开关，环境修好后可删掉这两行。
if (!app.isPackaged || process.env.NO_SANDBOX_FIX !== '0') {
  app.commandLine.appendSwitch('no-sandbox');
}
const { SerialPort } = require('serialport');

const { parseLine, splitLines, splitFrames, parseBinaryFrame, splitMixed, parseParam,
        buildRead, buildWrite, buildReadAll, hexOf } = require('./protocol');
const { Recorder } = require('./recorder');
const { Simulator } = require('./simulator');

// 与 E:\FPGA_project\to_zzh 工程保持一致的实物参数
const DEFAULT_CONFIG = {
  ANG_MID: 14957,          // 直立时 ADC 码值（to_zzh/rtl/board/BOARD.v:34）
  ANG_SPAN: 10241,         // 垂直向下与垂直向上的码值差（BOARD.v:35）
  INV_TH: 0,               // 摆角极性（BOARD.v:39）
  INV_AL: 0,               // 臂角极性（BOARD.v:38）
  THETA_WRAP_DEG: 360,     // 电位器量程：360=全周可分辨，180=仅半周
  ARM_LEN_M: 0.156,        // 旋转臂长度 r
  ROD_LEN_M: 0.135,        // 摆杆长度（质心 0.0675）
  BAUD: 115200,
  KEEP_RECORDINGS: 10,
  DERIV_WINDOW: 5          // 角速度用最近 N 帧做线性拟合（20Hz ≈ 250ms）
};

let win = null;
let port = null;
let rxBuffer = Buffer.alloc(0);
let rxMode = null;   // 'bin' = 二进制帧, 'ascii' = to_zzh 旧格式
let recorder = null;
let lastFrameAt = 0;
let frameCount = 0;
let config = { ...DEFAULT_CONFIG };
let sim = null;

const history = { theta: [], phi: [] };

const recordingsDir = () =>
  path.join(app.isPackaged ? path.dirname(app.getPath('exe')) : app.getAppPath(), 'recordings');

function loadConfig() {
  try {
    const user = JSON.parse(fs.readFileSync(path.join(app.getAppPath(), 'config.json'), 'utf8'));
    config = { ...DEFAULT_CONFIG, ...user };
  } catch {
    config = { ...DEFAULT_CONFIG };
  }
  return config;
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// 本机 GPU 进程起不来（gpu_process_host error_code=18 → Chromium "GPU process isn't usable" FATAL 退出），
// 表现就是"双击没反应/闪一下"。默认强制走软件光栅（SwiftShader），本场景规模下足够流畅。
// 想试硬件加速：设环境变量 PM_GPU=1 再启动。
if (process.env.PM_GPU !== '1') {
  app.disableHardwareAcceleration();
  app.commandLine.appendSwitch('disable-gpu');
  app.commandLine.appendSwitch('enable-unsafe-swiftshader');
  app.commandLine.appendSwitch('in-process-gpu');
}

function createWindow() {
  win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 1024,
    minHeight: 620,
    backgroundColor: '#0b0f14',
    title: '旋转倒立摆 · 实时监视',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  win.loadFile(path.join(__dirname, '../renderer/index.html'));
  win.on('closed', () => {
    win = null;
  });

  // 自检用：PM_SHOT=<png路径> 时自动开模拟数据、截图、退出
  if (process.env.PM_SHOT) {
    win.webContents.on('console-message', (_e, level, message, line, source) => {
      console.log(`[renderer:${level}] ${message} (${source}:${line})`);
    });
    win.webContents.on('did-fail-load', (_e, code, desc, url) => {
      console.log(`[load-fail] ${code} ${desc} ${url}`);
    });
    win.webContents.once('did-finish-load', async () => {
      await delay(1500);
      await win.webContents.executeJavaScript(
        "document.getElementById('btn-sim').click()"
      );
      await delay(Number(process.env.PM_SHOT_DELAY || 6000));
      if (process.env.PM_DEBUG) {
        const info = await win.webContents.executeJavaScript(`JSON.stringify({
          logBlock: (() => { const e = document.querySelector('.log-block'); const s = getComputedStyle(e); return { cls: e.className, flex: s.flex, h: e.clientHeight }; })(),
          recBlock: (() => { const e = document.querySelector('.rec-block'); const s = getComputedStyle(e); return { cls: e.className, flex: s.flex, h: e.clientHeight }; })(),
          logChars: document.getElementById('raw-log').textContent.length,
          logScroll: document.getElementById('raw-log').scrollHeight,
          css: document.querySelector('link[rel=stylesheet]').href
        })`);
        console.log('[layout]', info);
        const errs = await win.webContents.executeJavaScript('window.__errs || "none"');
        console.log('[jserr]', JSON.stringify(errs));
      }
      const image = await win.webContents.capturePage();
      fs.writeFileSync(process.env.PM_SHOT, image.toPNG());
      app.quit();
    });
  }
}

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}
const status = (patch) => send('status', patch);

function wrapDeg(deg, span) {
  const s = span || 360;
  return (((deg + s / 2) % s) + s) % s - s / 2;
}

/** 用最近 N 帧做最小二乘斜率，单位：度/秒 */
function slope(series) {
  const n = series.length;
  if (n < 3) return null;
  const t0 = series[0].t;
  let st = 0, sv = 0, stt = 0, stv = 0;
  for (const p of series) {
    const dt = (p.t - t0) / 1000;
    st += dt;
    sv += p.v;
    stt += dt * dt;
    stv += dt * p.v;
  }
  const denom = n * stt - st * st;
  if (Math.abs(denom) < 1e-12) return null;
  return (n * stv - st * sv) / denom;
}

function pushHistory(bucket, t, v) {
  const arr = history[bucket];
  if (v === null || v === undefined) {
    arr.length = 0;
    return;
  }
  // 解缠绕：臂角可能越过 ±180
  if (bucket === 'phi' && arr.length) {
    const prev = arr[arr.length - 1].raw;
    while (v - prev > 180) v -= 360;
    while (v - prev < -180) v += 360;
  }
  arr.push({ t, v, raw: v });
  while (arr.length > config.DERIV_WINDOW) arr.shift();
}

function handleFrame(frame) {
  const now = Date.now();
  lastFrameAt = now;
  frameCount += 1;

  if (!recorder.active) {
    recorder.start(new Date(now));
    status({ recording: true, recordingFile: recorder.filePath });
    send('recordings', recorder.list());
  }

  // v3（二进制帧）所有量都是 FPGA 算好的，直接用
  // v2 帧给出 θ/θ̇/α/α̇（0.1 单位）；v1 帧仍用 ADC 换算 + 差分
  const isV4 = frame.fmt === 'v4';
  const isV2 = frame.fmt === 'v2' || isV4;
  const isV3 = frame.fmt === 'v3';

  let theta, thetaDot, phi, phiDot, u;

  if (isV3) {
    // 摆杆角：帧里是“底部=0，0~35999”，换算成“直立=0，±180”
    let pendDeg = frame.pend / 100;                 // 0~360
    let th = pendDeg - 180;                         // 直立=0
    th = wrapDeg(th, 360);
    theta = th;
    thetaDot = frame.rodSpd / 10;
    phi = frame.arm / 100;                          // 0~360
    phiDot = frame.armSpd / 10;
    u = frame.u;
    pushHistory('theta', now, theta);
    pushHistory('phi', now, phi);
  } else if (isV2) {
    theta    = (config.INV_TH ? -frame.th  : frame.th)  / 10;
    thetaDot = (config.INV_TH ? -frame.thd : frame.thd) / 10;
    phi      = (config.INV_AL ? -frame.al  : frame.al)  / 10;
    phiDot   = (config.INV_AL ? -frame.ald : frame.ald) / 10;
    u        = isV4 ? frame.u : null;
    pushHistory('theta', now, theta);
    pushHistory('phi', now, phi);
  } else {
    const rawTheta = wrapDeg((frame.adc - config.ANG_MID) * (180 / config.ANG_SPAN), config.THETA_WRAP_DEG);
    theta = config.INV_TH ? -rawTheta : rawTheta;

    const isSwing = frame.mode === 3;
    phi = isSwing ? null : (config.INV_AL ? -frame.aField : frame.aField);
    u = (frame.u !== null && frame.u !== undefined) ? frame.u : (isSwing ? frame.aField : null);

    pushHistory('theta', now, theta);
    pushHistory('phi', now, phi);

    thetaDot = slope(history.theta);
    phiDot = slope(history.phi);
  }

  const out = {
    seq: frameCount,
    t: now,
    adc: frame.adc ?? null,
    theta,
    thetaDot,
    phi,
    phiDot,
    u,
    mode: isV3 ? (frame.fault ? 2 : (frame.balanced ? 1 : (frame.mode || 0))) : frame.mode,
    modeName: isV3
      ? (frame.fault ? 'FAULT' : (frame.balanced ? 'BALANCE' : 'IDLE'))
      : frame.modeName,
    zeroLatched: isV3 ? frame.zeroLatched : null,
    status: isV3 ? frame.status : null,
    fmt: frame.fmt,
    raw: frame.raw
  };
  send('frame', out);
  send('raw', out);

  recorder.append({
    time_ms: now,
    adc: frame.adc,
    theta_deg: theta,
    theta_dot_dps: thetaDot,
    phi_deg: phi,
    phi_dot_dps: phiDot,
    u_duty: u,
    mode: frame.mode,
    inv_al: frame.invAl,
    inv_th: frame.invTh,
    raw: frame.raw
  });
}

function closePort() {
  if (port && port.isOpen) {
    try {
      port.close();
    } catch {
      /* ignore */
    }
  }
  port = null;
  rxBuffer = Buffer.alloc(0);
}

ipcMain.handle('config:get', () => config);

ipcMain.handle('ports:list', async () => {
  const ports = await SerialPort.list();
  return ports.map((p) => ({
    path: p.path,
    description: p.friendlyName || p.manufacturer || '',
    serial: p.serialNumber || ''
  }));
});

ipcMain.handle('serial:open', async (_evt, { path: comPath, baud }) => {
  closePort();
  const baudRate = baud || config.BAUD;
  await new Promise((resolve, reject) => {
    port = new SerialPort({ path: comPath, baudRate, autoOpen: false });
    port.open((err) => (err ? reject(err) : resolve()));
  });
  frameCount = 0;
  history.theta.length = 0;
  history.phi.length = 0;

  port.on('data', (chunk) => {
    rxBuffer = Buffer.concat([rxBuffer, chunk]);
    if (rxBuffer.length > 16384) rxBuffer = rxBuffer.subarray(rxBuffer.length - 8192);

    // 混合流：AA 55（示波 14B）与 A5 5A（参数 10B）按帧头区分
    const mixed = splitMixed(rxBuffer);
    if (mixed.scopes.length || mixed.params.length || rxMode === 'bin') {
      rxMode = 'bin';
      rxBuffer = Buffer.from(mixed.rest);

      for (const f of mixed.scopes) {
        send('rawhex', { t: Date.now(), kind: 'osc', hex: hexOf(f) });
        handleFrame(parseBinaryFrame(f));
      }
      for (const f of mixed.params) {
        send('rawhex', { t: Date.now(), kind: 'param', hex: hexOf(f) });
        const p = parseParam(f);
        if (p) {
          send('param', p);
          resolveParam(p);
        }
      }
      if (mixed.scopes.length || mixed.params.length) return;
    }

    const { lines, rest: restText } = splitLines(rxBuffer);
    rxBuffer = Buffer.from(restText, 'latin1');
    for (const line of lines) {
      const frame = parseLine(line);
      if (frame) { rxMode = 'ascii'; handleFrame(frame); }
      else if (line.trim()) send('raw', { t: Date.now(), raw: line, invalid: true });
    }
  });
  port.on('close', () => status({ connected: false, portPath: null }));
  port.on('error', (err) => status({ error: String(err.message || err) }));

  status({ connected: true, portPath: comPath, baud: baudRate, simulating: false, error: null });
  return { ok: true };
});

ipcMain.handle('serial:close', async () => {
  closePort();
  status({ connected: false, portPath: null });
  return { ok: true };
});

ipcMain.handle('sim:start', () => {
  sim = sim || new Simulator((frame) => handleFrame(frame));
  sim.start();
  status({ simulating: true, connected: true, portPath: 'SIMULATED', baud: config.BAUD });
  return { ok: true };
});

ipcMain.handle('sim:stop', () => {
  if (sim) sim.stop();
  status({ simulating: false, connected: false, portPath: null });
  return { ok: true };
});

// ---------------- 参数协议：发送与应答配对 ----------------
let paramWaiters = [];

function resolveParam(p) {
  if (!paramWaiters.length) return;
  const w = paramWaiters[0];
  w.got.push(p);
  if (w.got.length >= w.need) {
    paramWaiters.shift();
    clearTimeout(w.timer);
    w.resolve(w.got);
  }
}

function writeToPort(buf) {
  return new Promise((resolve, reject) => {
    if (!port || !port.isOpen) return reject(new Error('串口未打开'));
    port.write(buf, (err) => (err ? reject(err) : resolve()));
  });
}

function paramRequest(buf, need, timeoutMs) {
  return new Promise((resolve, reject) => {
    const w = { need, got: [], resolve, reject };
    w.timer = setTimeout(() => {
      const i = paramWaiters.indexOf(w);
      if (i >= 0) paramWaiters.splice(i, 1);
      reject(new Error('等待应答超时（' + timeoutMs + ' ms）'));
    }, timeoutMs || 800);
    paramWaiters.push(w);
    writeToPort(buf).catch((err) => {
      clearTimeout(w.timer);
      const i = paramWaiters.indexOf(w);
      if (i >= 0) paramWaiters.splice(i, 1);
      reject(err);
    });
  });
}

ipcMain.handle('param:read', async (_e, idx) => (await paramRequest(buildRead(idx), 1, 800))[0]);

ipcMain.handle('param:write', async (_e, { idx, value }) => {
  const buf = buildWrite(idx, value);
  send('rawhex', { t: Date.now(), kind: 'tx', hex: hexOf(buf) });
  return (await paramRequest(buf, 1, 800))[0];
});

ipcMain.handle('param:readAll', async () => {
  const buf = buildReadAll();
  send('rawhex', { t: Date.now(), kind: 'tx', hex: hexOf(buf) });
  return paramRequest(buf, 10, 1500);
});

ipcMain.handle('serial:write', async (_e, { hex }) => {
  const clean = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
  if (!clean.length) throw new Error('没有可发送的字节');
  const buf = Buffer.from(clean, 'hex');
  if (!buf.length) throw new Error('HEX 解析失败');
  await writeToPort(buf);
  send('rawhex', { t: Date.now(), kind: 'tx', hex: hexOf(buf) });
  return buf.length;
});

ipcMain.handle('rec:list', () => recorder.list());
ipcMain.handle('rec:clear', async () => {
  const n = await recorder.clear();
  send('recordings', recorder.list());
  return n;
});

ipcMain.handle('rec:openFolder', () => {
  shell.openPath(recordingsDir());
  return { ok: true };
});

ipcMain.handle('app:dir', () => ({ recordings: recordingsDir(), exe: app.getPath('exe') }));

app.whenReady().then(() => {
  loadConfig();
  recorder = new Recorder(recordingsDir(), config.KEEP_RECORDINGS);
  createWindow();

  setInterval(() => {
    status({ stale: Boolean(port && port.isOpen && lastFrameAt && Date.now() - lastFrameAt > 3000) });
  }, 1000);

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (sim) sim.stop();
  closePort();
  if (recorder) recorder.stop();
  app.quit();
});

app.on('before-quit', () => {
  if (sim) sim.stop();
  closePort();
  if (recorder && recorder.active) recorder.stop();
});