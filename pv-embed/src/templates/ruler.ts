// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

/**
 * Based on reference frame_0085.jpg:
 * Monochrome/grayscale composition with L-shaped ruler graphic,
 * multiple overlapping blocks in white-to-gray shades with
 * breathing animation. Only lyrics shown, no decorative text.
 */
export const rulerTemplate: TemplateConfig = {
  name: '戒尺',
  palette: {
    background: '#e8e8e8',
    primary: '#ffffff',
    secondary: '#aaaaaa',
    accent: '#888888',
    text: '#1a1a1a',
  },
  effects: [
    // Multiple irregular blocks (white → light gray, breathing animation)
    {
      type: 'breathingBlocks',
      layer: 'background',
      config: {
        count: 8,
        minSize: 0.15, maxSize: 0.55,
        minBrightness: 180, maxBrightness: 255,
      },
    },
    // L-shaped ruler with tick marks and circle marker
    {
      type: 'rulerGuide',
      layer: 'decoration',
      config: {
        color: '#ffffff', alpha: 0.5,
        x: 0.12, y: 0.75,
        hLength: 0.85, vLength: 0.65,
        tickSpacing: 12, majorEvery: 5,
        minorTickLen: 6, majorTickLen: 14,
        circleRadius: 8, lineWidth: 1,
      },
    },
    // Lyrics centered
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 50, x: 0.5, y: 0.5,
        color: '$text', fontWeight: 'bold',
        fontFamily: '"Noto Serif JP", "Yu Mincho", serif',
        animation: 'breathe', animationSpeed: 0.2, animationAmount: 0.01,
      },
    },
    // Subtle vignette
    {
      type: 'vignette',
      layer: 'overlay',
      config: { color: '#888888', alpha: 0.25 },
    },
  ],
};