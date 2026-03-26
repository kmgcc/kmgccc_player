import { ExtensionType } from '../../../../extensions/Extensions';
import { type GpuPowerPreference } from '../../types';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { System } from '../../shared/system/System';
import type { WebGLRenderer } from '../WebGLRenderer';
import type { WebGLExtensions } from './WebGLExtensions';
/**
 * Options for the context system.
 * @category rendering
 * @advanced
 * @property {WebGL2RenderingContext | null} [context=null] - User-provided WebGL rendering context object.
 * @property {GpuPowerPreference} [powerPreference='default'] - An optional hint indicating what configuration
 * of GPU is suitable for the WebGL context, can be `'high-performance'` or `'low-power'`. Setting to `'high-performance'`
 * will prioritize rendering performance over power consumption, while setting to `'low-power'` will prioritize power saving
 * over rendering performance.
 * @property {boolean} [premultipliedAlpha=true] - Whether the compositor will assume the drawing buffer contains
 * colors with premultiplied alpha.
 * @property {boolean} [preserveDrawingBuffer=false] - Whether to enable drawing buffer preservation.
 * If enabled, the drawing buffer will preserve
 * its value until cleared or overwritten. Enable this if you need to call `toDataUrl` on the WebGL context.
 * @property {boolean} [antialias] - Whether to enable antialiasing.
 * @property {1 | 2} [preferWebGLVersion=2] - The preferred WebGL version to use.
 */
export interface ContextSystemOptions {
    /**
     * User-provided WebGL rendering context object.
     * @default null
     */
    context: WebGL2RenderingContext | null;
    /**
     * An optional hint indicating what configuration of GPU is suitable for the WebGL context,
     * can be `'high-performance'` or `'low-power'`.
     * Setting to `'high-performance'` will prioritize rendering performance over power consumption,
     * while setting to `'low-power'` will prioritize power saving over rendering performance.
     * @default undefined
     */
    powerPreference?: GpuPowerPreference;
    /**
     * Whether the compositor will assume the drawing buffer contains colors with premultiplied alpha.
     * @default true
     */
    premultipliedAlpha: boolean;
    /**
     * Whether to enable drawing buffer preservation. If enabled, the drawing buffer will preserve
     * its value until cleared or overwritten. Enable this if you need to call `toDataUrl` on the WebGL context.
     * @default false
     */
    preserveDrawingBuffer: boolean;
    antialias?: boolean;
    /**
     * The preferred WebGL version to use.
     * @default 2
     */
    preferWebGLVersion?: 1 | 2;
    /**
     * Whether to enable multi-view rendering. Set to true when rendering to multiple
     * canvases on the dom.
     * @default false
     */
    multiView: boolean;
}
/**
 * System plugin to the renderer to manage the context
 * @category rendering
 * @advanced
 */
export declare class GlContextSystem implements System<ContextSystemOptions> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "context";
    };
    /** The default options for the system. */
    static defaultOptions: ContextSystemOptions;
    protected CONTEXT_UID: number;
    protected gl: WebGL2RenderingContext;
    /**
     * Features supported by current renderer.
     * @type {object}
     * @readonly
     */
    supports: {
        /** Support for 32-bit indices buffer. */
        uint32Indices: boolean;
        /** Support for UniformBufferObjects */
        uniformBufferObject: boolean;
        /** Support for VertexArrayObjects */
        vertexArrayObject: boolean;
        /** Support for SRGB texture format */
        srgbTextures: boolean;
        /** Support for wrapping modes if a texture is non-power of two */
        nonPowOf2wrapping: boolean;
        /** Support for MSAA (antialiasing of dynamic textures) */
        msaa: boolean;
        /** Support for mipmaps if a texture is non-power of two */
        nonPowOf2mipmaps: boolean;
    };
    /**
     * Extensions available.
     * @type {object}
     * @readonly
     * @property {WEBGL_draw_buffers} drawBuffers - WebGL v1 extension
     * @property {WEBGL_depth_texture} depthTexture - WebGL v1 extension
     * @property {OES_texture_float} floatTexture - WebGL v1 extension
     * @property {WEBGL_lose_context} loseContext - WebGL v1 extension
     * @property {OES_vertex_array_object} vertexArrayObject - WebGL v1 extension
     * @property {EXT_texture_filter_anisotropic} anisotropicFiltering - WebGL v1 and v2 extension
     */
    extensions: WebGLExtensions;
    webGLVersion: 1 | 2;
    /**
     * Whether to enable multi-view rendering. Set to true when rendering to multiple
     * canvases on the dom.
     * @default false
     */
    multiView: boolean;
    /**
     * The canvas that the WebGL Context is rendering to.
     * This will be the view canvas. But if multiView is enabled, this canvas will not be attached to the DOM.
     * It will be rendered to and then copied to the target canvas.
     * @readonly
     */
    canvas: ICanvas;
    private _renderer;
    private _contextLossForced;
    /** @param renderer - The renderer this System works for. */
    constructor(renderer: WebGLRenderer);
    /**
     * `true` if the context is lost
     * @readonly
     */
    get isLost(): boolean;
    /**
     * Handles the context change event.
     * @param {WebGLRenderingContext} gl - New WebGL context.
     */
    protected contextChange(gl: WebGL2RenderingContext): void;
    init(options: ContextSystemOptions): void;
    ensureCanvasSize(targetCanvas: ICanvas): void;
    /**
     * Initializes the context.
     * @protected
     * @param {WebGLRenderingContext} gl - WebGL context
     */
    protected initFromContext(gl: WebGL2RenderingContext): void;
    /**
     * Initialize from context options
     * @protected
     * @see https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/getContext
     * @param preferWebGLVersion
     * @param {object} options - context attributes
     */
    protected createContext(preferWebGLVersion: 1 | 2, options: WebGLContextAttributes): void;
    /** Auto-populate the {@link GlContextSystem.extensions extensions}. */
    protected getExtensions(): void;
    /**
     * Handles a lost webgl context
     * @param {WebGLContextEvent} event - The context lost event.
     */
    protected handleContextLost(event: WebGLContextEvent): void;
    /** Handles a restored webgl context. */
    protected handleContextRestored(): void;
    destroy(): void;
    /**
     * this function can be called to force a webGL context loss
     * this will release all resources on the GPU.
     * Useful if you need to put Pixi to sleep, and save some GPU memory
     *
     * As soon as render is called - all resources will be created again.
     */
    forceContextLoss(): void;
    /**
     * Validate context.
     * @param {WebGLRenderingContext} gl - Render context.
     */
    protected validateContext(gl: WebGL2RenderingContext): void;
}
