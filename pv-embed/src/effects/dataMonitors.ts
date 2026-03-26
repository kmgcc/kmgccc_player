// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface Monitor {
  x: number;
  y: number;
  w: number;
  h: number;
  dataRows: number;
  phase: number;
  glitchRate: number;
}

/**
 * Small floating "monitor" rectangles with fake data/scanlines inside,
 * mimicking CRT screens or data terminals scattered across the frame.
 */
export class DataMonitors extends BaseEffect {
  readonly name = 'dataMonitors';
  override readonly heavy = true;
  private g!: PIXI.Graphics;
  private monitors: Monitor[] = [];

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  private ensureMonitors(count: number, sw: number, sh: number): void {
    if (this.monitors.length === count) return;
    this.monitors = [];
    for (let i = 0; i < count; i++) {
      const w = 80 + Math.random() * 160;
      const h = 50 + Math.random() * 100;
      this.monitors.push({
        x: Math.random() * (sw - w),
        y: Math.random() * (sh - h),
        w, h,
        dataRows: 3 + Math.floor(Math.random() * 8),
        phase: Math.random() * Math.PI * 2,
        glitchRate: 0.02 + Math.random() * 0.06,
      });
    }
  }

  update(ctx: UpdateContext): void {
    const g = this.g;
    g.clear();

    const w = ctx.screenWidth;
    const h = ctx.screenHeight;
    const count = this.config.count ?? 4;
    const borderColor = resolveColor(this.config.borderColor ?? '#ffffff', this.palette);
    const fillColor = resolveColor(this.config.fillColor ?? '#000000', this.palette);
    const dataColor = resolveColor(this.config.dataColor ?? '#ffffff', this.palette);
    const alpha = this.config.alpha ?? 0.7;

    this.ensureMonitors(count, w, h);

    for (const mon of this.monitors) {
      // Monitor frame
      g.rect(mon.x, mon.y, mon.w, mon.h);
      g.fill({ color: fillColor, alpha: alpha * 0.9 });
      g.rect(mon.x, mon.y, mon.w, mon.h);
      g.stroke({ color: borderColor, width: 1.5, alpha });

      // Header bar
      g.rect(mon.x + 1, mon.y + 1, mon.w - 2, 8);
      g.fill({ color: borderColor, alpha: alpha * 0.6 });

      // Data rows inside
      const contentY = mon.y + 12;
      const contentH = mon.h - 14;
      const rowH = contentH / mon.dataRows;

      for (let r = 0; r < mon.dataRows; r++) {
        const ry = contentY + r * rowH;

        // Occasional glitch: shift row horizontally
        const glitched = Math.random() < mon.glitchRate;
        const offsetX = glitched ? (Math.random() - 0.5) * 20 : 0;

        // Data bar (random width to simulate text/data)
        const barW = (0.3 + Math.random() * 0.6) * (mon.w - 8);
        g.rect(mon.x + 4 + offsetX, ry + 1, barW, rowH * 0.5);
        g.fill({ color: dataColor, alpha: alpha * (0.3 + Math.random() * 0.4) });
      }

      // Scanline overlay inside monitor
      for (let sy = contentY; sy < mon.y + mon.h; sy += 3) {
        g.rect(mon.x + 1, sy, mon.w - 2, 1);
      }
      g.fill({ color: fillColor, alpha: alpha * 0.15 });

      // Occasional full-screen glitch bar across monitor
      if (Math.random() < 0.05) {
        const gy = mon.y + Math.random() * mon.h;
        g.rect(mon.x, gy, mon.w, 3 + Math.random() * 5);
        g.fill({ color: borderColor, alpha: alpha * 0.6 });
      }
    }
  }
}
