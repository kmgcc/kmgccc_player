import { Texture } from '../../rendering/renderers/shared/texture/Texture';
import { TextureStyle, type TextureStyleOptions } from '../../rendering/renderers/shared/texture/TextureStyle';
import { TextStyle } from '../text/TextStyle';
import { AbstractBitmapFont } from './AbstractBitmapFont';
import type { CanvasAndContext } from '../../rendering/renderers/shared/texture/CanvasPool';
/** @internal */
export interface DynamicBitmapFontOptions {
    style: TextStyle;
    skipKerning?: boolean;
    resolution?: number;
    padding?: number;
    overrideFill?: boolean;
    overrideSize?: boolean;
    textureSize?: number;
    mipmap?: boolean;
    textureStyle?: TextureStyle | TextureStyleOptions;
}
/**
 * A BitmapFont that generates its glyphs dynamically.
 * @category text
 * @internal
 */
export declare class DynamicBitmapFont extends AbstractBitmapFont<DynamicBitmapFont> {
    static defaultOptions: DynamicBitmapFontOptions;
    /**
     * this is a resolution modifier for the font size..
     * texture resolution will also be used to scale texture according to its font size also
     */
    resolution: number;
    /** The pages of the font. */
    readonly pages: {
        canvasAndContext?: CanvasAndContext;
        texture: Texture;
    }[];
    private readonly _padding;
    private readonly _measureCache;
    private _currentChars;
    private _currentX;
    private _currentY;
    private _currentMaxCharHeight;
    private _currentPageIndex;
    private readonly _style;
    private readonly _skipKerning;
    private readonly _textureSize;
    private readonly _mipmap;
    private readonly _textureStyle?;
    /**
     * @param options - The options for the dynamic bitmap font.
     */
    constructor(options: DynamicBitmapFontOptions);
    ensureCharacters(chars: string): void;
    /**
     * @deprecated since 8.0.0
     * The map of base page textures (i.e., sheets of glyphs).
     */
    get pageTextures(): DynamicBitmapFont['pages'];
    private _applyKerning;
    private _nextPage;
    private _setupContext;
    private _drawGlyph;
    destroy(): void;
}
