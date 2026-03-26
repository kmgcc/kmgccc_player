import type { GraphicsContext } from '../../GraphicsContext';
/**
 * Determines if subpaths represent nested shapes or multiple holes pattern.
 * @param subpathsWithArea - Array of subpaths with their calculated areas
 * @returns True if nested pattern, false if multiple holes pattern
 * @internal
 */
export declare function checkForNestedPattern(subpathsWithArea: Array<{
    path: string;
    area: number;
}>): boolean;
/**
 * Gets fill instruction data from a graphics context.
 * @param context - The graphics context
 * @param index - Index of the fill instruction (default: 0)
 * @returns The fill instruction data
 * @throws Error if instruction at index is not a fill instruction
 * @internal
 */
export declare function getFillInstructionData(context: GraphicsContext, index?: number): {
    style: import("../../FillTypes").ConvertedFillStyle;
    path: import("../../path/GraphicsPath").GraphicsPath;
    hole?: import("../../path/GraphicsPath").GraphicsPath;
};
