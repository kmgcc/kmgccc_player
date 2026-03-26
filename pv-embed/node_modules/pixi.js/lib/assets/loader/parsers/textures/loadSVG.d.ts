import { type ImageLike } from '../../../../environment/ImageLike';
import { GraphicsContext } from '../../../../scene/graphics/shared/GraphicsContext';
import { type LoaderParser } from '../LoaderParser';
import type { TextureSourceOptions } from '../../../../rendering/renderers/shared/texture/sources/TextureSource';
import type { Texture } from '../../../../rendering/renderers/shared/texture/Texture';
/**
 * Configuration for the {@link loadSvg} plugin.
 * @see loadSvg
 * @category assets
 * @advanced
 */
export interface LoadSVGConfig {
    /**
     * The crossOrigin value to use for loading the SVG as an image.
     * @default 'anonymous'
     */
    crossOrigin: ImageLike['crossOrigin'];
    /**
     * When set to `true`, loading and decoding images will happen with `new Image()`,
     * @default false
     */
    parseAsGraphicsContext: boolean;
}
/**
 * A loader plugin for loading SVG data as textures or graphics contexts.
 * @category assets
 * @advanced
 */
export declare const loadSvg: LoaderParser<Texture | GraphicsContext, TextureSourceOptions & LoadSVGConfig, LoadSVGConfig>;
