import type { HTMLTextStyle } from '../HTMLTextStyle';
/**
 * Extracts font families from text. It will extract font families from the style, tagStyles and any font families
 * embedded in the text. It should also strip out duplicates as it goes.
 * @param  text - The text to extract font families from
 * @param style - The style to extract font families from
 * @returns {string[]} - The font families as an array of strings
 * @internal
 */
export declare function extractFontFamilies(text: string, style: HTMLTextStyle): string[];
