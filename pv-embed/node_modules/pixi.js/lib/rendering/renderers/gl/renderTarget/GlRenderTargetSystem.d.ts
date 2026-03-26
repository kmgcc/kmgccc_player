import { ExtensionType } from '../../../../extensions/Extensions';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem';
import { GlRenderTargetAdaptor } from './GlRenderTargetAdaptor';
import type { GlRenderTarget } from '../GlRenderTarget';
import type { WebGLRenderer } from '../WebGLRenderer';
/**
 * The WebGL adaptor for the render target system. Allows the Render Target System to be used with the WebGl renderer
 * @category rendering
 * @advanced
 */
export declare class GlRenderTargetSystem extends RenderTargetSystem<GlRenderTarget> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "renderTarget";
    };
    adaptor: GlRenderTargetAdaptor;
    constructor(renderer: WebGLRenderer);
}
