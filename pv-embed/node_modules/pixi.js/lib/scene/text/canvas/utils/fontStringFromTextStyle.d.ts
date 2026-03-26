import type { TextStyle } from '../../TextStyle';
/**
 * Generates a font style string to use for `TextMetrics.measureFont()`.
 * @param style
 * @returns Font style string, for passing to `TextMetrics.measureFont()`
 * @internal
 */
export declare function fontStringFromTextStyle(style: TextStyle): string;
