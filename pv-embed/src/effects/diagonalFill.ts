// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class DiagonalFill extends BaseEffect {
  readonly name = 'diagonalFill';
  private shapeContainer!: PIXI.Container;

  protected setup(): void {
    this.shapeContainer = new PIXI.Container();
    this.container.addChild(this.shapeContainer);
  }

  private drawn = false;

  private drawShape(_w: number, _h: number): void {
    const shape = this.config.shape ?? 'bowtie';
    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const lineSpacing = this.config.lineSpacing ?? 6;
    const lineWidth = this.config.lineWidth ?? 1.5;
    const alpha = this.config.alpha ?? 0.85;
    const size = this.config.size ?? 300;

    const g = new PIXI.Graphics();

    if (shape === 'bowtie') {
      // Two triangles meeting at center (X / bowtie shape)
      const half = size / 2;

      // Draw filled triangles with diagonal line pattern
      // Top-left triangle
      this.drawFilledTriangle(g, 0, -half, -half, half, half, half, color, lineSpacing, lineWidth, alpha);
      // Bottom-right triangle (mirrored)
      this.drawFilledTriangle(g, 0, half, -half, -half, half, -half, color, lineSpacing, lineWidth, alpha);

    } else if (shape === 'diamond') {
      const half = size / 2;
      // Diamond outline
      g.moveTo(0, -half).lineTo(half, 0).lineTo(0, half).lineTo(-half, 0).closePath();
      g.fill({ color, alpha: alpha * 0.8 });

      // Diagonal lines inside
      const mask = new PIXI.Graphics();
      mask.moveTo(0, -half).lineTo(half, 0).lineTo(0, half).lineTo(-half, 0).closePath();
      mask.fill({ color: 0xffffff });

      const lines = new PIXI.Graphics();
      for (let i = -size; i < size; i += lineSpacing) {
        lines.moveTo(i, -half);
        lines.lineTo(i + size, half);
      }
      lines.stroke({ color: resolveColor(this.config.lineColor ?? '$background', this.palette), width: lineWidth, alpha: 0.6 });

      lines.mask = mask;
      this.shapeContainer.addChild(mask);
      this.shapeContainer.addChild(lines);

    } else if (shape === 'rect') {
      const rw = this.config.rectWidth ?? size * 1.5;
      const rh = this.config.rectHeight ?? size;
      g.rect(-rw / 2, -rh / 2, rw, rh);
      g.fill({ color, alpha });

      // Diagonal lines
      const lines = new PIXI.Graphics();
      for (let i = -rw; i < rw + rh; i += lineSpacing) {
        lines.moveTo(-rw / 2 + i, -rh / 2);
        lines.lineTo(-rw / 2 + i - rh, rh / 2);
      }
      lines.stroke({ color: resolveColor(this.config.lineColor ?? '$background', this.palette), width: lineWidth, alpha: 0.4 });

      this.shapeContainer.addChild(lines);
    }

    this.shapeContainer.addChild(g);
  }

  private drawFilledTriangle(
    g: PIXI.Graphics,
    x1: number, y1: number,
    x2: number, y2: number,
    x3: number, y3: number,
    color: string, lineSpacing: number, lineWidth: number, alpha: number
  ) {
    g.moveTo(x1, y1).lineTo(x2, y2).lineTo(x3, y3).closePath();
    g.fill({ color, alpha });

    // Diagonal lines over the triangle area
    const minX = Math.min(x1, x2, x3);
    const maxX = Math.max(x1, x2, x3);
    const minY = Math.min(y1, y2, y3);
    const maxY = Math.max(y1, y2, y3);
    const span = Math.max(maxX - minX, maxY - minY);

    for (let i = -span; i < span * 2; i += lineSpacing) {
      g.moveTo(minX + i, minY);
      g.lineTo(minX + i - span, maxY);
    }
    g.stroke({ color: resolveColor(this.config.lineColor ?? '$background', this.palette), width: lineWidth, alpha: 0.3 });
  }

  update(ctx: UpdateContext): void {
    if (!this.drawn) {
      this.drawn = true;
      this.drawShape(ctx.screenWidth, ctx.screenHeight);
    }

    const cx = (this.config.x ?? 0.5) * ctx.screenWidth;
    const cy = (this.config.y ?? 0.5) * ctx.screenHeight;
    this.shapeContainer.x = cx;
    this.shapeContainer.y = cy;

    const speed = (this.config.animationSpeed ?? 0.05) * ctx.animationSpeed;
    const pulse = 1 + Math.sin(ctx.time * speed * Math.PI * 2) * 0.03 * ctx.motionIntensity;
    this.shapeContainer.scale.set(pulse);
  }
}