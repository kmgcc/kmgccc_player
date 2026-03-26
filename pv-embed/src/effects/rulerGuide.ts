// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * L-shaped ruler/scale with tick marks forming a right angle,
 * and a circle marker at the intersection point.
 */
export class RulerGuide extends BaseEffect {
  readonly name = 'rulerGuide';
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
    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const alpha = this.config.alpha ?? 0.5;
    const originX = w * (this.config.x ?? 0.12);
    const originY = h * (this.config.y ?? 0.75);
    const hLen = w * (this.config.hLength ?? 0.85);
    const vLen = h * (this.config.vLength ?? 0.65);
    const lineWidth = this.config.lineWidth ?? 1;

    // Main axes
    // Horizontal: from origin to the right
    g.moveTo(originX, originY).lineTo(originX + hLen, originY);
    // Vertical: from origin upward
    g.moveTo(originX, originY).lineTo(originX, originY - vLen);
    g.stroke({ color, width: lineWidth, alpha });

    // Tick marks on horizontal axis
    const tickSpacing = this.config.tickSpacing ?? 12;
    const majorEvery = this.config.majorEvery ?? 5;
    const minorLen = this.config.minorTickLen ?? 6;
    const majorLen = this.config.majorTickLen ?? 14;

    let tickIdx = 0;
    for (let x = originX; x <= originX + hLen; x += tickSpacing) {
      const isMajor = tickIdx % majorEvery === 0;
      const tl = isMajor ? majorLen : minorLen;
      g.moveTo(x, originY).lineTo(x, originY - tl);
      tickIdx++;
    }
    g.stroke({ color, width: 0.8, alpha: alpha * 0.7 });

    // Tick marks on vertical axis
    tickIdx = 0;
    for (let y = originY; y >= originY - vLen; y -= tickSpacing) {
      const isMajor = tickIdx % majorEvery === 0;
      const tl = isMajor ? majorLen : minorLen;
      g.moveTo(originX, y).lineTo(originX + tl, y);
      tickIdx++;
    }
    g.stroke({ color, width: 0.8, alpha: alpha * 0.7 });

    // Circle marker at origin
    const circleR = this.config.circleRadius ?? 8;
    g.circle(originX, originY, circleR);
    g.stroke({ color, width: 1.2, alpha: alpha * 0.9 });
    // Crosshair inside circle
    g.moveTo(originX - circleR * 0.6, originY).lineTo(originX + circleR * 0.6, originY);
    g.moveTo(originX, originY - circleR * 0.6).lineTo(originX, originY + circleR * 0.6);
    g.stroke({ color, width: 0.8, alpha: alpha * 0.6 });
    // Center dot
    g.circle(originX, originY, 1.5);
    g.fill({ color, alpha: alpha * 0.8 });
  }
}