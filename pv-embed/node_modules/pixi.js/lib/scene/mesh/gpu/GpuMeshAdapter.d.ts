import { ExtensionType } from '../../../extensions/Extensions';
import type { Mesh } from '../shared/Mesh';
import type { MeshAdaptor, MeshPipe } from '../shared/MeshPipe';
/**
 * The WebGL adaptor for the mesh system. Allows the Mesh System to be used with the WebGl renderer
 * @category rendering
 * @ignore
 */
export declare class GpuMeshAdapter implements MeshAdaptor {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGPUPipesAdaptor];
        readonly name: "mesh";
    };
    private _shader;
    init(): void;
    execute(meshPipe: MeshPipe, mesh: Mesh): void;
    destroy(): void;
}
