import { ExtensionType } from '../../../extensions/Extensions';
import type { Mesh } from '../shared/Mesh';
import type { MeshAdaptor, MeshPipe } from '../shared/MeshPipe';
/**
 * A MeshAdaptor that uses the WebGL to render meshes.
 * @category rendering
 * @ignore
 */
export declare class GlMeshAdaptor implements MeshAdaptor {
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipesAdaptor];
        readonly name: "mesh";
    };
    private _shader;
    init(): void;
    execute(meshPipe: MeshPipe, mesh: Mesh): void;
    destroy(): void;
}
