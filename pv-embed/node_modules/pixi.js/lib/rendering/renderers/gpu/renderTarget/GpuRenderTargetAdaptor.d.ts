import { TextureSource } from '../../shared/texture/sources/TextureSource';
import { GpuRenderTarget } from './GpuRenderTarget';
import type { RgbaArray } from '../../../../color/Color';
import type { Rectangle } from '../../../../maths/shapes/Rectangle';
import type { CLEAR_OR_BOOL } from '../../gl/const';
import type { RenderTarget } from '../../shared/renderTarget/RenderTarget';
import type { RenderTargetAdaptor, RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem';
import type { Texture } from '../../shared/texture/Texture';
import type { WebGPURenderer } from '../WebGPURenderer';
/**
 * The WebGPU adaptor for the render target system. Allows the Render Target System to
 * be used with the WebGPU renderer
 * @category rendering
 * @ignore
 */
export declare class GpuRenderTargetAdaptor implements RenderTargetAdaptor<GpuRenderTarget> {
    private _renderTargetSystem;
    private _renderer;
    init(renderer: WebGPURenderer, renderTargetSystem: RenderTargetSystem<GpuRenderTarget>): void;
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
    startRenderPass(renderTarget: RenderTarget, clear?: CLEAR_OR_BOOL, clearColor?: RgbaArray, viewport?: Rectangle, mipLevel?: number, layer?: number): void;
    finishRenderPass(): void;
    /**
     * returns the gpu texture for the first color texture in the render target
     * mainly used by the filter manager to get copy the texture for blending
     * @param renderTarget
     * @returns a gpu texture
     */
    private _getGpuColorTexture;
    getDescriptor(renderTarget: RenderTarget, clear: CLEAR_OR_BOOL, clearValue: RgbaArray, mipLevel?: number, layer?: number): GPURenderPassDescriptor;
    clear(renderTarget: RenderTarget, clear?: CLEAR_OR_BOOL, clearColor?: RgbaArray, viewport?: Rectangle, mipLevel?: number, layer?: number): void;
    initGpuRenderTarget(renderTarget: RenderTarget): GpuRenderTarget;
    destroyGpuRenderTarget(gpuRenderTarget: GpuRenderTarget): void;
    ensureDepthStencilTexture(renderTarget: RenderTarget): void;
    resizeGpuRenderTarget(renderTarget: RenderTarget): void;
}
