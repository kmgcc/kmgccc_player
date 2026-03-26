// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class CrossPattern extends BaseEffect {
  readonly name = 'crossPattern';
  private patternContainer!: PIXI.Container;
  private drawn = false;

  protected setup(): void {
    this.patternContainer = new PIXI.Container();
    this.container.addChild(this.patternContainer);
  }

  private drawPattern(width: number, height: number): void {
    const g = new PIXI.Graphics();
    const spacing = this.config.spacing ?? 40;
    const size = this.config.size ?? 4;
    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const alpha = this.config.alpha ?? 0.4;
    const area = this.config.area ?? { x: 0.2, y: 0.1, w: 0.6, h: 0.8 };

    const startX = area.x * width;
    const startY = area.y * height;
    const endX = (area.x + area.w) * width;
    const endY = (area.y + area.h) * height;

    for (let x = startX; x < endX; x += spacing) {
      for (let y = startY; y < endY; y += spacing) {
        g.moveTo(x - size, y - size).lineTo(x + size, y + size);
        g.moveTo(x + size, y - size).lineTo(x - size, y + size);
      }
    }
    g.stroke({ color, width: 1, alpha });
    this.patternContainer.addChild(g);
  }

  update(ctx: UpdateContext): void {
    if (!this.drawn) {
      this.drawn = true;
      this.drawPattern(ctx.screenWidth, ctx.screenHeight);
    }
    const speed = (this.config.driftSpeed ?? 0.2) * ctx.animationSpeed;
    const drift = ctx.motionIntensity;
    this.patternContainer.x = Math.sin(ctx.time * speed) * 5 * drift;
    this.patternContainer.y = Math.cos(ctx.time * speed * 0.7) * 5 * drift;
  }
}