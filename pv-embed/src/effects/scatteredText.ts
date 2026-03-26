// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface TextParticle {
  textObj: PIXI.Text;
  baseX: number;
  baseY: number;
  baseAlpha: number;
  fadeSpeed: number;
  fadePhase: number;
}

export class ScatteredText extends BaseEffect {
  readonly name = 'scatteredText';
  private particles: TextParticle[] = [];
  private initialized = false;

  protected setup(): void {}

  private initParticles(width: number, height: number): void {
    if (this.initialized) return;
    this.initialized = true;

    const userText = this.config._userText ?? '';
    const chars = userText || this.config.chars || '';
    if (chars.length === 0) return;
    const count = this.config.count ?? 15;
    const color = resolveColor(this.config.color ?? '$secondary', this.palette);
    const fontFamily = this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", serif';
    const minSize = this.config.minSize ?? 20;
    const maxSize = this.config.maxSize ?? 60;

    for (let i = 0; i < count; i++) {
      const char = chars[Math.floor(Math.random() * chars.length)];
      const fontSize = minSize + Math.random() * (maxSize - minSize);

      const style = new PIXI.TextStyle({
        fontFamily,
        fontSize,
        fill: color,
        fontWeight: Math.random() > 0.5 ? 'bold' : 'normal',
      });

      const textObj = new PIXI.Text({ text: char, style });
      textObj.anchor.set(0.5);
      textObj.rotation = (Math.random() - 0.5) * 0.6;

      const baseX = Math.random() * width;
      const baseY = Math.random() * height;
      textObj.x = baseX;
      textObj.y = baseY;

      const baseAlpha = 0.35 + Math.random() * 0.5;
      textObj.alpha = baseAlpha;

      this.particles.push({
        textObj,
        baseX,
        baseY,
        baseAlpha,
        fadeSpeed: 0.3 + Math.random() * 0.5,
        fadePhase: Math.random() * Math.PI * 2,
      });

      this.container.addChild(textObj);
    }
  }

  update(ctx: UpdateContext): void {
    this.initParticles(ctx.screenWidth, ctx.screenHeight);

    for (const p of this.particles) {
      const drift = ctx.motionIntensity;
      const spd = ctx.animationSpeed;
      p.textObj.x = p.baseX + Math.sin(ctx.time * 0.3 * spd + p.fadePhase) * 10 * drift;
      p.textObj.y = p.baseY + Math.cos(ctx.time * 0.2 * spd + p.fadePhase) * 8 * drift;
      p.textObj.alpha = p.baseAlpha + Math.sin(ctx.time * p.fadeSpeed * spd + p.fadePhase) * 0.08;
    }
  }
}