// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const cyberTemplate: TemplateConfig = {
  name: '电脑',
  palette: {
    background: '#e8edf2',
    primary: '#2255aa',
    secondary: '#334466',
    accent: '#4488cc',
    text: '#1a1a1a',
  },
  effects: [
    {
      type: 'halftoneBlocks',
      layer: 'decoration',
      config: {
        count: 10, color: '$primary',
        blockSize: 50, dotSpacing: 5, dotRadius: 1.5, alpha: 0.65,
      },
    },
    {
      type: 'diamondShapes',
      layer: 'decoration',
      config: {
        count: 3, maxSize: 200, x: 0.5, y: 0.5,
        color: '$secondary', strokeWidth: 2, alpha: 0.7,
        animationSpeed: 0.05,
      },
    },
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 100, x: 0.5, y: 0.45,
        color: '$text',
        animation: 'breathe', animationSpeed: 0.3, animationAmount: 0.02,
        letterSpacing: 20,
      },
    },
    {
      type: 'scatteredShapes',
      layer: 'decoration',
      config: {
        count: 15, color: '$primary',
        shapes: ['square'], minSize: 8, maxSize: 30, alpha: 0.6,
      },
    },
  ],
};