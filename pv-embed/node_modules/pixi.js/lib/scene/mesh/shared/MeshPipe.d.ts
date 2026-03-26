import { ExtensionType } from '../../../extensions/Extensions';
import { Matrix } from '../../../maths/matrix/Matrix';
import { BindGroup } from '../../../rendering/renderers/gpu/shader/BindGroup';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup';
import { type GPUData } from '../../view/ViewContainer';
import { BatchableMesh } from './BatchableMesh';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { InstructionPipe, RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../../../rendering/renderers/types';
import type { Mesh } from './Mesh';
/**
 * GPUData for Mesh
 * @internal
 */
export declare class MeshGpuData implements GPUData {
    meshData?: MeshData;
    batchableMesh?: BatchableMesh;
    destroy(): void;
}
/**
 * The data for the mesh
 * @internal
 */
interface MeshData {
    /** if the mesh is batched or not */
    batched: boolean;
    /** the size of the index buffer */
    indexSize: number;
    /** the size of the vertex buffer */
    vertexSize: number;
}
/** @internal */
export interface MeshAdaptor {
    init(): void;
    execute(meshPipe: MeshPipe, mesh: Mesh): void;
    destroy(): void;
}
/**
 * The MeshPipe is responsible for handling the rendering of Mesh objects.
 * It manages the batching of meshes, updates their GPU data, and executes the rendering instructions.
 * It also handles the local uniforms for each mesh, such as transformation matrices and colors.
 * @category scene
 * @internal
 */
export declare class MeshPipe implements RenderPipe<Mesh>, InstructionPipe<Mesh> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes];
        readonly name: "mesh";
    };
    localUniforms: UniformGroup<{
        uTransformMatrix: {
            value: Matrix;
            type: "mat3x3<f32>";
        };
        uColor: {
            value: Float32Array<ArrayBuffer>;
            type: "vec4<f32>";
        };
        uRound: {
            value: number;
            type: "f32";
        };
    }>;
    localUniformsBindGroup: BindGroup;
    renderer: Renderer;
    private _adaptor;
    constructor(renderer: Renderer, adaptor: MeshAdaptor);
    validateRenderable(mesh: Mesh): boolean;
    addRenderable(mesh: Mesh, instructionSet: InstructionSet): void;
    updateRenderable(mesh: Mesh): void;
    execute(mesh: Mesh): void;
    private _getMeshData;
    private _initMeshData;
    private _getBatchableMesh;
    private _initBatchableMesh;
    destroy(): void;
}
export {};
