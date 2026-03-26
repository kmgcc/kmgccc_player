import type { HTMLTextRenderData } from '../HTMLTextRenderData';
import type { HTMLTextStyle } from '../HTMLTextStyle';
/**
 * takes all the data and returns a svg url string can be loaded by an image element
 * @param text - The text to measure
 * @param style - The style to use
 * @param resolution - The resolution to use
 * @param fontCSS - The font css to use
 * @param htmlTextData - The HTMLTextRenderData to write the SVG to
 * @returns - The SVG as a url string
 * @internal
 */
export declare function getSVGUrl(text: string, style: HTMLTextStyle, resolution: number, fontCSS: string, htmlTextData: HTMLTextRenderData): string;
