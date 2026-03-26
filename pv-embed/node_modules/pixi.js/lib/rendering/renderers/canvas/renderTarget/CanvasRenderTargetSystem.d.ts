import { ExtensionType } from '../../../../extensions/Extensions';
import { RenderTargetSystem } from '../../shared/renderTarget/RenderTargetSystem';
import { type CanvasRenderTarget, CanvasRenderTargetAdaptor } from './CanvasRenderTargetAdaptor';
import type { CanvasRenderer } from '../CanvasRenderer';
/**
 * The Canvas adaptor for the render target system.
 * @category rendering
 * @advanced
 */
export declare class CanvasRenderTargetSystem extends RenderTargetSystem<CanvasRenderTarget> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "renderTarget";
    };
    adaptor: CanvasRenderTargetAdaptor;
    constructor(renderer: CanvasRenderer);
}
