import { ExtensionType } from '../../../extensions/Extensions';
import { AbstractTextSystem } from '../shared/AbstractTextSystem';
import type { Renderer } from '../../../rendering/renderers/types';
/**
 * System plugin to the renderer to manage canvas text for Canvas2D.
 * @category rendering
 * @advanced
 */
export declare class CanvasRendererTextSystem extends AbstractTextSystem {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "canvasText";
    };
    constructor(renderer: Renderer);
}
