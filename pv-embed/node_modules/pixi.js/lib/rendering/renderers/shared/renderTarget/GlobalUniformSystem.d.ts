import { ExtensionType } from '../../../../extensions/Extensions';
import { Matrix } from '../../../../maths/matrix/Matrix';
import { BindGroup } from '../../gpu/shader/BindGroup';
import { type Renderer, RendererType } from '../../types';
import { UniformGroup } from '../shader/UniformGroup';
import type { PointData } from '../../../../maths/point/PointData';
import type { GlRenderTargetSystem } from '../../gl/renderTarget/GlRenderTargetSystem';
import type { GpuRenderTargetSystem } from '../../gpu/renderTarget/GpuRenderTargetSystem';
import type { UboSystem } from '../shader/UboSystem';
import type { System } from '../system/System';
/**
 * Type definition for the global uniforms used in the renderer.
 * This includes projection matrix, world transform matrix, world color, and resolution.
 * @category rendering
 * @advanced
 */
export type GlobalUniformGroup = UniformGroup<{
    uProjectionMatrix: {
        value: Matrix;
        type: 'mat3x3<f32>';
    };
    uWorldTransformMatrix: {
        value: Matrix;
        type: 'mat3x3<f32>';
    };
    uWorldColorAlpha: {
        value: Float32Array;
        type: 'vec4<f32>';
    };
    uResolution: {
        value: number[];
        type: 'vec2<f32>';
    };
}>;
/**
 * Options for the global uniforms system.
 * This includes size, projection matrix, world transform matrix, world color, and offset.
 * @category rendering
 * @advanced
 */
export interface GlobalUniformOptions {
    size?: number[];
    projectionMatrix?: Matrix;
    worldTransformMatrix?: Matrix;
    worldColor?: number;
    offset?: PointData;
}
/**
 * Data structure for the global uniforms used in the renderer.
 * This includes the projection matrix, world transform matrix, world color, resolution, and bind group.
 * @category rendering
 * @advanced
 */
export interface GlobalUniformData {
    projectionMatrix: Matrix;
    worldTransformMatrix: Matrix;
    worldColor: number;
    resolution: number[];
    offset: PointData;
    bindGroup: BindGroup;
}
/** @internal */
export interface GlobalUniformRenderer {
    renderTarget: GlRenderTargetSystem | GpuRenderTargetSystem;
    renderPipes: Renderer['renderPipes'];
    ubo: UboSystem;
    type: RendererType;
}
/**
 * System plugin to the renderer to manage global uniforms for the renderer.
 * @category rendering
 * @advanced
 */
export declare class GlobalUniformSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "globalUniforms";
    };
    private readonly _renderer;
    private _stackIndex;
    private _globalUniformDataStack;
    private readonly _uniformsPool;
    private readonly _activeUniforms;
    private readonly _bindGroupPool;
    private readonly _activeBindGroups;
    private _currentGlobalUniformData;
    constructor(renderer: GlobalUniformRenderer);
    reset(): void;
    start(options: GlobalUniformOptions): void;
    bind({ size, projectionMatrix, worldTransformMatrix, worldColor, offset, }: GlobalUniformOptions): void;
    push(options: GlobalUniformOptions): void;
    pop(): void;
    get bindGroup(): BindGroup;
    get globalUniformData(): GlobalUniformData;
    get uniformGroup(): UniformGroup;
    private _createUniforms;
    destroy(): void;
}
