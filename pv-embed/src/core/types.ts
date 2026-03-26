// PV Embed Core - Types
// 基于 pv-tool 重构的可嵌入播放器组件

export type LayerType = 'background' | 'decoration' | 'media' | 'text' | 'overlay';

export interface ColorPalette {
  background: string;
  primary: string;
  secondary: string;
  accent: string;
  text: string;
}

export interface EffectEntry {
  type: string;
  layer: LayerType;
  config: Record<string, any>;
}

export interface TemplateConfig {
  name: string;
  palette: ColorPalette;
  effects: EffectEntry[];
  bpm?: number;
  animationSpeed?: number;
  bgOpacity?: number;
  postfx?: {
    shake?: number;
    zoom?: number;
    tilt?: number;
    glitch?: number;
    hueShift?: number;
  };
  features?: {
    mediaOutline?: boolean;
  };
}

export interface MotionTargetInfo {
  id: string;
  x: number;
  y: number;
  w: number;
  h: number;
  area: number;
}

// ===== 歌词系统统一类型 =====

export interface LyricChar {
  text: string;
  time: number;      // 开始时间（秒）
  endTime: number;   // 结束时间（秒）
  duration: number;  // 持续时间
}

export interface LyricLine {
  time: number;      // 行开始时间
  endTime: number;   // 行结束时间
  text: string;      // 完整行文本
  chars?: LyricChar[]; // 逐字信息（可选）
  hasChars?: boolean; // 是否有逐字信息
}

export type LyricFormat = 'lrc' | 'ttml-line' | 'ttml-word';

export interface LyricState {
  currentLine: LyricLine | null;
  currentChars: LyricChar[] | null;
  lineIndex: number;
  charStates: CharState[];
  isWordLevel: boolean;
}

export interface CharState {
  char: LyricChar;
  state: 'future' | 'active' | 'done';
  progress: number; // 0-1，active状态下的进度
}

export interface UpdateContext {
  time: number;
  deltaTime: number;
  screenWidth: number;
  screenHeight: number;
  palette: ColorPalette;
  animationSpeed: number;
  motionIntensity: number;
  currentText: string;
  beatIntensity: number;
  lyricState: LyricState | null;
  motionTargets: MotionTargetInfo[];
}

export interface Beat {
  time: number;
  type: 'kick' | 'snare' | 'accent';
}

// ===== API 接口类型 =====

export interface MediaInfo {
  title?: string;
  artist?: string;
  album?: string;
}

export interface PVEmbedAPI {
  // 内容输入
  setMedia(info: MediaInfo): void;
  setArtwork(url: string): Promise<void>;
  setPalette(palette: ColorPalette): void;
  setLyrics(text: string, format: LyricFormat): boolean;
  setCurrentTime(seconds: number): void;
  
  // 节奏控制
  setBPM(bpm: number): void;
  getBPM(): number;
  setBeatReactivity(value: number): void;
  getBeatReactivity(): number;
  
  // 视觉控制
  setTemplate(nameOrId: string): void;
  setShake(value: number): void;
  setZoom(value: number): void;
  setTilt(value: number): void;
  setGlitch(value: number): void;
  setHueShift(value: number): void;
  
  // 播放器状态
  play(): void;
  pause(): void;
  resize(width: number, height: number): void;
  destroy(): void;
  
  // 状态获取
  getCurrentTime(): number;
  getLyricState(): LyricState | null;
}

export function resolveColor(color: string, palette: ColorPalette): string {
  if (color === '$line') {
    const luminance = (hex: string): number => {
      const r = parseInt(hex.slice(1, 3), 16);
      const g = parseInt(hex.slice(3, 5), 16);
      const b = parseInt(hex.slice(5, 7), 16);
      return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    };
    return luminance(palette.background) > 0.55 ? '#999999' : '#ffffff';
  }
  if (color.startsWith('$')) {
    const key = color.slice(1) as keyof ColorPalette;
    return palette[key] || '#000000';
  }
  return color;
}
