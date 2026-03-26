import type { BitmapFontData } from '../AbstractBitmapFont';
/** @internal */
export declare const bitmapFontXMLParser: {
    test(data: string | XMLDocument | BitmapFontData): boolean;
    parse(xml: Document): BitmapFontData;
};
