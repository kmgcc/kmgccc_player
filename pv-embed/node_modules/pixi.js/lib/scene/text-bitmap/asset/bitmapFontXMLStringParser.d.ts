import type { BitmapFontData } from '../AbstractBitmapFont';
/** @internal */
export declare const bitmapFontXMLStringParser: {
    test(data: string | XMLDocument | BitmapFontData): boolean;
    parse(data: string): BitmapFontData;
};
