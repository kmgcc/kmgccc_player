// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const popArtTemplate: TemplateConfig = {
  name: '波普',
  palette: {
    background: '#1a3a6e',
    primary: '#2563eb',
    secondary: '#ffffff',
    accent: '#fbbf24',
    text: '#ffffff',
  },
  features: {
    mediaOutline: true,
  },
  effects: [
    {
      type: 'parallelogramStripes',
      layer: 'background',
      config: {
        skewAngle: 20,
        alpha: 0.92,
        moveSpeed: 0.8,
        dotSpacing: 10,
        dotRadius: 3,
        cellSize: 8,
        paras: [
          { xFrac: -0.12, widthFrac: 0.22, color1: '$background', color2: '$primary',   texture: 'halftone', phase: 0 },
          { xFrac: 0.04,  widthFrac: 0.20, color1: '$primary',    color2: '$primary',   texture: 'none', phase: 0.9 },
          { xFrac: 0.16,  widthFrac: 0.18, color1: '$primary',    color2: '$secondary', texture: 'checkerboard', phase: 1.8 },
          { xFrac: 0.28,  widthFrac: 0.22, color1: '$accent',     color2: '$accent',    texture: 'halftone', phase: 2.7 },
          { xFrac: 0.42,  widthFrac: 0.18, color1: '$secondary',  color2: '$secondary', texture: 'checkerboard', phase: 3.6 },
          { xFrac: 0.52,  widthFrac: 0.20, color1: '$secondary',  color2: '$primary',   texture: 'none', phase: 4.5 },
          { xFrac: 0.64,  widthFrac: 0.22, color1: '$primary',    color2: '$accent',    texture: 'halftone', phase: 5.4 },
          { xFrac: 0.76,  widthFrac: 0.18, color1: '$accent',     color2: '$secondary', texture: 'checkerboard', phase: 0.5 },
          { xFrac: 0.88,  widthFrac: 0.22, color1: '$primary',    color2: '$background', texture: 'halftone', phase: 1.4 },
        ],
      },
    },
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 28,
        x: 0.88,
        y: 0.93,
        color: '$text',
        fontWeight: '700',
        animation: 'none',
      },
    },
    {
      type: 'vignette',
      layer: 'overlay',
      config: { intensity: 0.2 },
    },
  ],
};