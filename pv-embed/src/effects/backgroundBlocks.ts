// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

interface BlockData {
  x: number;
  y: number;
  w: number;
  h: number;
  brightness: number;
}

export class BackgroundBlocks extends BaseEffect {
  readonly name = 'backgroundBlocks';
  private g!: PIXI.Graphics;
  private blocks: BlockData[] = [];
  private drawn = false;
  private lastW = 0;
  private lastH = 0;

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);

    const count = this.config.count ?? 7;
    for (let i = 0; i < count; i++) {
      this.blocks.push({
        x: Math.random(),
        y: Math.random(),
        w: 0.08 + Math.random() * 0.25,
        h: 0.04 + Math.random() * 0.3,
        brightness: 230 + Math.floor(Math.random() * 20),
      });
    }
  }

  update(ctx: UpdateContext): void {
    if (this.drawn && this.lastW === ctx.screenWidth && this.lastH === ctx.screenHeight) return;
    this.drawn = true;
    this.lastW = ctx.screenWidth;
    this.lastH = ctx.screenHeight;

    const g = this.g;
    g.clear();

    const alpha = this.config.alpha ?? 0.5;
    const w = ctx.screenWidth;
    const h = ctx.screenHeight;

    for (const b of this.blocks) {
      const hex = b.brightness.toString(16);
      const color = `#${hex}${hex}${hex}`;
      g.rect(b.x * w, b.y * h, b.w * w, b.h * h);
      g.fill({ color, alpha });
    }
  }
}