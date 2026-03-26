// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class DashedGuideLines extends BaseEffect {
  readonly name = 'dashedGuideLines';
  private graphics!: PIXI.Graphics;
  private drawn = false;

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  private draw(w: number, h: number): void {
    if (this.drawn) return;
    this.drawn = true;

    const color = resolveColor(this.config.color ?? '#cc0000', this.palette);
    const dashLen = this.config.dashLength ?? 12;
    const gapLen = this.config.gapLength ?? 8;
    const lineW = this.config.lineWidth ?? 2;
    const alpha = this.config.alpha ?? 0.8;

    const cx = w * (this.config.x ?? 0.5);
    const cy = h * (this.config.y ?? 0.5);
    const rw = w * (this.config.width ?? 0.4);
    const rh = h * (this.config.height ?? 0.55);

    const left = cx - rw / 2;
    const right = cx + rw / 2;
    const top = cy - rh / 2;
    const bottom = cy + rh / 2;

    const g = this.graphics;

    // Main rectangle dashes
    this.dashedLine(g, left, top, right, top, dashLen, gapLen, color, lineW, alpha);
    this.dashedLine(g, left, bottom, right, bottom, dashLen, gapLen, color, lineW, alpha);
    this.dashedLine(g, left, top, left, bottom, dashLen, gapLen, color, lineW, alpha);
    this.dashedLine(g, right, top, right, bottom, dashLen, gapLen, color, lineW, alpha);

    // Extended guide lines
    const ext = this.config.extend ?? 60;
    const halfA = alpha * 0.5;
    this.dashedLine(g, left - ext, top, left - 4, top, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, right + 4, top, right + ext, top, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, left - ext, bottom, left - 4, bottom, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, right + 4, bottom, right + ext, bottom, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, left, top - ext, left, top - 4, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, right, top - ext, right, top - 4, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, left, bottom + 4, left, bottom + ext, dashLen, gapLen, color, lineW, halfA);
    this.dashedLine(g, right, bottom + 4, right, bottom + ext, dashLen, gapLen, color, lineW, halfA);

    // Cross markers at corners
    const cs = this.config.crossSize ?? 12;
    const corners = [[left, top], [right, top], [left, bottom], [right, bottom]];
    for (const [px, py] of corners) {
      g.moveTo(px - cs, py).lineTo(px + cs, py);
      g.moveTo(px, py - cs).lineTo(px, py + cs);
    }
    g.stroke({ color, width: lineW * 0.8, alpha });

    // Centre crosshair (thin)
    g.moveTo(cx - cs * 0.7, cy).lineTo(cx + cs * 0.7, cy);
    g.moveTo(cx, cy - cs * 0.7).lineTo(cx, cy + cs * 0.7);
    g.stroke({ color, width: lineW * 0.5, alpha: alpha * 0.4 });
  }

  private dashedLine(
    g: PIXI.Graphics,
    x1: number, y1: number, x2: number, y2: number,
    dashLen: number, gapLen: number,
    color: string, width: number, alpha: number,
  ): void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (dist < 1) return;
    const nx = dx / dist;
    const ny = dy / dist;

    let pos = 0;
    let drawing = true;
    while (pos < dist) {
      const seg = drawing ? dashLen : gapLen;
      const end = Math.min(pos + seg, dist);
      if (drawing) {
        g.moveTo(x1 + nx * pos, y1 + ny * pos);
        g.lineTo(x1 + nx * end, y1 + ny * end);
        g.stroke({ color, width, alpha });
      }
      pos = end;
      drawing = !drawing;
    }
  }

  update(ctx: UpdateContext): void {
    this.draw(ctx.screenWidth, ctx.screenHeight);

    const pulse = 0.8 + 0.2 * Math.sin(ctx.time * 1.5 * ctx.animationSpeed);
    this.graphics.alpha = pulse;
  }
}