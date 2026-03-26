import { type HTMLTextStyle } from '../HTMLTextStyle';
/**
 * Internally converts all of the style properties into CSS equivalents.
 * @param style
 * @returns The CSS style string, for setting `style` property of root HTMLElement.
 * @internal
 */
export declare function textStyleToCSS(style: HTMLTextStyle): string;
