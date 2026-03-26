import { ExtensionType } from '../../extensions/Extensions';
import { Matrix } from '../../maths/matrix/Matrix';
import type { System } from '../../rendering/renderers/shared/system/System';
import type { Renderer } from '../../rendering/renderers/types';
import type { Container } from './Container';
/**
 * The view system manages the main canvas that is attached to the DOM.
 * This main role is to deal with how the holding the view reference and dealing with how it is resized.
 * @category rendering
 * @internal
 */
export declare class RenderGroupSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "renderGroup";
    };
    private readonly _renderer;
    constructor(renderer: Renderer);
    protected render({ container, transform }: {
        container: Container;
        transform: Matrix;
    }): void;
    destroy(): void;
    private _updateCachedRenderGroups;
    private _updateRenderGroups;
    private _updateRenderables;
    /**
     * @param renderGroup
     * @param renderPipes
     * @deprecated since 8.3.0
     */
    private _buildInstructions;
}
