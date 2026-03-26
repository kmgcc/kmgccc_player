// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Renders system status text at top of screen.
 * Faithful to CyberpunkTheme._draw_static_elements text.
 */
export class HudStatusText extends BaseEffect {
  readonly name = 'hudStatusText';
  private centerText!: PIXI.Text;
  private rightText!: PIXI.Text;
  private initialized = false;

  protected setup(): void {}

  private build(w: number): void {
    if (this.initialized) return;
    this.initialized = true;

    const textColor = resolveColor(this.config.textColor ?? '$text', this.palette);
    const alertColor = resolveColor(this.config.alertColor ?? '$accent', this.palette);
    const fontFamily = this.config.fontFamily ?? '"Courier New", monospace';
    const centerMsg = this.config.centerText ?? 'SYS.MONITOR // ONLINE';
    const rightMsg = this.config.rightText ?? 'NETWATCH // PROTOCOL V.2.0.77';
    const fontSize = this.config.fontSize ?? 13;

    this.centerText = new PIXI.Text({
      text: centerMsg,
      style: { fontFamily, fontSize, fill: textColor },
    });
    this.centerText.anchor.set(0.5, 0);
    this.centerText.x = w / 2;
    this.centerText.y = 15;
    this.container.addChild(this.centerText);

    this.rightText = new PIXI.Text({
      text: rightMsg,
      style: { fontFamily, fontSize: fontSize - 2, fill: alertColor },
    });
    this.rightText.anchor.set(1, 0);
    this.rightText.x = w - 30;
    this.rightText.y = 15;
    this.container.addChild(this.rightText);
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth);
    if (this.centerText) this.centerText.x = ctx.screenWidth / 2;
    if (this.rightText) this.rightText.x = ctx.screenWidth - 30;
  }
}