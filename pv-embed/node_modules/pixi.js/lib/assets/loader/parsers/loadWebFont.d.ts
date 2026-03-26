import { ExtensionType } from '../../../extensions/Extensions';
import { LoaderParserPriority } from './LoaderParser';
import type { ResolvedAsset } from '../../types';
/**
 * Cache for font faces
 * @internal
 */
export interface FontFaceCache {
    entries: {
        url: string;
        faces: FontFace[];
    }[];
}
/**
 * Data for loading a font
 * @category assets
 * @advanced
 */
export type LoadFontData = {
    /** Font family name */
    family: string;
    /** A set of optional descriptors passed as an object. It can contain any of the descriptors available for @font-face: */
    display: string;
    /**
     * The featureSettings property of the FontFace interface retrieves or sets infrequently used
     * font features that are not available from a font's variant properties.
     */
    featureSettings: string;
    /** The stretch property of the FontFace interface retrieves or sets how the font stretches. */
    stretch: string;
    /** The style property of the FontFace interface retrieves or sets the font's style. */
    style: string;
    /**
     * The unicodeRange property of the FontFace interface retrieves or sets the range of
     * unicode code points encompassing the font.
     */
    unicodeRange: string;
    /** The variant property of the FontFace interface programmatically retrieves or sets font variant values. */
    variant: string;
    /** The weight property of the FontFace interface retrieves or sets the weight of the font. */
    weights: string[];
};
/**
 * Return font face name from a file name
 * Ex.: 'fonts/titan-one.woff' turns into 'Titan One'
 * @param url - File url
 * @category assets
 * @internal
 */
export declare function getFontFamilyName(url: string): string;
/**
 * A loader plugin for handling web fonts
 * @example
 * import { Assets } from 'pixi.js';
 *
 * Assets.load({
 *   alias: 'font',
 *   src: 'fonts/titan-one.woff',
 *   data: {
 *     family: 'Titan One',
 *     weights: ['normal', 'bold'],
 *   }
 * })
 * @category assets
 * @advanced
 */
export declare const loadWebFont: {
    extension: {
        type: ExtensionType.LoadParser;
        priority: LoaderParserPriority;
    };
    /** used for deprecation purposes */
    name: string;
    id: string;
    test(url: string): boolean;
    load<T>(url: string, options?: ResolvedAsset<LoadFontData>): Promise<FontFace | FontFace[]>;
    unload(font: FontFace | FontFace[]): void;
};
