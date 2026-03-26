// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const holoScopeTemplate: TemplateConfig = {
  name: '全息',
  palette: {
    background: '#0a0a14',
    primary: '#6666cc',
    secondary: '#4444aa',
    accent: '#cc44aa',
    text: '#aaaaff',
  },
  bpm: 128,
  effects: [
    {
      type: 'glowRing',
      layer: 'background',
      config: {
        colorInner: '#3344dd',
        colorOuter: '#bb22aa',
        radius: 0.36,
        ringWidth: 0.14,
        alpha: 0.65,
      },
    },
    {
      type: 'targetGuide',
      layer: 'decoration',
      config: {
        color: '#7777cc',
        alpha: 0.35,
        rings: [0.1, 0.16, 0.24],
        tickCount: 12,
      },
    },
    {
      type: 'lightSpot',
      layer: 'overlay',
      config: {
        color: '#ccccff',
        alpha: 0.5,
        x: 0.5,
        y: 0.08,
        size: 0.55,
      },
    },
    {
      type: 'chromaticAberration',
      layer: 'overlay',
      config: {
        offset: 5,
        flickerSpeed: 2,
      },
    },
    {
      type: 'vignette',
      layer: 'overlay',
      config: {
        color: '#000011',
        alpha: 0.8,
        radius: 0.5,
      },
    },
  ],
};