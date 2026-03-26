// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class TargetGuide extends BaseEffect {
  readonly name = 'targetGuide';
  private g!: PIXI.Graphics;

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  update(ctx: UpdateContext): void {
    const g = this.g;
    g.clear();

    const cx = ctx.screenWidth / 2;
    const cy = ctx.screenHeight / 2;
    const base = Math.min(ctx.screenWidth, ctx.screenHeight);
    const color = resolveColor(this.config.color ?? '#6666cc', this.palette);
    const alpha = (this.config.alpha ?? 0.4) + ctx.beatIntensity * 0.15;
    const spd = ctx.animationSpeed;
    const rot = ctx.time * 0.15 * spd;

    // Concentric circles
    const rings = this.config.rings ?? [0.12, 0.18, 0.26];
    for (const rFrac of rings) {
      g.circle(cx, cy, base * rFrac);
      g.stroke({ color, width: 1, alpha: alpha * 0.6 });
    }

    // Crosshair lines
    const lineLen = base * 0.35;
    const lineAlpha = alpha * 0.35;
    g.moveTo(cx - lineLen, cy);
    g.lineTo(cx + lineLen, cy);
    g.stroke({ color, width: 0.8, alpha: lineAlpha });
    g.moveTo(cx, cy - lineLen);
    g.lineTo(cx, cy + lineLen);
    g.stroke({ color, width: 0.8, alpha: lineAlpha });

    // Arrow/chevron markers on axes
    const arrowDist = base * 0.22;
    const arrowSize = base * 0.015;
    const dirs = [
      { dx: 1, dy: 0, angle: 0 },
      { dx: -1, dy: 0, angle: Math.PI },
      { dx: 0, dy: -1, angle: -Math.PI / 2 },
      { dx: 0, dy: 1, angle: Math.PI / 2 },
    ];
    for (const d of dirs) {
      const ax = cx + d.dx * arrowDist;
      const ay = cy + d.dy * arrowDist;
      this.drawArrow(g, ax, ay, d.angle, arrowSize, color, alpha * 0.7);
    }

    // Rotating tick marks on outer ring
    const tickR = base * (rings[rings.length - 1] ?? 0.26);
    const tickCount = this.config.tickCount ?? 8;
    for (let i = 0; i < tickCount; i++) {
      const angle = rot + (i / tickCount) * Math.PI * 2;
      const x1 = cx + Math.cos(angle) * (tickR - 4);
      const y1 = cy + Math.sin(angle) * (tickR - 4);
      const x2 = cx + Math.cos(angle) * (tickR + 8);
      const y2 = cy + Math.sin(angle) * (tickR + 8);
      g.moveTo(x1, y1);
      g.lineTo(x2, y2);
      g.stroke({ color, width: 1.2, alpha: alpha * 0.5 });
    }

    // Small center dot
    g.circle(cx, cy, 2.5);
    g.fill({ color, alpha: alpha * 0.8 });
  }

  private drawArrow(
    g: PIXI.Graphics, x: number, y: number,
    angle: number, size: number, color: string, alpha: number
  ): void {
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    const tipX = x + cos * size;
    const tipY = y + sin * size;
    const leftX = x - cos * size * 0.5 - sin * size * 0.6;
    const leftY = y - sin * size * 0.5 + cos * size * 0.6;
    const rightX = x - cos * size * 0.5 + sin * size * 0.6;
    const rightY = y - sin * size * 0.5 - cos * size * 0.6;

    g.moveTo(tipX, tipY);
    g.lineTo(leftX, leftY);
    g.moveTo(tipX, tipY);
    g.lineTo(rightX, rightY);
    g.stroke({ color, width: 1.5, alpha });
  }
}