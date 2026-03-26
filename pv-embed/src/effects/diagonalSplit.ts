// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

export class DiagonalSplit extends BaseEffect {
  readonly name = 'diagonalSplit';
  private fillG!: PIXI.Graphics;
  private hatchSprite!: PIXI.TilingSprite;
  private maskG!: PIXI.Graphics;
  private centerG!: PIXI.Graphics;

  protected setup(): void {
    this.fillG = new PIXI.Graphics();
    this.container.addChild(this.fillG);

    const spacing = this.config.hatchSpacing ?? 6;
    const tile = document.createElement('canvas');
    tile.width = spacing;
    tile.height = spacing;
    const tctx = tile.getContext('2d')!;
    tctx.strokeStyle = 'rgba(0,0,0,0.12)';
    tctx.lineWidth = 0.7;
    tctx.beginPath();
    tctx.moveTo(0, spacing);
    tctx.lineTo(spacing, 0);
    tctx.stroke();

    this.hatchSprite = new PIXI.TilingSprite({
      texture: PIXI.Texture.from(tile),
      width: 1920,
      height: 1080,
    });
    this.container.addChild(this.hatchSprite);

    this.maskG = new PIXI.Graphics();
    this.container.addChild(this.maskG);
    this.hatchSprite.mask = this.maskG;

    this.centerG = new PIXI.Graphics();
    this.container.addChild(this.centerG);
  }

  update(ctx: UpdateContext): void {
    const w = ctx.screenWidth;
    const h = ctx.screenHeight;
    const cx = w / 2;
    const cy = h / 2;
    const reach = Math.sqrt(w * w + h * h);
    const speed = ctx.animationSpeed;
    const intensity = ctx.motionIntensity;

    const rotSpeed = (this.config.rotSpeed ?? 0.15) * speed;
    const baseHalf = this.config.baseHalfAngle ?? 0.6;
    const angleVar = (this.config.angleVariation ?? 0.3) * intensity;
    const initRot = this.config.initRotation ?? -Math.PI / 2;

    const rotation = initRot + ctx.time * rotSpeed;
    const halfAngle = baseHalf + Math.sin(ctx.time * 0.3 * speed) * angleVar;

    const a1 = rotation - halfAngle;
    const a2 = rotation + halfAngle;

    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const alpha = this.config.alpha ?? 1;

    this.fillG.clear();
    this.drawWedges(this.fillG, cx, cy, a1, a2, reach, color, alpha);

    this.maskG.clear();
    this.drawWedges(this.maskG, cx, cy, a1, a2, reach, '#ffffff', 1);

    this.hatchSprite.width = w;
    this.hatchSprite.height = h;

    const sq = this.config.centerSize ?? 12;
    const centerColor = resolveColor(this.config.centerColor ?? '$primary', this.palette);
    this.centerG.clear();
    this.centerG.rect(cx - sq / 2, cy - sq / 2, sq, sq);
    this.centerG.fill({ color: centerColor, alpha: 0.9 });
  }

  private drawWedges(
    g: PIXI.Graphics, cx: number, cy: number,
    a1: number, a2: number, reach: number,
    color: string, alpha: number,
  ): void {
    g.moveTo(cx, cy);
    g.lineTo(cx + Math.cos(a1) * reach, cy + Math.sin(a1) * reach);
    g.lineTo(cx + Math.cos(a2) * reach, cy + Math.sin(a2) * reach);
    g.closePath();

    g.moveTo(cx, cy);
    g.lineTo(cx + Math.cos(a1 + Math.PI) * reach, cy + Math.sin(a1 + Math.PI) * reach);
    g.lineTo(cx + Math.cos(a2 + Math.PI) * reach, cy + Math.sin(a2 + Math.PI) * reach);
    g.closePath();

    g.fill({ color, alpha });
  }
}