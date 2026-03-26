import { Texture } from '../../rendering/renderers/shared/texture/Texture';
import { AbstractBitmapFont } from './AbstractBitmapFont';
import type { BitmapFontData } from './AbstractBitmapFont';
import type { BitmapFontInstallOptions } from './BitmapFontManager';
/**
 * Options for creating a BitmapFont. Used when loading or creating bitmap fonts from existing textures and data.
 * @example
 * ```ts
 * import { BitmapFont, Texture } from 'pixi.js';
 *
 * // Create a bitmap font from loaded textures and data
 * const font = new BitmapFont({
 *     // Font data containing character metrics and layout info
 *     data: {
 *         pages: [{ id: 0, file: 'font.png' }],
 *         chars: {
 *             'A': {
 *                 id: 65,
 *                 page: 0,
 *                 x: 0,
 *                 y: 0,
 *                 width: 32,
 *                 height: 32,
 *                 xOffset: 0,
 *                 yOffset: 0,
 *                 xAdvance: 32,
 *                 letter: 'A'
 *             }
 *             // ... other characters
 *         },
 *         fontSize: 32,
 *         lineHeight: 36,
 *         baseLineOffset: 26,
 *         fontFamily: 'MyFont',
 *         // Optional distance field info for MSDF/SDF fonts
 *         distanceField: {
 *             type: 'msdf',
 *             range: 4
 *         }
 *     },
 *     // Array of textures containing the font glyphs
 *     textures: [
 *         Texture.from('font.png')
 *     ]
 * });
 * ```
 * @category text
 * @standard
 */
export interface BitmapFontOptions {
    /**
     * The bitmap font data containing character metrics, layout information,
     * and font properties. This includes character positions, dimensions,
     * kerning data, and general font settings.
     */
    data: BitmapFontData;
    /**
     * Array of textures containing the font glyphs. Each texture corresponds
     * to a page in the font data. For simple fonts this is typically just
     * one texture, but complex fonts may split glyphs across multiple textures.
     */
    textures: Texture[];
}
/**
 * A BitmapFont object represents a particular font face, size, and style.
 * This class handles both pre-loaded bitmap fonts and dynamically generated ones.
 * @example
 * ```ts
 * import { BitmapFont, Texture } from 'pixi.js';
 *
 * // Create a bitmap font from loaded textures and data
 * const font = new BitmapFont({
 *     data: {
 *         pages: [{ id: 0, file: 'font.png' }],
 *         chars: {
 *             'A': {
 *                 id: 65,
 *                 page: 0,
 *                 x: 0,
 *                 y: 0,
 *                 width: 32,
 *                 height: 32,
 *                 xOffset: 0,
 *                 yOffset: 0,
 *                 xAdvance: 32,
 *                 letter: 'A'
 *             }
 *         },
 *         fontSize: 32,
 *         lineHeight: 36,
 *         baseLineOffset: 26,
 *         fontFamily: 'MyFont',
 *         distanceField: {
 *             type: 'msdf',
 *             range: 4
 *         }
 *     },
 *     textures: [Texture.from('font.png')]
 * });
 *
 * // Install a font for global use
 * BitmapFont.install({
 *     name: 'MyCustomFont',
 *     style: {
 *         fontFamily: 'Arial',
 *         fontSize: 32,
 *         fill: '#ffffff',
 *         stroke: { color: '#000000', width: 2 }
 *     }
 * });
 *
 * // Uninstall when no longer needed
 * BitmapFont.uninstall('MyCustomFont');
 * ```
 * @category text
 * @standard
 */
export declare class BitmapFont extends AbstractBitmapFont<BitmapFont> {
    /**
     * The URL from which the font was loaded, if applicable.
     * This is useful for tracking font sources and reloading.
     * @example
     * ```ts
     * console.log(font.url); // 'fonts/myFont.fnt'
     * ```
     */
    url?: string;
    constructor(options: BitmapFontOptions, url?: string);
    /** Destroys the BitmapFont object. */
    destroy(): void;
    /**
     * Generates and installs a bitmap font with the specified options.
     * The font will be cached and available for use in BitmapText objects.
     * @param options - Setup options for font generation
     * @returns Installed font instance
     * @example
     * ```ts
     * // Install a basic font
     * BitmapFont.install({
     *     name: 'Title',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 32,
     *         fill: '#ffffff'
     *     }
     * });
     *
     * // Install with advanced options
     * BitmapFont.install({
     *     name: 'Custom',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 24,
     *         fill: '#00ff00',
     *         stroke: { color: '#000000', width: 2 }
     *     },
     *     chars: [['a', 'z'], ['A', 'Z'], ['0', '9']],
     *     resolution: 2,
     *     padding: 4,
     *     textureStyle: {
     *         scaleMode: 'nearest'
     *     }
     * });
     * ```
     */
    static install(options: BitmapFontInstallOptions): void;
    /**
     * Uninstalls a bitmap font from the cache.
     * This frees up memory and resources associated with the font.
     * @param name - The name of the bitmap font to uninstall
     * @example
     * ```ts
     * // Remove a font when it's no longer needed
     * BitmapFont.uninstall('MyCustomFont');
     *
     * // Clear multiple fonts
     * ['Title', 'Heading', 'Body'].forEach(BitmapFont.uninstall);
     * ```
     */
    static uninstall(name: string): void;
}
