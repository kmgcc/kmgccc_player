// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

export class Vignette extends BaseEffect {
  readonly name = 'vignette';
  private sprite!: PIXI.Sprite;

  protected setup(): void {
    const intensity = this.config.intensity ?? 0.6;
    const size = 512;

    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext('2d')!;

    const gradient = ctx.createRadialGradient(
      size / 2, size / 2, size * 0.15,
      size / 2, size / 2, size * 0.5
    );
    gradient.addColorStop(0, 'rgba(0,0,0,0)');
    gradient.addColorStop(0.5, 'rgba(0,0,0,0)');
    gradient.addColorStop(1, `rgba(0,0,0,${intensity})`);

    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, size, size);

    const texture = PIXI.Texture.from(canvas);
    this.sprite = new PIXI.Sprite(texture);
    this.container.addChild(this.sprite);
  }

  update(ctx: UpdateContext): void {
    this.sprite.width = ctx.screenWidth;
    this.sprite.height = ctx.screenHeight;
    this.sprite.alpha = 1 + ctx.beatIntensity * 0.4;
  }
}