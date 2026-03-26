// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class GradientOverlay extends BaseEffect {
  readonly name = 'gradientOverlay';
  private sprite!: PIXI.Sprite;
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const colorTop = resolveColor(this.config.colorTop ?? '#004040', this.palette);
    const colorBottom = resolveColor(this.config.colorBottom ?? '#001a2e', this.palette);
    const alpha = this.config.alpha ?? 0.55;
    const mode = this.config.mode ?? 'linear';

    const canvas = document.createElement('canvas');
    canvas.width = sw;
    canvas.height = sh;
    const ctx2d = canvas.getContext('2d')!;

    if (mode === 'radial') {
      const cx = sw / 2;
      const cy = sh / 2;
      const r = Math.max(sw, sh) * 0.7;
      const grad = ctx2d.createRadialGradient(cx, cy, 0, cx, cy, r);
      grad.addColorStop(0, colorTop);
      grad.addColorStop(1, colorBottom);
      ctx2d.fillStyle = grad;
    } else {
      const grad = ctx2d.createLinearGradient(0, 0, 0, sh);
      grad.addColorStop(0, colorTop);
      grad.addColorStop(0.5, this.config.colorMid ? resolveColor(this.config.colorMid, this.palette) : colorTop);
      grad.addColorStop(1, colorBottom);
      ctx2d.fillStyle = grad;
    }

    ctx2d.fillRect(0, 0, sw, sh);

    const texture = PIXI.Texture.from(canvas);
    this.sprite = new PIXI.Sprite(texture);
    this.sprite.alpha = alpha;
    this.container.addChild(this.sprite);
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);
  }
}