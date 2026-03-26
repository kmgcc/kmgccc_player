// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Simple L-shaped corner brackets at the four corners of the screen.
 * Faithful to CyberpunkTheme._draw_static_elements corner lines.
 */
export class HudCorners extends BaseEffect {
  readonly name = 'hudCorners';
  private g!: PIXI.Graphics;
  private drawn = false;
  private lastW = 0;
  private lastH = 0;

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  update(ctx: UpdateContext): void {
    if (this.drawn && this.lastW === ctx.screenWidth && this.lastH === ctx.screenHeight) return;
    this.drawn = true;
    this.lastW = ctx.screenWidth;
    this.lastH = ctx.screenHeight;

    const g = this.g;
    g.clear();

    const w = ctx.screenWidth;
    const h = ctx.screenHeight;
    const color = resolveColor(this.config.color ?? '$primary', this.palette);
    const alpha = this.config.alpha ?? 0.9;
    const margin = this.config.margin ?? 20;
    const armLen = this.config.armLength ?? 40;
    const lineWidth = this.config.lineWidth ?? 2;

    // 4 corners, each with a horizontal and vertical arm
    const corners = [
      // Top-Left
      { x: margin, y: margin, dx: armLen, dy: 0 },
      { x: margin, y: margin, dx: 0, dy: armLen },
      // Top-Right
      { x: w - margin, y: margin, dx: -armLen, dy: 0 },
      { x: w - margin, y: margin, dx: 0, dy: armLen },
      // Bottom-Left
      { x: margin, y: h - margin, dx: armLen, dy: 0 },
      { x: margin, y: h - margin, dx: 0, dy: -armLen },
      // Bottom-Right
      { x: w - margin, y: h - margin, dx: -armLen, dy: 0 },
      { x: w - margin, y: h - margin, dx: 0, dy: -armLen },
    ];

    for (const c of corners) {
      g.moveTo(c.x, c.y).lineTo(c.x + c.dx, c.y + c.dy);
    }
    g.stroke({ color, width: lineWidth, alpha });
  }
}