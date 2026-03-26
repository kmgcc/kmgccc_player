import EventEmitter from 'eventemitter3';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { FontMetrics } from '../text/canvas/utils/types';
/**
 * @category text
 * @advanced
 */
export interface CharData {
    /** Unique id of character */
    id: number;
    /** x-offset to apply when rendering character */
    xOffset: number;
    /** y-offset to apply when rendering character. */
    yOffset: number;
    /** Advancement to apply to next character. */
    xAdvance: number;
    /** The kerning values for this character. */
    kerning: Record<string, number>;
    /** The texture of the character. */
    texture?: Texture;
}
/**
 * The raw data of a character in a bitmap font.
 * @category text
 * @advanced
 */
export interface RawCharData extends Omit<CharData, 'texture'> {
    /** The page of the font texture that the character is on. */
    page: number;
    /** The x position of the character in the page. */
    x: number;
    /** The y position of the character in the page. */
    y: number;
    /** The width of the character in the page. */
    width: number;
    /** The height of the character in the page. */
    height: number;
    /** The letter of the character. */
    letter: string;
}
/**
 * The raw data of a bitmap font.
 * @category text
 * @advanced
 */
export interface BitmapFontData {
    /** The offset of the font face from the baseline. */
    baseLineOffset: number;
    /** The map of characters by character string. */
    chars: Record<string, RawCharData>;
    /** The map of base page textures (i.e., sheets of glyphs). */
    pages: {
        /** Unique id for bitmap texture */
        id: number;
        /** File name */
        file: string;
    }[];
    /** The line-height of the font face in pixels. */
    lineHeight: number;
    /** The size of the font face in pixels. */
    fontSize: number;
    /** The name of the font face. */
    fontFamily: string;
    /** The range and type of the distance field for this font. */
    distanceField?: {
        /** Type of distance field */
        type: 'sdf' | 'msdf' | 'none';
        /** Range of the distance field in pixels */
        range: number;
    };
}
interface BitmapFontEvents<Type> {
    destroy: [Type];
}
/**
 * An abstract representation of a bitmap font.
 * @category text
 * @advanced
 */
export declare abstract class AbstractBitmapFont<FontType> extends EventEmitter<BitmapFontEvents<FontType>> implements Omit<BitmapFontData, 'chars' | 'pages' | 'fontSize'> {
    /** The map of characters by character string. */
    readonly chars: Record<string, CharData>;
    /**
     * The line-height of the font face in pixels.
     * @type {number}
     */
    readonly lineHeight: BitmapFontData['lineHeight'];
    /**
     * The name of the font face
     * @type {string}
     */
    readonly fontFamily: BitmapFontData['fontFamily'];
    /** The metrics of the font face. */
    readonly fontMetrics: FontMetrics;
    /**
     * The offset of the font face from the baseline.
     * @type {number}
     */
    readonly baseLineOffset: BitmapFontData['baseLineOffset'];
    /** The range and type of the distance field for this font. */
    readonly distanceField: BitmapFontData['distanceField'];
    /** The map of base page textures (i.e., sheets of glyphs). */
    readonly pages: {
        texture: Texture;
    }[];
    /** should the fill for this font be applied as a tint to the text. */
    applyFillAsTint: boolean;
    /** The size of the font face in pixels. */
    readonly baseMeasurementFontSize: number;
    protected baseRenderedFontSize: number;
    /**
     * The name of the font face.
     * @deprecated since 8.0.0 Use `fontFamily` instead.
     */
    get font(): BitmapFontData['fontFamily'];
    /**
     * The map of base page textures (i.e., sheets of glyphs).
     * @deprecated since 8.0.0 Use `pages` instead.
     */
    get pageTextures(): AbstractBitmapFont<FontType>['pages'];
    /**
     * The size of the font face in pixels.
     * @deprecated since 8.0.0 Use `fontMetrics.fontSize` instead.
     */
    get size(): BitmapFontData['fontSize'];
    /**
     * The kind of distance field for this font or "none".
     * @deprecated since 8.0.0 Use `distanceField.type` instead.
     */
    get distanceFieldRange(): NonNullable<BitmapFontData['distanceField']>['range'];
    /**
     * The range of the distance field in pixels.
     * @deprecated since 8.0.0 Use `distanceField.range` instead.
     */
    get distanceFieldType(): NonNullable<BitmapFontData['distanceField']>['type'];
    destroy(destroyTextures?: boolean): void;
}
export {};
