// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface HalftoneBlock {
  container: PIXI.Container;
  baseX: number;
  baseY: number;
  driftPhase: number;
}

export class HalftoneBlocks extends BaseEffect {
  readonly name = 'halftoneBlocks';
  private blocks: HalftoneBlock[] = [];
  private initialized = false;

  protected setup(): void {}

  private initBlocks(width: number, height: number): void {
    if (this.initialized) return;
    this.initialized = true;

    const count = this.config.count ?? 8;
    const color = resolveColor(this.config.color ?? '$primary', this.palette);
    const blockSize = this.config.blockSize ?? 60;
    const dotSpacing = this.config.dotSpacing ?? 6;
    const dotRadius = this.config.dotRadius ?? 1.5;
    const alpha = this.config.alpha ?? 0.5;

    for (let i = 0; i < count; i++) {
      const blockContainer = new PIXI.Container();
      const g = new PIXI.Graphics();

      for (let x = 0; x < blockSize; x += dotSpacing) {
        for (let y = 0; y < blockSize; y += dotSpacing) {
          g.circle(x, y, dotRadius);
        }
      }
      g.fill({ color, alpha });

      blockContainer.addChild(g);
      blockContainer.pivot.set(blockSize / 2, blockSize / 2);

      const baseX = Math.random() * width;
      const baseY = Math.random() * height;
      blockContainer.x = baseX;
      blockContainer.y = baseY;
      blockContainer.rotation = (Math.random() - 0.5) * 0.5;
      blockContainer.scale.set(0.5 + Math.random());

      this.blocks.push({
        container: blockContainer,
        baseX,
        baseY,
        driftPhase: Math.random() * Math.PI * 2,
      });

      this.container.addChild(blockContainer);
    }
  }

  update(ctx: UpdateContext): void {
    this.initBlocks(ctx.screenWidth, ctx.screenHeight);

    for (const block of this.blocks) {
      const drift = ctx.motionIntensity;
      const spd = ctx.animationSpeed;
      block.container.x = block.baseX + Math.sin(ctx.time * 0.15 * spd + block.driftPhase) * 5 * drift;
      block.container.y = block.baseY + Math.cos(ctx.time * 0.1 * spd + block.driftPhase) * 5 * drift;
    }
  }
}