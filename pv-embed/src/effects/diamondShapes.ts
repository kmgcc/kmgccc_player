// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class DiamondShapes extends BaseEffect {
  readonly name = 'diamondShapes';
  private shapeContainer!: PIXI.Container;

  protected setup(): void {
    this.shapeContainer = new PIXI.Container();
    this.container.addChild(this.shapeContainer);
    this.drawDiamonds();
  }

  private drawDiamonds(): void {
    const count = this.config.count ?? 3;
    const maxSize = this.config.maxSize ?? 300;
    const strokeWidth = this.config.strokeWidth ?? 2;
    const color = resolveColor(this.config.color ?? '$primary', this.palette);
    const fillColor = this.config.fill ? resolveColor(this.config.fill, this.palette) : null;
    const alpha = this.config.alpha ?? 0.7;

    for (let i = 0; i < count; i++) {
      const g = new PIXI.Graphics();
      const size = maxSize - (maxSize / count) * i * 0.6;
      const half = size / 2;

      g.moveTo(0, -half)
        .lineTo(half, 0)
        .lineTo(0, half)
        .lineTo(-half, 0)
        .closePath();

      if (fillColor && i === count - 1) {
        g.fill({ color: fillColor, alpha: alpha * 0.3 });
      }
      g.stroke({ color, width: strokeWidth, alpha });

      this.shapeContainer.addChild(g);
    }
  }

  update(ctx: UpdateContext): void {
    const cx = (this.config.x ?? 0.5) * ctx.screenWidth;
    const cy = (this.config.y ?? 0.5) * ctx.screenHeight;
    this.shapeContainer.x = cx;
    this.shapeContainer.y = cy;

    const speed = (this.config.animationSpeed ?? 0.08) * ctx.animationSpeed;
    this.shapeContainer.rotation = ctx.time * speed;
  }
}