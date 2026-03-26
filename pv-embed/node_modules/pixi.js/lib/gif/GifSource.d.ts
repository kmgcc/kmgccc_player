import { CanvasSource, type CanvasSourceOptions } from '../rendering/renderers/shared/texture/sources/CanvasSource';
import { Texture } from '../rendering/renderers/shared/texture/Texture';
/**
 * Represents a single frame of a GIF. Includes image and timing data.
 * @category gif
 * @advanced
 */
interface GifFrame {
    /** Image data for the current frame */
    texture: Texture<CanvasSource>;
    /** The start of the current frame, in milliseconds */
    start: number;
    /** The end of the current frame, in milliseconds */
    end: number;
}
/**
 * Options when constructing from buffer
 * @category gif
 * @advanced
 */
interface GifBufferOptions extends Omit<CanvasSourceOptions, 'resource'> {
    /** FPS to use when the GIF animation doesn't define any delay between frames */
    fps?: number;
}
/**
 * Resource provided to GifSprite instances. This is very similar to using a shared
 * Texture between Sprites. This source contains all the frames and animation needed
 * to support playback.
 * @category gif
 * @advanced
 */
declare class GifSource {
    /** Width of the animation */
    readonly width: number;
    /** Height of the animation */
    readonly height: number;
    /** The total time to play the animation in milliseconds */
    readonly duration: number;
    /** Animation frames */
    readonly frames: GifFrame[];
    /** Textures */
    readonly textures: Texture<CanvasSource>[];
    /** Total number of frames in the animation */
    readonly totalFrames: number;
    /**
     * @param frames - Array of GifFrame instances.
     */
    constructor(frames: GifFrame[]);
    /** Destroy animation data and don't use after this */
    destroy(): void;
    /**
     * Create an animated GIF animation from a GIF image's ArrayBuffer. The easiest way to get
     * the buffer is to use Assets.
     * @example
     * import { GifSource, GifSprite } from 'pixi.js/gif';
     *
     * const buffer = await fetch('./file.gif').then(res => res.arrayBuffer());
     * const source = GifSource.from(buffer);
     * const sprite = new GifSprite(source);
     * @param buffer - GIF image arraybuffer from Assets.
     * @param options - Optional options to use when building from buffer.
     */
    static from(buffer: ArrayBuffer, options?: GifBufferOptions): GifSource;
}
export { GifBufferOptions, GifFrame, GifSource };
