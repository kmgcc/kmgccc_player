import type { ConvertedFillStyle, ConvertedStrokeStyle, FillInput, StrokeInput } from '../FillTypes';
/**
 * Converts a value to a fill style, we do this as PixiJS has a number of ways to define a fill style
 * They can be a direct color, a texture, a gradient, or an object with these values in them
 * This function will take any of these input types and convert them into a single object
 * that PixiJS can understand and use internally.
 * @param value - The value to convert to a fill style
 * @param defaultStyle - The default fill style to use
 * @private
 */
export declare function toFillStyle<T extends FillInput>(value: T, defaultStyle: ConvertedFillStyle): ConvertedFillStyle;
/**
 * Converts a value to a stroke style, similar to `toFillStyle` but for strokes
 * @param value - The value to convert to a stroke style
 * @param defaultStyle - The default stroke style to use
 * @private
 */
export declare function toStrokeStyle(value: StrokeInput, defaultStyle: ConvertedStrokeStyle): ConvertedStrokeStyle;
