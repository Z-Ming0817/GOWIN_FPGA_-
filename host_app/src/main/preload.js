const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bridge', {
  getConfig: () => ipcRenderer.invoke('config:get'),
  listPorts: () => ipcRenderer.invoke('ports:list'),
  openPort: (payload) => ipcRenderer.invoke('serial:open', payload),
  closePort: () => ipcRenderer.invoke('serial:close'),

  // 参数协议
  readParam: (idx) => ipcRenderer.invoke('param:read', idx),
  writeParam: (idx, value) => ipcRenderer.invoke('param:write', { idx, value }),
  readAllParams: () => ipcRenderer.invoke('param:readAll'),
  sendRaw: (hex) => ipcRenderer.invoke('serial:write', { hex }),

  startSim: () => ipcRenderer.invoke('sim:start'),
  stopSim: () => ipcRenderer.invoke('sim:stop'),
  listRecordings: () => ipcRenderer.invoke('rec:list'),
  clearRecordings: () => ipcRenderer.invoke('rec:clear'),
  openRecordings: () => ipcRenderer.invoke('rec:openFolder'),
  dirs: () => ipcRenderer.invoke('app:dir'),

  onFrame: (cb) => { ipcRenderer.on('frame', (_e, d) => cb(d)); },
  onRaw: (cb) => { ipcRenderer.on('raw', (_e, d) => cb(d)); },
  onRawHex: (cb) => { ipcRenderer.on('rawhex', (_e, d) => cb(d)); },
  onParam: (cb) => { ipcRenderer.on('param', (_e, d) => cb(d)); },
  onStatus: (cb) => { ipcRenderer.on('status', (_e, d) => cb(d)); },
  onRecordings: (cb) => { ipcRenderer.on('recordings', (_e, d) => cb(d)); }
});
