// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

interface Block {
  g: PIXI.Graphics;
  x: number;
  y: number;
  w: number;
  h: number;
  rotation: number;
  brightness: number;
  phase: number;
  breathSpeed: number;
}

/**
 * Multiple irregular blocks in varying shades from white to light gray,
 * with breathing animation (pulsing scale and alpha).
 */
export class BreathingBlocks extends BaseEffect {
  readonly name = 'breathingBlocks';
  private blocks: Block[] = [];
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const count = this.config.count ?? 8;
    const minSize = this.config.minSize ?? 0.15;
    const maxSize = this.config.maxSize ?? 0.55;
    const minBrightness = this.config.minBrightness ?? 180;
    const maxBrightness = this.config.maxBrightness ?? 255;

    for (let i = 0; i < count; i++) {
      const bw = sw * (minSize + Math.random() * (maxSize - minSize));
      const bh = sh * (minSize + Math.random() * (maxSize - minSize));
      const x = Math.random() * sw;
      const y = Math.random() * sh;
      const rotation = (Math.random() - 0.5) * 0.6;
      const brightness = minBrightness + Math.random() * (maxBrightness - minBrightness);
      const phase = Math.random() * Math.PI * 2;
      const breathSpeed = 0.3 + Math.random() * 0.5;

      const hex = Math.floor(brightness).toString(16).padStart(2, '0');
      const color = `#${hex}${hex}${hex}`;

      const g = new PIXI.Graphics();
      g.rect(-bw / 2, -bh / 2, bw, bh);
      g.fill({ color, alpha: 0.6 + Math.random() * 0.35 });

      g.x = x;
      g.y = y;
      g.rotation = rotation;
      g.pivot.set(0, 0);

      this.container.addChild(g);
      this.blocks.push({ g, x, y, w: bw, h: bh, rotation, brightness, phase, breathSpeed });
    }
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const speed = ctx.animationSpeed;
    for (const b of this.blocks) {
      const t = ctx.time * b.breathSpeed * speed;
      const breathScale = 1 + Math.sin(t + b.phase) * 0.04;
      const breathAlpha = 0.6 + Math.sin(t * 0.7 + b.phase + 1) * 0.15;

      b.g.scale.set(breathScale);
      b.g.alpha = Math.max(0.3, Math.min(1, breathAlpha));
    }
  }

  destroy(): void {
    for (const b of this.blocks) b.g.destroy();
    this.blocks = [];
    super.destroy();
  }
}