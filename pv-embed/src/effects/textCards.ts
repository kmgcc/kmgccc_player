// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import * as PIXI from 'pixi.js';
import { BaseEffect } from './base';
import type { UpdateContext } from '../core/types';
import { resolveColor } from '../core/types';

interface Card {
  container: PIXI.Container;
  targetX: number;
  targetY: number;
  targetRotation: number;
  targetScale: number;
  born: number;
  lifetime: number;
}

export class TextCards extends BaseEffect {
  readonly name = 'textCards';
  private cards: Card[] = [];
  private lastSpawn = 0;
  private displayedText = '';
  private charIndex = 0;

  protected setup(): void {}

  update(ctx: UpdateContext): void {
    const text = ctx.currentText ?? this.config.text ?? '';
    const cardColor = resolveColor(this.config.cardColor ?? '$primary', this.palette);
    const textColor = resolveColor(this.config.textColor ?? '$background', this.palette);
    const fontSize = this.config.fontSize ?? 80;
    const cardPadding = this.config.padding ?? 30;
    const spawnInterval = this.config.spawnInterval ?? 0.4;
    const lifetime = this.config.lifetime ?? 2.5;
    const speed = ctx.animationSpeed;

    if (text !== this.displayedText) {
      this.displayedText = text;
      this.charIndex = 0;
    }

    // Spawn one card per interval, cycling through characters
    if (ctx.time - this.lastSpawn > spawnInterval / Math.max(speed, 0.3) && this.displayedText.length > 0) {
      this.lastSpawn = ctx.time;

      const char = this.displayedText[this.charIndex % this.displayedText.length];
      this.charIndex++;

      const cardContainer = new PIXI.Container();

      // Background rect
      const bg = new PIXI.Graphics();
      const size = fontSize + cardPadding * 2;
      bg.rect(-size / 2, -size / 2, size, size);
      bg.fill({ color: cardColor });
      cardContainer.addChild(bg);

      // Border with slight offset for chromatic feel
      const border = new PIXI.Graphics();
      border.rect(-size / 2 - 2, -size / 2 - 2, size + 4, size + 4);
      border.stroke({ color: resolveColor(this.config.borderColor ?? '$accent', this.palette), width: 2 });
      cardContainer.addChild(border);

      // Text
      const style = new PIXI.TextStyle({
        fontFamily: this.config.fontFamily ?? '"Noto Serif JP", "Yu Mincho", serif',
        fontSize,
        fontWeight: '900',
        fill: textColor,
      });
      const t = new PIXI.Text({ text: char, style });
      t.anchor.set(0.5);
      cardContainer.addChild(t);

      // Random position and rotation
      const positions = [
        { x: 0.2 + Math.random() * 0.6, y: 0.2 + Math.random() * 0.6 },
        { x: 0.1 + Math.random() * 0.3, y: 0.3 + Math.random() * 0.4 },
        { x: 0.5 + Math.random() * 0.4, y: 0.2 + Math.random() * 0.6 },
      ];
      const pos = positions[Math.floor(Math.random() * positions.length)];
      const targetX = pos.x * ctx.screenWidth;
      const targetY = pos.y * ctx.screenHeight;
      const targetRotation = (Math.random() - 0.5) * 0.3;
      const targetScale = 0.7 + Math.random() * 0.6;

      // Start off-screen or at zero scale
      cardContainer.x = targetX + (Math.random() - 0.5) * 400;
      cardContainer.y = targetY;
      cardContainer.rotation = targetRotation + (Math.random() - 0.5) * 0.5;
      cardContainer.scale.set(0);

      this.container.addChild(cardContainer);
      this.cards.push({
        container: cardContainer,
        targetX,
        targetY,
        targetRotation,
        targetScale,
        born: ctx.time,
        lifetime,
      });
    }

    // Animate cards
    const motionMul = ctx.motionIntensity;
    this.cards = this.cards.filter(card => {
      const age = ctx.time - card.born;
      const progress = age / card.lifetime;

      if (progress > 1) {
        this.container.removeChild(card.container);
        card.container.destroy({ children: true });
        return false;
      }

      // Snap in quickly, hold, then fade out
      const easeIn = Math.min(age * 8 * speed, 1);
      const fadeOut = progress > 0.7 ? 1 - ((progress - 0.7) / 0.3) : 1;

      card.container.x += (card.targetX - card.container.x) * 0.15 * motionMul;
      card.container.y += (card.targetY - card.container.y) * 0.15 * motionMul;
      card.container.rotation += (card.targetRotation - card.container.rotation) * 0.12;
      const s = card.targetScale * easeIn;
      card.container.scale.set(s);
      card.container.alpha = fadeOut;

      return true;
    });
  }

  destroy(): void {
    this.cards.forEach(c => c.container.destroy({ children: true }));
    this.cards = [];
    super.destroy();
  }
}