// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface SquareLayer {
  container: PIXI.Container;
  phaseOffset: number;
  rotSpeed: number;
  scalePhase: number;
}

export class CenteredSquares extends BaseEffect {
  readonly name = 'centeredSquares';
  private layers: SquareLayer[] = [];

  protected setup(): void {
    const outerSize = this.config.outerSize ?? 300;
    const midSize = this.config.midSize ?? 220;
    const innerSize = this.config.innerSize ?? 160;
    const borderColor = resolveColor(this.config.borderColor ?? '$primary', this.palette);
    const midColor = resolveColor(this.config.midColor ?? '$primary', this.palette);
    const innerColor = resolveColor(this.config.innerColor ?? '$secondary', this.palette);

    // Layer 0: outer frame — no fill, irregular border widths
    const outerC = new PIXI.Container();
    const outerG = new PIXI.Graphics();
    const ho = outerSize / 2;
    outerG.moveTo(-ho, -ho).lineTo(ho, -ho);
    outerG.stroke({ color: borderColor, width: 4, alpha: 0.75 });
    outerG.moveTo(ho, -ho).lineTo(ho, ho);
    outerG.stroke({ color: borderColor, width: 1.5, alpha: 0.45 });
    outerG.moveTo(ho, ho).lineTo(-ho, ho);
    outerG.stroke({ color: borderColor, width: 2.8, alpha: 0.6 });
    outerG.moveTo(-ho, ho).lineTo(-ho, -ho);
    outerG.stroke({ color: borderColor, width: 5, alpha: 0.8 });
    outerC.addChild(outerG);
    this.container.addChild(outerC);
    this.layers.push({ container: outerC, phaseOffset: 0, rotSpeed: 0.7, scalePhase: 0 });

    // Layer 1: mid — solid diamond
    const midC = new PIXI.Container();
    const midG = new PIXI.Graphics();
    const hm = midSize / 2;
    midG.rect(-hm, -hm, midSize, midSize);
    midG.fill({ color: midColor, alpha: 1 });
    midC.addChild(midG);
    this.container.addChild(midC);
    this.layers.push({ container: midC, phaseOffset: 1.0, rotSpeed: 0.55, scalePhase: 1.2 });

    // Layer 2: inner — solid diamond
    const innerC = new PIXI.Container();
    const innerG = new PIXI.Graphics();
    const hi = innerSize / 2;
    innerG.rect(-hi, -hi, innerSize, innerSize);
    innerG.fill({ color: innerColor, alpha: 1 });
    innerC.addChild(innerG);
    this.container.addChild(innerC);
    this.layers.push({ container: innerC, phaseOffset: 2.0, rotSpeed: 0.4, scalePhase: 2.4 });
  }

  update(ctx: UpdateContext): void {
    const cx = ctx.screenWidth / 2;
    const cy = ctx.screenHeight / 2;
    const speed = ctx.animationSpeed;
    const intensity = ctx.motionIntensity;

    for (const layer of this.layers) {
      layer.container.x = cx;
      layer.container.y = cy;
      layer.container.rotation = ctx.time * layer.rotSpeed * speed;
      const scalePulse = 0.75 + Math.abs(Math.sin(ctx.time * 0.4 * speed + layer.scalePhase)) * 0.55 * intensity;
      layer.container.scale.set(scalePulse);
    }
  }
}