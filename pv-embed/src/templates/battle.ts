// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const battleTemplate: TemplateConfig = {
  name: '战场',
  palette: {
    background: '#1a1a1e',
    primary: '#e0e0e0',
    secondary: '#888888',
    accent: '#5577aa',
    text: '#ffffff',
  },
  effects: [
    {
      type: 'textureBackground',
      layer: 'background',
      config: { intensity: 0.15, driftSpeed: 0.2 },
    },
    {
      type: 'diamondShapes',
      layer: 'decoration',
      config: {
        count: 3, maxSize: 180, x: 0.3, y: 0.35,
        color: '$primary', strokeWidth: 2, alpha: 0.6,
        animationSpeed: 0.06,
      },
    },
    {
      type: 'scatteredShapes',
      layer: 'decoration',
      config: {
        count: 10, color: '$primary',
        shapes: ['square', 'diamond'], minSize: 10, maxSize: 35, alpha: 0.7,
      },
    },
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 80, x: 0.6, y: 0.6,
        color: '$text',
        animation: 'breathe', animationSpeed: 0.5, animationAmount: 0.025,
        fontWeight: '900',
      },
    },
    {
      type: 'flowingLines',
      layer: 'decoration',
      config: {
        count: 1, color: '$accent', alpha: 0.6,
        strokeWidth: 2, amplitude: 40, frequency: 0.008, speed: 0.4,
      },
    },
    {
      type: 'vignette',
      layer: 'overlay',
      config: { intensity: 0.8 },
    },
  ],
};