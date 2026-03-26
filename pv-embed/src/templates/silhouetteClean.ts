// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

/**
 * Inspired by reference SilhouetteTheme:
 * High-contrast white background with media outline (silhouette),
 * minimal HUD elements, motion detection brackets.
 */
export const silhouetteCleanTemplate: TemplateConfig = {
  name: '剪影极简',
  palette: {
    background: '#ffffff',
    primary: '#000000',
    secondary: '#888888',
    accent: '#333333',
    text: '#000000',
  },
  features: {
    mediaOutline: true,
  },
  effects: [
    {
      type: 'screenBorder',
      layer: 'decoration',
      config: { color: '$primary', lineWidth: 2, alpha: 0.5, margin: 30, gap: 4 },
    },
    {
      type: 'motionBrackets',
      layer: 'overlay',
      config: { color: '$primary', alpha: 0.6, lineWidth: 2, style: 'medium' },
    },
    {
      type: 'dashedGuideLines',
      layer: 'decoration',
      config: { color: '$secondary', alpha: 0.1 },
    },
    {
      type: 'heroText',
      layer: 'text',
      config: {
        fontSize: 48, x: 0.5, y: 0.88,
        color: '$text', fontWeight: 'bold',
        animation: 'breathe', animationSpeed: 0.3, animationAmount: 0.01,
      },
    },
    {
      type: 'scatteredText',
      layer: 'text',
      config: {
        count: 4, color: '$secondary',
        minSize: 9, maxSize: 12,
        chars: 'OPTICAL CAMOUFLAGE ACTIVE SYSTEM',
      },
    },
  ],
};