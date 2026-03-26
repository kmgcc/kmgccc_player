import type { GraphicsPath } from '../path/GraphicsPath';
/**
 * Computes the maximum miter ratio from polygon corner angles in a graphics path.
 * The miter ratio determines how much the stroke padding must expand to contain miter joins
 * at sharp angles. Returns a value >= 1, clamped by the miterLimit.
 * @param path - The graphics path containing polygon shapes
 * @param miterLimit - The maximum allowed miter ratio
 * @returns The maximum miter ratio found in all polygon corners, clamped by miterLimit
 * @internal
 */
export declare function getMaxMiterRatio(path: GraphicsPath, miterLimit: number): number;
