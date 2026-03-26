import { Container } from '../../../../scene/container/Container';
import { EventEmitter } from '../../../../utils/utils';
import { SystemRunner } from './SystemRunner';
import type { ColorSource } from '../../../../color/Color';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { Matrix } from '../../../../maths/matrix/Matrix';
import type { Rectangle } from '../../../../maths/shapes/Rectangle';
import type { TypeOrBool } from '../../../../scene/container/destroyTypes';
import type { CLEAR_OR_BOOL } from '../../gl/const';
import type { BackgroundSystem } from '../background/BackgroundSystem';
import type { GenerateTextureOptions, GenerateTextureSystem } from '../extract/GenerateTextureSystem';
import type { PipeConstructor } from '../instructions/RenderPipe';
import type { RenderSurface } from '../renderTarget/RenderTargetSystem';
import type { Texture } from '../texture/Texture';
import type { ViewSystem, ViewSystemDestroyOptions } from '../view/ViewSystem';
import type { SharedRendererOptions } from './SharedSystems';
import type { SystemConstructor } from './System';
/**
 * The configuration for the renderer.
 * This is used to define the systems and render pipes that will be used by the renderer.
 * @category rendering
 * @advanced
 */
export interface RendererConfig {
    type: number;
    name: string;
    runners?: string[];
    systems: {
        name: string;
        value: SystemConstructor;
    }[];
    renderPipes: {
        name: string;
        value: PipeConstructor;
    }[];
    renderPipeAdaptors: {
        name: string;
        value: any;
    }[];
}
/**
 * The options for rendering a view.
 * @category rendering
 * @standard
 */
export interface RenderOptions extends ClearOptions {
    /** The container to render. */
    container: Container;
    /** the transform to apply to the container. */
    transform?: Matrix;
}
/**
 * The options for clearing the render target.
 * @category rendering
 * @advanced
 */
export interface ClearOptions {
    /**
     * The render target to render. if this target is a canvas and  you are using the WebGL renderer,
     * please ensure you have set `multiView` to `true` on renderer.
     */
    target?: RenderSurface;
    /** The color to clear with. */
    clearColor?: ColorSource;
    /** The clear mode to use. */
    clear?: CLEAR_OR_BOOL;
    /**
     * Mip level to render/clear to when the target is a texture-backed render surface.
     * @default 0
     *
     * Note: When rendering to a {@link Texture} target, Pixi renders into the underlying {@link TextureSource}
     * (via an internal {@link RenderTarget}). The texture's `frame` is interpreted in mip 0 space and is scaled/clamped
     * to the requested mip level.
     * @advanced
     */
    mipLevel?: number;
    /**
     * Array layer index to render/clear to when the target is an array-backed texture source (e.g. `arrayLayerCount > 1`).
     *
     * This maps to WebGPU's `GPUTextureViewDescriptor.baseArrayLayer` when creating render-attachment views.
     * @default 0
     * @advanced
     */
    layer?: number;
}
/**
 * Options for destroying the renderer.
 * This can be a boolean or an object.
 * @category rendering
 * @standard
 */
export type RendererDestroyOptions = TypeOrBool<ViewSystemDestroyOptions & {
    /** Whether to clean up global resource pools/caches */
    releaseGlobalResources?: boolean;
}>;
declare const defaultRunners: readonly ["init", "destroy", "contextChange", "resolutionChange", "resetState", "renderEnd", "renderStart", "render", "update", "postrender", "prerender"];
type DefaultRunners = typeof defaultRunners[number];
type Runners = {
    [key in DefaultRunners]: SystemRunner;
} & {
    [K: ({} & string) | ({} & symbol)]: SystemRunner;
};
/**
 * The base class for a PixiJS Renderer. It contains the shared logic for all renderers.
 *
 * You should not use this class directly, but instead use {@link WebGLRenderer}
 * or {@link WebGPURenderer}.
 * Alternatively, you can also use {@link autoDetectRenderer} if you want us to
 * determine the best renderer for you.
 *
 * The renderer is composed of systems that manage specific tasks. The following systems are added by default
 * whenever you create a renderer:
 *
 *
 * | Generic Systems                      | Systems that manage functionality that all renderer types share               |
 * | ------------------------------------ | ----------------------------------------------------------------------------- |
 * | {@link ViewSystem}              | This manages the main view of the renderer usually a Canvas              |
 * | {@link BackgroundSystem}        | This manages the main views background color and alpha                   |
 * | {@link EventSystem}           | This manages UI events.                                                       |
 * | {@link AccessibilitySystem} | This manages accessibility features. Requires `import 'pixi.js/accessibility'`|
 *
 * | Core Systems                   | Provide an optimised, easy to use API to work with WebGL/WebGPU               |
 * | ------------------------------------ | ----------------------------------------------------------------------------- |
 * | {@link GlobalUniformSystem} | This manages shaders, programs that run on the GPU to calculate 'em pixels.   |
 * | {@link TextureGCSystem}     | This will automatically remove textures from the GPU if they are not used.    |
 *
 * | PixiJS High-Level Systems            | Set of specific systems designed to work with PixiJS objects                  |
 * | ------------------------------------ | ----------------------------------------------------------------------------- |
 * | {@link HelloSystem}               | Says hello, buy printing out the pixi version into the console log (along with the renderer type)       |
 * | {@link GenerateTextureSystem} | This adds the ability to generate textures from any Container       |
 * | {@link FilterSystem}          | This manages the filtering pipeline for post-processing effects.             |
 * | {@link PrepareSystem}               | This manages uploading assets to the GPU. Requires `import 'pixi.js/prepare'`|
 * | {@link ExtractSystem}               | This extracts image data from display objects.                               |
 *
 * The breadth of the API surface provided by the renderer is contained within these systems.
 * @abstract
 * @category rendering
 * @advanced
 * @property {HelloSystem} hello - HelloSystem instance.
 * @property {TextureGCSystem} textureGC - TextureGCSystem instance.
 * @property {FilterSystem} filter - FilterSystem instance.
 * @property {GlobalUniformSystem} globalUniforms - GlobalUniformSystem instance.
 * @property {TextureSystem} texture - TextureSystem instance.
 * @property {EventSystem} events - EventSystem instance.
 * @property {ExtractSystem} extract - ExtractSystem instance. Requires `import 'pixi.js/extract'`.
 * @property {PrepareSystem} prepare - PrepareSystem instance. Requires `import 'pixi.js/prepare'`.
 * @property {AccessibilitySystem} accessibility - AccessibilitySystem instance. Requires `import 'pixi.js/accessibility'`.
 */
export declare class AbstractRenderer<PIPES, OPTIONS extends SharedRendererOptions, CANVAS extends ICanvas = HTMLCanvasElement> extends EventEmitter<{
    resize: [screenWidth: number, screenHeight: number, resolution: number];
}> {
    /** The default options for the renderer. */
    static defaultOptions: {
        /**
         * Default resolution / device pixel ratio of the renderer.
         * @default 1
         */
        resolution: number;
        /**
         * Should the `failIfMajorPerformanceCaveat` flag be enabled as a context option used in the `isWebGLSupported`
         * function. If set to true, a WebGL renderer can fail to be created if the browser thinks there could be
         * performance issues when using WebGL.
         *
         * In PixiJS v6 this has changed from true to false by default, to allow WebGL to work in as many
         * scenarios as possible. However, some users may have a poor experience, for example, if a user has a gpu or
         * driver version blacklisted by the
         * browser.
         *
         * If your application requires high performance rendering, you may wish to set this to false.
         * We recommend one of two options if you decide to set this flag to false:
         *
         * 1: Use the Canvas renderer as a fallback in case high performance WebGL is
         *    not supported.
         *
         * 2: Call `isWebGLSupported` (which if found in the utils package) in your code before attempting to create a
         *    PixiJS renderer, and show an error message to the user if the function returns false, explaining that their
         *    device & browser combination does not support high performance WebGL.
         *    This is a much better strategy than trying to create a PixiJS renderer and finding it then fails.
         * @default false
         */
        failIfMajorPerformanceCaveat: boolean;
        /**
         * Should round pixels be forced when rendering?
         * @default false
         */
        roundPixels: boolean;
    };
    /** @internal */
    readonly type: number;
    /** The name of the renderer. */
    readonly name: string;
    /** The current tick of the renderer. */
    tick: number;
    /** @internal */
    readonly uid: number;
    /** @internal */
    _roundPixels: 0 | 1;
    /** @internal */
    readonly runners: Runners;
    /** @internal */
    readonly renderPipes: PIPES;
    /** The view system manages the main canvas that is attached to the DOM */
    view: ViewSystem;
    /** The background system manages the background color and alpha of the main view. */
    background: BackgroundSystem;
    /** System that manages the generation of textures from the renderer */
    textureGenerator: GenerateTextureSystem;
    protected _initOptions: OPTIONS;
    protected config: RendererConfig;
    private _systemsHash;
    private _lastObjectRendered;
    /**
     * Set up a system with a collection of SystemClasses and runners.
     * Systems are attached dynamically to this class when added.
     * @param config - the config for the system manager
     */
    constructor(config: RendererConfig);
    /**
     * Initialize the renderer.
     * @param options - The options to use to create the renderer.
     */
    init(options?: Partial<OPTIONS>): Promise<void>;
    /**
     * Renders the object to its view.
     * @param options - The options to render with.
     * @param options.container - The container to render.
     * @param [options.target] - The target to render to.
     */
    render(options: RenderOptions | Container): void;
    /** @deprecated since 8.0.0 */
    render(container: Container, options: {
        renderTexture: any;
    }): void;
    /**
     * Resizes the WebGL view to the specified width and height.
     * @param desiredScreenWidth - The desired width of the screen.
     * @param desiredScreenHeight - The desired height of the screen.
     * @param resolution - The resolution / device pixel ratio of the renderer.
     */
    resize(desiredScreenWidth: number, desiredScreenHeight: number, resolution?: number): void;
    /**
     * Clears the render target.
     * @param options - The options to use when clearing the render target.
     * @param options.target - The render target to clear.
     * @param options.clearColor - The color to clear with.
     * @param options.clear - The clear mode to use.
     * @advanced
     */
    clear(options?: ClearOptions): void;
    /** The resolution / device pixel ratio of the renderer. */
    get resolution(): number;
    set resolution(value: number);
    /**
     * Same as view.width, actual number of pixels in the canvas by horizontal.
     * @type {number}
     * @readonly
     * @default 800
     */
    get width(): number;
    /**
     * Same as view.height, actual number of pixels in the canvas by vertical.
     * @default 600
     */
    get height(): number;
    /**
     * The canvas element that everything is drawn to.
     * @type {environment.ICanvas}
     */
    get canvas(): CANVAS;
    /**
     * the last object rendered by the renderer. Useful for other plugins like interaction managers
     * @readonly
     */
    get lastObjectRendered(): Container;
    /**
     * Flag if we are rendering to the screen vs renderTexture
     * @readonly
     * @default true
     */
    get renderingToScreen(): boolean;
    /**
     * Measurements of the screen. (0, 0, screenWidth, screenHeight).
     *
     * Its safe to use as filterArea or hitArea for the whole stage.
     */
    get screen(): Rectangle;
    /**
     * Create a bunch of runners based of a collection of ids
     * @param runnerIds - the runner ids to add
     */
    private _addRunners;
    private _addSystems;
    /**
     * Add a new system to the renderer.
     * @param ClassRef - Class reference
     * @param name - Property name for system, if not specified
     *        will use a static `name` property on the class itself. This
     *        name will be assigned as s property on the Renderer so make
     *        sure it doesn't collide with properties on Renderer.
     * @returns Return instance of renderer
     */
    private _addSystem;
    private _addPipes;
    destroy(options?: RendererDestroyOptions): void;
    /**
     * Generate a texture from a container.
     * @param options - options or container target to use when generating the texture
     * @returns a texture
     */
    generateTexture(options: GenerateTextureOptions | Container): Texture;
    /**
     * Whether the renderer will round coordinates to whole pixels when rendering.
     * Can be overridden on a per scene item basis.
     */
    get roundPixels(): boolean;
    /**
     * Overridable function by `pixi.js/unsafe-eval` to silence
     * throwing an error if platform doesn't support unsafe-evals.
     * @private
     * @ignore
     */
    _unsafeEvalCheck(): void;
    /**
     * Resets the rendering state of the renderer.
     * This is useful when you want to use the WebGL context directly and need to ensure PixiJS's internal state
     * stays synchronized. When modifying the WebGL context state externally, calling this method before the next Pixi
     * render will reset all internal caches and ensure it executes correctly.
     *
     * This is particularly useful when combining PixiJS with other rendering engines like Three.js:
     * ```js
     * // Reset Three.js state
     * threeRenderer.resetState();
     *
     * // Render a Three.js scene
     * threeRenderer.render(threeScene, threeCamera);
     *
     * // Reset PixiJS state since Three.js modified the WebGL context
     * pixiRenderer.resetState();
     *
     * // Now render Pixi content
     * pixiRenderer.render(pixiScene);
     * ```
     * @advanced
     */
    resetState(): void;
}
export {};
