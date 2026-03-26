import { ExtensionType } from '../../../extensions/Extensions';
import { AbstractTextSystem } from './AbstractTextSystem';
import type { Renderer } from '../../../rendering/renderers/types';
/**
 * System plugin to the renderer to manage canvas text for GPU renderers.
 * @category rendering
 * @advanced
 */
export declare class CanvasTextSystem extends AbstractTextSystem {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem];
        readonly name: "canvasText";
    };
    constructor(renderer: Renderer);
}
