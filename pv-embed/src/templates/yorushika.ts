// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const yorushikaTemplate: TemplateConfig = {
  name: '夜色',
  palette: {
    background: '#1a1a1a',
    primary: '#ffffff',
    secondary: '#aaaaaa',
    accent: '#e8e8e8',
    text: '#ffffff',
  },
  effects: [
    {
      type: 'textureBackground',
      layer: 'background',
      config: { intensity: 0.12, driftSpeed: 0.3 },
    },
    {
      type: 'concentricCircles',
      layer: 'decoration',
      config: {
        count: 4, maxRadius: 250, x: 0.5, y: 0.5,
        color: '$primary', strokeWidth: 1.5, alpha: 0.7,
        animation: 'rotate', animationSpeed: 0.1,
      },
    },
    {
      type: 'textStrip',
      layer: 'decoration',
      config: {
        rotation: -25, x: 0.5, y: 0.5,
        stripColor: '$primary', textColor: '#1a1a1a',
        stripWidth: 70, stripHeight: 500, fontSize: 55,
      },
    },
    {
      type: 'flowingLines',
      layer: 'decoration',
      config: {
        count: 2, color: '$secondary', alpha: 0.5,
        strokeWidth: 1, amplitude: 60, speed: 0.3,
      },
    },
    {
      type: 'scatteredText',
      layer: 'text',
      config: {
        count: 10, color: '$secondary',
        minSize: 16, maxSize: 40,
        chars: 'つもにはでをがのへと',
      },
    },
    {
      type: 'vignette',
      layer: 'overlay',
      config: { intensity: 0.7 },
    },
  ],
};