// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * 上下花边效果 - 由圆形相接组成的波浪形边框
 * 带有上下向中间偏移再回到原位的动画
 */
export class ScalloppedBorder extends BaseEffect {
  readonly name = 'scalloppedBorder';
  private graphics!: PIXI.Graphics;

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  update(ctx: UpdateContext): void {
    const g = this.graphics;
    g.clear();

    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const alpha = this.config.alpha ?? 1.0;
    const shadowColor = resolveColor(this.config.shadowColor ?? '#f8c7ca', this.palette);
    const shadowAlpha = this.config.shadowAlpha ?? 0.6;
    const shadowOffsetX = this.config.shadowOffsetX ?? 0;
    const shadowOffsetY = this.config.shadowOffsetY ?? 8;
    const circleRadius = this.config.circleRadius ?? 80;
    const topY = this.config.topY ?? 0;
    const bottomY = this.config.bottomY ?? ctx.screenHeight;
    
    // 动画参数
    const animSpeed = (this.config.animSpeed ?? 0.2) * ctx.animationSpeed;
    const moveAmount = this.config.moveAmount ?? 15;
    
    // 计算偏移量（正弦波动画）
    // 使用绝对值让动画只向外移动，不向内
    const offset = Math.abs(Math.sin(ctx.time * animSpeed * Math.PI)) * moveAmount;
    
    const w = ctx.screenWidth;
    
    // 计算需要多少个圆形来填满宽度
    const circleSpacing = circleRadius * 2; // 圆形直径
    const circleCount = Math.ceil(w / circleSpacing) + 2;

    // 矩形高度
    const rectHeight = circleRadius * 1.2;

    // ===== 绘制上边花边（向上移动）=====
    
    // 1. 先绘制圆形阴影
    for (let i = 0; i < circleCount; i++) {
      const x = i * circleSpacing;
      g.circle(x + shadowOffsetX, topY + circleRadius - offset + shadowOffsetY, circleRadius);
    }
    g.fill({ color: shadowColor, alpha: shadowAlpha });
    
    // 2. 绘制圆形
    for (let i = 0; i < circleCount; i++) {
      const x = i * circleSpacing;
      g.circle(x, topY + circleRadius - offset, circleRadius);
    }
    g.fill({ color, alpha });
    
    // 3. 最后绘制矩形背景填充（在圆形上面）
    g.rect(0, topY - offset, w, rectHeight);
    g.fill({ color, alpha });

    // ===== 绘制下边花边（向下移动）=====
    
    // 1. 先绘制圆形阴影
    for (let i = 0; i < circleCount; i++) {
      const x = i * circleSpacing;
      g.circle(x + shadowOffsetX, bottomY - circleRadius + offset - shadowOffsetY, circleRadius);
    }
    g.fill({ color: shadowColor, alpha: shadowAlpha });
    
    // 2. 绘制圆形
    for (let i = 0; i < circleCount; i++) {
      const x = i * circleSpacing;
      g.circle(x, bottomY - circleRadius + offset, circleRadius);
    }
    g.fill({ color, alpha });
    
    // 3. 最后绘制矩形背景填充（在圆形上面）
    g.rect(0, bottomY - rectHeight + offset, w, rectHeight);
    g.fill({ color, alpha });
  }
}
