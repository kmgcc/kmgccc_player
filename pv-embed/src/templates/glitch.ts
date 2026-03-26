// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

/**
 * Matches reference PV section B (frames 8-12):
 * Black background, white text cards flying in,
 * chromatic aberration, glitch bars, bold katakana
 */
export const glitchTemplate: TemplateConfig = {
  name: '故障風 B',
  palette: {
    background: '#0a0a0a',
    primary: '#ffffff',
    secondary: '#ff00ff',
    accent: '#00ffff',
    text: '#0a0a0a',
  },
  effects: [
    {
      type: 'textCards',
      layer: 'decoration',
      config: {
        cardColor: '$primary', textColor: '$text',
        borderColor: '$accent',
        fontSize: 80, padding: 25,
        spawnInterval: 0.5, lifetime: 2.5,
        fontFamily: '"Noto Sans JP", "Yu Gothic", sans-serif',
      },
    },
    {
      type: 'glitchBars',
      layer: 'decoration',
      config: {
        color: '$primary', alpha: 0.85,
        spawnRate: 0.12, maxBars: 10,
        minHeight: 2, maxHeight: 10,
      },
    },
    {
      type: 'glitchBars',
      layer: 'decoration',
      config: {
        color: '$secondary', alpha: 0.4,
        spawnRate: 0.3, maxBars: 4,
        minHeight: 1, maxHeight: 4,
      },
    },
    {
      type: 'chromaticAberration',
      layer: 'overlay',
      config: { offset: 4, flickerSpeed: 3 },
    },
    {
      type: 'scatteredShapes',
      layer: 'decoration',
      config: {
        count: 8, color: '$primary',
        shapes: ['square'], minSize: 3, maxSize: 10, alpha: 0.3,
      },
    },
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 50, x: 0.5, y: 0.88,
        color: '$primary', fontWeight: 'bold',
        animation: 'breathe', animationSpeed: 0.8, animationAmount: 0.02,
        fontFamily: '"Noto Sans JP", sans-serif',
      },
    },
  ],
};