// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext, MotionTargetInfo } from '../core/types';
import { resolveColor } from '../core/types';

const RANDOM_NAMES = ['Unknown', 'Subject 89', 'Ghost', 'Rogue AI', 'Corpo Agent'];
const RANDOM_LOCATIONS = ['Sector 4', 'Night City', 'Arasaka Tower', 'Badlands', 'Grid 09'];
const RANDOM_THREATS = ['LOW', 'MODERATE', 'CRITICAL', 'EXTREME'];
const RANDOM_NOTES = ['Surveillance active', 'Scanning...', 'Data corrupted', 'Tracing signal'];

function stableRandom(seed: string, index: number): number {
  let h = 0;
  for (let i = 0; i < seed.length; i++) {
    h = ((h << 5) - h + seed.charCodeAt(i)) | 0;
  }
  return Math.abs((h * (index + 1) * 2654435761) | 0);
}

function pickStable<T>(arr: T[], seed: string, idx: number): T {
  return arr[stableRandom(seed, idx) % arr.length];
}

/**
 * Right-side detail card panel showing info for the primary motion target.
 * Faithful to CyberpunkTheme._draw_detail_card.
 */
export class HudInfoPanel extends BaseEffect {
  readonly name = 'hudInfoPanel';
  private g!: PIXI.Graphics;
  private texts: PIXI.Text[] = [];
  private lastTargetId = '';

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
  }

  update(ctx: UpdateContext): void {
    const g = this.g;
    g.clear();

    const targets: MotionTargetInfo[] = ctx.motionTargets ?? [];
    if (targets.length === 0) {
      this.clearTexts();
      return;
    }

    const primary = targets[0];
    const panelW = this.config.panelWidth ?? 240;
    const panelH = this.config.panelHeight ?? 420;
    const panelX = ctx.screenWidth - panelW - 30;
    const panelY = 70;

    const primaryColor = resolveColor(this.config.primaryColor ?? '$primary', this.palette);
    const alertColor = resolveColor(this.config.alertColor ?? '$accent', this.palette);
    const textColor = resolveColor(this.config.textColor ?? '$text', this.palette);
    const gridColor = resolveColor(this.config.gridColor ?? '#323200', this.palette);
    const fontFamily = this.config.fontFamily ?? '"Courier New", monospace';

    // Determine threat-based color
    const threat = pickStable(RANDOM_THREATS, primary.id, 3);
    const isHighThreat = threat === 'CRITICAL' || threat === 'EXTREME';
    const accentColor = isHighThreat ? alertColor : primaryColor;

    // Semi-transparent dark background
    g.rect(panelX, panelY, panelW, panelH);
    g.fill({ color: '#000000', alpha: 0.4 });

    // Accent bar at top (5px)
    g.rect(panelX, panelY, panelW, 5);
    g.fill({ color: accentColor, alpha: 0.9 });

    // Border
    g.rect(panelX, panelY, panelW, panelH);
    g.stroke({ color: accentColor, width: 1, alpha: 0.7 });

    // Avatar placeholder
    const avX = panelX + 10;
    const avY = panelY + 40;
    const avW = panelW - 20;
    const avH = 140;
    g.rect(avX, avY, avW, avH);
    g.stroke({ color: accentColor, width: 1, alpha: 0.5 });

    // X cross inside avatar
    g.moveTo(avX, avY).lineTo(avX + avW, avY + avH);
    g.moveTo(avX, avY + avH).lineTo(avX + avW, avY);
    g.stroke({ color: gridColor, width: 1, alpha: 0.4 });

    // Rebuild texts only when target changes
    if (primary.id !== this.lastTargetId) {
      this.clearTexts();
      this.lastTargetId = primary.id;

      const name = pickStable(RANDOM_NAMES, primary.id, 0);
      const location = pickStable(RANDOM_LOCATIONS, primary.id, 1);
      const notes = pickStable(RANDOM_NOTES, primary.id, 2);
      const gender = stableRandom(primary.id, 4) % 2 === 0 ? 'MALE' : 'FEMALE';
      const height = `1${70 + stableRandom(primary.id, 5) % 20}cm`;

      const lines: Array<{ text: string; x: number; y: number; size: number; color: string; bold?: boolean }> = [
        { text: `TARGET ${primary.id}`, x: panelX + 10, y: panelY + 18, size: 14, color: accentColor, bold: true },
        { text: 'IMG_REC_FAIL', x: avX + avW / 2 - 40, y: avY + avH / 2 - 5, size: 11, color: accentColor },
        { text: 'NAME', x: panelX + 15, y: avY + avH + 15, size: 9, color: textColor },
        { text: name, x: panelX + 15, y: avY + avH + 28, size: 12, color: accentColor },
        { text: 'GENDER', x: panelX + 15, y: avY + avH + 50, size: 9, color: textColor },
        { text: gender, x: panelX + 15, y: avY + avH + 63, size: 12, color: accentColor },
        { text: 'HEIGHT', x: panelX + panelW / 2 + 5, y: avY + avH + 50, size: 9, color: textColor },
        { text: height, x: panelX + panelW / 2 + 5, y: avY + avH + 63, size: 12, color: accentColor },
        { text: 'THREAT', x: panelX + 15, y: avY + avH + 85, size: 9, color: textColor },
        { text: threat, x: panelX + 15, y: avY + avH + 98, size: 12, color: alertColor, bold: true },
        { text: 'LOCATION', x: panelX + 15, y: avY + avH + 120, size: 9, color: textColor },
        { text: location, x: panelX + 15, y: avY + avH + 133, size: 12, color: accentColor },
        { text: 'NOTES', x: panelX + 15, y: avY + avH + 155, size: 9, color: textColor },
        { text: notes, x: panelX + 15, y: avY + avH + 168, size: 12, color: textColor },
        { text: 'ARASAKA INTEL // CLASSIFIED', x: panelX + 10, y: panelY + panelH - 18, size: 9, color: accentColor },
      ];

      for (const l of lines) {
        const t = new PIXI.Text({
          text: l.text,
          style: {
            fontFamily,
            fontSize: l.size,
            fill: l.color,
            fontWeight: l.bold ? 'bold' : 'normal',
          },
        });
        t.x = l.x;
        t.y = l.y;
        this.texts.push(t);
        this.container.addChild(t);
      }
    }
  }

  private clearTexts(): void {
    for (const t of this.texts) {
      t.destroy();
    }
    this.texts = [];
    this.lastTargetId = '';
  }
}