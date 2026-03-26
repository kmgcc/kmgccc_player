// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class ColorMask extends BaseEffect {
  readonly name = 'colorMask';
  private graphics!: PIXI.Graphics;
  private drawn = false;

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  private draw(width: number, height: number): void {
    const g = this.graphics;
    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const alpha = this.config.alpha ?? 0.3;
    const coverage = this.config.coverage ?? { x: 0, y: 0, w: 1, h: 1 };

    g.rect(
      coverage.x * width,
      coverage.y * height,
      coverage.w * width,
      coverage.h * height
    );
    g.fill({ color, alpha });
  }

  update(ctx: UpdateContext): void {
    if (!this.drawn) {
      this.drawn = true;
      this.draw(ctx.screenWidth, ctx.screenHeight);
    }
  }
}