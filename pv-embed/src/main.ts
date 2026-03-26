// PV Embed - Main API Entry
// 统一暴露的 API 接口

import { PVEngine } from './core/engine';
import type { 
  PVEmbedAPI, 
  MediaInfo, 
  ColorPalette, 
  LyricFormat,
  LyricState,
  TemplateConfig 
} from './core/types';
import { templates, getTemplateByName, getTemplateByIndex } from './templates';

export { templates, getTemplateByName, getTemplateByIndex };
export type { 
  PVEmbedAPI, 
  MediaInfo, 
  ColorPalette, 
  LyricFormat,
  LyricState,
  TemplateConfig 
} from './core/types';

export class PVEmbed implements PVEmbedAPI {
  private engine: PVEngine;
  private container: HTMLElement | null = null;
  private _currentTime = 0;
  private _isPlaying = false;
  
  constructor() {
    this.engine = new PVEngine();
  }
  
  async init(container: HTMLElement | string): Promise<void> {
    if (typeof container === 'string') {
      const el = document.getElementById(container);
      if (!el) throw new Error(`Element with id "${container}" not found`);
      this.container = el;
    } else {
      this.container = container;
    }
    
    await this.engine.init(this.container);
    
    // 默认加载第一个模板
    if (templates.length > 0) {
      this.setTemplate('0');
    }
  }
  
  // ===== 内容输入 =====
  
  setMedia(info: MediaInfo): void {
    this.engine.setMedia(info);
  }
  
  async setArtwork(url: string): Promise<void> {
    await this.engine.setArtwork(url);
  }
  
  setPalette(palette: ColorPalette): void {
    this.engine.setPalette(palette);
  }
  
  setLyrics(text: string, format: LyricFormat): boolean {
    return this.engine.setLyrics(text, format);
  }
  
  setText(text: string): void {
    this.engine.setText(text);
  }
  
  setCurrentTime(seconds: number): void {
    this.engine.setCurrentTime(seconds);
  }
  
  // ===== 节奏控制 =====
  
  setBPM(bpm: number): void {
    this.engine.setBPM(bpm);
  }
  
  getBPM(): number {
    return this.engine.getBPM();
  }
  
  setBeatReactivity(value: number): void {
    this.engine.setBeatReactivity(value);
  }
  
  getBeatReactivity(): number {
    return this.engine.getBeatReactivity();
  }
  
  // ===== 视觉控制 =====
  
  setTemplate(nameOrId: string): void {
    // 尝试按名称查找
    let template = getTemplateByName(nameOrId);
    
    // 尝试按索引查找
    if (!template) {
      const index = parseInt(nameOrId, 10);
      if (!isNaN(index)) {
        template = getTemplateByIndex(index);
      }
    }
    
    // 回退到第一个模板
    if (!template && templates.length > 0) {
      template = templates[0];
    }
    
    if (template) {
      this.engine.setTemplate(template);
    }
  }
  
  setShake(value: number): void {
    this.engine.setShake(value);
  }
  
  setZoom(value: number): void {
    this.engine.setZoom(value);
  }
  
  setTilt(value: number): void {
    this.engine.setTilt(value);
  }
  
  setGlitch(value: number): void {
    this.engine.setGlitch(value);
  }
  
  setHueShift(value: number): void {
    this.engine.setHueShift(value);
  }
  
  // ===== 播放器状态 =====
  
  play(): void {
    this._isPlaying = true;
    this.engine.play();
  }
  
  pause(): void {
    this._isPlaying = false;
    this.engine.pause();
  }
  
  resize(width: number, height: number): void {
    this.engine.resize(width, height);
  }
  
  destroy(): void {
    this.engine.destroy();
    this.container = null;
  }
  
  // ===== 状态获取 =====
  
  getCurrentTime(): number {
    return this.engine.getCurrentTime();
  }
  
  getLyricState(): LyricState | null {
    return this.engine.getLyricState();
  }
  
  // ===== 扩展 API =====
  
  get isPlaying(): boolean {
    return !this.engine.beat.paused;
  }
  
  get canvas(): HTMLCanvasElement {
    return this.engine.canvas;
  }
}

// 全局暴露
if (typeof window !== 'undefined') {
  (window as any).PVEmbed = PVEmbed;
  (window as any).PVEmbedTemplates = templates;
}

export default PVEmbed;
