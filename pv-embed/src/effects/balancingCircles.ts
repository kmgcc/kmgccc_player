// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

interface CircleData {
  x: number;
  y: number;
  radius: number;
  bluePrimary: boolean;
}

export class BalancingCircles extends BaseEffect {
  readonly name = 'balancingCircles';
  private sprite!: PIXI.Sprite;
  private built = false;
  private circles: CircleData[] = [];

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const count = this.config.count ?? 5;
    const blueColor = this.config.blueColor ?? '#0028B4';
    const whiteColor = this.config.whiteColor ?? '#ffffff';
    const glowAlpha = this.config.glowAlpha ?? 0.4;

    for (let i = 0; i < count; i++) {
      let cx: number, cy: number;
      do {
        cx = 50 + Math.random() * (sw - 100);
        cy = 50 + Math.random() * (sh - 100);
      } while (Math.abs(cx - sw / 2) < sw * 0.15 && Math.abs(cy - sh / 2) < sh * 0.2);

      this.circles.push({
        x: cx,
        y: cy,
        radius: 12 + Math.random() * 35,
        bluePrimary: Math.random() > 0.2,
      });
    }

    const canvas = document.createElement('canvas');
    canvas.width = sw;
    canvas.height = sh;
    const ctx2d = canvas.getContext('2d')!;

    for (const c of this.circles) {
      ctx2d.save();

      // Glow halo
      const glow = ctx2d.createRadialGradient(c.x, c.y, c.radius * 0.5, c.x, c.y, c.radius + 15);
      glow.addColorStop(0, `rgba(255,255,255,${glowAlpha * 0.6})`);
      glow.addColorStop(0.7, `rgba(255,255,255,${glowAlpha * 0.15})`);
      glow.addColorStop(1, 'rgba(255,255,255,0)');
      ctx2d.fillStyle = glow;
      ctx2d.beginPath();
      ctx2d.arc(c.x, c.y, c.radius + 15, 0, Math.PI * 2);
      ctx2d.fill();

      if (c.bluePrimary) {
        // White border
        ctx2d.beginPath();
        ctx2d.arc(c.x, c.y, c.radius + 2, 0, Math.PI * 2);
        ctx2d.fillStyle = whiteColor;
        ctx2d.fill();
        // Blue fill
        ctx2d.beginPath();
        ctx2d.arc(c.x, c.y, c.radius, 0, Math.PI * 2);
        ctx2d.fillStyle = blueColor;
        ctx2d.fill();
      } else {
        // Blue border
        ctx2d.beginPath();
        ctx2d.arc(c.x, c.y, c.radius + 2, 0, Math.PI * 2);
        ctx2d.fillStyle = blueColor;
        ctx2d.fill();
        // White fill
        ctx2d.beginPath();
        ctx2d.arc(c.x, c.y, c.radius, 0, Math.PI * 2);
        ctx2d.fillStyle = whiteColor;
        ctx2d.fill();
      }

      ctx2d.restore();
    }

    const texture = PIXI.Texture.from(canvas);
    this.sprite = new PIXI.Sprite(texture);
    this.container.addChild(this.sprite);
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);
  }
}