import { ExtensionType } from '../../../extensions/Extensions';
import type { Topology } from '../shared/geometry/const';
import type { Geometry } from '../shared/geometry/Geometry';
import type { Shader } from '../shared/shader/Shader';
import type { State } from '../shared/state/State';
import type { System } from '../shared/system/System';
import type { WebGLRenderer } from './WebGLRenderer';
/**
 * The system that handles encoding commands for the WebGL.
 * @category rendering
 * @advanced
 */
export declare class GlEncoderSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "encoder";
    };
    readonly commandFinished: Promise<void>;
    private readonly _renderer;
    constructor(renderer: WebGLRenderer);
    setGeometry(geometry: Geometry, shader?: Shader): void;
    finishRenderPass(): void;
    draw(options: {
        geometry: Geometry;
        shader: Shader;
        state?: State;
        topology?: Topology;
        size?: number;
        start?: number;
        instanceCount?: number;
        skipSync?: boolean;
    }): void;
    destroy(): void;
}
