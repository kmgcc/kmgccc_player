// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class Scanlines extends BaseEffect {
  readonly name = 'scanlines';
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
    const color = resolveColor(this.config.color ?? '#003333', this.palette);
    const alpha = this.config.alpha ?? 0.15;
    const spacing = this.config.spacing ?? 4;

    for (let y = 0; y < h; y += spacing) {
      g.moveTo(0, y).lineTo(w, y);
    }
    g.stroke({ color, width: 1, alpha });
  }
}