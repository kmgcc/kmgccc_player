// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext, LyricChar } from '../core/types';
import { resolveColor } from '../core/types';

interface CharSprite {
  sprite: PIXI.Text;
  char: LyricChar;
}

export class HeroText extends BaseEffect {
  readonly name = 'heroText';
  private textObj?: PIXI.Text;
  private charSprites: CharSprite[] = [];
  private isWordMode = false;
  private initialRotation = 0;
  private displayedLineIndex = -2;
  
  private lineText = '';
  private textAlpha = 1;
  private fadeState: 'idle' | 'fadeOut' | 'fadeIn' = 'idle';

  protected setup(): void {
    this.container.removeChildren();
    this.charSprites = [];
    this.textObj = undefined;
    this.isWordMode = false;
    
    const fontSize = this.config.fontSize ?? 120;
    const fontFamily = this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", "MS Mincho", serif';
    const color = resolveColor(this.config.color ?? '$text', this.palette);

    const style = new PIXI.TextStyle({
      fontFamily,
      fontSize,
      fontWeight: this.config.fontWeight ?? 'bold',
      fill: color,
      letterSpacing: this.config.letterSpacing ?? 8,
    });

    this.textObj = new PIXI.Text({ text: '', style });
    this.textObj.anchor.set(0.5);
    this.lineText = '';

    this.initialRotation = (this.config.rotation ?? 0) * Math.PI / 180;
    this.textObj.rotation = this.initialRotation;

    this.container.addChild(this.textObj);
  }
  
  private createCharSprites(chars: LyricChar[]): void {
    this.container.removeChildren();
    this.textObj = undefined;
    this.charSprites = [];
    this.isWordMode = true;
    
    const fontSize = this.config.fontSize ?? 72;
    const fontFamily = this.config.fontFamily ?? '"Noto Sans JP", "Hiragino Sans", sans-serif';
    const color = resolveColor(this.config.color ?? '$text', this.palette);
    
    const baseStyle = {
      fontFamily,
      fontSize,
      fontWeight: this.config.fontWeight ?? 'bold',
      fill: color,
      letterSpacing: this.config.letterSpacing ?? 4,
      dropShadow: true,
      dropShadowColor: '#000000',
      dropShadowBlur: 10,
      dropShadowDistance: 0,
    };
    
    for (const char of chars) {
      const sprite = new PIXI.Text({
        text: char.text,
        style: { ...baseStyle },
      });
      sprite.anchor.set(0.5);
      
      this.container.addChild(sprite);
      this.charSprites.push({ sprite, char });
    }
  }
  
  private layoutChars(ctx: UpdateContext): void {
    if (this.charSprites.length === 0) return;
    
    let totalWidth = 0;
    const charWidths: number[] = [];
    const spacing = 8;
    
    for (let i = 0; i < this.charSprites.length; i++) {
      const metrics = PIXI.TextMetrics.measureText(
        this.charSprites[i].char.text,
        this.charSprites[i].sprite.style
      );
      charWidths[i] = metrics.width;
      totalWidth += metrics.width + (i < this.charSprites.length - 1 ? spacing : 0);
    }
    
    const px = this.config.x ?? 0.5;
    const py = this.config.y ?? 0.5;
    const cx = px * ctx.screenWidth;
    const cy = py * ctx.screenHeight;
    
    let x = cx - totalWidth / 2;
    for (let i = 0; i < this.charSprites.length; i++) {
      const cs = this.charSprites[i];
      cs.sprite.x = x + charWidths[i] / 2;
      cs.sprite.y = cy;
      x += charWidths[i] + spacing;
    }
  }
  
  private updateCharStatesByTime(currentTime: number): void {
    for (const cs of this.charSprites) {
      const charStart = cs.char.time;
      const charEnd = cs.char.endTime;
      
      let state: 'future' | 'active' | 'done';
      let progress = 0;
      
      if (currentTime < charStart) {
        state = 'future';
        progress = 0;
      } else if (currentTime >= charEnd) {
        state = 'done';
        progress = 1;
      } else {
        state = 'active';
        const duration = charEnd - charStart;
        progress = duration > 0 ? (currentTime - charStart) / duration : 1;
        progress = Math.max(0, Math.min(1, progress));
      }
      
      const style = cs.sprite.style as PIXI.TextStyle;
      
      switch (state) {
        case 'future':
          cs.sprite.alpha = 0.25;
          (style as any).dropShadowBlur = 0;
          cs.sprite.scale.set(0.95);
          break;
        case 'active':
          cs.sprite.alpha = 0.25 + progress * 0.75;
          (style as any).dropShadowBlur = progress * 15;
          const scale = 1 + Math.sin(progress * Math.PI) * 0.05;
          cs.sprite.scale.set(scale);
          break;
        case 'done':
          cs.sprite.alpha = 1;
          (style as any).dropShadowBlur = 15;
          cs.sprite.scale.set(1);
          break;
      }
    }
  }
  
  private ensureTextObj(): void {
    if (this.textObj) return;
    
    this.container.removeChildren();
    this.charSprites = [];
    this.isWordMode = false;
    
    const fontSize = this.config.fontSize ?? 120;
    const fontFamily = this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", "MS Mincho", serif';
    const color = resolveColor(this.config.color ?? '$text', this.palette);

    const style = new PIXI.TextStyle({
      fontFamily,
      fontSize,
      fontWeight: this.config.fontWeight ?? 'bold',
      fill: color,
      letterSpacing: this.config.letterSpacing ?? 8,
    });

    this.textObj = new PIXI.Text({ text: '', style });
    this.textObj.anchor.set(0.5);
    this.textObj.rotation = this.initialRotation;
    this.container.addChild(this.textObj);
  }

  update(ctx: UpdateContext): void {
    const lyricState = ctx.lyricState;
    const currentLine = lyricState?.currentLine;
    const currentLineIndex = lyricState?.lineIndex ?? -1;
    const currentTime = ctx.time;
    
    const hasChars = currentLine?.chars && currentLine.chars.length > 0;
    
    if (hasChars && currentLineIndex !== this.displayedLineIndex) {
      this.displayedLineIndex = currentLineIndex;
      this.createCharSprites(currentLine!.chars!);
    }
    
    if (hasChars) {
      this.layoutChars(ctx);
      this.updateCharStatesByTime(currentTime);
      return;
    }
    
    if (this.isWordMode || currentLineIndex !== this.displayedLineIndex) {
      this.displayedLineIndex = currentLineIndex;
      this.charSprites = [];
      this.isWordMode = false;
      this.ensureTextObj();
      this.textAlpha = 0;
      this.fadeState = 'fadeIn';
      this.lineText = '';
    }
    
    const newText = currentLine?.text ?? ctx.currentText ?? '';

    if (newText !== this.lineText && this.fadeState === 'idle') {
      this.fadeState = 'fadeOut';
    }

    const fadeSpeed = 4 * Math.max(ctx.animationSpeed, 0.5);
    if (this.fadeState === 'fadeOut') {
      this.textAlpha -= ctx.deltaTime * fadeSpeed;
      if (this.textAlpha <= 0) {
        this.textAlpha = 0;
        if (this.textObj) {
          this.textObj.text = newText;
          this.lineText = newText;
        }
        this.fadeState = 'fadeIn';
      }
    } else if (this.fadeState === 'fadeIn') {
      this.textAlpha += ctx.deltaTime * fadeSpeed;
      if (this.textAlpha >= 1) {
        this.textAlpha = 1;
        this.fadeState = 'idle';
      }
    }
    
    if (this.textObj) {
      this.textObj.alpha = this.textAlpha;
      
      const px = this.config.x ?? 0.5;
      const py = this.config.y ?? 0.5;
      this.textObj.x = px * ctx.screenWidth;
      this.textObj.y = py * ctx.screenHeight;

      const animation = this.config.animation ?? 'breathe';
      if (animation === 'breathe') {
        const speed = (this.config.animationSpeed ?? 0.5) * ctx.animationSpeed;
        const amount = (this.config.animationAmount ?? 0.03) * ctx.motionIntensity;
        const beatPulse = ctx.beatIntensity * 0.08;
        const scale = 1 + Math.sin(ctx.time * speed * Math.PI * 2) * amount + beatPulse;
        this.textObj.scale.set(scale);
      } else if (animation === 'rotate') {
        const rotSpeed = (this.config.rotationSpeed ?? 0.1) * ctx.animationSpeed;
        this.textObj.rotation = this.initialRotation + ctx.time * rotSpeed;
      }
    }
  }
}