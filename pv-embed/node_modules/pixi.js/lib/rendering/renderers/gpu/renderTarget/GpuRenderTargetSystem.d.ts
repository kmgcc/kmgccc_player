import { ExtensionType } from '../../../../extensions/Extensions';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem';
import { GpuRenderTargetAdaptor } from './GpuRenderTargetAdaptor';
import type { WebGPURenderer } from '../WebGPURenderer';
import type { GpuRenderTarget } from './GpuRenderTarget';
/**
 * The WebGL adaptor for the render target system. Allows the Render Target System to be used with the WebGl renderer
 * @category rendering
 * @advanced
 */
export declare class GpuRenderTargetSystem extends RenderTargetSystem<GpuRenderTarget> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "renderTarget";
    };
    adaptor: GpuRenderTargetAdaptor;
    constructor(renderer: WebGPURenderer);
}
