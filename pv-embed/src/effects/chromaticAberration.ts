// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';

export class ChromaticAberration extends BaseEffect {
  readonly name = 'chromaticAberration';
  private filter!: PIXI.ColorMatrixFilter;
  private targetContainer!: PIXI.Container;

  protected setup(): void {
    // Apply to the parent container passed in (typically the effectsRoot)
    this.filter = new PIXI.ColorMatrixFilter();
    this.targetContainer = this.container.parent ?? this.container;
  }

  update(ctx: UpdateContext): void {
    const offset = (this.config.offset ?? 3) * ctx.motionIntensity;
    const flickerSpeed = (this.config.flickerSpeed ?? 4) * ctx.animationSpeed;
    const flicker = Math.sin(ctx.time * flickerSpeed * Math.PI * 2);

    // Simulate RGB split by shifting the color matrix red/blue channels
    const shift = offset * (0.6 + flicker * 0.4);
    const s = shift / 255;

    this.filter.matrix = [
      1, 0, 0, 0, s,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, -s,
      0, 0, 0, 1, 0,
    ];

    const existing = this.targetContainer.filters ?? [];
    if (!existing.includes(this.filter)) {
      this.targetContainer.filters = [...existing, this.filter];
    }
  }

  destroy(): void {
    if (this.targetContainer?.filters) {
      this.targetContainer.filters = this.targetContainer.filters.filter(f => f !== this.filter);
    }
    super.destroy();
  }
}