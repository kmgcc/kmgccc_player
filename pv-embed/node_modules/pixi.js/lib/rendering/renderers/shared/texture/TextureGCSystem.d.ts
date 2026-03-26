import { ExtensionType } from '../../../../extensions/Extensions';
import { type Renderer } from '../../types';
import type { System } from '../system/System';
/**
 * Options for the {@link TextureGCSystem}.
 * @category rendering
 * @advanced
 * @deprecated since 8.15.0
 * @see {@link GCSystem}
 */
export interface TextureGCSystemOptions {
    /**
     * If set to true, this will enable the garbage collector on the GPU.
     * @default true
     * @deprecated since 8.15.0
     */
    textureGCActive: boolean;
    /**
     * @deprecated since 8.3.0
     * @see {@link TextureGCSystemOptions.textureGCMaxIdle}
     */
    textureGCAMaxIdle: number;
    /**
     * The maximum idle frames before a texture is destroyed by garbage collection.
     * @default 60 * 60
     * @deprecated since 8.15.0
     */
    textureGCMaxIdle: number;
    /**
     * Frames between two garbage collections.
     * @default 600
     * @deprecated since 8.15.0
     */
    textureGCCheckCountMax: number;
}
/**
 * System plugin to the renderer to manage texture garbage collection on the GPU,
 * ensuring that it does not get clogged up with textures that are no longer being used.
 * @category rendering
 * @advanced
 * @deprecated since 8.15.0
 * @see {@link GCSystem}
 */
export declare class TextureGCSystem implements System<TextureGCSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem];
        readonly name: "textureGC";
    };
    /**
     * Default options for the TextureGCSystem
     * @deprecated since 8.15.0
     */
    static defaultOptions: TextureGCSystemOptions;
    /**
     * Frame count since started.
     * @readonly
     * @deprecated since 8.15.0
     */
    get count(): number;
    /**
     * Frame count since last garbage collection.
     * @readonly
     * @deprecated since 8.15.0
     */
    get checkCount(): number;
    set checkCount(value: number);
    private _checkCount;
    /**
     * Maximum idle frames before a texture is destroyed by garbage collection.
     * @see TextureGCSystem.defaultMaxIdle
     * @deprecated since 8.15.0
     */
    get maxIdle(): number;
    set maxIdle(value: number);
    /**
     * Frames between two garbage collections.
     * @see TextureGCSystem.defaultCheckCountMax
     * @deprecated since 8.15.0
     */
    get checkCountMax(): number;
    set checkCountMax(_value: number);
    /**
     * Current garbage collection mode.
     * @see TextureGCSystem.defaultMode
     * @deprecated since 8.15.0
     */
    get active(): boolean;
    set active(value: boolean);
    private _renderer;
    /** @param renderer - The renderer this System works for. */
    constructor(renderer: Renderer);
    init(options: TextureGCSystemOptions): void;
    /**
     * Checks to see when the last time a texture was used.
     * If the texture has not been used for a specified amount of time, it will be removed from the GPU.
     * @deprecated since 8.15.0
     */
    run(): void;
    destroy(): void;
}
