// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface FormulaElement {
  textObj: PIXI.Text;
  baseX: number;
  baseY: number;
  baseAlpha: number;
  phase: number;
}

const DEFAULT_FORMULAS = [
  'iℏ ∂/∂t Ψ = [-ℏ²/2m ∇² + V] Ψ',
  'ρ(∂v/∂t + v·∇v) = -∇p + μ∇²v + f',
  '∇·E = ρ/ε₀',
  '∇·B = 0',
  '∇×E = -∂B/∂t',
  '∇×B = μ₀(J + ε₀ ∂E/∂t)',
  'G_μν + Λg_μν = (8πG/c⁴) T_μν',
  'F(k) = ∫f(x) e^(-2πikx) dx',
  'E² = (pc)² + (mc²)²',
  'Δx·Δp ≥ ℏ/2',
  '∂²u/∂t² = c²∇²u',
  'S = k_B ln Ω',
  'dS/dt ≥ 0',
  'H = Σ pq̇ - L',
  '∮ E·dl = -dΦ_B/dt',
];

export class FormulaText extends BaseEffect {
  readonly name = 'formulaText';
  private elements: FormulaElement[] = [];
  private markers: PIXI.Graphics | null = null;
  private initialized = false;

  protected setup(): void {}

  private build(w: number, h: number): void {
    if (this.initialized) return;
    this.initialized = true;

    const color = resolveColor(this.config.color ?? '$text', this.palette);
    const fontFamily = this.config.fontFamily ?? '"SF Mono", "Fira Code", "Consolas", monospace';
    const count = this.config.count ?? 18;
    const formulas: string[] = this.config.formulas ?? DEFAULT_FORMULAS;
    const singleChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ΣΔΩΨΦπλαβγ';
    const formulaRatio = this.config.formulaRatio ?? 0.65;

    this.markers = new PIXI.Graphics();
    this.container.addChild(this.markers);

    for (let i = 0; i < count; i++) {
      const isFormula = Math.random() < formulaRatio;
      const text = isFormula
        ? formulas[Math.floor(Math.random() * formulas.length)]
        : singleChars[Math.floor(Math.random() * singleChars.length)];

      const fontSize = isFormula
        ? 11 + Math.random() * 5
        : 24 + Math.random() * 36;

      const style = new PIXI.TextStyle({
        fontFamily,
        fontSize,
        fill: color,
        fontWeight: isFormula ? 'normal' : (Math.random() > 0.5 ? 'bold' : 'normal'),
      });

      const textObj = new PIXI.Text({ text, style });
      const baseX = -80 + Math.random() * (w + 100);
      const baseY = 20 + Math.random() * (h - 40);
      textObj.x = baseX;
      textObj.y = baseY;

      const baseAlpha = 0.4 + Math.random() * 0.5;
      textObj.alpha = baseAlpha;

      this.elements.push({
        textObj,
        baseX,
        baseY,
        baseAlpha,
        phase: Math.random() * Math.PI * 2,
      });

      this.container.addChild(textObj);
    }
  }

  update(ctx: UpdateContext): void {
    this.build(ctx.screenWidth, ctx.screenHeight);

    const color = resolveColor(this.config.color ?? '$text', this.palette);

    if (this.markers) {
      this.markers.clear();

      for (const el of this.elements) {
        el.textObj.style.fill = color;
        const spd = ctx.animationSpeed;
        el.textObj.alpha = el.baseAlpha + Math.sin(ctx.time * 0.2 * spd + el.phase) * 0.06;

        if (Math.random() > 0.92) {
          const mx = el.baseX - 10;
          const my = el.baseY - 10;
          const s = 4;
          this.markers.moveTo(mx - s, my - s).lineTo(mx + s, my + s);
          this.markers.moveTo(mx + s, my - s).lineTo(mx - s, my + s);
          this.markers.stroke({ color, width: 0.8, alpha: 0.3 });
        }
      }
    }
  }
}