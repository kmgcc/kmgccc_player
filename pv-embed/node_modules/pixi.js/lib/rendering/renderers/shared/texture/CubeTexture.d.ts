import EventEmitter from 'eventemitter3';
import { CubeTextureSource } from './sources/CubeTextureSource';
import type { CubeTextureSourceOptions } from './sources/CubeTextureSource';
import type { BindableTexture, TextureSourceLike } from './Texture';
type CubeTextureFaceInputs = {
    left: TextureSourceLike | BindableTexture;
    right: TextureSourceLike | BindableTexture;
    top: TextureSourceLike | BindableTexture;
    bottom: TextureSourceLike | BindableTexture;
    front: TextureSourceLike | BindableTexture;
    back: TextureSourceLike | BindableTexture;
};
type CubeTextureFromOptions = Omit<CubeTextureSourceOptions, 'faces'> & {
    faces: CubeTextureFaceInputs;
};
/**
 * The options that can be passed to a new {@link CubeTexture}.
 * @category rendering
 * @advanced
 */
export interface CubeTextureOptions {
    /** The underlying cube texture source. */
    source: CubeTextureSource;
    /** Optional label, for debugging. */
    label?: string;
}
/**
 * A cube texture that can be bound to shaders (samplerCube / texture_cube).
 *
 * This is a lightweight wrapper around a {@link CubeTextureSource}.
 * @example
 * Load 6 images and create a cube texture (paths are just examples):
 *
 * ```ts
 * import { Assets, CubeTexture } from 'pixi.js';
 *
 * await Assets.load([
 *   'px.png', 'nx.png',
 *   'py.png', 'ny.png',
 *   'pz.png', 'nz.png',
 * ]);
 *
 * // IMPORTANT: string ids must already be in the cache (e.g. after Assets.load)
 * const cube = CubeTexture.from({
 *   faces: {
 *     right: 'px.png',  // +X
 *     left: 'nx.png',   // -X
 *     top: 'py.png',    // +Y
 *     bottom: 'ny.png', // -Y
 *     front: 'pz.png',  // +Z
 *     back: 'nz.png',   // -Z
 *   },
 *   label: 'skybox',
 * });
 * ```
 * @example
 * Bind to a shader (resources differ between WebGL and WebGPU, but the cube texture binding stays the same):
 *
 * ```ts
 * const shader = Shader.from({
 *   gl: { fragment: `uniform samplerCube uCube;` },
 *   gpu: { fragment: { source: `@group(0) @binding(0) var uCube : texture_cube<f32>;` } },
 *   resources: {
 *     uCube: cube.source,
 *     uSampler: cube.source.style,
 *   },
 * });
 * ```
 * @category rendering
 * @advanced
 */
export declare class CubeTexture extends EventEmitter<{
    destroy: CubeTexture;
}> implements BindableTexture {
    /** unique id for this cube texture */
    readonly uid: number;
    /** Has the texture been destroyed? */
    destroyed: boolean;
    /** The underlying cube texture source. */
    readonly source: CubeTextureSource;
    /** Optional label for debugging. */
    label?: string;
    constructor(options: CubeTextureOptions);
    /**
     * Convenience factory for creating a cube texture from a {@link CubeTextureSource}.
     * @param options - A cube texture source.
     * @param skipCache - Unused for this overload.
     */
    static from(options: CubeTextureSource, skipCache?: boolean): CubeTexture;
    /**
     * Convenience factory for creating a cube texture from 6 face inputs.
     *
     * Face inputs are converted to {@link Texture} via {@link Texture.from}. This does **not** load resources;
     * string ids must already be present in the cache (e.g. after `Assets.load`).
     * @example
     * ```ts
     * const cube = CubeTexture.from({
     *   faces: {
     *     right: 'px.png',
     *     left: 'nx.png',
     *     top: 'py.png',
     *     bottom: 'ny.png',
     *     front: 'pz.png',
     *     back: 'nz.png',
     *   },
     * });
     * ```
     * @param options - Options including the 6 face inputs.
     * @param skipCache - Skip caching the resulting {@link CubeTexture} when all faces are string ids.
     */
    static from(options: CubeTextureFromOptions, skipCache?: boolean): CubeTexture;
    /**
     * Destroy this CubeTexture.
     * @param destroySource - If true, destroys the underlying {@link CubeTextureSource}.
     */
    destroy(destroySource?: boolean): void;
}
export {};
