import { Texture } from './Texture';
import type { TextureSourceOptions } from './sources/TextureSource';
/**
 * A render texture, extends `Texture`.
 * @see {@link Texture}
 * @category rendering
 * @advanced
 */
export declare class RenderTexture extends Texture {
    /**
     * Creates a RenderTexture. Pass `dynamic: true` in options to allow resizing after creation.
     * @param options - Options for the RenderTexture, including width, height, and dynamic.
     * @returns A new RenderTexture instance.
     * @example
     * const rt = RenderTexture.create({ width: 100, height: 100, dynamic: true });
     * rt.resize(500, 500);
     */
    static create(options: TextureSourceOptions): RenderTexture;
    /**
     * Resizes the render texture.
     * @param width - The new width of the render texture.
     * @param height - The new height of the render texture.
     * @param resolution - The new resolution of the render texture.
     * @returns This texture.
     */
    resize(width: number, height: number, resolution?: number): this;
}
