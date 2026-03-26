/**
 * The stencil state for the GPU renderer.
 * This is used to define how the stencil buffer should be configured.
 * @category rendering
 * @advanced
 */
export interface StencilState {
    stencilWriteMask?: number;
    stencilReadMask?: number;
    stencilFront?: {
        compare: 'always' | 'equal' | 'not-equal';
        passOp: 'increment-clamp' | 'decrement-clamp' | 'keep' | 'replace';
    };
    stencilBack?: {
        compare: 'always' | 'equal' | 'not-equal';
        passOp: 'increment-clamp' | 'decrement-clamp' | 'keep' | 'replace';
    };
}
/** @internal */
export declare const GpuStencilModesToPixi: StencilState[];
