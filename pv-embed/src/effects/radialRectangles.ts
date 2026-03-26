// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

interface RRect {
  sprite: PIXI.Sprite;
  angle: number;
  distance: number;
  baseWidth: number;
  baseHeight: number;
  speed: number;
  phase: number;
}

/**
 * Radially arranged blue gradient rectangles with blurry yellow/inverted edges.
 * Animation: rotate around center and grow larger over time, extending beyond screen.
 */
export class RadialRectangles extends BaseEffect {
  readonly name = 'radialRectangles';
  private rects: RRect[] = [];
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const count = this.config.count ?? 12;
    const baseColor = this.config.baseColor ?? '#1133aa';
    const edgeColor = this.config.edgeColor ?? '#cccc00';
    const edgeBlur = this.config.edgeBlur ?? 6;

    for (let i = 0; i < count; i++) {
      const angle = (i / count) * Math.PI * 2 + (Math.random() - 0.5) * 0.5;
      const distance = 120 + Math.random() * Math.max(sw, sh) * 0.4;
      const baseWidth = 60 + Math.random() * 180;
      const baseHeight = 40 + Math.random() * 100;

      const canvas = document.createElement('canvas');
      const pad = edgeBlur * 3;
      canvas.width = baseWidth + pad * 2;
      canvas.height = baseHeight + pad * 2;
      const ctx2d = canvas.getContext('2d')!;

      // Yellow/inverted-color blurry edge glow
      ctx2d.shadowColor = edgeColor;
      ctx2d.shadowBlur = edgeBlur * 2;
      ctx2d.shadowOffsetX = 0;
      ctx2d.shadowOffsetY = 0;
      ctx2d.strokeStyle = edgeColor;
      ctx2d.lineWidth = 2;
      ctx2d.strokeRect(pad, pad, baseWidth, baseHeight);

      // Draw again for stronger glow
      ctx2d.strokeRect(pad, pad, baseWidth, baseHeight);

      // Blue gradient fill
      ctx2d.shadowBlur = 0;
      const grad = ctx2d.createLinearGradient(pad, pad, pad + baseWidth, pad + baseHeight);

      // Parse base color to create gradient
      const r = parseInt(baseColor.slice(1, 3), 16);
      const g = parseInt(baseColor.slice(3, 5), 16);
      const b = parseInt(baseColor.slice(5, 7), 16);
      grad.addColorStop(0, `rgba(${r},${g},${b},0.85)`);
      grad.addColorStop(0.5, `rgba(${Math.floor(r * 0.6)},${Math.floor(g * 0.6)},${Math.floor(b * 1.3)},0.7)`);
      grad.addColorStop(1, `rgba(${Math.floor(r * 0.3)},${Math.floor(g * 0.3)},${Math.floor(b * 0.8)},0.55)`);

      ctx2d.fillStyle = grad;
      ctx2d.fillRect(pad + 1, pad + 1, baseWidth - 2, baseHeight - 2);

      const texture = PIXI.Texture.from(canvas);
      const sprite = new PIXI.Sprite(texture);
      sprite.anchor.set(0.5);

      this.container.addChild(sprite);
      this.rects.push({
        sprite,
        angle,
        distance,
        baseWidth,
        baseHeight,
        speed: 0.03 + Math.random() * 0.06,
        phase: Math.random() * Math.PI * 2,
      });
    }
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const cx = ctx.screenWidth * (this.config.x ?? 0.5);
    const cy = ctx.screenHeight * (this.config.y ?? 0.5);
    const rotSpeed = (this.config.rotSpeed ?? 0.08) * ctx.animationSpeed;
    const growSpeed = (this.config.growSpeed ?? 0.03) * ctx.animationSpeed;
    const time = ctx.time;

    for (const r of this.rects) {
      const currentAngle = r.angle + time * rotSpeed * r.speed * 20;
      const grow = 1 + Math.sin(time * growSpeed * 10 + r.phase) * 0.3;
      const dist = r.distance * grow;

      r.sprite.x = cx + Math.cos(currentAngle) * dist;
      r.sprite.y = cy + Math.sin(currentAngle) * dist;
      r.sprite.rotation = currentAngle + Math.PI / 4;

      const scale = grow * (0.8 + dist / 600);
      r.sprite.scale.set(scale);

      // Fade based on distance from center
      const maxDist = Math.max(ctx.screenWidth, ctx.screenHeight) * 0.8;
      const alpha = Math.max(0.3, 1 - (dist / maxDist) * 0.5);
      r.sprite.alpha = alpha;
    }
  }

  destroy(): void {
    for (const r of this.rects) r.sprite.destroy(true);
    this.rects = [];
    super.destroy();
  }
}