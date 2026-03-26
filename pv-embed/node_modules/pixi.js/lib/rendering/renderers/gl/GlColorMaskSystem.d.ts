import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from '../shared/system/System';
import type { WebGLRenderer } from './WebGLRenderer';
/**
 * The system that handles color masking for the WebGL.
 * @category rendering
 * @advanced
 */
export declare class GlColorMaskSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "colorMask";
    };
    private readonly _renderer;
    private _colorMaskCache;
    constructor(renderer: WebGLRenderer);
    setMask(colorMask: number): void;
    destroy?: () => void;
}
