// PV Embed Core - Engine
// 基于原项目重构，保留完整模板/效果系统，移除无关功能

import * as PIXI from 'pixi.js';
import type { 
  TemplateConfig, 
  UpdateContext, 
  ColorPalette, 
  LayerType, 
  LyricLine, 
  LyricState,
  MediaInfo 
} from './types';
import { BeatProvider } from './beatProvider';
import { GlitchFilter } from './glitchFilter';
import { parseLyrics, getCurrentLine, getCharStates, LyricFormat } from './lyrics';
import { createEffect, BaseEffect } from '../effects';

const EFFECT_LAYERS: LayerType[] = ['background', 'decoration', 'text', 'overlay'];

export class PVEngine {
  private app!: PIXI.Application;
  private layers = new Map<LayerType, PIXI.Container>();
  private effectsRoot!: PIXI.Container;
  private activeEffects: BaseEffect[] = [];
  private palette: ColorPalette = {
    background: '#000000',
    primary: '#ffffff',
    secondary: '#888888',
    accent: '#ff3366',
    text: '#ffffff',
  };
  private currentTemplate: TemplateConfig | null = null;
  
  // 歌词系统
  private lyricLines: LyricLine[] = [];
  private lyricFormat: LyricFormat = 'lrc';
  private currentLyricState: LyricState | null = null;
  private _currentTime = 0;
  
  // 配置
  private _animationSpeed = 1;
  private _motionIntensity = 1;
  private _segmentDuration = 3;
  private _effectOpacity = 1;
  private _alphaMode = false;
  
  // PostFX
  private _shake = 0;
  private _zoom = 0;
  private _tilt = 0;
  private _glitch = 0;
  private _hueShift = 0;
  private hueFilter: PIXI.ColorMatrixFilter;
  private glitchFilter: GlitchFilter;
  private bgFill!: PIXI.Graphics;
  
  // 状态
  private _paused = false;
  private _time = 0;
  private _lastFrameTime = 0;
  private _tick = 0;
  private _beatReactivity = 0.5;
  private _nativeDPR = 1;
  private _currentResolution = 1;
  private _resizeParent: HTMLElement | null = null;
  
  // 媒体
  private mediaInfo: MediaInfo = {};
  private artworkTexture: PIXI.Texture | null = null;
  
  // 用户文本（当没有歌词时间轴时使用）
  private userText = '';
  private textSegments: string[] = [''];
  
  readonly beat = new BeatProvider();
  
  constructor() {
    this.hueFilter = new PIXI.ColorMatrixFilter();
    this.glitchFilter = new GlitchFilter();
  }
  
  async init(parent: HTMLElement): Promise<void> {
    this._nativeDPR = Math.min(window.devicePixelRatio || 1, 3);
    this._currentResolution = this._nativeDPR;
    this._resizeParent = parent;
    
    this.app = new PIXI.Application();
    
    await this.app.init({
      resizeTo: parent,
      backgroundColor: 0x000000,
      backgroundAlpha: 0,
      antialias: true,
      resolution: this._nativeDPR,
      autoDensity: true,
      preserveDrawingBuffer: true,
    });
    
    parent.appendChild(this.app.canvas);
    
    // 媒体层在最底层
    const mediaLayer = new PIXI.Container();
    this.layers.set('media', mediaLayer);
    this.app.stage.addChild(mediaLayer);
    
    // 效果层
    this.effectsRoot = new PIXI.Container();
    this.app.stage.addChild(this.effectsRoot);
    
    // 背景填充
    this.bgFill = new PIXI.Graphics();
    this.effectsRoot.addChild(this.bgFill);
    
    for (const layerType of EFFECT_LAYERS) {
      const container = new PIXI.Container();
      this.layers.set(layerType, container);
      this.effectsRoot.addChild(container);
    }
    
    this._lastFrameTime = performance.now();
    
    this.app.stage.filters = [this.hueFilter, this.glitchFilter];
    
    // 渲染循环
    this.app.ticker.add((ticker) => {
      const now = performance.now();
      const dt = (now - this._lastFrameTime) / 1000;
      this._lastFrameTime = now;
      
      if (!this._paused) {
        if (this.beat.isAudioMode) {
          this._time = this.beat.currentTime;
        } else {
          this._time += dt * this._animationSpeed;
        }
      }
      
      this._currentTime = this._time;
      this.update(this._time, ticker.deltaTime / 60);
    });
    
    console.log('[PVEngine] Initialized successfully');
  }
  
  // ===== 核心 API =====
  
  setMedia(info: MediaInfo): void {
    this.mediaInfo = info;
  }
  
  async setArtwork(url: string): Promise<void> {
    try {
      if (this.artworkTexture) {
        this.artworkTexture.destroy();
        this.artworkTexture = null;
      }
      
      const img = new Image();
      img.crossOrigin = 'anonymous';
      img.src = url;
      
      await new Promise<void>((resolve, reject) => {
        img.onload = () => resolve();
        img.onerror = () => reject(new Error('Failed to load artwork'));
      });
      
      // 限制最大尺寸
      const maxDim = 2048;
      let finalImg = img;
      if (img.naturalWidth > maxDim || img.naturalHeight > maxDim) {
        const scale = maxDim / Math.max(img.naturalWidth, img.naturalHeight);
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(img.naturalWidth * scale);
        canvas.height = Math.round(img.naturalHeight * scale);
        const ctx = canvas.getContext('2d')!;
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        
        const scaledImg = new Image();
        scaledImg.src = canvas.toDataURL();
        await new Promise<void>((r) => { scaledImg.onload = () => r(); });
        finalImg = scaledImg;
      }
      
      this.artworkTexture = PIXI.Texture.from(finalImg);
      this.updateMediaLayer();
      
      console.log('[PVEngine] Artwork loaded:', url);
    } catch (err) {
      console.warn('[PVEngine] Failed to load artwork:', err);
    }
  }
  
  setPalette(palette: ColorPalette): void {
    this.palette = { ...palette };
    if (!this._alphaMode) {
      this.app.renderer.background.color = new PIXI.Color(palette.background).toNumber();
    }
    this.updateBgFill();
    
    if (this.currentTemplate) {
      this.loadTemplate({
        ...this.currentTemplate,
        palette: this.palette
      });
    }
  }
  
  setLyrics(text: string, format: LyricFormat): boolean {
    try {
      const result = parseLyrics(text, format);
      this.lyricLines = result.lines;
      this.lyricFormat = result.format;
      
      // 设置第一行作为默认文本
      if (this.lyricLines.length > 0) {
        this.userText = this.lyricLines[0].text;
        this.textSegments = [this.userText];
      }
      
      // 如果有模板，刷新以应用新文本
      if (this.currentTemplate) {
        this.loadTemplate(this.currentTemplate);
      }
      
      console.log('[PVEngine] Lyrics loaded:', result.format, result.lines.length, 'lines');
      return true;
    } catch (err) {
      console.error('[PVEngine] Failed to parse lyrics:', err);
      return false;
    }
  }
  
  setText(text: string): void {
    // 清除歌词时间轴，使用普通文本
    this.lyricLines = [];
    this.userText = text;
    this.textSegments = text.split('/').map(s => s.trim()).filter(s => s.length > 0);
    if (this.textSegments.length === 0) {
      this.textSegments = [text];
    }
    
    if (this.currentTemplate) {
      this.loadTemplate(this.currentTemplate);
    }
  }
  
  setCurrentTime(seconds: number): void {
    this._time = Math.max(0, seconds);
    this._currentTime = this._time;
    this._lastFrameTime = performance.now();
  }
  
  // ===== 节奏控制 =====
  
  setBPM(bpm: number): void {
    this.beat.bpm = bpm;
  }
  
  getBPM(): number {
    return this.beat.bpm;
  }
  
  setBeatReactivity(value: number): void {
    this._beatReactivity = Math.max(0, Math.min(1, value));
  }
  
  getBeatReactivity(): number {
    return this._beatReactivity;
  }
  
  // ===== 视觉控制 =====
  
  setTemplate(template: TemplateConfig): void {
    this.loadTemplate(template);
  }
  
  setShake(value: number): void {
    this._shake = Math.max(0, Math.min(1, value));
  }
  
  setZoom(value: number): void {
    this._zoom = Math.max(-1, Math.min(1, value));
  }
  
  setTilt(value: number): void {
    this._tilt = Math.max(-1, Math.min(1, value));
  }
  
  setGlitch(value: number): void {
    this._glitch = Math.max(0, Math.min(1, value));
    this.glitchFilter.intensity = this._glitch;
  }
  
  setHueShift(value: number): void {
    this._hueShift = Math.max(-180, Math.min(180, value));
    this.hueFilter.matrix = [1,0,0,0,0, 0,1,0,0,0, 0,0,1,0,0, 0,0,0,1,0];
    this.hueFilter.hue(this._hueShift, false);
  }
  
  // ===== 播放器状态 =====
  
  play(): void {
    this._paused = false;
    this._lastFrameTime = performance.now();
    this.beat.play();
  }
  
  pause(): void {
    this._paused = true;
    this.beat.pause();
  }
  
  resize(width: number, height: number): void {
    if (this._resizeParent) {
      this._resizeParent.style.width = `${width}px`;
      this._resizeParent.style.height = `${height}px`;
    }
    this.app.renderer.resize(width, height);
    this.updateBgFill();
    this.updateMediaLayer();
  }
  
  destroy(): void {
    this.clearEffects();
    this.app.destroy(true);
    if (this.artworkTexture) {
      this.artworkTexture.destroy();
    }
  }
  
  // ===== 状态获取 =====
  
  getCurrentTime(): number {
    return this._currentTime;
  }
  
  getLyricState(): LyricState | null {
    return this.currentLyricState;
  }
  
  get canvas(): HTMLCanvasElement {
    return this.app.canvas as HTMLCanvasElement;
  }
  
  // ===== 内部方法 =====
  
  private loadTemplate(template: TemplateConfig): void {
    console.log('[PVEngine] Loading template:', template.name);
    
    this.clearEffects();
    this.currentTemplate = template;
    this.palette = { ...template.palette };
    
    if (!this._alphaMode) {
      this.app.renderer.background.color = new PIXI.Color(this.palette.background).toNumber();
    }
    this.updateBgFill();
    
    // 应用模板参数
    if (template.animationSpeed !== undefined) {
      this._animationSpeed = template.animationSpeed;
    }
    if (template.bgOpacity !== undefined) {
      this._effectOpacity = template.bgOpacity;
      this.bgFill.alpha = template.bgOpacity;
    }
    
    // 应用PostFX
    if (template.postfx) {
      this._shake = template.postfx.shake ?? 0;
      this._zoom = template.postfx.zoom ?? 0;
      this._tilt = template.postfx.tilt ?? 0;
      this._glitch = template.postfx.glitch ?? 0;
      this._hueShift = template.postfx.hueShift ?? 0;
      this.glitchFilter.intensity = this._glitch;
      this.hueFilter.hue(this._hueShift, false);
    }
    
    // 实例化所有effect - 关键修复：调用setup()
    let successCount = 0;
    for (const entry of template.effects) {
      const layer = this.layers.get(entry.layer);
      if (!layer) {
        console.warn('[PVEngine] Layer not found:', entry.layer);
        continue;
      }
      
      const config = { ...entry.config };
      // 注入用户文本
      if (this.userText && !config._userText) {
        config._userText = this.textSegments[0] || this.userText;
      }
      
      try {
        const effect = createEffect(entry.type, layer, config, this.palette);
        this.activeEffects.push(effect);
        successCount++;
      } catch (err) {
        console.warn(`[PVEngine] Failed to create effect "${entry.type}":`, err);
      }
    }
    
    console.log(`[PVEngine] Template loaded: ${successCount}/${template.effects.length} effects created`);
    
    // 检查是否有效果
    if (successCount === 0) {
      console.error('[PVEngine] WARNING: No effects were created! Template will be blank.');
    }
    
    this.syncResolution();
  }
  
  private updateMediaLayer(): void {
    const mediaLayer = this.layers.get('media');
    if (!mediaLayer) return;
    
    mediaLayer.removeChildren().forEach(c => c.destroy({ children: true }));
    
    if (this.artworkTexture) {
      const sprite = new PIXI.Sprite(this.artworkTexture);
      sprite.anchor.set(0.5);
      sprite.x = this.app.screen.width / 2;
      sprite.y = this.app.screen.height / 2;
      
      // 适配屏幕
      const scale = Math.max(
        this.app.screen.width / sprite.texture.width,
        this.app.screen.height / sprite.texture.height
      );
      sprite.scale.set(scale);
      sprite.alpha = 0.5;
      
      mediaLayer.addChild(sprite);
    }
  }
  
  private updateBgFill(): void {
    if (!this.bgFill) return;
    const w = this.app.screen.width;
    const h = this.app.screen.height;
    const pad = Math.max(w, h) * 0.5;
    this.bgFill.clear();
    this.bgFill.rect(-pad, -pad, w + pad * 2, h + pad * 2);
    this.bgFill.fill({ color: this.palette.background });
  }
  
  private updateLyricState(time: number): void {
    const { line, index } = getCurrentLine(this.lyricLines, time);
    
    if (!line) {
      this.currentLyricState = null;
      return;
    }
    
    const charStates = line.chars ? getCharStates(line, time) : null;
    
    this.currentLyricState = {
      currentLine: line,
      currentChars: line.chars || null,
      lineIndex: index,
      charStates: charStates || [],
      isWordLevel: !!line.chars
    };
  }
  
  private getDisplayText(time: number): string {
    // 优先使用歌词时间轴
    if (this.lyricLines.length > 0) {
      const { line } = getCurrentLine(this.lyricLines, time);
      if (line) return line.text;
    }
    
    // 回退到普通文本分段
    if (this.textSegments.length > 0) {
      const segIdx = this.textSegments.length > 1
        ? Math.floor(time / this._segmentDuration) % this.textSegments.length
        : 0;
      return this.textSegments[segIdx] || '';
    }
    
    return this.mediaInfo.title || '';
  }
  
  private update(time: number, deltaTime: number): void {
    // 更新歌词状态
    this.updateLyricState(time);
    
    // 构建上下文
    const lyricState = this.currentLyricState;
    const currentText = this.getDisplayText(time);
    
    const ctx: UpdateContext = {
      time,
      deltaTime,
      screenWidth: this.app.screen.width,
      screenHeight: this.app.screen.height,
      palette: this.palette,
      animationSpeed: this._animationSpeed,
      motionIntensity: this._motionIntensity,
      currentText,
      beatIntensity: this.beat.getIntensity(time) * this._beatReactivity,
      lyricState,
      motionTargets: [], // 不再使用motion detection
    };
    
    this.updateBgFill();
    this.applyCameraFX(time);
    
    this._tick++;
    
    // 性能优化：重效果跳帧
    const n = this.activeEffects.length;
    const heavySkip = n > 15 ? 3 : n > 8 ? 2 : 0;
    
    for (const effect of this.activeEffects) {
      try {
        if (heavySkip && effect.heavy && this._tick % heavySkip !== 0) continue;
        effect.update(ctx);
      } catch (err) {
        console.warn(`[PVEngine] Effect "${effect.name}" update error:`, err);
      }
    }
  }
  
  private applyCameraFX(time: number): void {
    const w = this.app.screen.width;
    const h = this.app.screen.height;
    const cx = w / 2;
    const cy = h / 2;
    
    this.app.stage.pivot.set(cx, cy);
    
    let px = cx, py = cy;
    
    // 节拍响应的震动
    const beatShake = this.beat.getIntensity(time) * this._beatReactivity;
    const totalShake = this._shake + beatShake * 0.15;
    if (totalShake > 0) {
      px += (Math.random() - 0.5) * totalShake * 30;
      py += (Math.random() - 0.5) * totalShake * 20;
    }
    
    this.app.stage.position.set(px, py);
    this.app.stage.scale.set(1 + this._zoom * 0.5);
    this.app.stage.rotation = this._tilt * 0.3;
    
    this.glitchFilter.time = time;
  }
  
  private clearEffects(): void {
    for (const e of this.activeEffects) {
      try { e.destroy(); } catch { }
    }
    this.activeEffects = [];
    
    for (const [key, layer] of this.layers) {
      if (key !== 'media' && layer.children.length > 0) {
        try { layer.removeChildren().forEach(c => c.destroy()); } catch { }
      }
    }
  }
  
  private syncResolution(): void {
    const n = this.activeEffects.length;
    const dpr = this._nativeDPR;
    
    let target: number;
    if (n <= 6) {
      target = dpr;
    } else if (n <= 12) {
      target = Math.min(dpr, 2);
    } else if (n <= 18) {
      target = Math.min(dpr, 1.5);
    } else {
      target = 1;
    }
    
    target = Math.round(target * 4) / 4;
    
    if (target !== this._currentResolution) {
      this._currentResolution = target;
      this.app.renderer.resolution = target;
      if (this._resizeParent) {
        const w = this._resizeParent.clientWidth;
        const h = this._resizeParent.clientHeight;
        this.app.renderer.resize(w, h);
      }
    }
  }
}
