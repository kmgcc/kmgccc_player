// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const flyMeToTheMoonTemplate: TemplateConfig = {
  name: 'Fly Me to the Moon',
  nameKey: 'tpl_flyMeToTheMoon',
  palette: {
    background: '#1122ee',
    primary: '#c0c0d0',
    secondary: '#888899',
    accent: '#6a6a8a',
    text: '#e0e0e0',
  },
  animationSpeed: 3.7,
  effects: [
    {
      type: 'textureBackground',
      layer: 'background',
      config: {},
    },
    {
      type: 'gradientOverlay',
      layer: 'background',
      config: {
        colorTop: '#0a0a18',
        colorBottom: '#000008',
        alpha: 0.55,
        mode: 'radial',
      },
    },
    {
      type: 'scatteredShapes',
      layer: 'decoration',
      config: {
        color: '$primary',
      },
    },
    {
      type: 'planet',
      layer: 'decoration',
      config: {
        color: '#ffffff',
        radius: 120,
        coreRadius: 12,
      },
    },
    {
      type: 'verticalSubText',
      layer: 'text',
      config: {
        color: '#ffffff',
        fontSize: 13,
      },
    },
    {
      type: 'vignette',
      layer: 'overlay',
      config: {
        color: '#000010',
        alpha: 0.35,
        radius: 0.7,
      },
    },
    {
      type: 'dotScreen',
      layer: 'overlay',
      config: {},
    },
  ],
  postfx: {
    shake: 0,
    zoom: 0.65,
    tilt: -0.52,
    glitch: 0,
    hueShift: -10,
  },
};
