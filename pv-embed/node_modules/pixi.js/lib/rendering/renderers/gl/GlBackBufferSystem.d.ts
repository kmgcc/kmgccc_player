import { ExtensionType } from '../../../extensions/Extensions';
import type { RenderOptions } from '../shared/system/AbstractRenderer';
import type { System } from '../shared/system/System';
import type { WebGLRenderer } from './WebGLRenderer';
/**
 * The options for the back buffer system.
 * @category rendering
 * @property {boolean} [useBackBuffer=false] - if true will use the back buffer where required
 * @property {boolean} [antialias=false] - if true will ensure the texture is antialiased
 * @advanced
 */
export interface GlBackBufferOptions {
    /**
     * if true will use the back buffer where required
     * @default false
     */
    useBackBuffer?: boolean;
    /** if true will ensure the texture is antialiased */
    antialias?: boolean;
}
/**
 * For blend modes you need to know what pixels you are actually drawing to. For this to be possible in WebGL
 * we need to render to a texture and then present that texture to the screen. This system manages that process.
 *
 * As the main scene is rendered to a texture, it means we can sample it and copy its pixels,
 * something not possible on the main canvas.
 *
 * If antialiasing is set to to true and useBackBuffer is set to true, then the back buffer will be antialiased.
 * and the main gl context will not.
 *
 * You only need to activate this back buffer if you are using a blend mode that requires it.
 *
 * to activate is simple, you pass `useBackBuffer:true` to your render options
 * @category rendering
 * @advanced
 */
export declare class GlBackBufferSystem implements System<GlBackBufferOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "backBuffer";
        readonly priority: 1;
    };
    /** default options for the back buffer system */
    static defaultOptions: GlBackBufferOptions;
    /** if true, the back buffer is used */
    useBackBuffer: boolean;
    private _backBufferTexture;
    private readonly _renderer;
    private _targetTexture;
    private _useBackBufferThisRender;
    private _antialias;
    private _state;
    private _bigTriangleShader;
    constructor(renderer: WebGLRenderer);
    init(options?: GlBackBufferOptions): void;
    /**
     * This is called before the RenderTargetSystem is started. This is where
     * we replace the target with the back buffer if required.
     * @param options - The options for this render.
     */
    protected renderStart(options: RenderOptions): void;
    protected renderEnd(): void;
    private _presentBackBuffer;
    private _getBackBufferTexture;
    /** destroys the back buffer */
    destroy(): void;
}
