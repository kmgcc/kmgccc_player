// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface ParaDef {
  xFrac: number;
  widthFrac: number;
  color1: string;
  color2: string;
  texture: 'none' | 'halftone' | 'checkerboard';
  phase: number;
}

interface LivePara {
  container: PIXI.Container;
  baseX: number;
  def: ParaDef;
}

export class ParallelogramStripes extends BaseEffect {
  readonly name = 'parallelogramStripes';
  private root!: PIXI.Container;
  private paras: LivePara[] = [];
  private built = false;

  protected setup(): void {
    this.root = new PIXI.Container();
    this.container.addChild(this.root);
  }

  private build(sw: number, sh: number): void {
    if (this.built) return;
    this.built = true;

    const skewDeg = this.config.skewAngle ?? 20;
    const alpha = this.config.alpha ?? 0.92;
    const paraH = sh * 1.5;
    const S = Math.tan((skewDeg * Math.PI) / 180) * paraH;
    const absS = Math.abs(S);

    const defs: ParaDef[] = this.config.paras ?? [
      { xFrac: -0.15, widthFrac: 0.38, color1: '$background', color2: '$primary', texture: 'none', phase: 0 },
      { xFrac: 0.10,  widthFrac: 0.32, color1: '$primary',    color2: '$secondary', texture: 'none', phase: 1.2 },
      { xFrac: 0.30,  widthFrac: 0.30, color1: '$accent',     color2: '$accent', texture: 'halftone', phase: 2.4 },
      { xFrac: 0.48,  widthFrac: 0.26, color1: '$secondary',  color2: '$secondary', texture: 'checkerboard', phase: 3.6 },
      { xFrac: 0.62,  widthFrac: 0.32, color1: '$secondary',  color2: '$primary', texture: 'none', phase: 4.8 },
      { xFrac: 0.82,  widthFrac: 0.30, color1: '$primary',    color2: '$background', texture: 'none', phase: 0.6 },
    ];

    for (const def of defs) {
      const pureW = sw * def.widthFrac;
      const totalW = pureW + absS;
      const baseX = sw * def.xFrac;

      let tlX: number, trX: number, blX: number, brX: number;
      if (S >= 0) {
        tlX = absS;  trX = absS + pureW;
        blX = 0;     brX = pureW;
      } else {
        tlX = 0;     trX = pureW;
        blX = absS;  brX = absS + pureW;
      }

      const pc = new PIXI.Container();
      pc.y = sh / 2;

      // Gradient fill
      const cvs = document.createElement('canvas');
      cvs.width = Math.max(1, Math.ceil(totalW));
      cvs.height = Math.max(1, Math.ceil(paraH));
      const gctx = cvs.getContext('2d')!;
      const c1 = resolveColor(def.color1, this.palette);
      const c2 = resolveColor(def.color2, this.palette);
      const grad = gctx.createLinearGradient(0, 0, cvs.width, 0);
      grad.addColorStop(0, c1);
      grad.addColorStop(1, c2);
      gctx.fillStyle = grad;
      gctx.fillRect(0, 0, cvs.width, cvs.height);

      const sp = new PIXI.Sprite(PIXI.Texture.from(cvs));
      sp.y = -paraH / 2;
      sp.alpha = alpha;
      pc.addChild(sp);

      if (def.texture === 'halftone') {
        const tile = createDotTile(this.config.dotSpacing ?? 10, this.config.dotRadius ?? 3);
        const ts = new PIXI.TilingSprite({
          texture: PIXI.Texture.from(tile),
          width: totalW,
          height: paraH,
        });
        ts.y = -paraH / 2;
        pc.addChild(ts);
      } else if (def.texture === 'checkerboard') {
        const tile = createCheckerTile(this.config.cellSize ?? 8);
        const ts = new PIXI.TilingSprite({
          texture: PIXI.Texture.from(tile),
          width: totalW,
          height: paraH,
        });
        ts.y = -paraH / 2;
        pc.addChild(ts);
      }

      // Parallelogram mask
      const mask = new PIXI.Graphics();
      mask.moveTo(tlX, -paraH / 2)
          .lineTo(trX, -paraH / 2)
          .lineTo(brX, paraH / 2)
          .lineTo(blX, paraH / 2)
          .closePath()
          .fill({ color: 0xffffff });
      pc.addChild(mask);
      pc.mask = mask;

      pc.x = baseX;
      this.root.addChild(pc);
      this.paras.push({ container: pc, baseX, def });
    }
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const speed = (this.config.moveSpeed ?? 0.3) * ctx.animationSpeed;
    const intensity = ctx.motionIntensity;

    for (const p of this.paras) {
      const offset = Math.sin(ctx.time * speed + p.def.phase) * 30 * intensity;
      p.container.x = p.baseX + offset;
    }
  }
}

function createDotTile(spacing: number, radius: number): HTMLCanvasElement {
  const canvas = document.createElement('canvas');
  canvas.width = spacing * 2;
  canvas.height = spacing * 2;
  const ctx = canvas.getContext('2d')!;
  ctx.fillStyle = 'rgba(0,0,0,0.13)';
  ctx.beginPath();
  ctx.arc(spacing / 2, spacing / 2, radius, 0, Math.PI * 2);
  ctx.arc(spacing * 1.5, spacing * 1.5, radius, 0, Math.PI * 2);
  ctx.fill();
  return canvas;
}

function createCheckerTile(size: number): HTMLCanvasElement {
  const canvas = document.createElement('canvas');
  canvas.width = size * 2;
  canvas.height = size * 2;
  const ctx = canvas.getContext('2d')!;
  ctx.fillStyle = 'rgba(255,255,255,0.18)';
  ctx.fillRect(0, 0, size, size);
  ctx.fillRect(size, size, size, size);
  return canvas;
}