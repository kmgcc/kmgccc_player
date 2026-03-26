// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * 跃动圆形效果 - 带有放大缩小动画的圆形边框
 */
export class PulsingCircle extends BaseEffect {
  readonly name = 'pulsingCircle';
  private graphics!: PIXI.Graphics;

  protected setup(): void {
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  update(ctx: UpdateContext): void {
    const g = this.graphics;
    g.clear();

    const strokeColor = resolveColor(this.config.strokeColor ?? '#ffffff', this.palette);
    const strokeAlpha = this.config.strokeAlpha ?? 0.8;
    const baseStrokeWidth = this.config.strokeWidth ?? 8;
    const baseRadius = this.config.radius ?? 250;
    const x = this.config.x ?? 0.5;
    const y = this.config.y ?? 0.5;
    
    // 外描边参数
    const outerStrokeColor = resolveColor(this.config.outerStrokeColor ?? '#ecbfc0', this.palette);
    const outerStrokeWidth = this.config.outerStrokeWidth ?? 3;
    const outerStrokeAlpha = this.config.outerStrokeAlpha ?? 0.6;
    
    // 动画参数
    const animSpeed = (this.config.animSpeed ?? 0.2) * ctx.animationSpeed;
    const strokePulseAmount = this.config.strokePulseAmount ?? 0.5;
    const radiusPulseAmount = this.config.radiusPulseAmount ?? 0.08;
    const enableBeatReact = this.config.enableBeatReact ?? false;
    
    // 计算动画进度（-1 到 1）
    // 使用与上下花边相同的周期：Math.PI 而不是 Math.PI * 2
    const animProgress = Math.sin(ctx.time * animSpeed * Math.PI);
    
    // 边框粗细变化：animProgress 为正时变粗，为负时变细
    const strokeScale = 1 + animProgress * strokePulseAmount;
    let currentStrokeWidth = baseStrokeWidth * strokeScale;
    
    // 圆形半径变化：与边框粗细反向，animProgress 为正时变小，为负时变大
    const radiusScale = 1 - animProgress * radiusPulseAmount;
    let currentRadius = baseRadius * radiusScale;
    
    // 可选的节拍反应（默认关闭以保持丝滑）
    if (enableBeatReact) {
      const beatPulse = ctx.beatIntensity * 0.1;
      currentStrokeWidth *= (1 + beatPulse);
      currentRadius *= (1 + beatPulse * 0.5);
    }
    
    const cx = x * ctx.screenWidth;
    const cy = y * ctx.screenHeight;

    // 先绘制外描边（粉色）
    g.circle(cx, cy, currentRadius);
    g.stroke({ color: outerStrokeColor, width: currentStrokeWidth + outerStrokeWidth * 2, alpha: outerStrokeAlpha });

    // 再绘制主圆形边框（白色）
    g.circle(cx, cy, currentRadius);
    g.stroke({ color: strokeColor, width: currentStrokeWidth, alpha: strokeAlpha });
  }
}
