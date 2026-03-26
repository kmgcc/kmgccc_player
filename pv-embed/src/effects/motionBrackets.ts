// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext, MotionTargetInfo } from '../core/types';
import { resolveColor } from '../core/types';

/**
 * Draws HUD-style corner brackets around motion-detected targets,
 * with optional node dots, skeleton connections between targets,
 * and directional dynamic trails.
 */
export class MotionBrackets extends BaseEffect {
  readonly name = 'motionBrackets';
  private g!: PIXI.Graphics;
  private label!: PIXI.Text;
  private hudLabels: PIXI.Text[] = [];

  protected setup(): void {
    this.g = new PIXI.Graphics();
    this.container.addChild(this.g);
    this.label = new PIXI.Text({ text: '', style: { fontSize: 11, fill: '#00ffcc', fontFamily: 'monospace' } });
    this.container.addChild(this.label);
  }

  update(ctx: UpdateContext): void {
    const g = this.g;
    g.clear();
    this.label.text = '';
    for (const hl of this.hudLabels) hl.destroy();
    this.hudLabels = [];

    const targets: MotionTargetInfo[] = ctx.motionTargets ?? [];
    if (targets.length === 0) return;

    const color = resolveColor(this.config.color ?? '#00ffcc', this.palette);
    const alpha = this.config.alpha ?? 0.8;
    const lineWidth = this.config.lineWidth ?? 2;
    const style = this.config.style ?? 'high';
    const showConnections = this.config.showConnections ?? false;
    const showTrails = this.config.showTrails ?? false;
    const showNodes = this.config.showNodes ?? false;
    const connColor = resolveColor(this.config.connColor ?? this.config.color ?? '#888888', this.palette);
    const trailColor = resolveColor(this.config.trailColor ?? this.config.color ?? '#E66432', this.palette);
    const nodeColor = resolveColor(this.config.nodeColor ?? this.config.color ?? '#E66432', this.palette);

    for (const t of targets) {
      // Node dot on target center
      if (showNodes) {
        const cx = t.x + t.w / 2;
        const cy = t.y + t.h / 2;
        g.circle(cx, cy, 3);
        g.fill({ color: nodeColor, alpha });
        const hashR = 8 + (Math.abs(t.id.charCodeAt(2) || 0) % 5);
        g.circle(cx, cy, hashR);
        g.stroke({ color, width: 1, alpha: alpha * 0.5 });
        // Small callout line
        g.moveTo(cx, cy).lineTo(cx + 20, cy - 20);
        g.stroke({ color: connColor, width: 1, alpha: alpha * 0.3 });
        g.circle(cx + 20, cy - 20, 2);
        g.fill({ color: connColor, alpha: alpha * 0.3 });
      }

      if (style === 'high') {
        this.drawHighPriority(g, t, color, alpha, lineWidth);
      } else if (style === 'medium') {
        this.drawMediumPriority(g, t, color, alpha, lineWidth);
      } else {
        this.drawLowPriority(g, t, color, alpha);
      }
    }

    // Skeleton connections between nearby targets
    if (showConnections && targets.length > 1) {
      const maxDist = this.config.connMaxDist ?? 350;
      for (let i = 0; i < targets.length; i++) {
        for (let j = i + 1; j < targets.length; j++) {
          const a = targets[i];
          const b = targets[j];
          const ax = a.x + a.w / 2;
          const ay = a.y + a.h / 2;
          const bx = b.x + b.w / 2;
          const by = b.y + b.h / 2;
          const d = Math.sqrt((ax - bx) ** 2 + (ay - by) ** 2);
          if (d < maxDist) {
            const connAlpha = alpha * 0.4 * (1 - d / maxDist);
            g.moveTo(ax, ay).lineTo(bx, by);
            g.stroke({ color: connColor, width: 1, alpha: connAlpha });
            // Cross marker at midpoint
            const mx = (ax + bx) / 2;
            const my = (ay + by) / 2;
            g.moveTo(mx - 3, my - 3).lineTo(mx + 3, my + 3);
            g.moveTo(mx + 3, my - 3).lineTo(mx - 3, my + 3);
            g.stroke({ color, width: 1, alpha: connAlpha * 0.6 });
          }
        }
      }
    }

    // Dynamic trails from each target
    if (showTrails) {
      for (const t of targets) {
        const cx = t.x + t.w / 2;
        const cy = t.y + t.h / 2;
        const angle = ((cx * cy) % 360) * (Math.PI / 180);
        const len = 50;
        const ex = cx + Math.cos(angle) * len;
        const ey = cy + Math.sin(angle) * len;
        g.moveTo(cx, cy).lineTo(ex, ey);
        g.stroke({ color: trailColor, width: 1, alpha: alpha * 0.5 });
        g.circle(ex, ey, 3);
        g.stroke({ color: trailColor, width: 1, alpha: alpha * 0.5 });
      }
    }

    if (targets.length > 0) {
      this.label.text = `TARGETS: ${targets.length}`;
      this.label.x = 30;
      this.label.y = ctx.screenHeight - 30;
      (this.label.style as PIXI.TextStyle).fill = color;
    }
  }

  private drawHighPriority(g: PIXI.Graphics, t: MotionTargetInfo, color: string, alpha: number, lw: number): void {
    const l = Math.min(t.w, t.h) / 3;
    const off = 5;

    // Extended corner brackets with offset
    const corners = [
      { x: t.x - off, y: t.y, dx: l, dy: 0, x2: t.x, y2: t.y - off, dx2: 0, dy2: l },
      { x: t.x + t.w + off, y: t.y, dx: -l, dy: 0, x2: t.x + t.w, y2: t.y - off, dx2: 0, dy2: l },
      { x: t.x - off, y: t.y + t.h, dx: l, dy: 0, x2: t.x, y2: t.y + t.h + off, dx2: 0, dy2: -l },
      { x: t.x + t.w + off, y: t.y + t.h, dx: -l, dy: 0, x2: t.x + t.w, y2: t.y + t.h + off, dx2: 0, dy2: -l },
    ];

    for (const c of corners) {
      g.moveTo(c.x, c.y).lineTo(c.x + c.dx, c.y + c.dy);
      g.moveTo(c.x2, c.y2).lineTo(c.x2 + c.dx2, c.y2 + c.dy2);
    }
    g.stroke({ color, width: lw, alpha });

    // "NO MATCH" header bar above target
    const headerW = 100;
    const headerH = 20;
    g.rect(t.x, t.y - headerH - 5, headerW, headerH);
    g.fill({ color, alpha: alpha * 0.9 });

    const noMatchLabel = new PIXI.Text({
      text: 'NO MATCH',
      style: { fontFamily: 'monospace', fontSize: 11, fill: '#000000', fontWeight: 'bold' },
    });
    noMatchLabel.x = t.x + 5;
    noMatchLabel.y = t.y - headerH - 2;
    this.hudLabels.push(noMatchLabel);
    this.container.addChild(noMatchLabel);

    // X crosshair at 1/4 height
    const cx = t.x + t.w / 2;
    const cy = t.y + t.h / 4;
    const xr = 10;
    g.moveTo(cx - xr, cy - xr).lineTo(cx + xr, cy + xr);
    g.moveTo(cx + xr, cy - xr).lineTo(cx - xr, cy + xr);
    g.stroke({ color, width: 1, alpha: alpha * 0.7 });

    // Warning triangle with "!" on left side
    const triH = 15;
    const triX = t.x - 20;
    const triY = t.y + t.h / 2;
    g.poly([triX, triY, triX + 15, triY - triH / 2, triX + 15, triY + triH / 2]);
    g.stroke({ color, width: 1, alpha: alpha * 0.7 });

    const warnLabel = new PIXI.Text({
      text: '!',
      style: { fontFamily: 'monospace', fontSize: 10, fill: color },
    });
    warnLabel.x = t.x - 14;
    warnLabel.y = t.y + t.h / 2 - 6;
    this.hudLabels.push(warnLabel);
    this.container.addChild(warnLabel);

    // Callout line to the right with "MATCH: XX%"
    const callX = t.x + t.w + 5;
    const callY = t.y + t.h / 3;
    const callEndX = t.x + t.w + 40;
    g.moveTo(callX, callY).lineTo(callEndX, callY);
    g.stroke({ color, width: 1, alpha: alpha * 0.6 });

    const matchPct = 10 + Math.abs((t.id.charCodeAt(2) || 0) * 7) % 30;
    const matchLabel = new PIXI.Text({
      text: `MATCH: ${matchPct}%`,
      style: { fontFamily: 'monospace', fontSize: 10, fill: color },
    });
    matchLabel.x = callEndX + 5;
    matchLabel.y = callY - 7;
    this.hudLabels.push(matchLabel);
    this.container.addChild(matchLabel);
  }

  private drawMediumPriority(g: PIXI.Graphics, t: MotionTargetInfo, color: string, alpha: number, lw: number): void {
    const l = Math.min(t.w, t.h) / 4;
    const corners = [
      [t.x, t.y, l, 0, 0, l],
      [t.x + t.w, t.y, -l, 0, 0, l],
      [t.x, t.y + t.h, l, 0, 0, -l],
      [t.x + t.w, t.y + t.h, -l, 0, 0, -l],
    ];
    for (const [x, y, dx1, dy1, dx2, dy2] of corners) {
      g.moveTo(x, y).lineTo(x + dx1, y + dy1);
      g.moveTo(x, y).lineTo(x + dx2, y + dy2);
    }
    g.stroke({ color, width: lw, alpha });
  }

  private drawLowPriority(g: PIXI.Graphics, t: MotionTargetInfo, color: string, alpha: number): void {
    const cx = t.x + t.w / 2;
    const cy = t.y;
    const s = 10;
    g.poly([cx - s, cy - s * 2, cx + s, cy - s * 2, cx, cy - 5]);
    g.stroke({ color, width: 1, alpha: alpha * 0.6 });
    g.moveTo(cx, cy - 5).lineTo(cx, cy + 5);
    g.stroke({ color, width: 1, alpha: alpha * 0.6 });
  }
}