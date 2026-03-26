import { ExtensionType } from '../../../extensions/Extensions';
import { STENCIL_MODES } from '../shared/state/const';
import type { RenderTarget } from '../shared/renderTarget/RenderTarget';
import type { System } from '../shared/system/System';
import type { WebGLRenderer } from './WebGLRenderer';
/**
 * This manages the stencil buffer. Used primarily for masking
 * @category rendering
 * @advanced
 */
export declare class GlStencilSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "stencil";
    };
    private _gl;
    private readonly _stencilCache;
    private _renderTargetStencilState;
    private _stencilOpsMapping;
    private _comparisonFuncMapping;
    private _activeRenderTarget;
    constructor(renderer: WebGLRenderer);
    protected contextChange(gl: WebGLRenderingContext): void;
    protected onRenderTargetChange(renderTarget: RenderTarget): void;
    resetState(): void;
    setStencilMode(stencilMode: STENCIL_MODES, stencilReference: number): void;
    destroy?: () => void;
}
