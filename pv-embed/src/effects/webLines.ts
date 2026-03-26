// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface WebLine {
  x1: number; y1: number;
  x2: number; y2: number;
  width: number;
  alpha: number;
  phase: number;
  speed: number;
}

/**
 * Tangled crossing lines converging toward a focal area,
 * creating an aggressive spider-web / red-thread aesthetic.
 * Lines extend edge-to-edge with varying angles and thicknesses.
 */
export class WebLines extends BaseEffect {
  readonly name = 'webLines';
  private g!: PIXI.Graphics;
  private lines: WebLine[] = [];
  private lastW = 0;
  private lastH = 0;

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  private buildLines(w: number, h: number): void {
    this.lastW = w;
    this.lastH = h;
    this.lines = [];

    const count = this.config.count ?? 22;
    const focalX = w * (this.config.focalX ?? 0.5);
    const focalY = h * (this.config.focalY ?? 0.45);
    const spread = this.config.spread ?? 0.25;

    for (let i = 0; i < count; i++) {
      const angle = Math.random() * Math.PI * 2;
      const maxDim = Math.max(w, h);

      // Line passes near the focal point with some random offset
      const offsetX = (Math.random() - 0.5) * w * spread;
      const offsetY = (Math.random() - 0.5) * h * spread;
      const cx = focalX + offsetX;
      const cy = focalY + offsetY;

      const x1 = cx - Math.cos(angle) * maxDim;
      const y1 = cy - Math.sin(angle) * maxDim;
      const x2 = cx + Math.cos(angle) * maxDim;
      const y2 = cy + Math.sin(angle) * maxDim;

      // Vary thickness: most are thin, a few are thicker for emphasis
      const isThick = Math.random() < 0.15;
      const width = isThick ? 2.5 + Math.random() * 2 : 0.8 + Math.random() * 1.5;
      const alpha = isThick ? 0.8 + Math.random() * 0.2 : 0.4 + Math.random() * 0.4;

      this.lines.push({
        x1, y1, x2, y2, width, alpha,
        phase: Math.random() * Math.PI * 2,
        speed: 0.3 + Math.random() * 0.7,
      });
    }
  }

  update(ctx: UpdateContext): void {
    const w = ctx.screenWidth;
    const h = ctx.screenHeight;

    if (this.lines.length === 0 || this.lastW !== w || this.lastH !== h) {
      this.buildLines(w, h);
    }

    const g = this.g;
    g.clear();

    const color = resolveColor(this.config.color ?? '#ff2222', this.palette);
    const glowColor = resolveColor(this.config.glowColor ?? '#ff4444', this.palette);
    const spd = ctx.animationSpeed;
    const beat = ctx.beatIntensity;
    const motion = ctx.motionIntensity;

    // Occasional full-rebuild on strong beat for impact
    const rebuildChance = this.config.rebuildChance ?? 0.008;
    if (beat > 0.7 && Math.random() < rebuildChance) {
      this.buildLines(w, h);
    }

    for (const line of this.lines) {
      const breathe = 0.7 + Math.sin(ctx.time * line.speed * spd + line.phase) * 0.3;
      const beatPulse = 1 + beat * 0.3;
      const currentAlpha = line.alpha * breathe * beatPulse;

      // Subtle drift animation
      const drift = motion * 3;
      const dx = Math.sin(ctx.time * 0.15 + line.phase) * drift;
      const dy = Math.cos(ctx.time * 0.12 + line.phase * 1.3) * drift;

      // Glow layer (slightly wider, lower alpha)
      g.moveTo(line.x1 + dx, line.y1 + dy);
      g.lineTo(line.x2 + dx, line.y2 + dy);
      g.stroke({ color: glowColor, width: line.width * 2.5, alpha: currentAlpha * 0.2 });

      // Core line
      g.moveTo(line.x1 + dx, line.y1 + dy);
      g.lineTo(line.x2 + dx, line.y2 + dy);
      g.stroke({ color, width: line.width, alpha: currentAlpha });
    }
  }
}
