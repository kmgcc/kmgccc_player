import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from '../shared/system/System';
/**
 * Basic limits for CanvasRenderer.
 * @category rendering
 * @advanced
 */
export declare class CanvasLimitsSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "limits";
    };
    maxTextures: number;
    maxBatchableTextures: number;
    maxUniformBindings: number;
    init(): void;
}
