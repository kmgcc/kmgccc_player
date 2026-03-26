import { ExtensionType } from '../../../extensions/Extensions';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { Renderer } from '../../../rendering/renderers/types';
import type { Graphics } from '../shared/Graphics';
import type { GraphicsAdaptor, GraphicsPipeLike } from '../shared/GraphicsPipe';
/**
 * A GraphicsAdaptor that uses Canvas2D to render graphics.
 * @category rendering
 * @ignore
 */
export declare class CanvasGraphicsAdaptor implements GraphicsAdaptor {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasPipesAdaptor];
        readonly name: "graphics";
    };
    shader: Shader;
    contextChange(renderer: Renderer): void;
    execute(graphicsPipe: GraphicsPipeLike, renderable: Graphics): void;
    destroy(): void;
}
