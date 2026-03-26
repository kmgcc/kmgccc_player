import { type TextureStyle, type TextureStyleOptions } from '../../rendering/renderers/shared/texture/TextureStyle';
import { TextStyle } from '../text/TextStyle';
import type { TextStyleOptions } from '../text/TextStyle';
import type { BitmapFont } from './BitmapFont';
import type { BitmapTextLayoutData } from './utils/getBitmapTextLayout';
/**
 * The options for installing a new BitmapFont. Once installed, the font will be available
 * for use in BitmapText objects through the fontFamily property of TextStyle.
 * @example
 * ```ts
 * import { BitmapFont, BitmapText } from 'pixi.js';
 *
 * // Basic font installation
 * BitmapFont.install({
 *     name: 'BasicFont',
 *     style: {
 *         fontFamily: 'Arial',
 *         fontSize: 24,
 *         fill: '#ffffff'
 *     }
 * });
 *
 * // Advanced font installation
 * BitmapFont.install({
 *     name: 'AdvancedFont',
 *     style: {
 *         fontFamily: 'Arial',
 *         fontSize: 32,
 *         fill: '#ff0000',
 *         stroke: { color: '#000000', width: 2 }
 *     },
 *     // Include specific character ranges
 *     chars: [
 *         ['a', 'z'],           // lowercase letters
 *         ['A', 'Z'],           // uppercase letters
 *         ['0', '9'],           // numbers
 *         '!@#$%^&*()_+-=[]{}' // symbols
 *     ],
 *     resolution: 2,            // High-DPI support
 *     padding: 4,              // Glyph padding
 *     skipKerning: false,      // Enable kerning
 *     textureStyle: {
 *         scaleMode: 'linear',
 *     }
 * });
 *
 * // Using the installed font
 * const text = new BitmapText({
 *     text: 'Hello World',
 *     style: {
 *         fontFamily: 'AdvancedFont',
 *         fontSize: 48
 *     }
 * });
 * ```
 * @category text
 * @standard
 */
export interface BitmapFontInstallOptions {
    /**
     * The name of the font. This will be used as the fontFamily in text styles to access this font.
     * Must be unique across all installed bitmap fonts.
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'MyCustomFont',
     *     style: { fontFamily: 'Arial' }
     * });
     * ```
     */
    name?: string;
    /**
     * Characters included in the font set. You can specify individual characters or ranges.
     * Don't forget to include spaces ' ' in your character set!
     * @default BitmapFont.ALPHANUMERIC
     * @example
     * ```ts
     * // Different ways to specify characters
     * BitmapFont.install({
     *     name: 'RangeFont',
     *     chars: [
     *         ['a', 'z'],              // Range of characters
     *         '0123456789',            // String of characters
     *         [['0', '9'], ['A', 'Z']] // Multiple ranges
     *     ]
     * });
     * ```
     */
    chars?: string | (string | string[])[];
    /**
     * Render resolution for glyphs. Higher values create sharper text at the cost of memory.
     * Useful for supporting high-DPI displays.
     * @default 1
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'HiDPIFont',
     *     resolution: window.devicePixelRatio || 2
     * });
     * ```
     */
    resolution?: number;
    /**
     * Padding between glyphs on texture atlas. Balances visual quality with texture space.
     * - Lower values: More compact, but may have visual artifacts
     * - Higher values: Better quality, but uses more texture space
     * @default 4
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'PaddedFont',
     *     padding: 8 // More padding for better quality
     * });
     * ```
     */
    padding?: number;
    /**
     * Skip generation of kerning information for the BitmapFont.
     * - true: Faster generation, but text may have inconsistent spacing
     * - false: Better text appearance, but slower generation
     * @default false
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'FastFont',
     *     skipKerning: true // Prioritize performance
     * });
     * ```
     */
    skipKerning?: boolean;
    /**
     * Style options to render the BitmapFont with.
     * Supports all TextStyle properties including fill, stroke, and shadow effects.
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'StyledFont',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 32,
     *         fill: 'white',
     *         stroke: { color: '#000000', width: 2 },
     *         dropShadow: {
     *             color: '#000000',
     *             blur: 2,
     *             distance: 3
     *         }
     *     }
     * });
     * ```
     */
    style?: TextStyle | TextStyleOptions;
    /**
     * Optional texture style to use when creating the font textures.
     * Controls how the font textures are rendered and filtered.
     * @example
     * ```ts
     * BitmapFont.install({
     *     name: 'CrispFont',
     *     textureStyle: {
     *         scaleMode: 'nearest',
     *     }
     * });
     * ```
     */
    textureStyle?: TextureStyle | TextureStyleOptions;
    /**
     * Whether to allow overriding the fill color with a tint at runtime.
     *
     * When enabled, the font can be dynamically tinted using the `tint` property of BitmapText,
     * allowing a single font to display multiple colors without creating separate font textures.
     * This is memory efficient but requires the font to be rendered with white fill color.
     *
     * When disabled, the fill color is permanently baked into the font texture. This allows
     * any fill color but prevents runtime tinting - each color variation requires a separate font.
     * @default false (automatically determined based on style)
     *
     * **Requirements for tinting:**
     * - Fill color must be white (`0xFFFFFF` or `'#ffffff'`)
     * - No stroke effects
     * - No drop shadows (or only black shadows)
     * - No gradient or pattern fills
     *
     * **Performance considerations:**
     * - ✅ Enabled: One font texture, multiple colors via tinting (memory efficient)
     * - ❌ Disabled: Separate font texture per color (higher memory usage)
     * @example
     * ```ts
     * // Correct usage - white fill with tinting enabled
     * BitmapFont.install({
     *     name: 'TintableFont',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 24,
     *         fill: 0xFFFFFF  // Must be white for tinting
     *     },
     *     dynamicFill: true
     * });
     *
     * // Use the font with different colors via tinting
     * const redText = new BitmapText({
     *     text: 'Red Text',
     *     style: { fontFamily: 'TintableFont', fill: 'red }, // Red tint
     * });
     *
     * const blueText = new BitmapText({
     *     text: 'Blue Text',
     *     style: { fontFamily: 'TintableFont', fill: 'blue' }, // Blue tint
     * });
     * ```
     * @example
     * ```ts
     * // Incorrect usage - colored fill with tinting enabled
     * BitmapFont.install({
     *     name: 'BadTintFont',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 24,
     *         fill: 0xFF0000  // ❌ Red fill won't tint properly
     *     },
     *     dynamicFill: true  // ❌ Will not work as expected
     * });
     * ```
     * @example
     * ```ts
     * // Alternative - baked colors (no tinting)
     * BitmapFont.install({
     *     name: 'BakedColorFont',
     *     style: {
     *         fontFamily: 'Arial',
     *         fontSize: 24,
     *         fill: 0xFF0000,  // Any color works
     *         stroke: { color: 0x000000, width: 2 }  // Strokes allowed
     *     },
     *     dynamicFill: false  // Color is baked in
     * });
     * ```
     */
    dynamicFill?: boolean;
}
/** @advanced */
declare class BitmapFontManagerClass {
    /**
     * This character set includes all the letters in the alphabet (both lower- and upper- case).
     * @type {string[][]}
     * @example
     * BitmapFont.from('ExampleFont', style, { chars: BitmapFont.ALPHA })
     */
    readonly ALPHA: (string | string[])[];
    /**
     * This character set includes all decimal digits (from 0 to 9).
     * @type {string[][]}
     * @example
     * BitmapFont.from('ExampleFont', style, { chars: BitmapFont.NUMERIC })
     */
    readonly NUMERIC: string[][];
    /**
     * This character set is the union of `BitmapFont.ALPHA` and `BitmapFont.NUMERIC`.
     * @type {string[][]}
     */
    readonly ALPHANUMERIC: (string | string[])[];
    /**
     * This character set consists of all the ASCII table.
     * @type {string[][]}
     * @see http://www.asciitable.com/
     */
    readonly ASCII: string[][];
    /** Default options for installing a new BitmapFont. */
    defaultOptions: Omit<BitmapFontInstallOptions, 'style'>;
    /** Cache for measured text layouts to avoid recalculating them multiple times. */
    readonly measureCache: import("tiny-lru").LRU<BitmapTextLayoutData>;
    /**
     * Get a font for the specified text and style.
     * @param text - The text to get the font for
     * @param style - The style to use
     */
    getFont(text: string, style: TextStyle): BitmapFont;
    /**
     * Get the layout of a text for the specified style.
     * @param text - The text to get the layout for
     * @param style - The style to use
     * @param trimEnd - Whether to ignore whitespaces at the end of each line
     */
    getLayout(text: string, style: TextStyle, trimEnd?: boolean): BitmapTextLayoutData;
    /**
     * Measure the text using the specified style.
     * @param text - The text to measure
     * @param style - The style to use
     * @param trimEnd - Whether to ignore whitespaces at the end of each line
     */
    measureText(text: string, style: TextStyle, trimEnd?: boolean): {
        width: number;
        height: number;
        scale: number;
        offsetY: number;
    };
    /**
     * Generates a bitmap-font for the given style and character set
     * @param options - Setup options for font generation.
     * @returns Font generated by style options.
     * @example
     * import { BitmapFontManager, BitmapText } from 'pixi.js';
     *
     * BitmapFontManager.install('TitleFont', {
     *     fontFamily: 'Arial',
     *     fontSize: 12,
     *     strokeThickness: 2,
     *     fill: 'purple',
     * });
     *
     * const title = new BitmapText({ text: 'This is the title', fontFamily: 'TitleFont' });
     */
    install(options: BitmapFontInstallOptions): BitmapFont;
    /** @deprecated since 7.0.0 */
    install(name: string, style?: TextStyle | TextStyleOptions, options?: BitmapFontInstallOptions): BitmapFont;
    /**
     * Uninstalls a bitmap font from the cache.
     * @param {string} name - The name of the bitmap font to uninstall.
     */
    uninstall(name: string): void;
    /**
     * Determines if a style can use tinting instead of baking colors into the bitmap.
     * Tinting is more efficient as it allows reusing the same bitmap with different colors.
     * @param style - The text style to evaluate
     * @returns true if the style can use tinting, false if colors must be baked in
     * @private
     */
    private _canUseTintForStyle;
}
/**
 * The BitmapFontManager is a helper that exists to install and uninstall fonts
 * into the cache for BitmapText objects.
 * @category text
 * @advanced
 * @class
 * @example
 * import { BitmapFontManager, BitmapText } from 'pixi.js';
 *
 * BitmapFontManager.install({
 *   name: 'TitleFont',
 *   style: {}
 * });
 *
 * const title = new BitmapText({ text: 'This is the title', style: { fontFamily: 'TitleFont' }});
 */
export declare const BitmapFontManager: BitmapFontManagerClass;
export {};
