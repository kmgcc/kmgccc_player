// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Displays the previous text segment as small vertical columns
 * next to the main text area. White, no background, no glow.
 */
export class VerticalSubText extends BaseEffect {
  readonly name = 'verticalSubText';
  private textObjs: PIXI.Text[] = [];
  private currentText = '';
  private prevSegment = '';

  protected setup(): void {}

  update(ctx: UpdateContext): void {
    const text = ctx.currentText || '';

    // Use config._allSegments to get the previous segment
    // The engine passes currentText for the current segment.
    // We derive the "previous" text from a different approach:
    // we track segment changes and remember the old one.
    if (text !== this.currentText) {
      this.prevSegment = this.currentText;
      this.currentText = text;
      this.rebuildText(ctx);
    }

    // Update color and fade animation
    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    for (const t of this.textObjs) {
      t.style.fill = color;
      t.alpha = 0.7 + Math.sin(ctx.time * 0.5) * 0.1;
    }
  }

  private rebuildText(ctx: UpdateContext): void {
    for (const t of this.textObjs) {
      this.container.removeChild(t);
      t.destroy();
    }
    this.textObjs = [];

    if (!this.prevSegment) return;

    const color = resolveColor(this.config.color ?? '#ffffff', this.palette);
    const fontFamily = this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", serif';
    const fontSize = this.config.fontSize ?? 14;
    const x = ctx.screenWidth * (this.config.x ?? 0.62);
    const y = ctx.screenHeight * (this.config.y ?? 0.35);
    const lineHeight = fontSize * 1.4;
    const colGap = fontSize * 1.6;

    // Split text into columns (Japanese vertical text reads right-to-left)
    const charsPerCol = this.config.charsPerCol ?? 5;
    const cols: string[] = [];
    for (let i = 0; i < this.prevSegment.length; i += charsPerCol) {
      cols.push(this.prevSegment.slice(i, i + charsPerCol));
    }

    for (let c = 0; c < cols.length; c++) {
      const col = cols[c];
      for (let r = 0; r < col.length; r++) {
        const style = new PIXI.TextStyle({
          fontFamily,
          fontSize,
          fill: color,
        });
        const t = new PIXI.Text({ text: col[r], style });
        t.anchor.set(0.5);
        // Vertical layout: each column to the left of previous (Japanese right-to-left)
        t.x = x - c * colGap;
        t.y = y + r * lineHeight;
        t.alpha = 0.7;
        this.textObjs.push(t);
        this.container.addChild(t);
      }
    }
  }

  destroy(): void {
    for (const t of this.textObjs) t.destroy();
    this.textObjs = [];
    super.destroy();
  }
}