import type { StrokeAttributes } from '../FillTypes';
/**
 * Builds a line to draw using the polygon method.
 * @param points
 * @param lineStyle
 * @param flipAlignment
 * @param closed
 * @param vertices
 * @param indices
 * @internal
 */
export declare function buildLine(points: number[], lineStyle: StrokeAttributes, flipAlignment: boolean, closed: boolean, vertices: number[], indices: number[]): void;
