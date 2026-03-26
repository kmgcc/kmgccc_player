// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

export class LightSpot extends BaseEffect {
  readonly name = 'lightSpot';
  private sprite!: PIXI.Sprite;
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const color = this.config.color ?? '#ffffff';
    const spotAlpha = this.config.alpha ?? 0.45;
    const xFrac = this.config.x ?? 0.5;
    const yFrac = this.config.y ?? 0.1;
    const sizeFrac = this.config.size ?? 0.5;

    const r = parseInt(color.slice(1, 3), 16);
    const g = parseInt(color.slice(3, 5), 16);
    const b = parseInt(color.slice(5, 7), 16);

    const dim = Math.max(sw, sh) * sizeFrac;
    const canvas = document.createElement('canvas');
    canvas.width = dim;
    canvas.height = dim;
    const ctx2d = canvas.getContext('2d')!;

    const grad = ctx2d.createRadialGradient(dim / 2, dim / 2, 0, dim / 2, dim / 2, dim / 2);
    grad.addColorStop(0, `rgba(${r},${g},${b},${spotAlpha})`);
    grad.addColorStop(0.4, `rgba(${r},${g},${b},${spotAlpha * 0.4})`);
    grad.addColorStop(1, `rgba(${r},${g},${b},0)`);
    ctx2d.fillStyle = grad;
    ctx2d.fillRect(0, 0, dim, dim);

    const texture = PIXI.Texture.from(canvas);
    this.sprite = new PIXI.Sprite(texture);
    this.sprite.anchor.set(0.5);
    this.sprite.x = sw * xFrac;
    this.sprite.y = sh * yFrac;
    this.sprite.blendMode = 'add';
    this.container.addChild(this.sprite);
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const flicker = 1 + Math.sin(ctx.time * 0.8 * ctx.animationSpeed) * 0.08 * ctx.motionIntensity;
    const beat = 1 + ctx.beatIntensity * 0.12;
    this.sprite.alpha = flicker * beat;
  }
}