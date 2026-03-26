// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const digitalImpressionTemplate: TemplateConfig = {
  name: '数字印象',
  palette: {
    background: '#0a0e1a',
    primary: '#00ccff',
    secondary: '#6633aa',
    accent: '#44ddaa',
    text: '#e0f0ff',
  },
  effects: [
    // Dark-to-deep-blue gradient base
    { type: 'gradientOverlay', layer: 'background', config: {
      colorTop: '#0c1028', colorBottom: '#0a1a2e', alpha: 0.9,
    }},

    // Large paint smear / scrape strokes — the core visual identity
    { type: 'smearBrush', layer: 'decoration', config: {
      count: 12,
      colors: ['#00ccff', '#0088dd', '#6633aa', '#44ddaa', '#2244aa', '#cc44ff'],
      grainAlpha: 0.05,
    }},

    // Flowing cable/wire lines across the sky
    { type: 'flowingLines', layer: 'decoration', config: {
      color: '#1a1a2a', count: 15, alpha: 0.5,
    }},

    // Overexposed glow — bright area bleeding through
    { type: 'lightSpot', layer: 'overlay', config: {
      color: '#88eeff', x: 0.45, y: 0.35, alpha: 0.25, radius: 0.4,
    }},

    // Second glow for the street reflection area
    { type: 'lightSpot', layer: 'overlay', config: {
      color: '#00aaff', x: 0.4, y: 0.75, alpha: 0.2, radius: 0.5,
    }},

    // Glitch bars — pixel block displacement on the right side
    { type: 'glitchBars', layer: 'overlay', config: {
      color: '#00ffcc', alpha: 0.5,
    }},

    // Chromatic aberration — RGB channel separation
    { type: 'chromaticAberration', layer: 'overlay', config: {
      offset: 4,
    }},

    // Film grain for painterly texture
    { type: 'filmGrain', layer: 'overlay', config: {
      alpha: 0.06, mono: false, updateInterval: 4,
    }},

    // Scattered shapes — abstract geometric city silhouettes
    { type: 'scatteredShapes', layer: 'decoration', config: {
      color: '#1a1a3a', alpha: 0.12,
    }},

    // Hero text with glow feel
    { type: 'heroText', layer: 'text', config: {
      color: '#e0f0ff', fontSize: 64,
    }},

    // Deep vignette
    { type: 'vignette', layer: 'overlay', config: {
      color: '#050510', alpha: 0.65,
    }},
  ],
};
