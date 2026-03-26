/** @internal */
export declare const FontStylePromiseCache: Map<string, Promise<string>>;
/**
 * takes the font families and returns a css string that can be injected into a style tag
 * It will contain the font families and the font urls encoded as base64
 * @param fontFamilies - The font families to load
 * @returns - The css string
 * @internal
 */
export declare function getFontCss(fontFamilies: string[]): Promise<string>;
