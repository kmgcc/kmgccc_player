import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from '../shared/system/System';
import type { WebGPURenderer } from './WebGPURenderer';
/**
 * The system that handles color masking for the GPU.
 * @category rendering
 * @advanced
 */
export declare class GpuColorMaskSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUSystem];
        readonly name: "colorMask";
    };
    private readonly _renderer;
    private _colorMaskCache;
    constructor(renderer: WebGPURenderer);
    setMask(colorMask: number): void;
    destroy(): void;
}
