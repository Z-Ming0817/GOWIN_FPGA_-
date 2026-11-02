import { PendulumScene } from './scene.js';
import { StripChart } from './chart.js';

const $ = (id) => document.getElementById(id);
const bridge = window.bridge;

const MODE_LABEL = {
  0: '待机 IDLE',
  1: '平衡 BALANCE',
  2: '故障 FAULT',
  3: '起摆 SWING'
};

/* ---------------- 曲线 ---------------- */
const charts = {
  theta: new StripChart(document.querySelector('[data-chart="theta"]'), {
    label: 'θ 摆角',
    unit: '°',
    color: '#4cc9f0',
    minSpan: 30,
    windowMs: 20000
  }),
  thetadot: new StripChart(document.querySelector('[data-chart="thetadot"]'), {
    label: 'θ̇ 摆角速度',
    unit: '°/s',
    color: '#7ee0ff',
    minSpan: 40,
    windowMs: 20000
  }),
  phi: new StripChart(document.querySelector('[data-chart="phi"]'), {
    label: 'φ 臂角',
    unit: '°',
    color: '#e8853c',
    minSpan: 40,
    windowMs: 20000
  }),
  phidot: new StripChart(document.querySelector('[data-chart="phidot"]'), {
    label: 'φ̇ 臂角速度',
    unit: '°/s',
    color: '#ffb066',
    minSpan: 40,
    windowMs: 20000
  })
};

/* ---------------- 三维 ---------------- */
let scene = null;
try {
  scene = new PendulumScene($('scene'));
} catch (err) {
  console.error('三维场景初始化失败', err);
  $('st-msg').textContent = '三维场景初始化失败：' + err.message;
}

/* ---------------- 状态 ---------------- */
const state = {
  connected: false,
  simulating: false,
  stale: false,
  frames: 0,
  rateFrames: 0,
  rateAt: 0,
  hz: 0,
  invalid: 0,
  lastFrame: null,
  recording: false,
  recordingFile: null
};

/* ---------------- 端口列表 ---------------- */
async function refreshPorts() {
  const select = $('port-select');
  const previous = select.value;
  try {
    const ports = await bridge.listPorts();
    select.innerHTML = '';
    if (!ports.length) {
      const opt = document.createElement('option');
      opt.textContent = '（未发现串口）';
      opt.value = '';
      select.appendChild(opt);
      return;
    }
    for (const p of ports) {
      const opt = document.createElement('option');
      opt.value = p.path;
      opt.textContent = p.description ? `${p.path} — ${p.description}` : p.path;
      select.appendChild(opt);
    }
    if (ports.some((p) => p.path === previous)) select.value = previous;
    else if (ports.some((p) => p.path === 'COM10')) select.value = 'COM10';
  } catch (err) {
    $('st-msg').textContent = '串口枚举失败：' + err.message;
  }
}

function setConnectedUI() {
  const dot = $('link-dot');
  dot.className = 'dot';
  if (state.stale) dot.classList.add('warn');
  else if (state.simulating) dot.classList.add('sim');
  else if (state.connected) dot.classList.add('on');

  $('btn-connect').textContent = state.connected && !state.simulating ? '断开' : '连接';
  $('btn-connect').classList.toggle('active', state.connected && !state.simulating);
  $('btn-sim').classList.toggle('active', state.simulating);

  $('st-port').textContent = state.connected
    ? `${$('port-select').value || 'SIMULATED'} @ ${$('baud-input').value} 8N1`
    : '未连接';
  $('stat-rec').textContent = state.recording ? '录制中' : '未录制';
  $('stat-rec').classList.toggle('on', state.recording);
}

/* ---------------- 帧处理 ---------------- */
bridge.onFrame((f) => {
  const now = performance.now();
  state.frames += 1;
  state.rateFrames += 1;
  if (!state.rateAt) state.rateAt = now;
  if (now - state.rateAt > 500) {
    state.hz = (state.rateFrames * 1000) / (now - state.rateAt);
    state.rateFrames = 0;
    state.rateAt = now;
    $('stat-rate').textContent = `${state.hz.toFixed(1)} Hz`;
    $('stat-count').textContent = `${state.frames} 帧`;
  }

  state.lastFrame = f;

  $('ro-theta').textContent = f.theta.toFixed(1);
  $('ro-thetadot').textContent = f.thetaDot === null ? '--' : f.thetaDot.toFixed(0);
  $('ro-phi').textContent = f.phi === null ? '--' : f.phi.toFixed(0);
  $('ro-phidot').textContent = f.phiDot === null ? '--' : f.phiDot.toFixed(0);
  $('ro-adc').textContent = f.adc;
  $('ro-u').textContent = f.u === null ? '--' : f.u;

  // 状态位（文档定义：bit0 平衡 / bit1 起摆 / bit2 故障 / bit3 ZERO）
  $('flag-bal').classList.toggle('on', !!f.balanced);
  $('flag-swing').classList.toggle('on', !!f.swinging);
  $('flag-fault').classList.toggle('on', !!f.fault);
  $('flag-zero').classList.toggle('on', !!f.zeroLatched);

  const badge = $('mode-badge');
  if (f.fmt === 'v2') {
    // expand_project 帧没有 mode，改显示当前菜单页
    badge.textContent = f.page ? `菜单 P${f.page}` : '菜单';
    badge.dataset.mode = '1';
  } else {
    badge.textContent = MODE_LABEL[f.mode] ?? `未知 (${f.mode})`;
    badge.dataset.mode = String(f.mode);
  }

  charts.theta.push(f.t, f.theta);
  charts.thetadot.push(f.t, f.thetaDot);
  charts.phi.push(f.t, f.phi);
  charts.phidot.push(f.t, f.phiDot);

  if (scene) {
    scene.setPhiKnown(f.phi !== null);
    scene.setPose(f.theta, f.phi === null ? scene.targetPhi : f.phi);
    scene.pushTrail();
  }
});

/* ---------------- 原始报文 ---------------- */
const logLines = [];
bridge.onRaw((r) => {
  if (r.invalid) {
    state.invalid += 1;
    $('st-msg').textContent = `无法解析: ${r.raw.slice(0, 40)}（累计 ${state.invalid} 条）`;
    return;
  }
  logLines.push(r.raw);
  if (logLines.length > 200) logLines.splice(0, logLines.length - 200);
  const el = $('raw-log');
  if (el) {
    el.textContent = logLines.slice(-40).join('\n');
    el.scrollTop = el.scrollHeight;
  }
});

/* ---------------- 状态 ---------------- */
bridge.onStatus((s) => {
  Object.assign(state, s);
  if (s.error) $('st-msg').textContent = s.error;
  $('st-recfile').textContent = state.recordingFile
    ? '录制：' + state.recordingFile.split(/[\\/]/).pop()
    : '录制未开始';
  setConnectedUI();
});

bridge.onRecordings((list) => renderRecordings(list));

function renderRecordings(list) {
  const ul = $('rec-list');
  ul.innerHTML = '';
  for (const item of list) {
    const li = document.createElement('li');
    const name = document.createElement('span');
    name.textContent = item.name.replace(/^live_/, '').replace(/\.csv$/, '');
    const size = document.createElement('span');
    size.textContent = (item.size / 1024).toFixed(0) + ' KB';
    if (state.recordingFile && item.path === state.recordingFile) {
      li.className = 'current';
      name.textContent += ' ●';
    }
    li.append(name, size);
    ul.appendChild(li);
  }
  if (!list.length) {
    const li = document.createElement('li');
    li.textContent = '（暂无录制文件）';
    ul.appendChild(li);
  }
}

async function refreshRecordings() {
  try {
    renderRecordings(await bridge.listRecordings());
  } catch {
    /* ignore */
  }
}

/* ---------------- 交互 ---------------- */
$('btn-refresh').addEventListener('click', refreshPorts);
$('btn-open-rec').addEventListener('click', () => bridge.openRecordings());

$('btn-sim').addEventListener('click', async () => {
  if (state.simulating) {
    await bridge.stopSim();
    $('st-msg').textContent = '模拟数据已停止';
  } else {
    if (state.connected) await bridge.closePort();
    charts.theta.clear();
    charts.thetadot.clear();
    charts.phi.clear();
    charts.phidot.clear();
    if (scene) scene.reset();
    await bridge.startSim();
    $('st-msg').textContent = '模拟数据运行中（20Hz，模式自动循环）';
  }
});

$('btn-connect').addEventListener('click', async () => {
  try {
    if (state.connected && !state.simulating) {
      await bridge.closePort();
      $('st-msg').textContent = '串口已断开';
      return;
    }
    if (state.simulating) await bridge.stopSim();
    const path = $('port-select').value;
    if (!path) {
      $('st-msg').textContent = '没有可用串口';
      return;
    }
    const baud = Number($('baud-input').value) || 115200;
    await bridge.openPort({ path, baud });
    $('st-msg').textContent = `已打开 ${path} @ ${baud}`;
    if (scene) scene.reset();
  } catch (err) {
    $('st-msg').textContent = '打开串口失败：' + (err.message || err);
  }
});

/* ---------------- 渲染循环 ---------------- */
let lastChart = 0;
function frame(ts) {
  const mon = $('page-monitor');
  const onMonitor = mon && !mon.hidden;
  // 不在监视页时完全不渲染：避免 0 尺寸画布参与 three.js / 曲线计算
  if (onMonitor) {
    if (scene) scene.step();
    if (ts - lastChart > 45) {
      lastChart = ts;
      const now = Date.now();
      for (const key of Object.keys(charts)) charts[key].render(now);
      $('stat-clock').textContent = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

/* ---------------- 尺寸 ---------------- */
function relayout() {
  // 监视页不可见时不要 resize/render：画布尺寸为 0 会让曲线计算退化并卡住
  const mon = $('page-monitor');
  if (mon && mon.hidden) return;
  if (scene) scene.resize();
  for (const key of Object.keys(charts)) {
    charts[key].resize();
    charts[key].render(Date.now());
  }
}
let resizeTimer = 0;
new ResizeObserver(() => {
  if (resizeTimer) cancelAnimationFrame(resizeTimer);
  resizeTimer = requestAnimationFrame(relayout);
}).observe(document.body);

/* ---------------- 启动 ---------------- */
(async () => {
  await refreshPorts();
  await refreshRecordings();
  setConnectedUI();
  setInterval(refreshRecordings, 4000);
  setInterval(() => {
    if (!state.connected) refreshPorts();
  }, 15000);
  setTimeout(relayout, 50);
  setTimeout(relayout, 300);
})();

/* ==================== 分页切换 ==================== */
const PAGES = { monitor: $('page-monitor'), io: $('page-io') };

function switchTab(name) {
  for (const k of Object.keys(PAGES)) PAGES[k].hidden = k !== name;
  document.querySelectorAll('.tab').forEach((t) => {
    t.classList.toggle('active', t.dataset.tab === name);
  });
  $('page-sub').textContent = name === 'io' ? '串口读写' : '实时监测';
  if (relayoutTimer) {
    clearTimeout(relayoutTimer);
    relayoutTimer = 0;
  }
  if (name === 'monitor') {
    // 等浏览器完成一次布局后再取真实尺寸；只排一次，避免排队重排
    relayoutTimer = setTimeout(() => {
      relayoutTimer = 0;
      try {
        relayout();
      } catch (err) {
        $('st-msg').textContent = '重排失败：' + (err.message || err);
      }
    }, 60);
  }
}
let relayoutTimer = 0;
document.querySelectorAll('.tab').forEach((t) => {
  t.addEventListener('click', () => switchTab(t.dataset.tab));
});

/* ==================== 串口原始报文（HEX）—— 显示在实时监测页 ==================== */
// 100 Hz 的帧如果每帧都写 DOM 会很卡：先进缓冲，定时批量刷新
const hexLines = [];
let hexDirty = false;

bridge.onRawHex((r) => {
  const tag = r.kind === 'tx' ? 'TX   ' : r.kind === 'param' ? 'PARAM' : 'OSC  ';
  const t = new Date(r.t).toLocaleTimeString('zh-CN', { hour12: false });
  hexLines.push(`${t} ${tag} ${r.hex}`);
  if (hexLines.length > 400) hexLines.splice(0, hexLines.length - 400);
  hexDirty = true;
});

$('btn-clear-hex').addEventListener('click', () => {
  hexLines.length = 0;
  hexDirty = true;
});

/* ==================== 发送 ==================== */
$('btn-send').addEventListener('click', async () => {
  try {
    const n = await bridge.sendRaw($('send-hex').value);
    $('io-msg').textContent = `已发送 ${n} 字节`;
  } catch (err) {
    $('io-msg').textContent = '发送失败：' + (err.message || err);
  }
});

/* ==================== 页内确认框（替代 window.confirm） ====================
 * ★ 为什么不用 window.confirm：
 *   它是 Chromium 原生模态，关闭后本窗口会丢掉【操作系统级键盘焦点】
 *   （实测 document.hasFocus() 由 true 变 false 且不自动恢复），
 *   表现为：鼠标能用、输入框点了没光标、打字无反应，刷新页面也无效。
 *   页内自绘遮罩完全不碰原生对话框，因此不影响焦点。
 * ========================================================================== */
let confirmResolve = null;

function closeConfirm(val) {
  const mask = $('cf-mask');
  if (!mask || mask.hidden) return;
  mask.hidden = true;
  const r = confirmResolve;
  confirmResolve = null;
  if (r) r(val);
}

function ensureConfirm() {
  if ($('cf-mask')) return;
  const mask = document.createElement('div');
  mask.id = 'cf-mask';
  mask.className = 'cf-mask';
  mask.hidden = true;
  mask.innerHTML =
    '<div class="cf-card" role="dialog" aria-modal="true">' +
    '  <div class="cf-title" id="cf-title">确认</div>' +
    '  <pre class="cf-body" id="cf-body"></pre>' +
    '  <div class="cf-actions">' +
    '    <button class="mini" id="cf-cancel">取消</button>' +
    '    <button class="primary" id="cf-ok">确定</button>' +
    '  </div>' +
    '</div>';
  document.body.appendChild(mask);

  $('cf-cancel').addEventListener('click', () => closeConfirm(false));
  $('cf-ok').addEventListener('click', () => closeConfirm(true));
  // 点遮罩空白处 = 取消
  mask.addEventListener('mousedown', (e) => { if (e.target === mask) closeConfirm(false); });
  // Esc 取消 / Enter 确定（仅在弹框可见时生效）
  document.addEventListener('keydown', (e) => {
    if (mask.hidden) return;
    if (e.key === 'Escape') { e.preventDefault(); closeConfirm(false); }
    else if (e.key === 'Enter') { e.preventDefault(); closeConfirm(true); }
  });
}

/** 返回 Promise<boolean>，用法与 window.confirm 等价（要 await） */
function askConfirm(title, body) {
  ensureConfirm();
  $('cf-title').textContent = title;
  $('cf-body').textContent = body;
  $('cf-mask').hidden = false;
  // 默认焦点给「取消」，避免误按回车就写参数
  setTimeout(() => { const b = $('cf-cancel'); if (b) b.focus(); }, 0);
  return new Promise((resolve) => { confirmResolve = resolve; });
}

/* ==================== 参数定义 ==================== */
const PARAMS = [
  { idx: 0x01, name: 'CLK_FREQ',       writable: false, def: 50000000 },
  { idx: 0x02, name: 'BAUD',           writable: false, def: 115200 },
  { idx: 0x03, name: 'PWM_HZ',         writable: false, def: 80000 },
  { idx: 0x04, name: 'SCOPE_DIV',      writable: true,  def: 500000 },
  { idx: 0x05, name: 'COUNTS_PER_REV', writable: false, def: 1064 },
  { idx: 0x10, name: 'LQR_C1',         writable: true,  def: -1011 },
  { idx: 0x11, name: 'LQR_C2',         writable: true,  def: -1770 },
  { idx: 0x12, name: 'LQR_C3',         writable: true,  def: 7050 },
  { idx: 0x13, name: 'LQR_C4',         writable: true,  def: 1950 },
  { idx: 0x14, name: 'TH_CATCH',       writable: true,  def: 1650 }
];

const PARAM_NAME = {};
PARAMS.forEach((p) => { PARAM_NAME[p.idx] = p.name; });

// 范围与板端 param_link 一致（只读项不显示）
const RANGE = {
  0x04: '50 000 ~ 5 000 000',
  0x10: '-8191 ~ 8191', 0x11: '-8191 ~ 8191',
  0x12: '-8191 ~ 8191', 0x13: '-8191 ~ 8191',
  0x14: '0 ~ 8191'
};

const paramCells = new Map();   // idx -> { valEl, inpEl, stEl, btnW, row }

function hex2(idx) {
  return '0x' + idx.toString(16).toUpperCase().padStart(2, '0');
}

/* ==================== 参数表构建 ==================== */
function buildParamTable() {
  const body = $('param-body');
  if (!body) return;
  body.innerHTML = '';

  for (const p of PARAMS) {
    const tr = document.createElement('tr');

    const cIdx = document.createElement('td');
    cIdx.textContent = hex2(p.idx);
    cIdx.className = 'mono';

    const cName = document.createElement('td');
    cName.textContent = p.name;
    cName.className = 'mono';

    const cVal = document.createElement('td');
    cVal.className = 'num';
    cVal.textContent = '--';

    const cInp = document.createElement('td');
    const inp = document.createElement('input');
    inp.className = 'pval';
    inp.value = '';
    inp.disabled = !p.writable;
    inp.placeholder = p.writable ? '输入新值' : '只读';
    cInp.appendChild(inp);

    const cRange = document.createElement('td');
    cRange.className = 'hint';
    cRange.textContent = p.writable ? (RANGE[p.idx] || '待确认') : '—';

    const cSt = document.createElement('td');
    cSt.className = 'st';
    cSt.textContent = '—';

    const cOp = document.createElement('td');
    cOp.className = 'ops';

    const bRead = document.createElement('button');
    bRead.className = 'mini';
    bRead.textContent = '读';
    bRead.addEventListener('click', () => doRead(p.idx));

    const bWrite = document.createElement('button');
    bWrite.className = 'mini primary';
    bWrite.textContent = '写';
    bWrite.disabled = !p.writable;
    bWrite.addEventListener('click', () => doWrite(p.idx, inp.value));

    cOp.append(bRead, bWrite);

    tr.append(cIdx, cName, cVal, cInp, cRange, cSt, cOp);
    body.appendChild(tr);

    paramCells.set(p.idx, { valEl: cVal, inpEl: inp, stEl: cSt, btnW: bWrite, row: tr });
  }
}

function setRowStatus(idx, kind, text) {
  const c = paramCells.get(idx);
  if (!c) return;
  c.stEl.textContent = text;
  c.row.classList.remove('row-ok', 'row-err', 'row-busy');
  if (kind === 'ok')   c.row.classList.add('row-ok');
  if (kind === 'err')  c.row.classList.add('row-err');
  if (kind === 'busy') c.row.classList.add('row-busy');
}

function applyParam(p) {
  const c = paramCells.get(p.idx);
  if (!c) return;
  c.valEl.textContent = String(p.value);
  setRowStatus(p.idx, p.ok ? 'ok' : 'err', p.ok ? '✅ 成功' : `❌ 失败 0x0${p.code}`);
}

function logLine(text) {
  const el = $('read-log');
  if (!el) return;
  const t = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  readLines.push(`${t} ${text}`);
  if (readLines.length > 200) readLines.splice(0, readLines.length - 200);
  el.textContent = readLines.slice(-60).join('\n');
  el.scrollTop = el.scrollHeight;
}

const readLines = [];

/* ==================== 单行读 ==================== */
async function doRead(idx) {
  const c = paramCells.get(idx);
  if (c && c.btnW) c.btnW.disabled = true;
  setRowStatus(idx, 'busy', '读取中…');
  try {
    const p = await bridge.readParam(idx);
    applyParam(p);
    logLine(`读 ${hex2(p.idx)} ${PARAM_NAME[p.idx] || ''} = ${p.value}  ${p.ok ? 'OK' : 'ERR'}`);
    $('io-msg').textContent = '读取完成';
    return p.ok;
  } catch (err) {
    setRowStatus(idx, 'err', '❌ 超时');
    logLine(`读 ${hex2(idx)} 失败：${err.message || err}`);
    $('io-msg').textContent = '读取失败：' + (err.message || err);
    return false;
  } finally {
    const meta = PARAMS.find((x) => x.idx === idx);
    if (c && c.btnW) c.btnW.disabled = !(meta && meta.writable);
  }
}

/* ==================== 单行写 ==================== */
async function doWrite(idx, value, opts) {
  const silent = !!(opts && opts.silent);
  // ★ 必须先判空：Number('') === 0，直接转换会把"没填"当成写 0
  const raw = String(value === undefined || value === null ? '' : value).trim();
  if (!raw) {
    $('io-msg').textContent = '请先在「写入值」里填写数值';
    return false;
  }
  const num = Number(raw);
  if (!Number.isFinite(num)) {
    $('io-msg').textContent = '请输入数值';
    return false;
  }
  value = num;
  if (!silent) {
    const name = PARAM_NAME[idx] || hex2(idx);
    const ok = await askConfirm('确认写入参数',
      `${name}（${hex2(idx)}）\n新值：${value}`);
    if (!ok) {
      $('io-msg').textContent = '已取消写入';
      return false;
    }
  }

  const c = paramCells.get(idx);
  if (c && c.btnW) c.btnW.disabled = true;
  setRowStatus(idx, 'busy', '写入中…');
  try {
    const p = await bridge.writeParam(idx, value);
    applyParam(p);
    logLine(`写 ${hex2(p.idx)} ${PARAM_NAME[p.idx] || ''} = ${value}  ${p.ok ? 'OK' : 'ERR 0x0' + p.code}`);
    $('io-msg').textContent = p.ok
      ? `写入成功，回读值 ${p.value}`
      : `写入被拒绝（结果码 0x0${p.code}），板内值未变`;
    return p.ok;
  } catch (err) {
    setRowStatus(idx, 'err', '❌ 超时');
    logLine(`写 ${hex2(idx)} 失败：${err.message || err}`);
    $('io-msg').textContent = '写入失败：' + (err.message || err);
    return false;
  } finally {
    const meta = PARAMS.find((x) => x.idx === idx);
    if (c && c.btnW) c.btnW.disabled = !(meta && meta.writable);
  }
}

/* ==================== 批量读取 ==================== */
$('btn-readall').addEventListener('click', async () => {
  const btn = $('btn-readall');
  btn.disabled = true;
  $('io-msg').textContent = '批量读取中…';
  try {
    const list = await bridge.readAllParams();
    list.forEach(applyParam);
    logLine(`批量读取完成，共 ${list.length} 项`);
    $('io-msg').textContent = `批量读取完成（${list.length} 项）`;
  } catch (err) {
    logLine(`批量读取失败：${err.message || err}`);
    $('io-msg').textContent = '批量读取失败：' + (err.message || err);
  } finally {
    btn.disabled = false;
  }
});

/* ==================== 批量写入 ==================== */
$('btn-batch-write').addEventListener('click', async () => {
  // 只提交“写入值与当前值不同”的可写行，避免无谓的串口流量
  const todo = [];
  for (const p of PARAMS) {
    if (!p.writable) continue;
    const c = paramCells.get(p.idx);
    if (!c) continue;
    const raw = String(c.inpEl.value).trim();
    if (!raw) continue;                     // 没填就不写
    const v = Number(raw);
    if (!Number.isFinite(v)) continue;
    if (c.valEl.textContent !== '--' && Number(c.valEl.textContent) === v) continue;
    todo.push({ p, v, cur: c.valEl.textContent });
  }
  if (!todo.length) {
    $('io-msg').textContent = '没有需要写入的改动（请先在「写入值」列填写数值）';
    return;
  }
  const lines = todo
    .map((t) => `  ${t.p.name}（${hex2(t.p.idx)}）：${t.cur} → ${t.v}`)
    .join('\n');
  if (!(await askConfirm('确认批量写入', `共 ${todo.length} 项：\n\n${lines}`))) {
    $('io-msg').textContent = '已取消批量写入';
    return;
  }

  const btn = $('btn-batch-write');
  btn.disabled = true;
  let ok = 0;
  let fail = 0;
  for (let i = 0; i < todo.length; i += 1) {
    const t = todo[i];
    $('io-msg').textContent = `批量写入中 ${i + 1}/${todo.length}：${t.p.name}`;
    // eslint-disable-next-line no-await-in-loop
    const r = await doWrite(t.p.idx, t.v, { silent: true });
    if (r) ok += 1; else fail += 1;
  }
  btn.disabled = false;
  $('io-msg').textContent = `批量写入完成：成功 ${ok} 项，失败 ${fail} 项`;
  logLine(`批量写入完成：成功 ${ok}，失败 ${fail}`);
});

/* ==================== 串口推送的参数帧 ==================== */
bridge.onParam((p) => {
  applyParam(p);
  logLine(`${p.cmd === 2 ? '写' : '读'} ${hex2(p.idx)} ${PARAM_NAME[p.idx] || ''} = ${p.value}  ${p.ok ? 'OK' : 'ERR'}`);
});

/* ==================== 录制 ==================== */
$('btn-clear-rec').addEventListener('click', async () => {
  try {
    const n = await bridge.clearRecordings();
    $('io-msg').textContent = `已清除 ${n} 个历史录制文件（新数据会继续保存）`;
  } catch (err) {
    $('io-msg').textContent = '清除失败：' + (err.message || err);
  }
});

$('btn-clear-read').addEventListener('click', () => {
  readLines.length = 0;
  $('read-log').textContent = '';
});

/* ==================== 快捷参数读写 ==================== */
function parseIdx(v) {
  const t = String(v || '').trim().replace(/^0x/i, '');
  const n = parseInt(t, 16);
  return Number.isFinite(n) ? n : NaN;
}

$('btn-q-read').addEventListener('click', () => {
  const idx = parseIdx($('q-idx').value);
  if (!Number.isFinite(idx)) { $('io-msg').textContent = '请输入参数编号（十六进制，如 10）'; return; }
  doRead(idx);
});

$('btn-q-write').addEventListener('click', () => {
  const idx = parseIdx($('q-idx').value);
  const val = Number($('q-val').value);
  if (!Number.isFinite(idx)) { $('io-msg').textContent = '请输入参数编号（十六进制，如 12）'; return; }
  if (!Number.isFinite(val)) { $('io-msg').textContent = '请输入要写入的数值'; return; }
  doWrite(idx, val);
});

/* ==================== 页内 Tab（角度/状态 <-> 参数配置） ==================== */
function switchIoTab(name) {
  $('iotab-angle').hidden = name !== 'angle';
  $('iotab-param').hidden = name !== 'param';
  document.querySelectorAll('.iotab').forEach((t) => {
    t.classList.toggle('active', t.dataset.iotab === name);
  });
}
document.querySelectorAll('.iotab').forEach((t) => {
  t.addEventListener('click', () => switchIoTab(t.dataset.iotab));
});

/* ==================== 角度/状态表刷新（10 Hz，避免 100 Hz 刷 DOM） ==================== */
function fmt(v, dec) {
  return v === null || v === undefined || Number.isNaN(v) ? '--' : Number(v).toFixed(dec);
}

function updateAngleTable() {
  // 串口报文窗口（缓冲批量刷）
  if (hexDirty) {
    hexDirty = false;
    const el = $('hex-log');
    if (el) {
      el.textContent = hexLines.slice(-120).join('\n');
      el.scrollTop = el.scrollHeight;
    }
  }

  // 顶部设备状态镜像到工具栏
  const st = $('st-port');
  if (st) $('io-conn-state').textContent = st.textContent;

  const f = state.lastFrame;
  if (!f) return;
  $('at-theta').textContent    = fmt(f.theta, 1);
  $('at-thetadot').textContent = fmt(f.thetaDot, 0);
  $('at-phi').textContent      = fmt(f.phi, 0);
  $('at-phidot').textContent   = fmt(f.phiDot, 0);
  $('at-u').textContent        = f.u === null || f.u === undefined ? '--' : String(f.u);
  $('at-adc').textContent      = f.adc === null || f.adc === undefined ? '--' : String(f.adc);
  $('at-bal').textContent      = `${f.balanced ? '平衡' : '—'} / ${f.swinging ? '起摆' : '—'}`;
  $('at-fault').textContent    = `${f.fault ? '故障' : '—'} / ${f.zeroLatched ? 'ZERO' : '—'}`;
}

setInterval(updateAngleTable, 100);

buildParamTable();
