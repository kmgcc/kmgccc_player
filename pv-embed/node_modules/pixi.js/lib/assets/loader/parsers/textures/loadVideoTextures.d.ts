import { type ImageLike } from '../../../../environment/ImageLike';
import { ExtensionType } from '../../../../extensions/Extensions';
import type { VideoSourceOptions } from '../../../../rendering/renderers/shared/texture/sources/VideoSource';
import type { Texture } from '../../../../rendering/renderers/shared/texture/Texture';
import type { ResolvedAsset } from '../../../types';
import type { Loader } from '../../Loader';
/**
 * Set cross origin based detecting the url and the crossorigin
 * @param element - Element to apply crossOrigin
 * @param url - URL to check
 * @param crossorigin - Cross origin value to use
 * @category assets
 * @advanced
 */
export declare function crossOrigin(element: ImageLike | HTMLVideoElement, url: string, crossorigin?: boolean | string): void;
/**
 * Preload a video element
 * @param element - Video element to preload
 * @internal
 */
export declare function preloadVideo(element: HTMLVideoElement): Promise<void>;
/**
 * Sets the `crossOrigin` property for this resource based on if the url
 * for this resource is cross-origin. If crossOrigin was manually set, this
 * function does nothing.
 * Nipped from the resource loader!
 * @ignore
 * @param url - The url to test.
 * @param {object} [loc=window.location] - The location object to test against.
 * @returns The crossOrigin value to use (or empty string for none).
 * @category assets
 */
export declare function determineCrossOrigin(url: string, loc?: Location): string;
type LoadVideoData = VideoSourceOptions & {
    mime?: string;
};
/**
 * A simple plugin to load video textures.
 *
 * You can pass VideoSource options to the loader via the .data property of the asset descriptor
 * when using Assets.load().
 * ```js
 * // Set the data
 * const texture = await Assets.load({
 *     src: './assets/city.mp4',
 *     data: {
 *         preload: true,
 *         autoPlay: true,
 *     },
 * });
 * ```
 * @category assets
 * @advanced
 */
export declare const loadVideoTextures: {
    /** used for deprecation purposes */
    name: string;
    id: string;
    extension: {
        type: ExtensionType.LoadParser;
        name: string;
    };
    test(url: string): boolean;
    load<T>(url: string, asset: ResolvedAsset<LoadVideoData>, loader: Loader): Promise<Texture>;
    unload(texture: Texture): void;
};
export {};
