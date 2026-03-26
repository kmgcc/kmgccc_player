// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';


/**
 * 星轨 — 沿一个大椭圆弧段排列矩形序列，近大远小，循环运动。
 * 多条完整椭圆轨道线产生行星轨道感。
 */
export class StarTrail extends BaseEffect {
  readonly name = 'starTrail';
  private graphics!: PIXI.Graphics;
  private count = 20;
  private strokeWidth = 3;
  private radiusX = 600;
  private radiusY = 400;
  private maxSize = 260;
  private minSize = 35;
  private loopSpeed = 0.12;
  private tilt = -0.25;
  private arcCenter = -0.6;
  private arcSpan = 4.2;
  private invertColor: string = '#000000';

  protected setup(): void {
    this.count = this.config.count ?? 20;
    this.strokeWidth = this.config.strokeWidth ?? 3;
    this.radiusX = this.config.radiusX ?? 600;
    this.radiusY = this.config.radiusY ?? 400;
    this.maxSize = this.config.maxSize ?? 260;
    this.minSize = this.config.minSize ?? 35;
    this.loopSpeed = this.config.loopSpeed ?? 0.12;
    this.tilt = this.config.tilt ?? -0.25;
    this.arcCenter = this.config.arcCenter ?? -0.6;
    this.arcSpan = this.config.arcSpan ?? 4.2;
    this.graphics = new PIXI.Graphics();
    this.container.addChild(this.graphics);
  }

  private computeInvertColor(): void {
    const hex = this.palette.background.replace('#', '');
    const br = parseInt(hex.substring(0, 2), 16);
    const bg = parseInt(hex.substring(2, 4), 16);
    const bb = parseInt(hex.substring(4, 6), 16);
    this.invertColor = `#${(255 - br).toString(16).padStart(2, '0')}${(255 - bg).toString(16).padStart(2, '0')}${(255 - bb).toString(16).padStart(2, '0')}`;
  }

  update(ctx: UpdateContext): void {
    this.computeInvertColor();
    const g = this.graphics;
    g.clear();

    const speed = ctx.animationSpeed;
    const t = ctx.time * speed * this.loopSpeed;

    const ellipseCx = ctx.screenWidth * 0.35;
    const ellipseCy = ctx.screenHeight * 0.85;

    const arcStart = this.arcCenter - this.arcSpan / 2;

    const curveFrac = this.config.curveFrac ?? 0.45;
    const arcSegments = 64;
    for (let i = 0; i <= arcSegments; i++) {
      const a = arcStart + (i / arcSegments) * curveFrac * this.arcSpan;
      const px = ellipseCx + Math.cos(a) * this.radiusX;
      const py = ellipseCy + Math.sin(a) * this.radiusY + Math.cos(a) * this.radiusX * Math.sin(this.tilt);
      if (i === 0) g.moveTo(px, py);
      else g.lineTo(px, py);
    }
    g.stroke({ color: this.invertColor, width: 1, alpha: 0.15 });

    // 多条完整椭圆轨道
    const orbitCount = 4;
    const ellipseSegs = 96;
    for (let o = 0; o < orbitCount; o++) {
      const scale = 0.7 + o * 0.2;
      const tiltOff = (o - 1.5) * 0.06;
      const alpha = 0.08 + 0.04 * (orbitCount - o);
      const rx = this.radiusX * scale;
      const ry = this.radiusY * scale;
      const ti = this.tilt + tiltOff;
      const ocx = ellipseCx + (o - 1.5) * 25;
      const ocy = ellipseCy + (o - 1.5) * 18;

      for (let i = 0; i <= ellipseSegs; i++) {
        const a = (i / ellipseSegs) * Math.PI * 2;
        const px = ocx + Math.cos(a) * rx;
        const py = ocy + Math.sin(a) * ry + Math.cos(a) * rx * Math.sin(ti);
        if (i === 0) g.moveTo(px, py);
        else g.lineTo(px, py);
      }
      g.stroke({ color: this.invertColor, width: 0.8, alpha });
    }

    // 收集矩形，按深度排序
    const items: { angle: number; depth: number; x: number; y: number; size: number; alpha: number }[] = [];

    for (let i = 0; i < this.count; i++) {
      let frac = (i / this.count - t) % 1;
      if (frac < 0) frac += 1;
      const angle = arcStart + frac * this.arcSpan;

      const ex = Math.cos(angle) * this.radiusX;
      const ey = Math.sin(angle) * this.radiusY;

      const depthNorm = frac;
      const size = this.minSize + (this.maxSize - this.minSize) * depthNorm;
      const alpha = 0.15 + 0.7 * depthNorm;

      const x = ellipseCx + ex;
      const y = ellipseCy + ey + ex * Math.sin(this.tilt);

      items.push({ angle, depth: depthNorm, x, y, size, alpha });
    }

    items.sort((a, b) => a.depth - b.depth);

    for (const item of items) {
      const half = item.size / 2;
      const rotation = item.angle * 0.3 + ctx.time * 0.05;
      const cos = Math.cos(rotation);
      const sin = Math.sin(rotation);

      const corners = [
        [-half, -half],
        [half, -half],
        [half, half],
        [-half, half],
      ];

      const rotated = corners.map(([lx, ly]) => ({
        x: item.x + lx * cos - ly * sin,
        y: item.y + lx * sin + ly * cos,
      }));

      g.moveTo(rotated[0].x, rotated[0].y);
      for (let j = 1; j < 4; j++) {
        g.lineTo(rotated[j].x, rotated[j].y);
      }
      g.lineTo(rotated[0].x, rotated[0].y);
      g.stroke({ color: this.invertColor, width: this.strokeWidth, alpha: item.alpha });
    }
  }
}
