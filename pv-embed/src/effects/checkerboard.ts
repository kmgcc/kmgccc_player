// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Checkerboard / chessboard pattern overlay.
 */
export class Checkerboard extends BaseEffect {
  readonly name = 'checkerboard';
  private tiling!: PIXI.TilingSprite;

  protected setup(): void {
    const cellSize = this.config.cellSize ?? 40;
    const color1 = resolveColor(this.config.color1 ?? '#000000', this.palette);
    const color2 = resolveColor(this.config.color2 ?? '#ffffff', this.palette);
    const alpha = this.config.alpha ?? 0.08;

    const tileSize = cellSize * 2;
    const canvas = document.createElement('canvas');
    canvas.width = tileSize;
    canvas.height = tileSize;
    const ctx = canvas.getContext('2d')!;

    ctx.fillStyle = color1;
    ctx.fillRect(0, 0, cellSize, cellSize);
    ctx.fillRect(cellSize, cellSize, cellSize, cellSize);
    ctx.fillStyle = color2;
    ctx.fillRect(cellSize, 0, cellSize, cellSize);
    ctx.fillRect(0, cellSize, cellSize, cellSize);

    const tex = PIXI.Texture.from(canvas);
    this.tiling = new PIXI.TilingSprite({ texture: tex, width: 1920, height: 1080 });
    this.tiling.alpha = alpha;
    this.container.addChild(this.tiling);
  }

  update(ctx: UpdateContext): void {
    this.tiling.width = ctx.screenWidth;
    this.tiling.height = ctx.screenHeight;
  }
}