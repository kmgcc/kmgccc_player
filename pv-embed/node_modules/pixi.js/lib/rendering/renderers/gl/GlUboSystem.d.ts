import { ExtensionType } from '../../../extensions/Extensions';
import { UboSystem } from '../shared/shader/UboSystem';
/**
 * System plugin to the renderer to manage uniform buffers. But with an WGSL adaptor.
 * @category rendering
 * @advanced
 */
export declare class GlUboSystem extends UboSystem {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "ubo";
    };
    constructor();
}
