// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class Planet extends BaseEffect {
  readonly name = 'planet';
  private graphics!: PIXI.Graphics;
  private glowSprite!: PIXI.Sprite;
  private infTop!: PIXI.Text;
  private infBottom!: PIXI.Text;
  private glowBuilt = false;

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  private buildGlow(_cx: number, _cy: number, size: number): void {
    if (this.glowBuilt) return;
    this.glowBuilt = true;

    const glowSize = size * 1.2;
    const canvas = document.createElement('canvas');
    canvas.width = glowSize * 2;
    canvas.height = glowSize * 2;
    const ctx2d = canvas.getContext('2d')!;

    const grad = ctx2d.createRadialGradient(glowSize, glowSize, 0, glowSize, glowSize, glowSize);
    grad.addColorStop(0, 'rgba(255,255,255,0.5)');
    grad.addColorStop(0.15, 'rgba(255,255,255,0.15)');
    grad.addColorStop(0.4, 'rgba(255,255,255,0.03)');
    grad.addColorStop(1, 'rgba(255,255,255,0)');
    ctx2d.fillStyle = grad;
    ctx2d.fillRect(0, 0, glowSize * 2, glowSize * 2);

    const texture = PIXI.Texture.from(canvas);
    this.glowSprite = new PIXI.Sprite(texture);
    this.glowSprite.anchor.set(0.5);
    this.container.addChildAt(this.glowSprite, 0);

    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const infStyle = new PIXI.TextStyle({
      fontFamily: 'serif',
      fontSize: this.config.infFontSize ?? 18,
      fill: color,
      fontStyle: 'italic',
    });
    this.infTop = new PIXI.Text({ text: '∞', style: infStyle });
    this.infTop.anchor.set(0.5);
    this.container.addChild(this.infTop);

    this.infBottom = new PIXI.Text({ text: '-∞', style: infStyle });
    this.infBottom.anchor.set(0.5);
    this.container.addChild(this.infBottom);
  }

  update(ctx: UpdateContext): void {
    const g = this.graphics;
    g.clear();

    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const px = (this.config.x ?? 0.5) * ctx.screenWidth;
    const py = (this.config.y ?? 0.5) * ctx.screenHeight;
    const baseR = this.config.radius ?? 120;
    const speed = ctx.animationSpeed;
    const t = ctx.time * speed;

    const breathe = 1 + Math.sin(t * 0.3) * 0.015 * ctx.motionIntensity;
    const coreR = (this.config.coreRadius ?? 12) * breathe;

    this.buildGlow(px, py, baseR);
    this.glowSprite.x = px;
    this.glowSprite.y = py;
    const glowPulse = 1 + Math.sin(t * 0.5) * 0.06 + ctx.beatIntensity * 0.08;
    this.glowSprite.scale.set(glowPulse);

    // Core circle
    g.circle(px, py, coreR);
    g.fill({ color: '#000000', alpha: 1 });
    g.circle(px, py, coreR);
    g.stroke({ color, width: 1.5, alpha: 0.8 });

    // Concentric rings
    const ringCounts = [
      { r: 0.35, w: 1.0, a: 0.2 },
      { r: 0.55, w: 0.8, a: 0.15 },
      { r: 0.75, w: 0.6, a: 0.12 },
      { r: 1.0,  w: 0.8, a: 0.2 },
    ];
    for (const ring of ringCounts) {
      const rr = baseR * ring.r * breathe;
      g.circle(px, py, rr);
      g.stroke({ color, width: ring.w, alpha: ring.a });
    }

    // Tick marks on the outermost ring
    const outerR = baseR * 1.0 * breathe;
    const tickCount = 60;
    const tickLen = this.config.tickLen ?? 5;
    const rotOffset = t * 0.02;
    for (let i = 0; i < tickCount; i++) {
      const a = (i / tickCount) * Math.PI * 2 + rotOffset;
      const isMajor = i % 5 === 0;
      const len = isMajor ? tickLen * 1.6 : tickLen;
      const alpha = isMajor ? 0.35 : 0.15;
      const x1 = px + Math.cos(a) * (outerR - len);
      const y1 = py + Math.sin(a) * (outerR - len);
      const x2 = px + Math.cos(a) * outerR;
      const y2 = py + Math.sin(a) * outerR;
      g.moveTo(x1, y1);
      g.lineTo(x2, y2);
      g.stroke({ color, width: isMajor ? 1.2 : 0.6, alpha });
    }

    // Inner tick ring
    const innerTickR = baseR * 0.55 * breathe;
    const innerTickCount = 36;
    for (let i = 0; i < innerTickCount; i++) {
      const a = (i / innerTickCount) * Math.PI * 2 - rotOffset * 0.5;
      const len = tickLen * 0.6;
      const x1 = px + Math.cos(a) * (innerTickR - len);
      const y1 = py + Math.sin(a) * (innerTickR - len);
      const x2 = px + Math.cos(a) * innerTickR;
      const y2 = py + Math.sin(a) * innerTickR;
      g.moveTo(x1, y1);
      g.lineTo(x2, y2);
      g.stroke({ color, width: 0.5, alpha: 0.12 });
    }

    // Cross axis lines
    const lineExtend = this.config.lineExtend ?? 1.8;
    const lineLen = baseR * lineExtend;

    // Horizontal line
    g.moveTo(px - lineLen, py);
    g.lineTo(px + lineLen, py);
    g.stroke({ color, width: 0.8, alpha: 0.25 });

    // Vertical line
    g.moveTo(px, py - lineLen);
    g.lineTo(px, py + lineLen);
    g.stroke({ color, width: 0.8, alpha: 0.15 });

    // Dots along horizontal axis
    const dotCount = 6;
    for (let i = 1; i <= dotCount; i++) {
      const frac = i / (dotCount + 1);
      const dotR = 2.0 - frac * 0.8;
      const dotAlpha = 0.4 - frac * 0.15;
      g.circle(px - lineLen * frac, py, dotR);
      g.fill({ color, alpha: dotAlpha });
      g.circle(px + lineLen * frac, py, dotR);
      g.fill({ color, alpha: dotAlpha });
    }

    // Large arc (planet edge) on the right
    const arcR = this.config.arcRadius ?? (ctx.screenHeight * 0.9);
    const arcCx = px + arcR * 0.62;
    const arcAlpha = this.config.arcAlpha ?? 0.08;
    const arcStart = Math.PI * 0.6;
    const arcEnd = Math.PI * 1.4;
    const arcSegs = 80;
    for (let i = 0; i <= arcSegs; i++) {
      const a = arcStart + (i / arcSegs) * (arcEnd - arcStart);
      const ax = arcCx + Math.cos(a) * arcR;
      const ay = py + Math.sin(a) * arcR;
      if (i === 0) g.moveTo(ax, ay);
      else g.lineTo(ax, ay);
    }
    g.stroke({ color, width: 1.5, alpha: arcAlpha });

    // Infinity symbols
    const infOffset = baseR * lineExtend * 0.7;
    this.infTop.x = px;
    this.infTop.y = py - infOffset;
    this.infTop.alpha = 0.5;
    this.infBottom.x = px;
    this.infBottom.y = py + infOffset;
    this.infBottom.alpha = 0.5;
  }
}
