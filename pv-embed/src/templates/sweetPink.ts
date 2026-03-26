// PV Tool — Copyright (c) 2026 DanteAlighieri13210914
// Licensed under Non-Commercial License. See LICENSE for terms.

import type { TemplateConfig } from '../core/types';

export const sweetPinkTemplate: TemplateConfig = {
  name: '格子花边',
  nameKey: 'tpl_sweetPink',
  palette: {
    background: '#fef5f8',
    primary: '#fab2b5',
    secondary: '#f8c7ca',
    accent: '#ecbfc0',
    text: '#fab2b5',
  },
  bpm: 120,
  animationSpeed: 1.0,
  effects: [
    {
      type: 'pinkGrid',
      layer: 'background',
      config: {
        color: '#f8c7ca',
        cellSize: 50,
        lineColor: '#ffffff',
        lineWidth: 2,
        speed: 30,
        alpha: 1.0,
      },
    },
    {
      type: 'pulsingCircle',
      layer: 'background',
      config: {
        strokeColor: '#ffffff',
        strokeAlpha: 0.8,
        strokeWidth: 8,
        outerStrokeColor: '#ecbfc0',
        outerStrokeWidth: 3,
        outerStrokeAlpha: 0.6,
        radius: 250,
        x: 0.5,
        y: 0.5,
        animSpeed: 0.2,
        strokePulseAmount: 0.5,
        radiusPulseAmount: 0.08,
        enableBeatReact: false,
      },
    },
    {
      type: 'scalloppedBorder',
      layer: 'decoration',
      config: {
        color: '#ffffff',
        shadowColor: '#ecbfc0',
        shadowAlpha: 0.6,
        shadowOffsetX: 0,
        shadowOffsetY: 8,
        circleRadius: 80,
        animSpeed: 0.2,
        moveAmount: 15,
        alpha: 1.0,
      },
    },
    {
      type: 'cuteOutlineText',
      layer: 'text',
      config: {
        fillColor: '#fab2b5',
        strokeColor: '#ffffff',
        fontSize: 80,
        strokeWidth: 8,
        fontWeight: '900',
        letterSpacing: 4,
        x: 0.5,
        y: 0.5,
      },
    },
  ],
};
