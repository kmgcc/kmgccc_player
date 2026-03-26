import { GraphicsPath } from '../../path/GraphicsPath';
/**
 * Extracts individual subpaths from SVG path data by splitting on Move commands.
 * @param pathData - The SVG path data string
 * @returns Array of subpath strings
 * @internal
 */
export declare function extractSubpaths(pathData: string): string[];
/**
 * Calculates the area of a path using bounding box estimation.
 * @param pathData - The SVG path data string
 * @returns The estimated area of the path
 * @internal
 */
export declare function calculatePathArea(pathData: string): number;
/**
 * Parses SVG path data and appends instructions to a GraphicsPath.
 * @param pathData - The SVG path data string
 * @param graphicsPath - The GraphicsPath to append instructions to
 * @internal
 */
export declare function appendSVGPath(pathData: string, graphicsPath: GraphicsPath): void;
