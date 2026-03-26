// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

/**
 * 粉色格子效果 - 带有向左移动动画的格子图案
 */
export class PinkGrid extends BaseEffect {
  readonly name = 'pinkGrid';
  private tiling!: PIXI.TilingSprite;

  protected setup(): void {
    const cellSize = this.config.cellSize ?? 50;
    const color = this.config.color ?? '#f8c7ca';
    const lineColor = this.config.lineColor ?? '#ffffff';
    const lineWidth = this.config.lineWidth ?? 2;
    const alpha = this.config.alpha ?? 1.0;

    // 创建单个格子的纹理
    const tileSize = cellSize;
    const canvas = document.createElement('canvas');
    canvas.width = tileSize;
    canvas.height = tileSize;
    const ctx = canvas.getContext('2d')!;

    // 填充粉色背景
    ctx.fillStyle = color;
    ctx.fillRect(0, 0, tileSize, tileSize);

    // 绘制白色边框线
    ctx.strokeStyle = lineColor;
    ctx.lineWidth = lineWidth;
    ctx.strokeRect(0, 0, tileSize, tileSize);

    const tex = PIXI.Texture.from(canvas);
    this.tiling = new PIXI.TilingSprite({ 
      texture: tex, 
      width: 1920, 
      height: 1080 
    });
    this.tiling.alpha = alpha;
    this.container.addChild(this.tiling);
  }

  update(ctx: UpdateContext): void {
    this.tiling.width = ctx.screenWidth;
    this.tiling.height = ctx.screenHeight;

    // 向左移动动画
    const speed = (this.config.speed ?? 30) * ctx.animationSpeed;
    const cellSize = this.config.cellSize ?? 50;
    
    // 使用时间计算偏移量，实现平滑的向左移动
    const offset = (ctx.time * speed) % cellSize;
    this.tiling.tilePosition.x = -offset;
  }
}
