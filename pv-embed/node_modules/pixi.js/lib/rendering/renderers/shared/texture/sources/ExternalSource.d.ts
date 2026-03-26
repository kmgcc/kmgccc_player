import { type Renderer } from '../../../types';
import { TextureSource } from './TextureSource';
/**
 * Options for creating an ExternalSource.
 * @category rendering
 * @advanced
 */
export interface ExternalSourceOptions {
    /**
     * The external GPU texture (GPUTexture for WebGPU, WebGLTexture for WebGL).
     * If not provided, a shared 1x1 placeholder texture will be used until
     * `updateGPUTexture()` is called.
     * @advanced
     */
    resource?: GPUTexture | WebGLTexture;
    /**
     * The renderer this texture will be used with
     * @advanced
     */
    renderer: Renderer;
    /**
     * Width of the texture. Auto-detected for GPUTexture, required for WebGLTexture.
     * @advanced
     */
    width?: number;
    /**
     * Height of the texture. Auto-detected for GPUTexture, required for WebGLTexture.
     * @advanced
     */
    height?: number;
    /**
     * Optional label for debugging
     * @advanced
     */
    label?: string;
}
/**
 * A texture source that uses a GPU texture from an external library (e.g., Three.js).
 *
 * This allows sharing textures between PixiJS and other WebGL/WebGPU libraries without
 * re-uploading pixel data. The renderer is required so that ExternalSource can
 * pre-populate the GPU data and validate context ownership.
 * @example
 * ```typescript
 * // WebGPU - dimensions auto-detected
 * const texture = new Texture({
 *     source: new ExternalSource({
 *         resource: threeJsGpuTexture,
 *         renderer: renderer,
 *     })
 * });
 *
 * // WebGL - must provide dimensions (WebGLTexture is opaque)
 * const texture = new Texture({
 *     source: new ExternalSource({
 *         resource: threeJsGlTexture,
 *         renderer: renderer,
 *         width: 512,
 *         height: 512,
 *     })
 * });
 *
 * // Update to a new external texture
 * (texture.source as ExternalSource).updateGPUTexture(newExternalTexture);
 * ```
 * @category rendering
 * @advanced
 */
export declare class ExternalSource extends TextureSource<GPUTexture | WebGLTexture> {
    private readonly _renderer;
    constructor({ resource, renderer, label, width, height }: ExternalSourceOptions);
    /**
     * Test if a resource is a valid external GPU texture.
     * @param resource - The resource to test
     * @returns True if the resource is a GPUTexture or WebGLTexture
     */
    static test(resource: unknown): resource is GPUTexture | WebGLTexture;
    private _validateTexture;
    private _initGpuData;
    /**
     * Update the external GPU texture reference.
     * Call this when the external library provides a new texture.
     * @param gpuTexture - The new GPU texture
     * @param width - New width (required for WebGLTexture, auto-detected for GPUTexture)
     * @param height - New height (required for WebGLTexture, auto-detected for GPUTexture)
     */
    updateGPUTexture(gpuTexture: GPUTexture | WebGLTexture, width?: number, height?: number): void;
    destroy(): void;
}
