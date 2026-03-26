// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

export class GlowRing extends BaseEffect {
  readonly name = 'glowRing';
  private sprite!: PIXI.Sprite;
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const colorInner = this.config.colorInner ?? '#4444ff';
    const colorOuter = this.config.colorOuter ?? '#cc22aa';
    const ringRadius = this.config.radius ?? 0.38;
    const ringWidth = this.config.ringWidth ?? 0.12;
    const glowAlpha = this.config.alpha ?? 0.7;

    const size = Math.max(sw, sh);
    const canvas = document.createElement('canvas');
    canvas.width = sw;
    canvas.height = sh;
    const ctx2d = canvas.getContext('2d')!;

    const cx = sw / 2;
    const cy = sh / 2;
    const r = size * ringRadius;
    const innerR = r * (1 - ringWidth);
    const outerR = r * (1 + ringWidth);

    // Outer glow
    const outerGlow = ctx2d.createRadialGradient(cx, cy, r * 0.6, cx, cy, outerR * 1.3);
    outerGlow.addColorStop(0, 'rgba(0,0,0,0)');
    outerGlow.addColorStop(0.5, this.hexToRgba(colorOuter, 0.15));
    outerGlow.addColorStop(0.75, this.hexToRgba(colorInner, glowAlpha * 0.6));
    outerGlow.addColorStop(0.88, this.hexToRgba(colorOuter, glowAlpha * 0.4));
    outerGlow.addColorStop(1, 'rgba(0,0,0,0)');
    ctx2d.fillStyle = outerGlow;
    ctx2d.fillRect(0, 0, sw, sh);

    // Ring stroke
    ctx2d.beginPath();
    ctx2d.arc(cx, cy, r, 0, Math.PI * 2);
    ctx2d.lineWidth = size * ringWidth * 0.08;
    ctx2d.strokeStyle = this.hexToRgba(colorInner, 0.5);
    ctx2d.stroke();

    // Inner ring
    ctx2d.beginPath();
    ctx2d.arc(cx, cy, innerR, 0, Math.PI * 2);
    ctx2d.lineWidth = 1.5;
    ctx2d.strokeStyle = this.hexToRgba(colorInner, 0.25);
    ctx2d.stroke();

    const texture = PIXI.Texture.from(canvas);
    this.sprite = new PIXI.Sprite(texture);
    this.container.addChild(this.sprite);
  }

  private hexToRgba(hex: string, alpha: number): string {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgba(${r},${g},${b},${alpha})`;
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const spd = ctx.animationSpeed;
    const pulse = 1 + Math.sin(ctx.time * 0.4 * spd) * 0.03 * ctx.motionIntensity;
    const beatPulse = 1 + ctx.beatIntensity * 0.05;
    this.sprite.scale.set(pulse * beatPulse);
    this.sprite.anchor.set(0.5);
    this.sprite.x = ctx.screenWidth / 2;
    this.sprite.y = ctx.screenHeight / 2;
  }
}