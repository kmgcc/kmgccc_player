import { ExtensionType } from '../../../../extensions/Extensions';
import { type GPUData } from '../../../../scene/view/ViewContainer';
import { GCManagedHash } from '../../../../utils/data/GCManagedHash';
import type { Topology } from '../../shared/geometry/const';
import type { Geometry } from '../../shared/geometry/Geometry';
import type { System } from '../../shared/system/System';
import type { GlRenderingContext } from '../context/GlRenderingContext';
import type { GlProgram } from '../shader/GlProgram';
import type { WebGLRenderer } from '../WebGLRenderer';
/**
 * Stores GPU-specific data for a Geometry instance in WebGL context.
 *
 * This class manages Vertex Array Object (VAO) caching for geometries,
 * allowing efficient reuse of VAOs across different shader programs.
 * Each geometry can have multiple VAOs cached, one for each unique
 * shader program signature it's used with.
 * @internal
 */
export declare class GlGeometryGpuData implements GPUData {
    vaoCache: Record<string, WebGLVertexArrayObject>;
    constructor();
    destroy(): void;
}
/**
 * System plugin to the renderer to manage geometry.
 * @category rendering
 * @advanced
 */
export declare class GlGeometrySystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "geometry";
    };
    /**
     * `true` if we has `*_vertex_array_object` extension.
     * @readonly
     */
    hasVao: boolean;
    /**
     * `true` if has `ANGLE_instanced_arrays` extension.
     * @readonly
     */
    hasInstance: boolean;
    protected gl: GlRenderingContext;
    protected _activeGeometry: Geometry;
    /** @internal */
    _activeVao: WebGLVertexArrayObject;
    /** @internal */
    _managedGeometries: GCManagedHash<Geometry>;
    /** Renderer that owns this {@link GeometrySystem}. */
    private _renderer;
    /** @param renderer - The renderer this System works for. */
    constructor(renderer: WebGLRenderer);
    /** Sets up the renderer context and necessary buffers. */
    protected contextChange(): void;
    /**
     * Binds geometry so that is can be drawn. Creating a Vao if required
     * @param geometry - Instance of geometry to bind.
     * @param program - Instance of program to use vao for.
     */
    bind(geometry?: Geometry, program?: GlProgram): void;
    /** Reset and unbind any active VAO and geometry. */
    resetState(): void;
    /** Update buffers of the currently bound geometry. */
    updateBuffers(): void;
    /**
     * Check compatibility between a geometry and a program
     * @param geometry - Geometry instance.
     * @param program - Program instance.
     */
    protected checkCompatibility(geometry: Geometry, program: GlProgram): void;
    /**
     * Takes a geometry and program and generates a unique signature for them.
     * @param geometry - To get signature from.
     * @param program - To test geometry against.
     * @returns - Unique signature of the geometry and program
     */
    protected getSignature(geometry: Geometry, program: GlProgram): string;
    protected getVao(geometry: Geometry, program: GlProgram): WebGLVertexArrayObject;
    /**
     * Creates or gets Vao with the same structure as the geometry and stores it on the geometry.
     * If vao is created, it is bound automatically. We use a shader to infer what and how to set up the
     * attribute locations.
     * @param geometry - Instance of geometry to to generate Vao for.
     * @param program
     * @param _incRefCount - Increment refCount of all geometry buffers.
     */
    protected initGeometryVao(geometry: Geometry, program: GlProgram, _incRefCount?: boolean): WebGLVertexArrayObject;
    protected onGeometryUnload(geometry: Geometry, contextLost?: boolean): void;
    /**
     * Dispose all WebGL resources of all managed geometries.
     * @param [contextLost=false] - If context was lost, we suppress `gl.delete` calls
     */
    destroyAll(contextLost?: boolean): void;
    /**
     * Activate vertex array object.
     * @param geometry - Geometry instance.
     * @param program - Shader program instance.
     */
    protected activateVao(geometry: Geometry, program: GlProgram): void;
    /**
     * Draws the currently bound geometry.
     * @param topology - The type primitive to render.
     * @param size - The number of elements to be rendered. If not specified, all vertices after the
     *  starting vertex will be drawn.
     * @param start - The starting vertex in the geometry to start drawing from. If not specified,
     *  drawing will start from the first vertex.
     * @param instanceCount - The number of instances of the set of elements to execute. If not specified,
     *  all instances will be drawn.
     * @returns This instance of the geometry system.
     */
    draw(topology?: Topology, size?: number, start?: number, instanceCount?: number): this;
    /** Unbind/reset everything. */
    protected unbind(): void;
    destroy(): void;
}
