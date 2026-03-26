// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Perspective grid with a vanishing point, creating depth.
 * Supports both "floor" (Retrowave horizon) and "full" (centered vanishing point) modes.
 * Horizontal lines converge toward the vanishing point; vertical lines recede with perspective.
 */
export class PerspectiveGrid extends BaseEffect {
  readonly name = 'perspectiveGrid';
  private g!: PIXI.Graphics;
  private drawn = false;
  private lastW = 0;
  private lastH = 0;

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  update(ctx: UpdateContext): void {
    const mode = this.config.mode ?? 'floor';
    const isStatic = mode === 'full';
    if (isStatic && this.drawn && this.lastW === ctx.screenWidth && this.lastH === ctx.screenHeight) return;
    this.drawn = true;
    this.lastW = ctx.screenWidth;
    this.lastH = ctx.screenHeight;

    const g = this.g;
    g.clear();

    const w = ctx.screenWidth;
    const h = ctx.screenHeight;
    const color = resolveColor(this.config.color ?? '$primary', this.palette);
    const alpha = this.config.alpha ?? 0.3;
    const lineWidth = this.config.lineWidth ?? 1;
    const spd = ctx.animationSpeed;
    const scrollSpeed = (this.config.scrollSpeed ?? 0.5) * spd;

    // Vanishing point
    const vpx = w * (this.config.vpX ?? 0.5);
    const vpy = h * (this.config.vpY ?? (mode === 'floor' ? 0.45 : 0.5));

    if (mode === 'floor') {
      this.drawFloorGrid(g, w, h, vpx, vpy, color, alpha, lineWidth, ctx.time, scrollSpeed);
    } else {
      this.drawFullGrid(g, w, h, vpx, vpy, color, alpha, lineWidth);
    }
  }

  private drawFloorGrid(
    g: PIXI.Graphics, w: number, h: number,
    vpx: number, vpy: number,
    color: string, alpha: number, lineWidth: number,
    time: number, scrollSpeed: number,
  ): void {
    const horizonY = vpy;
    const bottomY = h;

    // Vertical lines converging to vanishing point
    const vLines = this.config.vLines ?? 20;
    const spread = w * 1.5;
    for (let i = 0; i <= vLines; i++) {
      const frac = i / vLines;
      const bottomX = (vpx - spread / 2) + frac * spread;
      g.moveTo(vpx, horizonY).lineTo(bottomX, bottomY);
    }
    g.stroke({ color, width: lineWidth, alpha: alpha * 0.6 });

    // Horizontal lines with perspective spacing (closer together near horizon)
    const hLines = this.config.hLines ?? 15;
    const scrollOffset = (time * scrollSpeed * 50) % 30;

    for (let i = 0; i < hLines; i++) {
      // Exponential spacing: lines bunch up near horizon
      const t = (i + scrollOffset / 30) / hLines;
      const y = horizonY + Math.pow(t, 2.2) * (bottomY - horizonY);

      if (y > horizonY && y < bottomY) {
        // Compute left/right X at this Y by line equation from VP
        const progress = (y - horizonY) / (bottomY - horizonY);
        const halfW = (spread / 2) * progress;
        const lx = vpx - halfW;
        const rx = vpx + halfW;
        g.moveTo(lx, y).lineTo(rx, y);
      }
    }
    g.stroke({ color, width: lineWidth * 0.8, alpha });

    // Horizon line (brighter)
    g.moveTo(0, horizonY).lineTo(w, horizonY);
    g.stroke({ color, width: lineWidth * 1.5, alpha: alpha * 1.2 });
  }

  private drawFullGrid(
    g: PIXI.Graphics, w: number, h: number,
    vpx: number, vpy: number,
    color: string, alpha: number, lineWidth: number,
  ): void {
    // Lines radiating from VP to all edges
    const rayCount = this.config.rayCount ?? 24;

    for (let i = 0; i < rayCount; i++) {
      const angle = (i / rayCount) * Math.PI * 2;
      const len = Math.max(w, h);
      const ex = vpx + Math.cos(angle) * len;
      const ey = vpy + Math.sin(angle) * len;
      g.moveTo(vpx, vpy).lineTo(ex, ey);
    }
    g.stroke({ color, width: lineWidth * 0.7, alpha: alpha * 0.5 });

    // Concentric perspective rectangles
    const rings = this.config.rings ?? 6;
    for (let i = 1; i <= rings; i++) {
      const t = Math.pow(i / rings, 1.5);
      const hw = (w / 2) * t;
      const hh = (h / 2) * t;
      g.rect(vpx - hw, vpy - hh, hw * 2, hh * 2);
    }
    g.stroke({ color, width: lineWidth, alpha: alpha * 0.7 });
  }
}