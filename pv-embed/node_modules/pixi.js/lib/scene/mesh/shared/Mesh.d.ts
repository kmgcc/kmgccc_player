import { Geometry } from '../../../rendering/renderers/shared/geometry/Geometry';
import { State } from '../../../rendering/renderers/shared/state/State';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import { ViewContainer } from '../../view/ViewContainer';
import { MeshGeometry } from './MeshGeometry';
import { type MeshGpuData } from './MeshPipe';
import '../init';
import type { PointData } from '../../../maths/point/PointData';
import type { Topology } from '../../../rendering/renderers/shared/geometry/const';
import type { Instruction } from '../../../rendering/renderers/shared/instructions/Instruction';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { View } from '../../../rendering/renderers/shared/view/View';
import type { ContainerOptions } from '../../container/Container';
import type { DestroyOptions } from '../../container/destroyTypes';
/**
 * Shader that uses a texture.
 * This is the default shader used by `Mesh` when no shader is provided.
 * It is a simple shader that samples a texture and applies it to the geometry.
 * @category scene
 * @advanced
 */
export interface TextureShader extends Shader {
    /** The texture that the shader uses. */
    texture: Texture;
}
/**
 * Constructor options used for `Mesh` instances. Extends {@link MeshViewOptions}
 * ```js
 * const mesh = new Mesh({
 *    texture: Texture.from('assets/image.png'),
 *    geometry: new PlaneGeometry(),
 *    shader: Shader.from(VERTEX, FRAGMENT),
 * });
 * ```
 * @see {@link Mesh}
 * @see {@link MeshViewOptions}
 * @category scene
 */
/**
 * Options for creating a Mesh instance.
 * @category scene
 * @advanced
 * @noInheritDoc
 */
export interface MeshOptions<GEOMETRY extends Geometry = MeshGeometry, SHADER extends Shader = TextureShader> extends PixiMixins.MeshOptions, ContainerOptions {
    /**
     * Includes vertex positions, face indices, colors, UVs, and
     * custom attributes within buffers, reducing the cost of passing all
     * this data to the GPU. Can be shared between multiple Mesh objects.
     */
    geometry: GEOMETRY;
    /**
     * Represents the vertex and fragment shaders that processes the geometry and runs on the GPU.
     * Can be shared between multiple Mesh objects.
     */
    shader?: SHADER | null;
    /** The state of WebGL required to render the mesh. */
    state?: State;
    /** The texture that the Mesh uses. Null for non-MeshMaterial shaders */
    texture?: Texture;
    /** Whether or not to round the x/y position. */
    roundPixels?: boolean;
}
export interface Mesh extends PixiMixins.Mesh, ViewContainer<MeshGpuData> {
}
/**
 * Base mesh class.
 *
 * This class empowers you to have maximum flexibility to render any kind of WebGL/WebGPU visuals you can think of.
 * This class assumes a certain level of WebGL/WebGPU knowledge.
 * If you know a bit this should abstract enough away to make your life easier!
 *
 * Pretty much ALL WebGL/WebGPU can be broken down into the following:
 * - Geometry - The structure and data for the mesh. This can include anything from positions, uvs, normals, colors etc..
 * - Shader - This is the shader that PixiJS will render the geometry with (attributes in the shader must match the geometry)
 * - State - This is the state of WebGL required to render the mesh.
 *
 * Through a combination of the above elements you can render anything you want, 2D or 3D!
 * @category scene
 * @advanced
 */
export declare class Mesh<GEOMETRY extends Geometry = MeshGeometry, SHADER extends Shader = TextureShader> extends ViewContainer<MeshGpuData> implements View, Instruction {
    /** @internal */
    readonly renderPipeId: string;
    state: State;
    /** @internal */
    _texture: Texture;
    /** @internal */
    _geometry: GEOMETRY;
    /** @internal */
    _shader: SHADER | null;
    /**
     * @param {MeshOptions} options - options for the mesh instance
     */
    constructor(options: MeshOptions<GEOMETRY, SHADER>);
    /** @deprecated since 8.0.0 */
    constructor(geometry: GEOMETRY, shader: SHADER, state?: State, drawMode?: Topology);
    /** Alias for {@link Mesh#shader}. */
    get material(): SHADER;
    /**
     * Represents the vertex and fragment shaders that processes the geometry and runs on the GPU.
     * Can be shared between multiple Mesh objects.
     */
    set shader(value: SHADER | null);
    get shader(): SHADER | null;
    /**
     * Includes vertex positions, face indices, colors, UVs, and
     * custom attributes within buffers, reducing the cost of passing all
     * this data to the GPU. Can be shared between multiple Mesh objects.
     */
    set geometry(value: GEOMETRY);
    get geometry(): GEOMETRY;
    /** The texture that the Mesh uses. Null for non-MeshMaterial shaders */
    set texture(value: Texture);
    get texture(): Texture;
    get batched(): boolean;
    /**
     * The local bounds of the mesh.
     * @type {Bounds}
     */
    get bounds(): import("../..").Bounds;
    /**
     * Update local bounds of the mesh.
     * @private
     */
    protected updateBounds(): void;
    /**
     * Checks if the object contains the given point.
     * @param point - The point to check
     */
    containsPoint(point: PointData): boolean;
    /**
     * Destroys this sprite renderable and optionally its texture.
     * @param options - Options parameter. A boolean will act as if all options
     *  have been set to that value
     * @example
     * mesh.destroy();
     * mesh.destroy(true);
     * mesh.destroy({ texture: true, textureSource: true });
     */
    destroy(options?: DestroyOptions): void;
}
