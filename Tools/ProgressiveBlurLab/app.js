// Progressive blur lab.
//
// Blur radius is a smooth function of x only: zero inside the cover until the
// start point, grows slowly to `edgeRadius` at the cover edge, then
// accelerates across the fill region with a matched slope (C1) and eases into
// `maxRadius` through a soft knee. The curve is then Gaussian-smoothed into a
// per-column lookup table, so the growth rate never jumps.
//
// Renderers sharing that profile:
//   resample  — separable; each pixel resamples one single-axis pyramid
//               level with a smooth kernel of its own sigma (RESAMPLE_FS).
//               Constant cost per pixel whatever the radius, no seams.
//   reference — the same kernel on full-resolution pixels. Slow; used to
//               check the fast path.
//   pyramid   — kept for comparison: mixes two Gaussian-pyramid levels per
//               pixel. The mixed kernel's shape cycles once per octave of
//               sigma, which shows as bands.

const DEFAULTS = {
  placement: 'leading', fill: 'stretch', aspect: '16:9',
  startRatio: 0.02, edgeRadius: 33.5, innerPower: 5.0, maxRadius: 139, endRatio: 0.44, fillPower: 3.7, knee: 0.47, maxSlope: 0.5, smooth: 28, strip: 4,
  algo: 'resample', density: 1.5, renderScale: 1, linear: false, deep: true, dither: true,
  overlay: 'none', contour: 3.5, pattern: 'off',
  autoplay: false, interval: 4, shuffle: true,
};

const CONTROLS = [
  ['半径曲线'],
  { key: 'startRatio', label: '起点（距封面边缘，占封面宽）', min: 0.02, max: 1, step: 0.01, fmt: (v) => `${Math.round(v * 100)}%` },
  { key: 'edgeRadius', label: '封面边缘处半径', min: 0, max: 40, step: 0.5, fmt: (v) => `${v} pt` },
  { key: 'innerPower', label: '封面内增长曲线', min: 1, max: 5, step: 0.05, fmt: (v) => v.toFixed(2) },
  { key: 'maxRadius', label: '最大半径', min: 4, max: 200, step: 1, fmt: (v) => `${v} pt` },
  { key: 'endRatio', label: '到达最大值（占填充宽）', min: 0.1, max: 1.5, step: 0.01, fmt: (v) => `${Math.round(v * 100)}%` },
  { key: 'fillPower', label: '填充区加速', min: 1.05, max: 5, step: 0.05, fmt: (v) => v.toFixed(2) },
  { key: 'knee', label: '末端缓和', min: 0, max: 0.6, step: 0.01, fmt: (v) => v.toFixed(2) },
  { key: 'maxSlope', label: '最大增长斜率', min: 0.1, max: 3, step: 0.05, fmt: (v) => v.toFixed(2) },
  { key: 'smooth', label: '曲线平滑', min: 0, max: 80, step: 1, fmt: (v) => `${v} pt` },
  ['画面'],
  { key: 'placement', label: '封面位置', options: [['leading', '靠左'], ['center', '居中']] },
  { key: 'fill', label: '边缘填充', options: [['stretch', '像素拉伸'], ['mirror', '镜像']] },
  { key: 'strip', label: '拉伸取样宽度', min: 1, max: 40, step: 1, fmt: (v) => `${v} pt` },
  { key: 'aspect', label: '画布比例', options: [['16:10', '16:10'], ['16:9', '16:9'], ['21:9', '21:9'], ['3:2', '3:2']] },
  { key: 'overlay', label: '叠加', options: [['none', '无'], ['heat', '半径热图'], ['contour', '等半径线'], ['grain', '归一化颗粒（配噪声）']] },
  { key: 'contour', label: '等半径线间隔', min: 1, max: 20, step: 0.5, fmt: (v) => `${v} pt` },
  { key: 'pattern', label: '测试图案', options: [['off', '无'], ['grid', '棋盘'], ['noise', '噪声']] },
  ['算法'],
  { key: 'algo', label: '算法', options: [['resample', '分级重采样'], ['reference', '全分辨率参考（慢）'], ['pyramid', '金字塔（旧，会分层）']] },
  { key: 'density', label: '采样密度', min: 1, max: 3, step: 0.1, fmt: (v) => v.toFixed(1) },
  { key: 'renderScale', label: '渲染分辨率', min: 0.25, max: 1, step: 0.05, fmt: (v) => `${Math.round(v * 100)}%` },
  { key: 'linear', label: '线性光混合', check: true },
  { key: 'deep', label: '16 位浮点输出', check: true },
  { key: 'dither', label: '抖动去色带', check: true },
  ['播放'],
  { key: 'autoplay', label: '自动切换', check: true },
  { key: 'interval', label: '切换间隔', min: 1, max: 15, step: 0.5, fmt: (v) => `${v} s` },
  { key: 'shuffle', label: '随机顺序', check: true },
];

const STORE_KEY = 'progressive-blur-lab.params';
let params = { ...DEFAULTS };
try { Object.assign(params, JSON.parse(localStorage.getItem(STORE_KEY) || '{}')); } catch {}
for (const k of Object.keys(params)) if (!(k in DEFAULTS)) delete params[k];
if (!['resample', 'reference', 'pyramid'].includes(params.algo)) params.algo = DEFAULTS.algo;
const saveParams = () => { try { localStorage.setItem(STORE_KEY, JSON.stringify(params)); } catch {} };

// ---------- Radius profile (shared by GLSL and the graph) ----------

// d: signed distance outward from the cover edge. Units are whatever the
// caller uses for every length (pt in the graph, px in the shader).
function sigmaOut(d, coverW, fillW, p) {
  const L = Math.max(p.startRatio * coverW, 1e-3);
  if (d <= -L) return 0;
  let raw;
  if (d <= 0) raw = p.edgeRadius * Math.pow((d + L) / L, p.innerPower);
  else {
    const D = Math.max(p.endRatio * fillW, 1);
    const s = p.edgeRadius * p.innerPower / L;
    const rest = p.maxRadius - p.edgeRadius - s * D;
    raw = rest >= 0 ? p.edgeRadius + s * d + rest * Math.pow(d / D, p.fillPower)
      : p.edgeRadius + (p.maxRadius - p.edgeRadius) * d / D;
  }
  const k = p.knee * p.maxRadius;
  if (k > 0 && raw > p.maxRadius - k) return p.maxRadius - k * Math.exp(-(raw - (p.maxRadius - k)) / k);
  return Math.min(raw, p.maxRadius);
}

// Per-column sigma (px), from buildSigmaLut().
const PROFILE_GLSL = `
uniform sampler2D uLut;
float sigmaAt(float x) {
  float s = texelFetch(uLut, ivec2(int(x), 0), 0).r;
  return s < 0.05 ? 0.0 : s;
}`;

// The piecewise curve can only be made C1 at the cover edge when the fill has
// room to accelerate; with a steep edge it falls back to a straight line and
// the growth rate jumps. A Gaussian pass over the curve removes every such
// corner (and the hard clamp at the max), so the rate always changes smoothly.
function buildSigmaLut(W, H, pxPerPt) {
  const g = coverGeometry(W, H);
  const p = { ...params, edgeRadius: params.edgeRadius * pxPerPt, maxRadius: params.maxRadius * pxPerPt };
  const raw = new Float32Array(W);
  for (let x = 0; x < W; x++) {
    let s = sigmaOut(x + 0.5 - g.x1, g.coverW, W - g.x1, p);
    if (params.placement === 'center') s = Math.max(s, sigmaOut(g.x0 - x - 0.5, g.coverW, g.x0, p));
    raw[x] = s;
  }
  // Slope limit: sigma may grow at most `maxSlope` px per px. Where the curve
  // is steeper, adjacent columns' footprints stop overlapping and sharp
  // content meets heavy blur in a visible wall. The limit raises the inner
  // side (the blur starts earlier) instead of lowering the fill.
  const lambda = params.maxSlope;
  for (let x = W - 2; x >= 0; x--) raw[x] = Math.max(raw[x], raw[x + 1] - lambda);
  for (let x = 1; x < W; x++) raw[x] = Math.max(raw[x], raw[x - 1] - lambda);
  const ss = params.smooth * pxPerPt;
  if (ss < 0.5) return raw;
  const r = Math.ceil(3 * ss), kernel = new Float32Array(2 * r + 1);
  let total = 0;
  for (let i = -r; i <= r; i++) total += kernel[i + r] = Math.exp(-0.5 * (i / ss) ** 2);
  const out = new Float32Array(W);
  for (let x = 0; x < W; x++) {
    let acc = 0;
    for (let i = -r; i <= r; i++) acc += kernel[i + r] * raw[Math.min(W - 1, Math.max(0, x + i))];
    out[x] = acc / total;
  }
  return out;
}

// ---------- GL setup ----------

const canvas = document.getElementById('view');
// alpha: true only because a float drawing buffer needs it; every pixel is
// written opaque.
const gl = canvas.getContext('webgl2', { alpha: true, antialias: false, premultipliedAlpha: false });
if (!gl || !gl.getExtension('EXT_color_buffer_float')) {
  document.getElementById('title').textContent = '需要 WebGL2 与 EXT_color_buffer_float';
  throw new Error('WebGL2 unsupported');
}

const VS = `#version 300 es
void main() {
  vec2 p = vec2[3](vec2(-1, -1), vec2(3, -1), vec2(-1, 3))[gl_VertexID];
  gl_Position = vec4(p, 0, 1);
}`;
const HEAD = `#version 300 es
precision highp float;
precision highp int;
out vec4 outColor;
uniform vec2 uSize;
`;

const FINISH_GLSL = `
uniform int uLinear, uDither, uOverlay;
uniform float uMaxSigma, uContour, uNoiseBias, uDitherStep;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
vec3 toSRGB(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
vec4 finish(vec3 c, float sg) {
  // Normalized grain: blurred white noise scales as 1/sigma, so multiplying
  // by sigma should give the same grain everywhere. Any seam shows as a band.
  // Noise is stored centred on 0 so half floats keep its tiny residual.
  if (uOverlay == 3) return vec4(vec3(0.5 + c.r * max(sg, 0.5) * 3.0), 1.0);
  c += uNoiseBias;
  if (uLinear == 1) c = toSRGB(max(c, 0.0));
  if (uOverlay == 1) {
    float t = clamp(sg / uMaxSigma, 0.0, 1.0);
    vec3 heat = clamp(vec3(1.5 * t, 1.5 - abs(2.0 * t - 1.0) * 1.5, 1.5 * (1.0 - t)), 0.0, 1.0);
    c = mix(c, heat, sg > 0.0 ? 0.4 : 0.0);
  }
  if (uOverlay >= 1) {
    float f = sg / uContour;
    float w = max(fwidth(f), 1e-4);
    float line = 1.0 - smoothstep(0.0, 1.5 * w, abs(fract(f - 0.5) - 0.5));
    c = mix(c, vec3(1.0), sg > 0.0 ? line * 0.85 : 0.0);
  }
  // Triangular dither of one output step: gradients finer than the display's
  // bit depth become fine grain instead of bands.
  if (uDither == 1) c += (hash(gl_FragCoord.xy) + hash(gl_FragCoord.xy + 17.31) - 1.0) * uDitherStep;
  return vec4(c, 1.0);
}`;

// Cover + edge fill at full resolution, linear light when enabled.
const BASE_FS = HEAD + `
uniform sampler2D uCover;
uniform vec4 uGeo;
uniform int uFill, uPattern, uLinear;
uniform float uStripU;
vec3 toLinear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 pattern(vec2 st) {
  float c = mod(floor(st.x * 12.0) + floor(st.y * 12.0), 2.0);
  vec3 col = mix(vec3(0.08, 0.10, 0.14), vec3(0.95, 0.90, 0.80), c);
  float lines = step(0.92, fract(st.x * 48.0)) + step(0.92, fract(st.y * 48.0));
  col = mix(col, vec3(0.9, 0.25, 0.2), min(lines, 1.0) * 0.8);
  float r = length(st - 0.5);
  return mix(col, vec3(0.2, 0.6, 1.0), step(abs(r - 0.3), 0.01));
}
void main() {
  float x = gl_FragCoord.x, x0 = uGeo.x, x1 = uGeo.y, W = uGeo.z;
  float u = (x - x0) / (x1 - x0);
  float t = 1.0 - gl_FragCoord.y / uSize.y;
  if (uFill == 0) {
    if (u > 1.0) u = 1.0 - uStripU * clamp((x - x1) / max(W - x1, 1.0), 0.0, 1.0);
    else if (u < 0.0) u = uStripU * clamp((x0 - x) / max(x0, 1.0), 0.0, 1.0);
  } else {
    u = 1.0 - abs(mod(u, 2.0) - 1.0);
  }
  vec2 st = vec2(u, t);
  // Noise fills the whole canvas: blur strength becomes directly visible as
  // grain size, so any seam between radii shows up as a stripe.
  float n = fract(sin(dot(floor(gl_FragCoord.xy), vec2(12.9898, 78.233))) * 43758.5453);
  vec3 c = uPattern == 1 ? pattern(st) : uPattern == 2 ? vec3(n - 0.5) : texture(uCover, st).rgb;
  outColor = vec4(uLinear == 1 ? toLinear(c) : c, 1.0);
}`;

// One pyramid level: 2x downsample with separable [1 3 3 1]/8.
const DOWN_FS = HEAD + `
uniform sampler2D uSrc;
uniform vec2 uSrcTexel;
void main() {
  vec2 uv = gl_FragCoord.xy / uSize;
  vec2 o = 0.75 * uSrcTexel;
  outColor = 0.25 * (textureLod(uSrc, uv + vec2(-o.x, -o.y), 0.0) + textureLod(uSrc, uv + vec2(o.x, -o.y), 0.0)
                   + textureLod(uSrc, uv + vec2(-o.x, o.y), 0.0) + textureLod(uSrc, uv + vec2(o.x, o.y), 0.0));
}`;

// Single-axis atlas helpers. Levels are stacked along the blur axis; positions
// are in texel-centre units of a level (texel j at j). Beyond the image the
// blur sees the edge pixel repeated. Levels above 0 store two extra texels on
// each side, computed like the rest; the outer one covers only repeated edge
// pixels, so clamping to it is exact at every level.
const ATLAS_GLSL = (axis) => `
uniform vec2 uAtlasSize;
#define POS gl_FragCoord.${axis}
vec2 atlasUV(float a) {
  return ${axis === 'x' ? 'vec2(a / uAtlasSize.x, gl_FragCoord.y / uAtlasSize.y)' : 'vec2(gl_FragCoord.x / uAtlasSize.x, a / uAtlasSize.y)'};
}`;

// One level down along one axis: [1 3 3 1]/8 as two bilinear fetches.
// uSrcBase / uDstBase: atlas coordinate of texel 0 of the source / output
// level; uSrcLo..uSrcHi: the source texels that exist, margins included.
const DOWN1_FS = (axis) => HEAD + ATLAS_GLSL(axis) + `
uniform sampler2D uAtlas;
uniform float uSrcBase, uSrcLo, uSrcHi, uDstBase;
void main() {
  float i = POS - uDstBase - 0.5;
  float a = clamp(2.0 * i - 0.25, uSrcLo, uSrcHi), b = clamp(2.0 * i + 1.25, uSrcLo, uSrcHi);
  outColor = 0.5 * (textureLod(uAtlas, atlasUV(uSrcBase + a + 0.5), 0.0) + textureLod(uAtlas, atlasUV(uSrcBase + b + 0.5), 0.0));
}`;

const PYRAMID_FS = HEAD + PROFILE_GLSL + FINISH_GLSL + `
uniform sampler2D uPyr;
uniform int uLevels;
// Cubic B-spline reconstruction from 4 bilinear taps (C2 smooth, no blocks).
vec4 bspline(int k, vec2 uv) {
  vec2 size = vec2(textureSize(uPyr, k));
  vec2 st = uv * size - 0.5;
  vec2 i = floor(st), f = st - i;
  vec2 f2 = f * f, f3 = f2 * f;
  vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
  vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
  vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
  vec2 w3 = f3 / 6.0;
  vec2 g0 = w0 + w1, g1 = w2 + w3;
  vec2 p0 = (i - 0.5 + w1 / g0) / size;
  vec2 p1 = (i + 1.5 + w3 / g1) / size;
  float lod = float(k);
  return g0.y * (g0.x * textureLod(uPyr, vec2(p0.x, p0.y), lod) + g1.x * textureLod(uPyr, vec2(p1.x, p0.y), lod))
       + g1.y * (g0.x * textureLod(uPyr, vec2(p0.x, p1.y), lod) + g1.x * textureLod(uPyr, vec2(p1.x, p1.y), lod));
}
// Effective variance of B-spline-sampled level k in level-0 pixels:
// sum of downsample variances (0.75 * 4^(j-1)) + B-spline (4^k / 3).
float levelVar(int k) { return k == 0 ? 0.0 : (7.0 / 12.0) * exp2(2.0 * float(k)) - 0.25; }
// Exact full-resolution Gaussian for sigma below level 1 (~1.44 px), where
// mixing sharp and blurred levels would read as a ghost instead of softness.
// Bilinear pairs: 7 taps per axis cover +-6 px, 49 fetches in 2D.
vec4 exactGauss(vec2 uv, float sg) {
  float o[7], w[7];
  float k = -0.5 / (sg * sg), total = 1.0;
  o[0] = 0.0; w[0] = 1.0;
  for (int j = 0; j < 3; j++) {
    float a = float(2 * j + 1), b = a + 1.0;
    float wa = exp(a * a * k), wb = exp(b * b * k), s = wa + wb;
    float off = s > 0.0 ? (a * wa + b * wb) / s : a;
    o[1 + 2 * j] = off; o[2 + 2 * j] = -off;
    w[1 + 2 * j] = s; w[2 + 2 * j] = s;
    total += 2.0 * s;
  }
  vec2 texel = 1.0 / uSize;
  vec4 acc = vec4(0.0);
  for (int i = 0; i < 7; i++)
    for (int j = 0; j < 7; j++)
      acc += w[i] * w[j] * textureLod(uPyr, uv + vec2(o[i], o[j]) * texel, 0.0);
  return acc / (total * total);
}
void main() {
  vec2 uv = gl_FragCoord.xy / uSize;
  float sg = sigmaAt(gl_FragCoord.x);
  float v = sg * sg;
  vec4 c;
  if (v <= 0.0) c = textureLod(uPyr, uv, 0.0);
  else if (v <= levelVar(1)) c = exactGauss(uv, sg);
  else {
    float kf = 0.5 * log2((v + 0.25) * 12.0 / 7.0);
    int k = clamp(int(floor(kf)), 1, uLevels - 2);
    float t = clamp((v - levelVar(k)) / (levelVar(k + 1) - levelVar(k)), 0.0, 1.0);
    vec4 a = k == 1 ? exactGauss(uv, sqrt(levelVar(1))) : bspline(k, uv);
    c = mix(a, bspline(k + 1, uv), t);
  }
  outColor = finish(c.rgb, sg);
}`;

// Separable resampling blur. Sigma depends on x only, so the order matters:
// horizontal first, then vertical. The vertical pass reads one column, whose
// pixels all went through the same horizontal kernel, so every output pixel
// gets exactly the 2D Gaussian of its own sigma. The other order mixes in
// columns that were blurred vertically by a smaller sigma, and the stretched
// fill (rows constant along x) then drags sharp rows far into the blur.
//
// Each pass reads a pyramid downsampled along its own axis only (levels
// stacked in one atlas), picking the level whose texel h = 2^k is at most
// sigma / density. It then sums that level's texels with a smooth compact
// kernel centred on the pixel, in bilinear pairs (one fetch per 2 texels):
//   - the kernel is a Gaussian tapered by (1 - (d/R)^2)^2, R = 3s. It reaches
//     zero with zero slope, so texels entering the window never step.
//   - total variance per axis is exactly sigma^2: the [1 3 3 1] downsamples
//     contribute 0.25 (4^k - 1) px^2, the kernel the rest. Their split varies
//     by a few percent of sigma^2 across an octave and both parts are near
//     Gaussian, so the blur shape stays the same at every radius.
//   - with sigma >= density texels, the sampled kernel's variance ripples by
//     < 1e-3 with the sub-texel phase, and the triple zero of [1 3 3 1]
//     keeps aliasing near DC below 1e-4: no periodic stripes.
//   - levels k and k+1 are mixed only in the last 30% of each octave; both
//     already have the target variance.
// Cost per pass is ~3 * density + 1 fetches, independent of sigma.
// Even levels live in atlas 0, odd levels in atlas 1 (see buildAtlas).
const BLUR_LEVEL_GLSL = (n) => `
vec4 blurLevel${n}(int k, float sg) {
  float h = exp2(float(k));
  float pv = 0.25 * (h * h - 1.0);
  float s = sqrt(max(sg * sg - pv, 1e-4) / KERNEL_VAR) / h;   // level texels
  float R = 3.0 * s, inv = -0.5 / (s * s), invR = 1.0 / (R * R);
  float c = POS / h - 0.5, lo = uLo[k], hi = uHi[k], off = uBase[k] + 0.5;
  int j0 = int(ceil(c - R)), j1 = int(floor(c + R));
  vec4 sum = vec4(0.0);
  float wsum = 0.0;
  for (int j = j0; j <= j1; j += 2) {
    float da = float(j) - c, db = da + 1.0;
    float ua = max(1.0 - da * da * invR, 0.0), ub = max(1.0 - db * db * invR, 0.0);
    float wa = exp(da * da * inv) * ua * ua, wb = exp(db * db * inv) * ub * ub;
    float w = wa + wb;
    if (w <= 0.0) continue;
    sum += w * textureLod(uAtlas${n}, atlasUV(off + clamp(float(j) + wb / w, lo, hi)), 0.0);
    wsum += w;
  }
  return sum / wsum;
}`;
const RESAMPLE_FS = (axis, last) => HEAD + PROFILE_GLSL + FINISH_GLSL + ATLAS_GLSL(axis) + `
uniform sampler2D uAtlas0, uAtlas1;
uniform float uBase[12], uLo[12], uHi[12];
uniform int uLevels;
uniform float uDensity;
const float KERNEL_VAR = 0.6324;   // variance of the tapered kernel, in s^2
${BLUR_LEVEL_GLSL(0)}
${BLUR_LEVEL_GLSL(1)}
vec4 blurLevel(int k, float sg) { return (k & 1) == 0 ? blurLevel0(k, sg) : blurLevel1(k, sg); }
void main() {
  float sg = sigmaAt(gl_FragCoord.x);
  vec4 c;
  if (sg < 0.3) c = texelFetch(uAtlas0, ivec2(gl_FragCoord.xy), 0);
  else {
    float lam = log2(sg / uDensity);
    int k = clamp(int(floor(lam)), 0, uLevels - 1);
    float t = lam >= 0.0 && k < uLevels - 1 ? smoothstep(0.7, 1.0, lam - float(k)) : 0.0;
    c = t < 1.0 ? blurLevel(k, sg) : vec4(0.0);
    if (t > 0.0) c = mix(c, blurLevel(k + 1, sg), t);
  }
  outColor = ${last ? 'finish(c.rgb, sg)' : 'c'};
}`;

function program(fs) {
  const p = gl.createProgram();
  for (const [type, src] of [[gl.VERTEX_SHADER, VS], [gl.FRAGMENT_SHADER, fs]]) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    gl.attachShader(p, s);
  }
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const locs = {};
  const loc = (n) => (n in locs ? locs[n] : (locs[n] = gl.getUniformLocation(p, n)));
  return {
    use() { gl.useProgram(p); return this; },
    f(n, ...v) { gl[`uniform${v.length}f`](loc(n), ...v); return this; },
    i(n, v) { gl.uniform1i(loc(n), v); return this; },
    fv(n, v) { gl.uniform1fv(loc(n), v); return this; },
  };
}

const progs = {
  base: program(BASE_FS),
  down: program(DOWN_FS),
  downX: program(DOWN1_FS('x')),
  downY: program(DOWN1_FS('y')),
  pyramid: program(PYRAMID_FS),
  blurX: program(RESAMPLE_FS('x', false)),
  blurY: program(RESAMPLE_FS('y', true)),
};
gl.bindVertexArray(gl.createVertexArray());

const sampler = gl.createSampler();
gl.samplerParameteri(sampler, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
gl.samplerParameteri(sampler, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
gl.samplerParameteri(sampler, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
gl.bindSampler(0, sampler);

const coverTex = gl.createTexture();
let coverAspect = 1;
gl.bindTexture(gl.TEXTURE_2D, coverTex);
gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([40, 40, 40, 255]));
gl.generateMipmap(gl.TEXTURE_2D);

// Mip-chained RGBA16F target whose levels are our own Gaussian pyramid.
function makeChain(w, h) {
  const sizes = [[w, h]];
  while (sizes.length < 14) {
    const [pw, ph] = sizes[sizes.length - 1];
    if (Math.min(pw, ph) < 4) break;
    sizes.push([Math.max(1, pw >> 1), Math.max(1, ph >> 1)]);
  }
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texStorage2D(gl.TEXTURE_2D, sizes.length, gl.RGBA16F, w, h);
  const fbos = sizes.map((_, k) => {
    const fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, k);
    return fb;
  });
  return { tex, fbos, sizes };
}
function freeChain(c) {
  if (!c) return;
  gl.deleteTexture(c.tex);
  c.fbos.forEach((f) => gl.deleteFramebuffer(f));
}

function buildPyramid(chain) {
  const { tex, fbos, sizes } = chain;
  progs.down.use().i('uSrc', 0);
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, tex);
  for (let k = 1; k < sizes.length; k++) {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_BASE_LEVEL, k - 1);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, k - 1);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbos[k]);
    gl.viewport(0, 0, sizes[k][0], sizes[k][1]);
    progs.down.f('uSize', sizes[k][0], sizes[k][1]).f('uSrcTexel', 1 / sizes[k - 1][0], 1 / sizes[k - 1][1]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_BASE_LEVEL, 0);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, sizes.length - 1);
}

// Single-axis pyramid: level k is W x (H >> k) for y (stacked vertically) or
// (W >> k) x H for x (stacked horizontally). WebGL cannot sample and render
// the same texture, and blitting levels into place costs more than the blur
// itself, so levels alternate between two atlases: even ones in atlas 0, odd
// ones in atlas 1. (A Metal compute pass can write one atlas directly.)
const MAX_LEVELS = 12;
function target(w, h) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, w, h);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  return { tex, fb };
}
function makeAtlas(w, h, axis) {
  // Lengths round up: rounding down would drop the last row or column of an
  // odd level, and coarser levels would no longer reach the image edge.
  // Per level: region start and size in the atlas, atlas coordinate of
  // texel 0, and the range of stored texels (margins included).
  const levels = [];
  let total = 0;
  for (let n = axis === 'x' ? w : h; levels.length < MAX_LEVELS && n >= 4; n = Math.ceil(n / 2)) {
    const m = levels.length ? 2 : 0;
    levels.push({ start: total, size: n + 2 * m, base: total + m, lo: -m, hi: n - 1 + m });
    total += n + 2 * m;
  }
  const aw = axis === 'x' ? total : w, ah = axis === 'x' ? h : total;
  const pad = (key) => Float32Array.from({ length: MAX_LEVELS }, (_, k) => levels[Math.min(k, levels.length - 1)][key]);
  return {
    axis, w, h, aw, ah, levels, t: [target(aw, ah), target(aw, ah)],
    uBase: pad('base'), uLo: pad('lo'), uHi: pad('hi'),
  };
}
function freeAtlas(a) {
  a?.t.forEach((t) => { gl.deleteTexture(t.tex); gl.deleteFramebuffer(t.fb); });
}
// Level 0 must already be in atlas 0.
function buildAtlas(a) {
  const x = a.axis === 'x', p = (x ? progs.downX : progs.downY).use().i('uAtlas', 0).f('uAtlasSize', a.aw, a.ah);
  gl.activeTexture(gl.TEXTURE0);
  for (let k = 1; k < a.levels.length; k++) {
    const src = a.levels[k - 1], dst = a.levels[k];
    gl.bindTexture(gl.TEXTURE_2D, a.t[(k - 1) & 1].tex);
    gl.bindFramebuffer(gl.FRAMEBUFFER, a.t[k & 1].fb);
    if (x) gl.viewport(dst.start, 0, dst.size, a.h);
    else gl.viewport(0, dst.start, a.w, dst.size);
    p.f('uSrcBase', src.base).f('uSrcLo', src.lo).f('uSrcHi', src.hi).f('uDstBase', dst.base);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
function bindAtlas(p, a, density) {
  gl.activeTexture(gl.TEXTURE2);
  gl.bindTexture(gl.TEXTURE_2D, a.t[1].tex);
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, a.t[0].tex);
  return p.i('uAtlas0', 0).i('uAtlas1', 2).f('uAtlasSize', a.aw, a.ah)
    .fv('uBase', a.uBase).fv('uLo', a.uLo).fv('uHi', a.uHi)
    .i('uLevels', a.levels.length).f('uDensity', density);
}

// ---------- Layout ----------

const stage = document.getElementById('stage');
let base = null, yAtlas = null, xAtlas = null, layout = null;

function computeLayout() {
  const sw = stage.clientWidth, sh = stage.clientHeight;
  // The canvas always keeps a landscape ratio, like the fullscreen player.
  let cw = sw, ch = sh;
  const ratio = { '16:10': 16 / 10, '16:9': 16 / 9, '21:9': 21 / 9, '3:2': 3 / 2 }[params.aspect] ?? 16 / 10;
  if (sw / sh > ratio) cw = sh * ratio; else ch = sw / ratio;
  cw = Math.floor(cw); ch = Math.floor(ch);
  const pxPerPt = (window.devicePixelRatio || 1) * params.renderScale;
  const W = Math.max(8, Math.round(cw * pxPerPt)), H = Math.max(8, Math.round(ch * pxPerPt));
  canvas.style.width = `${cw}px`; canvas.style.height = `${ch}px`;
  const resized = canvas.width !== W || canvas.height !== H || !base;
  const deep = params.deep && canDeep;
  if (resized || deep !== deepBuffer) {
    canvas.width = W; canvas.height = H;
    if (canDeep) gl.drawingBufferStorage(deep ? gl.RGBA16F : gl.RGBA8, W, H);
    deepBuffer = deep;
  }
  if (resized) {
    freeChain(base); freeAtlas(yAtlas); freeAtlas(xAtlas);
    base = makeChain(W, H); yAtlas = makeAtlas(W, H, 'y'); xAtlas = makeAtlas(W, H, 'x');
  }
  layout = { W, H, cw, ch, pxPerPt };
}

// Output depth. Everything before the last pass is 16-bit float; with a float
// drawing buffer the last pass stays float too, and the system quantizes once
// to whatever the display takes. The dither step follows the depth the screen
// reports (8 bits per channel here), so no band survives either way.
const canDeep = typeof gl.drawingBufferStorage === 'function';
let deepBuffer = false;
const ditherStep = 1 / (2 ** Math.max(8, (screen.colorDepth || 24) / 3) - 1);
// Reads the canvas as 8-bit RGBA, whatever its storage.
const halfToFloat = (h) => {
  const e = (h >> 10) & 31, m = h & 1023;
  return (h >> 15 ? -1 : 1) * (e ? 2 ** (e - 15) * (1 + m / 1024) : 2 ** -14 * (m / 1024));
};
function readOutput(x, y, w, h) {
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  const type = gl.getParameter(gl.IMPLEMENTATION_COLOR_READ_TYPE);
  const n = w * h * 4, to8 = (v) => Math.round(Math.min(1, Math.max(0, v)) * 255);
  if (type === gl.FLOAT) {
    const f = new Float32Array(n);
    gl.readPixels(x, y, w, h, gl.RGBA, gl.FLOAT, f);
    return Uint8Array.from(f, to8);
  }
  if (type === gl.HALF_FLOAT) {
    const f = new Uint16Array(n);
    gl.readPixels(x, y, w, h, gl.RGBA, gl.HALF_FLOAT, f);
    return Uint8Array.from(f, (v) => to8(halfToFloat(v)));
  }
  const px = new Uint8Array(n);
  gl.readPixels(x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
  return px;
}

// The cover fills the canvas height at its own aspect ratio; never squeezed.
function coverGeometry(width, height) {
  const coverW = height * coverAspect;
  const x0 = params.placement === 'center' ? (width - coverW) / 2 : 0;
  return { x0, x1: x0 + coverW, coverW };
}

// ---------- Render ----------

const lutTex = gl.createTexture();
let lut = null, lutKey = '';
function updateLut() {
  const { W, H, pxPerPt } = layout;
  const key = JSON.stringify([W, H, pxPerPt, coverAspect, params.placement, params.startRatio, params.edgeRadius,
    params.innerPower, params.maxRadius, params.endRatio, params.fillPower, params.knee, params.smooth, params.maxSlope]);
  if (key === lutKey) return;
  lutKey = key;
  lut = buildSigmaLut(W, H, pxPerPt);
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, lutTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R32F, W, 1, 0, gl.RED, gl.FLOAT, lut);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
}

function setProfileUniforms(p) {
  const { W, H, pxPerPt } = layout;
  p.f('uSize', W, H).i('uLut', 1)
    .i('uLinear', params.linear ? 1 : 0).i('uDither', params.dither ? 1 : 0)
    .i('uOverlay', { none: 0, heat: 1, contour: 2, grain: 3 }[params.overlay])
    .f('uNoiseBias', params.pattern === 'noise' ? 0.5 : 0).f('uDitherStep', ditherStep)
    .f('uMaxSigma', params.maxRadius * pxPerPt).f('uContour', params.contour * pxPerPt);
  return p;
}

// The base image and its horizontal levels depend only on the cover and the
// layout, so they are kept while only the radius curve or overlays change.
let coverVersion = 0, baseKey = '';

function render(force = false) {
  const { W, H, pxPerPt } = layout;
  const g = coverGeometry(W, H);
  updateLut();
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, lutTex);
  gl.activeTexture(gl.TEXTURE0);

  const pyramid = params.algo === 'pyramid';
  const key = JSON.stringify([coverVersion, W, H, pxPerPt, coverAspect, params.placement, params.fill, params.strip,
    params.pattern, params.linear, pyramid]);
  const fresh = force || pyramid || key !== baseKey;
  baseKey = key;
  if (fresh) {
    gl.bindTexture(gl.TEXTURE_2D, coverTex);
    gl.bindFramebuffer(gl.FRAMEBUFFER, pyramid ? base.fbos[0] : xAtlas.t[0].fb);
    gl.viewport(0, 0, W, H);
    progs.base.use().i('uCover', 0).f('uSize', W, H)
      .f('uGeo', g.x0, g.x1, W, params.placement === 'center' ? 1 : 0)
      .i('uFill', params.fill === 'stretch' ? 0 : 1).i('uPattern', { grid: 1, noise: 2 }[params.pattern] ?? 0)
      .i('uLinear', params.linear ? 1 : 0).f('uStripU', Math.min(1, params.strip * pxPerPt / g.coverW));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  if (pyramid) {
    buildPyramid(base);
    gl.bindTexture(gl.TEXTURE_2D, base.tex);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, W, H);
    setProfileUniforms(progs.pyramid.use()).i('uPyr', 0).i('uLevels', base.sizes.length);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    return;
  }
  // The reference reads level 0 only: the same kernel at full resolution.
  const density = params.algo === 'reference' ? 1e6 : params.density;
  // Horizontal pass into the y atlas, then its y levels, then vertical.
  if (fresh) buildAtlas(xAtlas);
  gl.bindFramebuffer(gl.FRAMEBUFFER, yAtlas.t[0].fb);
  gl.viewport(0, 0, W, H);
  bindAtlas(setProfileUniforms(progs.blurX.use()), xAtlas, density);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  buildAtlas(yAtlas);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.viewport(0, 0, W, H);
  bindAtlas(setProfileUniforms(progs.blurY.use()), yAtlas, density);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
}

let frameQueued = false;
function requestRender() {
  if (frameQueued) return;
  frameQueued = true;
  requestAnimationFrame(() => {
    frameQueued = false;
    computeLayout();
    render();
    drawGraph();
  });
}

function bench() {
  computeLayout();
  // Queue frames back to back and sync once: GPU throughput per frame,
  // without a pipeline stall after every frame. "Full" redraws the base image
  // each frame (a new cover); "cached" keeps it (radius or animation only).
  const time = (force) => {
    render(force); readOutput(0, 0, 1, 1);
    const n = 60, t0 = performance.now();
    for (let i = 0; i < n; i++) render(force);
    readOutput(0, 0, 1, 1);
    return ((performance.now() - t0) / n).toFixed(2);
  };
  document.getElementById('perf').textContent = `${layout.W}×${layout.H} · 整帧 ${time(true)} ms · 封面不变 ${time(false)} ms`;
}

// ---------- Graph ----------

const graph = document.getElementById('graph');
function drawGraph() {
  const dpr = window.devicePixelRatio || 1;
  const gw = graph.clientWidth, gh = graph.clientHeight;
  graph.width = gw * dpr; graph.height = gh * dpr;
  const ctx = graph.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, gw, gh);
  const { cw: W, ch: H } = layout;
  const g = coverGeometry(W, H);
  const sig = (x) => {
    const f = Math.min(lut.length - 1, Math.max(0, x * layout.pxPerPt - 0.5)), i = Math.floor(f);
    const b = lut[Math.min(lut.length - 1, i + 1)];
    return (lut[i] + (b - lut[i]) * (f - i)) / layout.pxPerPt;
  };
  const pad = 8, n = 300;
  const xs = Array.from({ length: n + 1 }, (_, i) => (i / n) * W);
  const ys = xs.map(sig);
  const ds = ys.map((y, i) => (i === 0 ? 0 : Math.abs(y - ys[i - 1])));
  ds[0] = ds[1];
  const ymax = Math.max(params.maxRadius, 1), dmax = Math.max(...ds, 1e-6);
  const X = (x) => pad + (x / W) * (gw - 2 * pad);
  const Y = (v, m) => gh - pad - (v / m) * (gh - 2 * pad);

  ctx.fillStyle = 'rgba(255,255,255,0.04)';
  ctx.fillRect(X(g.x0), pad, X(g.x1) - X(g.x0), gh - 2 * pad);
  ctx.strokeStyle = '#555'; ctx.lineWidth = 1;
  const marks = [g.x1, g.x1 - params.startRatio * g.coverW];
  if (params.placement === 'center') marks.push(g.x0, g.x0 + params.startRatio * g.coverW);
  for (const m of marks) { ctx.beginPath(); ctx.moveTo(X(m), pad); ctx.lineTo(X(m), gh - pad); ctx.stroke(); }

  const line = (vals, m, color) => {
    ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.beginPath();
    vals.forEach((v, i) => (i ? ctx.lineTo(X(xs[i]), Y(v, m)) : ctx.moveTo(X(xs[i]), Y(v, m))));
    ctx.stroke();
  };
  line(ds, dmax, '#6f9fd8');
  line(ys, ymax, '#e0b25c');
  ctx.fillStyle = '#8d8b88';
  ctx.font = '10px -apple-system, sans-serif';
  ctx.fillText(`${params.maxRadius} pt`, pad + 2, pad + 9);
}

// ---------- Covers ----------

let covers = [], order = [], pos = 0, timer = null, loadToken = 0;

function rebuildOrder() {
  const current = order[pos];
  order = covers.map((_, i) => i);
  if (params.shuffle) for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  pos = Math.max(0, order.indexOf(current));
}

async function show(nextPos) {
  if (!covers.length) return;
  pos = (nextPos + order.length) % order.length;
  const idx = order[pos], token = ++loadToken;
  const blob = await (await fetch(`/art/${idx}`)).blob();
  const bmp = await createImageBitmap(blob);
  if (token !== loadToken) { bmp.close(); return; }
  gl.bindTexture(gl.TEXTURE_2D, coverTex);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, bmp);
  gl.generateMipmap(gl.TEXTURE_2D);
  coverAspect = bmp.width / bmp.height;
  coverVersion++;
  bmp.close();
  const c = covers[idx];
  document.getElementById('title').textContent = `${c.title} — ${c.artist}`;
  document.getElementById('counter').textContent = `${pos + 1} / ${order.length}`;
  requestRender();
  new Image().src = `/art/${order[(pos + 1) % order.length]}`;
}

function restartTimer() {
  clearInterval(timer);
  if (params.autoplay) timer = setInterval(() => show(pos + 1), params.interval * 1000);
}

// ---------- Controls ----------

const controlsEl = document.getElementById('controls');
const refreshers = [];
for (const c of CONTROLS) {
  if (Array.isArray(c)) {
    const h = document.createElement('h2'); h.textContent = c[0]; controlsEl.append(h);
    continue;
  }
  const row = document.createElement('div'); row.className = 'row';
  const label = document.createElement('span'); label.textContent = c.label;
  row.append(label);
  let input, val;
  if (c.options) {
    input = document.createElement('select');
    for (const [v, t] of c.options) input.append(new Option(t, v));
    input.onchange = () => update(c.key, input.value);
    refreshers.push(() => { input.value = params[c.key]; });
    row.append(input);
  } else if (c.check) {
    input = document.createElement('input'); input.type = 'checkbox';
    input.onchange = () => update(c.key, input.checked);
    refreshers.push(() => { input.checked = params[c.key]; });
    row.append(input);
  } else {
    val = document.createElement('span'); val.className = 'val';
    input = document.createElement('input'); input.type = 'range';
    Object.assign(input, { min: c.min, max: c.max, step: c.step });
    input.oninput = () => { update(c.key, Number(input.value)); val.textContent = c.fmt(params[c.key]); };
    refreshers.push(() => { input.value = params[c.key]; val.textContent = c.fmt(params[c.key]); });
    row.append(val, input);
  }
  controlsEl.append(row);
}
const refreshControls = () => refreshers.forEach((r) => r());

function update(key, value) {
  params[key] = value;
  saveParams();
  if (key === 'autoplay' || key === 'interval') restartTimer();
  if (key === 'shuffle') { rebuildOrder(); show(pos); }
  requestRender();
}

document.getElementById('bench').onclick = bench;
document.getElementById('reset').onclick = () => {
  params = { ...DEFAULTS }; saveParams(); refreshControls(); restartTimer(); requestRender();
};
document.getElementById('export').onclick = () => {
  const ta = document.getElementById('exportText');
  const keys = ['placement', 'fill', 'startRatio', 'edgeRadius', 'innerPower', 'maxRadius', 'endRatio', 'fillPower', 'knee', 'maxSlope', 'smooth', 'strip', 'algo', 'density', 'linear', 'dither'];
  ta.value = JSON.stringify(Object.fromEntries(keys.map((k) => [k, params[k]])), null, 2);
  ta.style.display = 'block';
  ta.select();
};
window.addEventListener('keydown', (e) => {
  if (['INPUT', 'SELECT', 'TEXTAREA'].includes(e.target.tagName)) return;
  if (e.key === 'ArrowRight') { show(pos + 1); restartTimer(); }
  else if (e.key === 'ArrowLeft') { show(pos - 1); restartTimer(); }
  else if (e.key === ' ') { e.preventDefault(); update('autoplay', !params.autoplay); refreshControls(); }
});
stage.addEventListener('click', () => { show(pos + 1); restartTimer(); });
new ResizeObserver(requestRender).observe(stage);

window.labDebug = () => ({ lut, layout, coverAspect, gl, yAtlas, xAtlas });
window.labShow = (coverIndex) => show(order.indexOf(coverIndex));
// Console hook for measurements: renders with overrides, returns RGBA8 pixels.
window.labGrab = (overrides = {}) => {
  const saved = { ...params };
  Object.assign(params, overrides);
  computeLayout(); render();
  const { W, H } = layout, px = readOutput(0, 0, W, H);
  params = saved;
  return { W, H, px, lut };
};

refreshControls();
covers = await (await fetch('/api/covers')).json();
rebuildOrder();
restartTimer();
show(0);
