import { Matrix } from '../../../../maths/matrix/Matrix';
import { Rectangle } from '../../../../maths/shapes/Rectangle';
import { CLEAR } from '../../gl/const';
import { SystemRunner } from '../system/SystemRunner';
import { TextureSource } from '../texture/sources/TextureSource';
import { Texture } from '../texture/Texture';
import { RenderTarget } from './RenderTarget';
import type { RgbaArray } from '../../../../color/Color';
import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { CanvasRenderTarget } from '../../canvas/renderTarget/CanvasRenderTargetAdaptor';
import type { CLEAR_OR_BOOL } from '../../gl/const';
import type { GlRenderTarget } from '../../gl/GlRenderTarget';
import type { GpuRenderTarget } from '../../gpu/renderTarget/GpuRenderTarget';
import type { Renderer } from '../../types';
import type { System } from '../system/System';
import type { BindableTexture } from '../texture/Texture';
/**
 * A render surface is a texture, canvas, or render target
 * @category rendering
 * @see environment.ICanvas
 * @see Texture
 * @see RenderTarget
 * @advanced
 */
export type RenderSurface = ICanvas | BindableTexture | RenderTarget;
/**
 * An adaptor interface for RenderTargetSystem to support WebGL and WebGPU.
 * This is used internally by the renderer, and is not intended to be used directly.
 * @ignore
 */
type RendererRenderTarget = GlRenderTarget | GpuRenderTarget | CanvasRenderTarget;
/**
 * An adaptor interface for RenderTargetSystem to support WebGL and WebGPU.
 * This is used internally by the renderer, and is not intended to be used directly.
 * @category rendering
 * @ignore
 */
export interface RenderTargetAdaptor<RENDER_TARGET extends RendererRenderTarget> {
    /**
     * Initializes the adaptor.
     * @param {Renderer} renderer - the renderer
     * @param {RenderTargetSystem} renderTargetSystem - the render target system
     */
    init(renderer: Renderer, renderTargetSystem: RenderTargetSystem<RENDER_TARGET>): void;
    /**
     * A function copies the contents of a render surface to a texture
     * @param {RenderTarget} sourceRenderSurfaceTexture - the render surface to copy from
     * @param {Texture} destinationTexture - the texture to copy to
     * @param {object} originSrc - the origin of the copy
     * @param {number} originSrc.x - the x origin of the copy
     * @param {number} originSrc.y - the y origin of the copy
     * @param {object} size - the size of the copy
     * @param {number} size.width - the width of the copy
     * @param {number} size.height - the height of the copy
     * @param {object} originDest - the destination origin (top left to paste from!)
     * @param {number} originDest.x - the x destination origin of the copy
     * @param {number} originDest.y - the y destination origin of the copy
     */
    copyToTexture(sourceRenderSurfaceTexture: RenderTarget, destinationTexture: Texture, originSrc: {
        x: number;
        y: number;
    }, size: {
        width: number;
        height: number;
    }, originDest?: {
        x: number;
        y: number;
    }): Texture;
    /**
     * starts a render pass on the render target
     * @param {RenderTarget} renderTarget - the render target to start the render pass on
     * @param {CLEAR_OR_BOOL} clear - the clear mode to use. Can be true or a CLEAR number 'COLOR | DEPTH | STENCIL' 0b111*
     * @param {RgbaArray} [clearColor] - the color to clear to
     * @param {Rectangle} [viewport] - the viewport to use
     */
    startRenderPass(renderTarget: RenderTarget, clear: CLEAR_OR_BOOL, clearColor?: RgbaArray, 
    /** the viewport to use */
    viewport?: Rectangle, 
    /** mip level to render to (subresource) */
    mipLevel?: number, 
    /** array layer to render to (subresource) */
    layer?: number): void;
    /**
     * clears the current render target to the specified color
     * @param {RenderTarget} renderTarget - the render target to clear
     * @param {CLEAR_OR_BOOL} clear - the clear mode to use. Can be true or a CLEAR number 'COLOR | DEPTH | STENCIL' 0b111*
     * @param {RgbaArray} [clearColor] - the color to clear to
     * @param {Rectangle} [viewport] - the viewport to use
     */
    clear(renderTarget: RenderTarget, clear: CLEAR_OR_BOOL, clearColor?: RgbaArray, 
    /** the viewport to use */
    viewport?: Rectangle, 
    /** mip level to clear (subresource) */
    mipLevel?: number, 
    /** array layer to clear (subresource) */
    layer?: number): void;
    /**
     * finishes the current render pass
     * @param {RenderTarget} renderTarget - the render target to finish the render pass for
     */
    finishRenderPass(renderTarget: RenderTarget): void;
    /**
     * called after the render pass is finished
     * @param {RenderTarget} renderTarget - the render target that was rendered to
     */
    postrender?(renderTarget: RenderTarget): void;
    /**
     * called before the render main pass is started
     * @param {RenderTarget} renderTarget - the render target that will be rendered to
     */
    prerender?(renderTarget: RenderTarget): void;
    /**
     * initializes a gpu render target
     * @param {RenderTarget} renderTarget - the render target to initialize
     */
    initGpuRenderTarget(renderTarget: RenderTarget): RENDER_TARGET;
    /**
     * resizes the gpu render target
     * @param {RenderTarget} renderTarget - the render target to resize
     */
    resizeGpuRenderTarget(renderTarget: RenderTarget): void;
    /**
     * destroys the gpu render target
     * @param {RendererRenderTarget} gpuRenderTarget - the gpu render target to destroy
     */
    destroyGpuRenderTarget(gpuRenderTarget: RENDER_TARGET): void;
}
/**
 * A system that manages render targets. A render target is essentially a place where the shaders can color in the pixels.
 * The render target system is responsible for binding the render target to the renderer, and managing the viewport.
 * Render targets can be pushed and popped.
 *
 * To make it easier, you can also bind textures and canvases too. This will automatically create a render target for you.
 * The render target itself is a lot more powerful than just a texture or canvas,
 * as it can have multiple textures attached to it.
 * It will also give ou fine grain control over the stencil buffer / depth texture.
 * @example
 *
 * ```js
 *
 * // create a render target
 * const renderTarget = new RenderTarget({
 *   colorTextures: [new TextureSource({ width: 100, height: 100 })],
 * });
 *
 * // bind the render target
 * renderer.renderTarget.bind(renderTarget);
 *
 * // draw something!
 * ```
 * @category rendering
 * @advanced
 */
export declare class RenderTargetSystem<RENDER_TARGET extends RendererRenderTarget> implements System {
    /** When rendering of a scene begins, this is where the root render surface is stored */
    rootRenderTarget: RenderTarget;
    /** This is the root viewport for the render pass */
    rootViewPort: Rectangle;
    /** A boolean that lets the dev know if the current render pass is rendering to the screen. Used by some plugins */
    renderingToScreen: boolean;
    /** the current active render target */
    renderTarget: RenderTarget;
    /** the current active render surface that the render target is created from */
    renderSurface: RenderSurface;
    /** the current viewport that the gpu is using */
    readonly viewport: Rectangle;
    /** the current mip level being rendered to (for texture subresources) */
    mipLevel: number;
    /** the current array layer being rendered to (for array-backed targets) */
    layer: number;
    /**
     * a runner that lets systems know if the active render target has changed.
     * Eg the Stencil System needs to know so it can manage the stencil buffer
     */
    readonly onRenderTargetChange: SystemRunner;
    /** the projection matrix that is used by the shaders based on the active render target and the viewport */
    readonly projectionMatrix: Matrix;
    /** the default clear color for render targets */
    readonly defaultClearColor: RgbaArray;
    /** a reference to the adaptor that interfaces with WebGL / WebGP */
    readonly adaptor: RenderTargetAdaptor<RENDER_TARGET>;
    /**
     * a hash that stores the render target for a given render surface. When you pass in a texture source,
     * a render target is created for it. This map stores and makes it easy to retrieve the render target
     */
    private readonly _renderSurfaceToRenderTargetHash;
    /** A hash that stores a gpu render target for a given render target. */
    private _gpuRenderTargetHash;
    /**
     * A stack that stores the render target and frame that is currently being rendered to.
     * When push is called, the current render target is stored in this stack.
     * When pop is called, the previous render target is restored.
     */
    private readonly _renderTargetStack;
    /** A reference to the renderer */
    private readonly _renderer;
    constructor(renderer: Renderer);
    /** called when dev wants to finish a render pass */
    finishRenderPass(): void;
    /**
     * called when the renderer starts to render a scene.
     * @param options
     * @param options.target - the render target to render to
     * @param options.clear - the clear mode to use. Can be true or a CLEAR number 'COLOR | DEPTH | STENCIL' 0b111
     * @param options.clearColor - the color to clear to
     * @param options.frame - the frame to render to
     * @param options.mipLevel - the mip level to render to
     * @param options.layer - The layer of the render target to render to. Used for array or 3D textures, or when rendering
     * to a specific layer of a layered render target. Optional.
     */
    renderStart({ target, clear, clearColor, frame, mipLevel, layer }: {
        target: RenderSurface;
        clear: CLEAR_OR_BOOL;
        clearColor: RgbaArray;
        frame?: Rectangle;
        mipLevel?: number;
        layer?: number;
    }): void;
    postrender(): void;
    /**
     * Binding a render surface! This is the main function of the render target system.
     * It will take the RenderSurface (which can be a texture, canvas, or render target) and bind it to the renderer.
     * Once bound all draw calls will be rendered to the render surface.
     *
     * If a frame is not provided and the render surface is a {@link Texture}, the frame of the texture will be used.
     *
     * IMPORTANT:
     * - `frame` is treated as **base mip (mip 0) pixel space**.
     * - When `mipLevel > 0`, the viewport derived from `frame` is scaled by \(2^{mipLevel}\) and clamped to the
     *   mip dimensions. This keeps "render the same region" semantics consistent across mip levels.
     * - When `renderSurface` is a {@link Texture}, `renderer.render({ container, target: texture, mipLevel })` will
     *   render into
     *   the underlying {@link TextureSource} (Pixi will create/use a {@link RenderTarget} for the source) using the
     *   texture's frame to define the region (in mip 0 space).
     * @param renderSurface - the render surface to bind
     * @param clear - the clear mode to use. Can be true or a CLEAR number 'COLOR | DEPTH | STENCIL' 0b111
     * @param clearColor - the color to clear to
     * @param frame - the frame to render to
     * @param mipLevel - the mip level to render to
     * @param layer - the layer (or slice) of the render surface to render to. For array textures,
     * 3D textures, or cubemaps, this specifies the target layer or face. Defaults to 0 (the first layer/face).
     * Ignored for surfaces that do not support layers.
     * @returns the render target that was bound
     */
    bind(renderSurface: RenderSurface, clear?: CLEAR_OR_BOOL, clearColor?: RgbaArray, frame?: Rectangle, mipLevel?: number, layer?: number): RenderTarget;
    clear(target?: RenderSurface, clear?: CLEAR_OR_BOOL, clearColor?: RgbaArray, mipLevel?: number, layer?: number): void;
    protected contextChange(): void;
    /**
     * Push a render surface to the renderer. This will bind the render surface to the renderer,
     * @param renderSurface - the render surface to push
     * @param clear - the clear mode to use. Can be true or a CLEAR number 'COLOR | DEPTH | STENCIL' 0b111
     * @param clearColor - the color to clear to
     * @param frame - the frame to use when rendering to the render surface
     * @param mipLevel - the mip level to render to
     * @param layer - The layer of the render surface to render to. For array textures or cube maps, this specifies
     * which layer or face to target. Defaults to 0 (the first layer).
     */
    push(renderSurface: RenderSurface, clear?: CLEAR | boolean, clearColor?: RgbaArray, frame?: Rectangle, mipLevel?: number, layer?: number): RenderTarget;
    /** Pops the current render target from the renderer and restores the previous render target. */
    pop(): void;
    /**
     * Gets the render target from the provide render surface. Eg if its a texture,
     * it will return the render target for the texture.
     * If its a render target, it will return the same render target.
     * @param renderSurface - the render surface to get the render target for
     * @returns the render target for the render surface
     */
    getRenderTarget(renderSurface: RenderSurface): RenderTarget;
    /**
     * Copies a render surface to another texture.
     *
     * NOTE:
     * for sourceRenderSurfaceTexture, The render target must be something that is written too by the renderer
     *
     * The following is not valid:
     * @example
     * const canvas = document.createElement('canvas')
     * canvas.width = 200;
     * canvas.height = 200;
     *
     * const ctx = canvas2.getContext('2d')!
     * ctx.fillStyle = 'red'
     * ctx.fillRect(0, 0, 200, 200);
     *
     * const texture = RenderTexture.create({
     *   width: 200,
     *   height: 200,
     * })
     * const renderTarget = renderer.renderTarget.getRenderTarget(canvas2);
     *
     * renderer.renderTarget.copyToTexture(renderTarget,texture, {x:0,y:0},{width:200,height:200},{x:0,y:0});
     *
     * The best way to copy a canvas is to create a texture from it. Then render with that.
     *
     * Parsing in a RenderTarget canvas context (with a 2d context)
     * @param sourceRenderSurfaceTexture - the render surface to copy from
     * @param {Texture} destinationTexture - the texture to copy to
     * @param {object} originSrc - the origin of the copy
     * @param {number} originSrc.x - the x origin of the copy
     * @param {number} originSrc.y - the y origin of the copy
     * @param {object} size - the size of the copy
     * @param {number} size.width - the width of the copy
     * @param {number} size.height - the height of the copy
     * @param {object} originDest - the destination origin (top left to paste from!)
     * @param {number} originDest.x - the x origin of the paste
     * @param {number} originDest.y - the y origin of the paste
     */
    copyToTexture(sourceRenderSurfaceTexture: RenderTarget, destinationTexture: Texture, originSrc: {
        x: number;
        y: number;
    }, size: {
        width: number;
        height: number;
    }, originDest: {
        x: number;
        y: number;
    }): Texture<TextureSource<any>>;
    /**
     * ensures that we have a depth stencil buffer available to render to
     * This is used by the mask system to make sure we have a stencil buffer.
     */
    ensureDepthStencil(): void;
    /** nukes the render target system */
    destroy(): void;
    private _initRenderTarget;
    getGpuRenderTarget(renderTarget: RenderTarget): RENDER_TARGET;
    resetState(): void;
}
export {};
