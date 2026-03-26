import { ExtensionType } from '../../../extensions/Extensions';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import { type Renderer } from '../../../rendering/renderers/types';
import type { Graphics } from '../shared/Graphics';
import type { GraphicsAdaptor, GraphicsPipeLike } from '../shared/GraphicsPipe';
/**
 * A GraphicsAdaptor that uses WebGL to render graphics.
 * @category rendering
 * @ignore
 */
export declare class GlGraphicsAdaptor implements GraphicsAdaptor {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipesAdaptor];
        readonly name: "graphics";
    };
    shader: Shader;
    contextChange(renderer: Renderer): void;
    execute(graphicsPipe: GraphicsPipeLike, renderable: Graphics): void;
    destroy(): void;
}
