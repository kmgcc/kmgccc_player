import { Texture } from '../../../../../rendering/renderers/shared/texture/Texture';
import type { TextureSource } from '../../../../../rendering/renderers/shared/texture/sources/TextureSource';
import type { Loader } from '../../../Loader';
/**
 * Creates a texture from a source and adds it to the cache.
 * @param source - source of the texture
 * @param loader - loader
 * @param url - url of the texture
 * @ignore
 */
export declare function createTexture(source: TextureSource, loader: Loader, url: string): Texture<TextureSource<any>>;
