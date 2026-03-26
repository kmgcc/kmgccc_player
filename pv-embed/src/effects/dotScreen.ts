// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Full halftone dot screen pattern overlay.
 * Evenly spaced filled circles creating a print-like texture.
 */
export class DotScreen extends BaseEffect {
  readonly name = 'dotScreen';
  private tiling!: PIXI.TilingSprite;
  private lastBg = '';

  protected setup(): void {
    this.buildTile();
  }

  private buildTile(): void {
    const spacing = this.config.spacing ?? 8;
    const dotRadius = this.config.dotRadius ?? 1.5;
    const color = resolveColor(this.config.color ?? '$text', this.palette);
    const alpha = this.config.alpha ?? 0.12;
    const angle = (this.config.angle ?? 15) * Math.PI / 180;

    const tileSize = spacing;
    const canvas = document.createElement('canvas');
    canvas.width = tileSize;
    canvas.height = tileSize;
    const ctx = canvas.getContext('2d')!;

    ctx.fillStyle = color;
    ctx.globalAlpha = alpha;
    ctx.beginPath();
    ctx.arc(tileSize / 2, tileSize / 2, dotRadius, 0, Math.PI * 2);
    ctx.fill();

    const tex = PIXI.Texture.from(canvas);
    if (this.tiling) {
      this.tiling.texture = tex;
    } else {
      this.tiling = new PIXI.TilingSprite({ texture: tex, width: 1920, height: 1080 });
      this.tiling.rotation = angle;
      this.tiling.anchor.set(0.5);
      this.container.addChild(this.tiling);
    }
  }

  update(ctx: UpdateContext): void {
    const bg = ctx.palette.background;
    if (this.lastBg !== bg) {
      this.lastBg = bg;
      this.buildTile();
    }
    this.tiling.width = ctx.screenWidth * 1.5;
    this.tiling.height = ctx.screenHeight * 1.5;
    this.tiling.x = ctx.screenWidth / 2;
    this.tiling.y = ctx.screenHeight / 2;
  }
}