// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface FallingChar {
  text: PIXI.Text;
  x: number;
  y: number;
  speed: number;
  rotSpeed: number;
  flipSpeed: number;
  flipPhase: number;
  rotation: number;
  size: number;
}

export class FallingText extends BaseEffect {
  readonly name = 'fallingText';
  private chars: FallingChar[] = [];
  private initialized = false;

  protected setup(): void {}

  private spawn(sw: number, sh: number): void {
    if (this.initialized) return;
    this.initialized = true;

    const userText = this.config._userText ?? '';
    const pool = userText || this.config.chars || '';
    if (pool.length === 0) return;
    const count = this.config.count ?? 30;
    const color = resolveColor(this.config.color ?? '$accent', this.palette);
    const fontFamily = this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", serif';
    const minSize = this.config.minSize ?? 28;
    const maxSize = this.config.maxSize ?? 72;

    for (let i = 0; i < count; i++) {
      const ch = pool[Math.floor(Math.random() * pool.length)];
      const size = minSize + Math.random() * (maxSize - minSize);

      const style = new PIXI.TextStyle({
        fontFamily,
        fontSize: size,
        fill: color,
        fontWeight: 'bold',
        stroke: { color: '#000000', width: Math.max(2, size * 0.06) },
        dropShadow: {
          color: color,
          blur: size * 0.3,
          alpha: 0.5,
          distance: 0,
        },
      });
      const text = new PIXI.Text({ text: ch, style });
      text.anchor.set(0.5);

      const x = Math.random() * sw;
      const y = -size + Math.random() * (sh + size * 2) * -0.1 - Math.random() * sh;

      text.x = x;
      text.y = y;

      const fc: FallingChar = {
        text,
        x,
        y,
        speed: 60 + Math.random() * 120,
        rotSpeed: (Math.random() - 0.5) * 3,
        flipSpeed: 1.5 + Math.random() * 3,
        flipPhase: Math.random() * Math.PI * 2,
        rotation: (Math.random() - 0.5) * 0.5,
        size,
      };

      this.chars.push(fc);
      this.container.addChild(text);
    }
  }

  update(ctx: UpdateContext): void {
    this.spawn(ctx.screenWidth, ctx.screenHeight);

    const spd = ctx.animationSpeed;
    const intensity = ctx.motionIntensity;

    for (const c of this.chars) {
      c.y += c.speed * spd * (1 + ctx.beatIntensity * 0.6) * ctx.deltaTime;

      if (c.y > ctx.screenHeight + c.size) {
        c.y = -c.size * 2;
        c.x = Math.random() * ctx.screenWidth;
      }

      c.rotation += c.rotSpeed * spd * ctx.deltaTime * intensity;
      c.text.x = c.x;
      c.text.y = c.y;
      c.text.rotation = c.rotation;

      const flip = Math.cos(ctx.time * c.flipSpeed + c.flipPhase);
      c.text.scale.x = flip;
    }
  }
}