// Demo UI: transport, A/B, parameters, meters and spectrum.

import { DEFAULTS } from './dsp/engine.js';
import { LIBRARY } from './dsp/signals.js';
import { normalizationGainDB } from './dsp/lufs.js';

const $ = (id) => document.getElementById(id);

const MODES = [
  { id: 'spectral', label: '分音谐波 (Spectral)', note: '推荐：无互调' },
  { id: 'analytic', label: '解析谐波 (Analytic)', note: '第二版' },
  { id: 'apple', label: '电平归一化 NLD', note: 'Apple 专利模型' },
  { id: 'legacyApp', label: 'App 经典模式', note: '当前线上' },
  { id: 'legacyLab', label: 'Lab 混合模式', note: '此前修复版' },
];
const SYNTH = ['spectral', 'analytic', 'apple'];

// Parameter schema. `modes` limits where a control is shown.
const GROUPS = [
  {
    title: '扬声器适配', params: [
      { key: 'cutoff', label: '扬声器截止频率', min: 40, max: 300, step: 1, unit: 'Hz', log: true,
        hint: '目标扬声器能有效回放的最低频率。低于此频率的低音将转化为泛音。' },
      { key: 'keepLowDB', label: '保留物理低音', min: -60, max: 0, step: 1, unit: 'dB', modes: SYNTH,
        fmt: (v) => (v <= -60 ? '关闭' : `${v} dB`),
        hint: '关闭时只去除截止频率 0.7 倍以下、扬声器几乎放不出的低音，节省动态余量与振膜行程；耳机建议设为 0 dB。' },
      { key: 'excursionProtect', label: '防冲程滤波斜率', type: 'select', modes: SYNTH,
        options: [
          ['tight6', '均衡保护 (36 dB/oct，推荐)'],
          ['steep8', '陡峭硬切 (48 dB/oct，消除次声)'],
          ['tight4', '标准平滑 (24 dB/oct)']
        ],
        hint: '压制泛音通道在截止频率以下泄漏的次声基波。微型喇叭推荐使用均衡保护或陡峭硬切，避免振膜过冲与空气噗噗声。' },
      { key: 'speakerSim', label: '模拟小型扬声器', type: 'toggle',
        hint: '对输出施加高通滤波，使耳机听感模拟目标扬声器的低音损失状态。仅供试听辅助。' },
      { key: 'simCutoff', label: '模拟截止频率', min: 0, max: 300, step: 1, unit: 'Hz', fmt: (v) => (v === 0 ? '同上' : `${v} Hz`) },
      { key: 'simOrder', label: '模拟滚降斜率', type: 'select', options: [[2, '12 dB/oct (密闭箱)'], [4, '24 dB/oct (倒相箱)']] },
    ],
  },
  {
    title: '泛音合成 (分音)', modes: ['spectral'], params: [
      { key: 'amountDB', label: '泛音增益', min: -24, max: 12, step: 0.5, unit: 'dB',
        hint: '0 dB：扬声器放出的泛音与它替代的低音能量相同。想要更多低音，调这里。' },
      { key: 'orders', label: '泛音数量', min: 1, max: 8, step: 1, unit: '阶',
        hint: '从扬声器能放出的第一个泛音算起。4–6 阶最平顺；少了偏薄，易听成高八度；超过 6 阶，各音的高阶泛音相互拍打，开始发毛。' },
      { key: 'specSlopeDB', label: '每阶衰减', min: -12, max: 0, step: 0.5, unit: 'dB',
        hint: '越接近 0，高阶泛音越响，低音越结实，阶数多时也越容易发毛；越低，越接近单一泛音，容易听成高八度。' },
      { key: 'dispersion', label: '相位分散', type: 'toggle',
        hint: '错开各阶泛音的相位，让包络平坦。关闭后各阶同相叠成脉冲，会听到嗡嗡的毛刺。' },
      { key: 'resolution', label: '频率分辨率', type: 'select', options: [['high', '高 (170 ms)'], ['standard', '标准 (85 ms)']],
        hint: '高：相距 12 Hz 的两个音也能分开，底鼓叠在贝斯上时更干净，起音稍缓，延迟约 105 ms。标准：鼓点更利落，相近的音会略微发毛，延迟约 60 ms。' },
      { key: 'transientFix', label: '起音修正', type: 'toggle',
        hint: '分析窗会提前看到即将到来的鼓点；开启后，尚未发声的音的泛音被压低，避免鼓点前出现预回声。' },
      { key: 'loudnessMatch', label: '等响度校准', min: 0, max: 1, step: 0.05,
        hint: '0：各音高的泛音与原低音同等能量；1：按 ISO 226 等响度曲线压低极低音的泛音。' },
      { key: 'loudnessRefDB', label: '基准低音听音级', min: 60, max: 100, step: 1, unit: 'dB SPL' },
      { key: 'floor', label: '最低基频', min: 15, max: 60, step: 1, unit: 'Hz' },
    ],
  },
  {
    title: '泛音合成 (解析)', modes: ['analytic'], params: [
      { key: 'amountDB', label: '泛音增益', min: -24, max: 12, step: 0.5, unit: 'dB',
        hint: '0 dB：泛音与它替代的低音能量相同。想要更多低音，调这里。' },
      { key: 'slopeDB', label: '泛音衰减 (每阶)', min: -20, max: -2, step: 0.5, unit: 'dB',
        hint: '越低越干净，接近单一的二次谐波；越接近 0，高阶泛音越多，音色更饱满，也更容易发毛。' },
      { key: 'followMs', label: '电平跟随释放', min: 10, max: 500, step: 5, unit: 'ms', log: true,
        hint: '短：大鼓过后，紧随的低音更快恢复；长：两个低音重叠时更圆滑。' },
      { key: 'loudnessMatch', label: '等响度校准', min: 0, max: 1, step: 0.05,
        hint: '0：各音高的泛音与原低音同等能量；1：按 ISO 226 等响度曲线压低极低音的泛音。' },
      { key: 'loudnessRefDB', label: '基准低音听音级', min: 60, max: 100, step: 1, unit: 'dB SPL' },
      { key: 'floor', label: '最低基频', min: 15, max: 60, step: 1, unit: 'Hz' },
      { key: 'topMult', label: '泛音上限倍率', min: 2, max: 8, step: 0.5, unit: '× 截止频率' },
    ],
  },
  {
    title: '电平归一化 NLD', modes: ['apple'], params: [
      { key: 'amountDB', label: '泛音增益', min: -24, max: 12, step: 0.5, unit: 'dB' },
      { key: 'nld', label: '非线性失真模型', type: 'select', options: [['smooth23', '平滑复合谐波 (2次+3次，推荐)'], ['exp2', 'EXP2 (去直流优化)'], ['tanh', 'tanh (平滑软饱和)']] },
      { key: 'drive', label: '基准驱动量 (Drive)', min: 0.1, max: 2, step: 0.05,
        hint: '基准软饱和驱动量。控制二次与三次泛音饱满度，配合自适应绑定可在全频段保持干净不破音。' },
      { key: 'autoDrive', label: '自适应驱动绑定', type: 'toggle',
        hint: '驱动量与扬声器截止频率动态绑定：高截频时自动按比例降低驱动，杜绝互调杂音与破音；低截频时保证饱满度。' },
      { key: 'holdMs', label: '电平保持时间', min: 0, max: 1000, step: 10, unit: 'ms' },
      { key: 'releaseMs', label: '电平释放时间', min: 20, max: 2000, step: 10, unit: 'ms' },
      { key: 'floor', label: '最低基频', min: 15, max: 60, step: 1, unit: 'Hz' },
      { key: 'topMult', label: '泛音上限倍率', min: 2, max: 8, step: 0.5, unit: '× 截止频率' },
    ],
  },
  {
    title: '旧版实现 (Legacy)', modes: ['legacyApp'], params: [
      { key: 'legacyIntensity', label: '强度', min: 0, max: 2, step: 0.05 },
      { key: 'legacyBassGainDB', label: '低频搁架增益', min: 0, max: 9, step: 0.5, unit: 'dB' },
      { key: 'floor', label: '最低频率', min: 15, max: 80, step: 1, unit: 'Hz' },
    ],
  },
  {
    title: '输出控制', params: [
      { key: 'normalize', label: '标准化至 −14 LUFS', type: 'toggle',
        hint: '按主 App 默认目标响度回放，即实际效果器运行的标准工作点。' },
      { key: 'inputGainDB', label: '输入增益', min: -18, max: 6, step: 0.5, unit: 'dB' },
      { key: 'limiter', label: '安全限幅器', type: 'toggle' },
      { key: 'ceilingDB', label: '限幅阈值', min: -6, max: 0, step: 0.1, unit: 'dBFS' },
      { key: 'alignMs', label: '干声延迟对齐', min: -1, max: 150, step: 0.5, unit: 'ms', modes: SYNTH,
        fmt: (v) => (v < 0 ? '自动' : `${v} ms`), hint: '将干声信号与泛音处理延迟对齐。基于滤波器群延迟自动推导。' },
      { key: 'solo', label: '监听模式', type: 'select',
        options: [['none', '完整混音'], ['harmonics', '仅生成的泛音 (独奏)'], ['removed', '扬声器损失的低音']] },
    ],
  },
];

const PRESETS = {
  '小型扬声器 (模拟)': { cutoff: 150, keepLowDB: -60, speakerSim: true, simCutoff: 0, simOrder: 4, amountDB: 0, excursionProtect: 'tight6' },
  '笔记本扬声器 (模拟)': { cutoff: 200, keepLowDB: -60, speakerSim: true, simCutoff: 0, simOrder: 2, amountDB: 0, excursionProtect: 'steep8' },
  '耳机 (完整保留真实低音)': { cutoff: 60, keepLowDB: 0, speakerSim: false, amountDB: 0, floor: 20, excursionProtect: 'tight4' },
  '平头塞 / 半入耳耳机': { cutoff: 100, keepLowDB: -6, speakerSim: false, amountDB: 0, excursionProtect: 'tight6' },
};

const STORE = 'vbproto.params.v2';
// From the first prototype's settings only the listening setup carries
// over; its algorithm parameters belonged to the retired phase-locked mode.
const KEEP_V1 = ['cutoff', 'keepLowDB', 'speakerSim', 'simCutoff', 'simOrder', 'normalize', 'inputGainDB', 'limiter', 'ceilingDB'];
let params = { ...DEFAULTS, ...PRESETS['小型扬声器 (模拟)'], normalize: true };
try {
  const saved = localStorage.getItem(STORE);
  if (saved) {
    const s = JSON.parse(saved);
    Object.assign(params, s);
    // Saved before the spectral mode existed: open on it once.
    if (!('orders' in s)) params.mode = DEFAULTS.mode;
  } else {
    const v1 = JSON.parse(localStorage.getItem('vbproto.params.v1') || '{}');
    for (const k of KEEP_V1) if (k in v1) params[k] = v1[k];
  }
} catch { /* storage unavailable */ }
if (!MODES.some((m) => m.id === params.mode)) params.mode = DEFAULTS.mode;
params.bypass = false;
params.normGainDB = 0;
let loudness = null;

// ------------------------------------------------------------------ audio
let ctx = null, node = null, master = null, anIn = null, anOut = null, anHarm = null;
let buffer = null, source = null, startedAt = 0, offset = 0, playing = false;

async function ensureAudio() {
  if (ctx) return;
  ctx = new AudioContext({ latencyHint: 'playback' });
  await ctx.audioWorklet.addModule('worklet.js');
  node = new AudioWorkletNode(ctx, 'virtual-bass', {
    numberOfInputs: 1, numberOfOutputs: 2, outputChannelCount: [2, 1],
    channelCount: 2, channelCountMode: 'explicit', channelInterpretation: 'speakers',
  });
  master = ctx.createGain();
  master.gain.value = Number($('volume').value);
  const mk = () => { const a = ctx.createAnalyser(); a.fftSize = 16384; a.smoothingTimeConstant = 0.8; return a; };
  anIn = mk(); anOut = mk(); anHarm = mk();
  node.connect(master, 0);
  master.connect(ctx.destination);
  node.connect(anOut, 0);
  node.connect(anHarm, 1);
  node.port.onmessage = onWorkletMessage;
  sendParams(params);
  requestAnimationFrame(draw);
}

function sendParams(p) {
  if (node) node.port.postMessage({ type: 'params', params: p });
}

let pending = {};
let timer = 0;
function setParam(key, value) {
  params[key] = value;
  if (key === 'normalize') {
    key = 'normGainDB';
    value = value && loudness ? loudness.gainDB : 0;
    params.normGainDB = value;
  }
  pending[key] = value;
  clearTimeout(timer);
  // Structural changes rebuild the engine (with a crossfade); batch drags.
  timer = setTimeout(() => { sendParams(pending); pending = {}; }, 60);
  try { const { bypass, ...rest } = params; localStorage.setItem(STORE, JSON.stringify(rest)); } catch { /* ignore */ }
}

function startAt(pos) {
  if (!buffer || !ctx) return;
  if (source) { source.onended = null; try { source.stop(); } catch { /* already stopped */ } source.disconnect(); }
  source = ctx.createBufferSource();
  source.buffer = buffer;
  source.loop = $('loop').checked;
  source.connect(node);
  source.connect(anIn);
  offset = Math.max(0, Math.min(pos, buffer.duration - 0.01));
  startedAt = ctx.currentTime;
  source.start(0, offset);
  source.onended = () => { if (playing && !source.loop) { playing = false; offset = 0; updatePlay(); } };
  playing = true;
  updatePlay();
}

function position() {
  if (!buffer) return 0;
  if (!playing) return offset;
  const p = offset + (ctx.currentTime - startedAt);
  return $('loop').checked ? p % buffer.duration : Math.min(p, buffer.duration);
}

function pause() {
  if (!playing) return;
  offset = position();
  playing = false;
  if (source) { source.onended = null; try { source.stop(); } catch { /* ignore */ } }
  updatePlay();
}

function updatePlay() { $('play').textContent = playing ? '暂停' : '播放'; }

async function loadBuffer(promiseOrBuffer, name) {
  await ensureAudio();
  pause();
  $('info').textContent = `正在加载 ${name}…`;
  buffer = await promiseOrBuffer;
  // Loudness of the whole file, for the −14 LUFS normalization option.
  const chans = [buffer.getChannelData(0), buffer.getChannelData(buffer.numberOfChannels > 1 ? 1 : 0)];
  loudness = normalizationGainDB(chans, buffer.sampleRate, -14);
  setParam('normalize', !!params.normalize);
  offset = 0;
  $('seek').value = 0;
  document.title = `${name} · 虚拟低音原型`;
  startAt(0);
}

$('file').addEventListener('change', async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  await ensureAudio();
  loadBuffer(f.arrayBuffer().then((b) => ctx.decodeAudioData(b)), f.name);
});

document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', async (e) => {
  e.preventDefault();
  const f = e.dataTransfer.files[0];
  if (!f) return;
  await ensureAudio();
  loadBuffer(f.arrayBuffer().then((b) => ctx.decodeAudioData(b)), f.name);
});

for (const [id, s] of Object.entries(LIBRARY)) {
  const o = document.createElement('option');
  o.value = id; o.textContent = s.label;
  $('signal').appendChild(o);
}
$('signal').addEventListener('change', async (e) => {
  const id = e.target.value;
  if (!id) return;
  await ensureAudio();
  const sig = LIBRARY[id].make(ctx.sampleRate);
  const b = ctx.createBuffer(2, sig.L.length, ctx.sampleRate);
  b.getChannelData(0).set(sig.L);
  b.getChannelData(1).set(sig.R);
  loadBuffer(b, LIBRARY[id].label);
});

fetch('media-list').then((r) => (r.ok ? r.json() : [])).then((list) => {
  if (!list.length) return;
  const sel = $('library');
  sel.classList.remove('hidden');
  sel.innerHTML = '<option value="">曲库音频…</option>' + list.map((f) => `<option>${f.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</option>`).join('');
  sel.addEventListener('change', async () => {
    if (!sel.value) return;
    await ensureAudio();
    const url = 'media/' + sel.value.split('/').map(encodeURIComponent).join('/');
    loadBuffer(fetch(url).then((r) => r.arrayBuffer()).then((b) => ctx.decodeAudioData(b)), sel.value);
  });
}).catch(() => {});

$('play').addEventListener('click', async () => {
  await ensureAudio();
  if (ctx.state === 'suspended') await ctx.resume();
  if (!buffer) { $('signal').value = 'groove'; $('signal').dispatchEvent(new Event('change')); return; }
  if (playing) pause(); else startAt(offset);
});
$('seek').addEventListener('input', () => {
  if (!buffer) return;
  const pos = Number($('seek').value) * buffer.duration;
  if (playing) startAt(pos); else offset = pos;
});
$('loop').addEventListener('change', () => { if (source) source.loop = $('loop').checked; });
$('volume').addEventListener('input', () => { if (master) master.gain.value = Number($('volume').value); });

function setBypass(on) {
  params.bypass = on;
  sendParams({ bypass: on });
  $('abProc').classList.toggle('on', !on);
  $('abOrig').classList.toggle('on', on);
}
$('abProc').addEventListener('click', () => setBypass(false));
$('abOrig').addEventListener('click', () => setBypass(true));

document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' && e.target.type !== 'range') return;
  if (e.code === 'Space') { e.preventDefault(); $('play').click(); }
  if (e.key === 'b' || e.key === 'B') setBypass(!params.bypass);
  if (e.key === 'h' || e.key === 'H') { setParam('solo', params.solo === 'harmonics' ? 'none' : 'harmonics'); render(); }
  if (e.key === 's' || e.key === 'S') { setParam('speakerSim', !params.speakerSim); render(); }
});

// ------------------------------------------------------------------ controls
function fmtValue(p, v) {
  if (p.fmt) return p.fmt(v);
  if (p.type === 'toggle') return v ? '开' : '关';
  const d = p.step < 0.1 ? 2 : p.step < 1 ? 1 : 0;
  return `${Number(v).toFixed(d)}${p.unit ? ` ${p.unit}` : ''}`;
}

function toSlider(p, v) { return p.log ? Math.log(v / p.min) / Math.log(p.max / p.min) : (v - p.min) / (p.max - p.min); }
function fromSlider(p, s) {
  const raw = p.log ? p.min * Math.pow(p.max / p.min, s) : p.min + s * (p.max - p.min);
  return Math.round(raw / p.step) * p.step;
}

function renderModes() {
  const box = $('modes');
  box.innerHTML = '';
  for (const m of MODES) {
    const b = document.createElement('button');
    b.innerHTML = `${m.label}<small>${m.note}</small>`;
    b.classList.toggle('on', params.mode === m.id);
    b.addEventListener('click', () => { setParam('mode', m.id); render(); });
    box.appendChild(b);
  }
}

function render() {
  renderModes();
  const box = $('panels');
  box.innerHTML = '';
  for (const g of GROUPS) {
    if (g.modes && !g.modes.includes(params.mode)) continue;
    const panel = document.createElement('section');
    panel.className = 'panel';
    panel.innerHTML = `<h2>${g.title}</h2>`;
    for (const p of g.params) {
      if (p.modes && !p.modes.includes(params.mode)) continue;
      const row = document.createElement('div');
      row.className = 'ctl' + (p.type === 'toggle' ? ' toggle' : '');
      const id = `p-${g.title}-${p.key}`.replace(/\W/g, '');
      const val = document.createElement('span');
      val.className = 'val';
      val.textContent = fmtValue(p, params[p.key]);
      const label = document.createElement('label');
      label.htmlFor = id;
      label.textContent = p.label;
      row.append(label, val);
      if (p.type === 'toggle') {
        const t = document.createElement('input');
        t.type = 'checkbox'; t.id = id; t.checked = !!params[p.key];
        t.addEventListener('change', () => { setParam(p.key, t.checked); val.textContent = fmtValue(p, t.checked); });
        val.replaceWith(t);
      } else if (p.type === 'select') {
        const s = document.createElement('select');
        s.id = id;
        for (const [v, l] of p.options) {
          const o = document.createElement('option');
          o.value = String(v); o.textContent = l;
          if (String(params[p.key]) === String(v)) o.selected = true;
          s.appendChild(o);
        }
        s.addEventListener('change', () => {
          const v = typeof p.options[0][0] === 'number' ? Number(s.value) : s.value;
          setParam(p.key, v);
        });
        val.textContent = '';
        row.appendChild(s);
      } else {
        const r = document.createElement('input');
        r.type = 'range'; r.id = id; r.min = 0; r.max = 1; r.step = 0.001;
        r.value = toSlider(p, params[p.key]);
        r.addEventListener('input', () => {
          const v = fromSlider(p, Number(r.value));
          val.textContent = fmtValue(p, v);
          setParam(p.key, v);
        });
        r.addEventListener('dblclick', () => {
          setParam(p.key, DEFAULTS[p.key]);
          r.value = toSlider(p, DEFAULTS[p.key]);
          val.textContent = fmtValue(p, DEFAULTS[p.key]);
        });
        row.appendChild(r);
      }
      if (p.hint) {
        const h = document.createElement('p');
        h.className = 'hint';
        h.style.gridColumn = '1 / -1';
        h.textContent = p.hint;
        row.appendChild(h);
      }
      panel.appendChild(row);
    }
    box.appendChild(panel);
  }
}

const presetSel = $('preset');
presetSel.innerHTML = '<option value="">选择预设…</option>' + Object.keys(PRESETS).map((k) => `<option>${k}</option>`).join('')
  + '<option value="__reset">重置为默认值</option>';
presetSel.addEventListener('change', () => {
  const v = presetSel.value;
  presetSel.value = '';
  if (!v) return;
  const next = v === '__reset' ? { ...DEFAULTS, ...PRESETS['小型扬声器 (模拟)'], mode: params.mode } : PRESETS[v];
  for (const [k, val] of Object.entries(next)) setParam(k, val);
  render();
});

// ------------------------------------------------------------------ meters
const METERS = [
  ['in', '输入峰值'], ['out', '输出峰值'], ['gr', '限幅衰减'], ['harm', '泛音电平'],
  ['low', '截止频率以下低音'], ['lat', '系统延迟'],
];
const meterEls = {};
for (const [id, label] of METERS) {
  const row = document.createElement('div');
  row.className = 'm';
  row.innerHTML = `<span>${label}</span><div class="track${id === 'gr' ? ' gr' : ''}"><div></div></div><b>—</b>`;
  $('meters').appendChild(row);
  meterEls[id] = { bar: row.querySelector('.track > div'), text: row.querySelector('b') };
}
const holds = {};
function setMeter(id, frac, text, warn = false) {
  const el = meterEls[id];
  el.bar.style.width = `${Math.max(0, Math.min(1, frac)) * 100}%`;
  el.text.textContent = text;
  el.text.classList.toggle('warn', warn);
}
const dbFrac = (db) => (db + 60) / 60;

function onWorkletMessage(e) {
  const m = e.data;
  if (m.type === 'info') {
    const i = m.info;
    const lines = [`干声对齐延迟 ${i.alignMs.toFixed(1)} ms`];
    if (loudness) {
      lines.unshift(`音轨响度 ${loudness.lufs.toFixed(1)} LUFS，峰值 ${loudness.peakDB.toFixed(1)} dBFS，`
        + `响度校正 ${params.normalize ? `${loudness.gainDB.toFixed(1)} dB` : '关闭'}`);
    }
    if (i.effDrive !== null && i.effDrive !== undefined) {
      lines.push(`实际工作驱动量 ${i.effDrive}（设定基准 ${params.drive}）`);
    }
    if (i.recipe) {
      lines.push(`分析窗 ${i.delayModel?.frameMs ?? '—'} ms`);
      lines.push('各基频的泛音（阶数：经扬声器后相对原低音的电平 dB）：');
      for (const [f, orders] of i.recipe) lines.push(`${f} Hz  ${orders.map(([k, d]) => `${k}×:${d}`).join('  ')}`);
    }
    if (i.levelModel) {
      lines.push(`谐波阶数 2–${i.orders}；音高补偿 EQ ${i.eq.corners.map((c, j) => `${c} Hz ${i.eq.gainsDB[j] >= 0 ? '+' : ''}${i.eq.gainsDB[j]} dB`).join('，') || '无'}`);
      lines.push('各基频的泛音能量（相对原低音，实际 / 目标）：');
      lines.push(i.levelModel.map(([f, got, want]) => `${f} Hz ${got} / ${want} dB`).join(' · '));
    }
    if (i.delayModel?.perFundamentalMs) {
      lines.push('各基频泛音延迟：');
      lines.push(i.delayModel.perFundamentalMs.map(([f, d]) => `${f} Hz ${d} ms`).join(' · '));
    }
    $('info').textContent = lines.join('\n');
  }
  if (m.type === 'meters') {
    const x = m.meters;
    const now = performance.now();
    const hold = (id, v) => {
      const h = holds[id];
      if (!h || v > h.v || now - h.t > 1500) holds[id] = { v, t: now };
      return holds[id].v;
    };
    const inP = hold('in', x.inPeakDB), outP = hold('out', x.outPeakDB), gr = hold('gr', -x.grDB);
    setMeter('in', dbFrac(inP), `${inP.toFixed(1)} dB`, inP > -0.1);
    setMeter('out', dbFrac(outP), `${outP.toFixed(1)} dB`, outP > -0.1);
    setMeter('gr', gr / 12, `${gr.toFixed(1)} dB`, gr > 3);
    setMeter('harm', dbFrac(x.harmDB), `${x.harmDB.toFixed(1)} dB`);
    setMeter('low', dbFrac(x.lowDB), `${x.lowDB.toFixed(1)} dB`);
    setMeter('lat', x.latencyMs / 120, `${x.latencyMs.toFixed(1)} ms`);
  }
}

// ------------------------------------------------------------------ spectrum
const canvas = $('spectrum');
const g2 = canvas.getContext('2d');
let fIn, fOut, fHarm;
function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

function draw() {
  requestAnimationFrame(draw);
  if (buffer) {
    const pos = position();
    $('seek').value = pos / buffer.duration;
    const t = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
    $('time').textContent = `${t(pos)} / ${t(buffer.duration)}`;
  }
  const dpr = window.devicePixelRatio || 1;
  const W = canvas.clientWidth * dpr, H = canvas.clientHeight * dpr;
  if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
  g2.clearRect(0, 0, W, H);
  const f0 = 20, f1 = 2000, dbLo = -110, dbHi = -10;
  const x = (f) => (Math.log(f / f0) / Math.log(f1 / f0)) * W;
  const y = (db) => H - ((db - dbLo) / (dbHi - dbLo)) * H;
  g2.strokeStyle = cssVar('--line');
  g2.fillStyle = cssVar('--muted');
  g2.lineWidth = 1;
  g2.font = `${10 * dpr}px ${cssVar('--mono')}`;
  for (const f of [20, 30, 50, 100, 200, 300, 500, 1000, 2000]) {
    g2.beginPath(); g2.moveTo(x(f), 0); g2.lineTo(x(f), H); g2.stroke();
    g2.fillText(f >= 1000 ? `${f / 1000}k` : String(f), x(f) + 3 * dpr, H - 4 * dpr);
  }
  g2.setLineDash([4 * dpr, 4 * dpr]);
  g2.strokeStyle = cssVar('--muted');
  g2.beginPath(); g2.moveTo(x(params.cutoff), 0); g2.lineTo(x(params.cutoff), H); g2.stroke();
  g2.setLineDash([]);
  if (!anIn) return;
  const n = anIn.frequencyBinCount;
  if (!fIn) { fIn = new Float32Array(n); fOut = new Float32Array(n); fHarm = new Float32Array(n); }
  anIn.getFloatFrequencyData(fIn);
  anOut.getFloatFrequencyData(fOut);
  anHarm.getFloatFrequencyData(fHarm);
  const binHz = ctx.sampleRate / anIn.fftSize;
  const line = (arr, color, width) => {
    g2.strokeStyle = color;
    g2.lineWidth = width * dpr;
    g2.beginPath();
    let started = false;
    for (let px = 0; px < W; px += 2) {
      const f = f0 * Math.pow(f1 / f0, px / W);
      const b = f / binHz;
      const i = Math.floor(b), fr = b - i;
      const v = (arr[i] ?? -200) * (1 - fr) + (arr[i + 1] ?? -200) * fr;
      const yy = y(Math.max(dbLo, v));
      if (!started) { g2.moveTo(px, yy); started = true; } else g2.lineTo(px, yy);
    }
    g2.stroke();
  };
  line(fIn, cssVar('--dim'), 1.2);
  line(fHarm, cssVar('--accent-2'), 1.2);
  line(fOut, cssVar('--accent'), 1.6);
}

render();
