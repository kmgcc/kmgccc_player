// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class DiagonalHatch extends BaseEffect {
  readonly name = 'diagonalHatch';
  private tiling!: PIXI.TilingSprite;
  private lastBg = '';

  protected setup(): void {
    this.buildTile();
  }

  private buildTile(): void {
    const spacing = this.config.spacing ?? 8;
    const lineWidth = this.config.lineWidth ?? 0.8;
    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const alpha = this.config.alpha ?? 0.15;

    const tileSize = spacing;
    const canvas = document.createElement('canvas');
    canvas.width = tileSize;
    canvas.height = tileSize;
    const ctx = canvas.getContext('2d')!;
    ctx.strokeStyle = color;
    ctx.globalAlpha = alpha;
    ctx.lineWidth = lineWidth;
    ctx.beginPath();
    ctx.moveTo(0, tileSize);
    ctx.lineTo(tileSize, 0);
    ctx.stroke();

    const tex = PIXI.Texture.from(canvas);
    if (this.tiling) {
      this.tiling.texture = tex;
    } else {
      this.tiling = new PIXI.TilingSprite({ texture: tex, width: 1920, height: 1080 });
      this.container.addChild(this.tiling);
    }
  }

  update(ctx: UpdateContext): void {
    const bg = ctx.palette.background;
    if (this.lastBg !== bg) {
      this.lastBg = bg;
      this.buildTile();
    }
    this.tiling.width = ctx.screenWidth;
    this.tiling.height = ctx.screenHeight;
  }
}