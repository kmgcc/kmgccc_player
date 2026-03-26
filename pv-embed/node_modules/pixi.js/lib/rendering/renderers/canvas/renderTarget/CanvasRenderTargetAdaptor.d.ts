import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { ICanvasRenderingContext2D } from '../../../../environment/canvas/ICanvasRenderingContext2D';
import type { Rectangle } from '../../../../maths/shapes/Rectangle';
import type { CLEAR_OR_BOOL } from '../../gl/const';
import type { RenderTarget } from '../../shared/renderTarget/RenderTarget';
import type { RenderTargetAdaptor, RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem';
import type { Texture } from '../../shared/texture/Texture';
import type { CanvasRenderer } from '../CanvasRenderer';
/**
 * Canvas render target backing store.
 * @internal
 */
export type CanvasRenderTarget = {
    /** Backing canvas element. */
    canvas: ICanvas;
    /** 2D context associated with the canvas. */
    context: ICanvasRenderingContext2D;
    /** Pixel width. */
    width: number;
    /** Pixel height. */
    height: number;
};
/**
 * Canvas adaptor for render targets.
 * @category rendering
 * @advanced
 */
export declare class CanvasRenderTargetAdaptor implements RenderTargetAdaptor<CanvasRenderTarget> {
    private _renderer;
    private _renderTargetSystem;
    /**
     * Initializes the adaptor.
     * @param renderer - Canvas renderer instance.
     * @param renderTargetSystem - The render target system.
     * @advanced
     */
    init(renderer: CanvasRenderer, renderTargetSystem: RenderTargetSystem<CanvasRenderTarget>): void;
    /**
     * Creates a GPU render target for canvas.
     * @param renderTarget - Render target to initialize.
     * @advanced
     */
    initGpuRenderTarget(renderTarget: RenderTarget): CanvasRenderTarget;
    /**
     * Resizes the backing canvas for a render target.
     * @param renderTarget - Render target to resize.
     * @advanced
     */
    resizeGpuRenderTarget(renderTarget: RenderTarget): void;
    /**
     * Starts a render pass on the canvas target.
     * @param renderTarget - Target to render to.
     * @param clear - Clear mode.
     * @param clearColor - Optional clear color.
     * @param viewport - Optional viewport.
     * @advanced
     */
    startRenderPass(renderTarget: RenderTarget, clear: CLEAR_OR_BOOL, clearColor?: number[], viewport?: Rectangle): void;
    /**
     * Clears the render target.
     * @param renderTarget - Target to clear.
     * @param _clear - Clear mode (unused).
     * @param clearColor - Optional clear color.
     * @param viewport - Optional viewport rectangle.
     * @advanced
     */
    clear(renderTarget: RenderTarget, _clear: CLEAR_OR_BOOL, clearColor?: number[], viewport?: Rectangle): void;
    /**
     * Finishes the render pass (no-op for canvas).
     * @advanced
     */
    finishRenderPass(): void;
    /**
     * Copies a render target into a texture source.
     * @param {RenderTarget} sourceRenderSurfaceTexture - Source render target.
     * @param {Texture} destinationTexture - Destination texture.
     * @param {object} originSrc - Source origin.
     * @param {number} originSrc.x - Source x origin.
     * @param {number} originSrc.y - Source y origin.
     * @param {object} size - Copy size.
     * @param {number} size.width - Copy width.
     * @param {number} size.height - Copy height.
     * @param {object} [originDest] - Destination origin.
     * @param {number} originDest.x - Destination x origin.
     * @param {number} originDest.y - Destination y origin.
     * @advanced
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
     * Destroys a GPU render target (no-op for canvas).
     * @param _gpuRenderTarget - Target to destroy.
     * @advanced
     */
    destroyGpuRenderTarget(_gpuRenderTarget: CanvasRenderTarget): void;
    private _ensureCanvas;
}
