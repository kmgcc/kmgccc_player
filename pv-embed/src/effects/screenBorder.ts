// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class ScreenBorder extends BaseEffect {
  readonly name = 'screenBorder';
  private graphics!: PIXI.Graphics;
  private drawn = false;
  private lastW = 0;
  private lastH = 0;
  private lastBg = '';

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  update(ctx: UpdateContext): void {
    const bg = ctx.palette.background;
    if (this.drawn && this.lastW === ctx.screenWidth && this.lastH === ctx.screenHeight && this.lastBg === bg) return;
    this.drawn = true;
    this.lastW = ctx.screenWidth;
    this.lastH = ctx.screenHeight;
    this.lastBg = bg;

    const g = this.graphics;
    g.clear();

    const color = resolveColor(this.config.color ?? '$primary', this.palette);
    const lineW = this.config.lineWidth ?? 1.5;
    const alpha = this.config.alpha ?? 0.6;
    const margin = this.config.margin ?? 20;
    const gap = this.config.gap ?? 6;
    const w = ctx.screenWidth;
    const h = ctx.screenHeight;

    // Outer border
    g.rect(margin, margin, w - margin * 2, h - margin * 2);
    g.stroke({ color, width: lineW, alpha });

    // Inner border
    const m2 = margin + gap;
    g.rect(m2, m2, w - m2 * 2, h - m2 * 2);
    g.stroke({ color, width: lineW * 0.6, alpha: alpha * 0.5 });

    // Cross-star decorations
    const starSize = this.config.starSize ?? 5;
    const starAlpha = alpha * 0.85;

    // Corner cross-stars (larger)
    const cSize = starSize * 1.6;
    const corners = [
      [margin, margin], [w - margin, margin],
      [margin, h - margin], [w - margin, h - margin],
    ];
    for (const [px, py] of corners) {
      this.drawCrossStar(g, px, py, cSize, color, starAlpha);
    }

    // Edge cross-stars at regular intervals
    const edgeCount = this.config.edgeStarCount ?? 5;
    // Top & bottom edges
    for (let i = 1; i <= edgeCount; i++) {
      const frac = i / (edgeCount + 1);
      const x = margin + (w - margin * 2) * frac;
      this.drawCrossStar(g, x, margin, starSize, color, starAlpha * 0.7);
      this.drawCrossStar(g, x, h - margin, starSize, color, starAlpha * 0.7);
    }
    // Left & right edges
    const edgeCountV = this.config.edgeStarCountV ?? 3;
    for (let i = 1; i <= edgeCountV; i++) {
      const frac = i / (edgeCountV + 1);
      const y = margin + (h - margin * 2) * frac;
      this.drawCrossStar(g, margin, y, starSize, color, starAlpha * 0.7);
      this.drawCrossStar(g, w - margin, y, starSize, color, starAlpha * 0.7);
    }
  }

  private drawCrossStar(g: PIXI.Graphics, cx: number, cy: number, size: number, color: string, alpha: number): void {
    // Cross lines
    g.moveTo(cx - size, cy).lineTo(cx + size, cy);
    g.moveTo(cx, cy - size).lineTo(cx, cy + size);
    g.stroke({ color, width: 1.2, alpha });

    // Diagonal lines (shorter)
    const ds = size * 0.6;
    g.moveTo(cx - ds, cy - ds).lineTo(cx + ds, cy + ds);
    g.moveTo(cx + ds, cy - ds).lineTo(cx - ds, cy + ds);
    g.stroke({ color, width: 0.7, alpha: alpha * 0.6 });

    // Center dot
    g.circle(cx, cy, 1.2);
    g.fill({ color, alpha });
  }
}