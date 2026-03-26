// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface ShapeItem {
  container: PIXI.Container;
  shape: PIXI.Graphics;
  shadow: PIXI.Graphics;
  cx: number;
  cy: number;
  baseSize: number;
  baseRotation: number;
  breathSpeed: number;
  breathPhase: number;
  breathAmp: number;
}

export class ShadowShapes extends BaseEffect {
  readonly name = 'shadowShapes';
  private items: ShapeItem[] = [];
  private built = false;

  protected setup(): void {}

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const fillColor = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const shadowColor = resolveColor(this.config.shadowColor ?? '#000066', this.palette);
    const shadowAlpha = this.config.shadowAlpha ?? 0.5;
    const shadowOffX = this.config.shadowOffX ?? 12;
    const shadowOffY = this.config.shadowOffY ?? 14;
    const count = this.config.count ?? 4;

    const rawDefs = this.config.shapes ?? this.defaultShapes(sw, sh, count);

    const defs = rawDefs.map((d: any) => ({
      ...d,
      x: d.x <= 1 ? d.x * sw : d.x,
      y: d.y <= 1 ? d.y * sh : d.y,
      size: d.size <= 1 ? d.size * Math.min(sw, sh) : d.size,
    }));

    for (const def of defs) {
      const cont = new PIXI.Container();

      const shadow = new PIXI.Graphics();
      this.drawShape(shadow, def.type, def.size, shadowColor, shadowAlpha);
      shadow.x = shadowOffX;
      shadow.y = shadowOffY;
      cont.addChild(shadow);

      const shape = new PIXI.Graphics();
      this.drawShape(shape, def.type, def.size, fillColor, 1);
      cont.addChild(shape);

      cont.x = def.x;
      cont.y = def.y;
      cont.rotation = def.rotation ?? 0;

      this.items.push({
        container: cont,
        shape,
        shadow,
        cx: def.x,
        cy: def.y,
        baseSize: def.size,
        baseRotation: def.rotation ?? 0,
        breathSpeed: 0.6 + Math.random() * 0.8,
        breathPhase: Math.random() * Math.PI * 2,
        breathAmp: 0.08 + Math.random() * 0.08,
      });

      this.container.addChild(cont);
    }
  }

  private defaultShapes(sw: number, sh: number, count: number) {
    const types: ('square' | 'diamond' | 'rect')[] = ['square', 'diamond', 'rect', 'square'];
    const shapes = [];
    for (let i = 0; i < count; i++) {
      const size = sw * (0.1 + Math.random() * 0.12);
      shapes.push({
        type: types[i % types.length],
        x: sw * (0.2 + (i / count) * 0.6),
        y: sh * (0.3 + Math.random() * 0.4),
        size,
        rotation: types[i % types.length] === 'diamond' ? Math.PI / 4 : (Math.random() - 0.5) * 0.15,
      });
    }
    return shapes;
  }

  private drawShape(g: PIXI.Graphics, type: string, size: number, color: string, alpha: number): void {
    const half = size / 2;
    switch (type) {
      case 'square':
        g.rect(-half, -half, size, size);
        break;
      case 'diamond':
        g.rect(-half, -half, size, size);
        break;
      case 'rect':
        g.rect(-size * 0.8, -half * 0.4, size * 1.6, size * 0.4);
        break;
      default:
        g.rect(-half, -half, size, size);
    }
    g.fill({ color, alpha });
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const spd = ctx.animationSpeed;
    const intensity = ctx.motionIntensity;

    for (const item of this.items) {
      const t = ctx.time * item.breathSpeed * spd + item.breathPhase;
      const beatPulse = ctx.beatIntensity * 0.1;
      const scale = 1 + Math.sin(t) * item.breathAmp * intensity + beatPulse;
      item.container.scale.set(scale);
    }
  }
}