import type { BitmapFontData } from '../AbstractBitmapFont';
/**
 * Internal data format used to convert to BitmapFontData.
 * @private
 */
export interface BitmapFontRawData {
    info: {
        face: string;
        size: string;
    }[];
    common: {
        lineHeight: string;
        base: string;
    }[];
    page: {
        id: string;
        file: string;
    }[];
    chars: {
        count: number;
    }[];
    char: {
        id: string;
        page: string;
        xoffset: string;
        yoffset: string;
        xadvance: string;
        x: string;
        y: string;
        width: string;
        height: string;
        letter?: string;
        char?: string;
    }[];
    kernings?: {
        count: number;
    }[];
    kerning?: {
        first: string;
        second: string;
        amount: string;
    }[];
    distanceField?: {
        fieldType: 'sdf' | 'msdf' | 'none';
        distanceRange: string;
    }[];
}
/** @internal */
export declare const bitmapFontTextParser: {
    test(data: string | XMLDocument | BitmapFontData): boolean;
    parse(txt: string): BitmapFontData;
};
