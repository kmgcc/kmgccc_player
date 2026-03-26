import { HTMLTextRenderData } from '../HTMLTextRenderData';
import type { Size } from '../../../maths/misc/Size';
import type { HTMLTextStyle } from '../HTMLTextStyle';
/**
 * Measures the HTML text without actually generating an image.
 * This is used to calculate the size of the text.
 * @param text - The text to measure
 * @param style - The style to use
 * @param fontStyleCSS - The font css to use
 * @param htmlTextRenderData - The HTMLTextRenderData to write the SVG to
 * @returns - The size of the text
 * @internal
 */
export declare function measureHtmlText(text: string, style: HTMLTextStyle, fontStyleCSS?: string, htmlTextRenderData?: HTMLTextRenderData): Size;
