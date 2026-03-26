import { ExtensionType } from '../../../../extensions/Extensions';
import type { BufferResource } from '../../shared/buffer/BufferResource';
import type { Shader } from '../../shared/shader/Shader';
import type { UniformGroup } from '../../shared/shader/UniformGroup';
import type { GlRenderingContext } from '../context/GlRenderingContext';
import type { WebGLRenderer } from '../WebGLRenderer';
import type { GlProgram } from './GlProgram';
import type { GlProgramData } from './GlProgramData';
/** @internal */
export interface ShaderSyncData {
    textureCount: number;
    blockIndex: number;
}
/** @internal */
export type ShaderSyncFunction = (renderer: WebGLRenderer, shader: Shader, syncData: ShaderSyncData) => void;
/**
 * System plugin to the renderer to manage the shaders for WebGL.
 * @category rendering
 * @advanced
 */
export declare class GlShaderSystem {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem];
        readonly name: "shader";
    };
    /** @internal */
    _activeProgram: GlProgram;
    private _programDataHash;
    private readonly _renderer;
    /** @internal */
    _gl: WebGL2RenderingContext;
    private _shaderSyncFunctions;
    constructor(renderer: WebGLRenderer);
    protected contextChange(gl: GlRenderingContext): void;
    /**
     * Changes the current shader to the one given in parameter.
     * @param shader - the new shader
     * @param skipSync - false if the shader should automatically sync its uniforms.
     * @returns the glProgram that belongs to the shader.
     */
    bind(shader: Shader, skipSync?: boolean): void;
    /**
     * Updates the uniform group.
     * @param uniformGroup - the uniform group to update
     */
    updateUniformGroup(uniformGroup: UniformGroup): void;
    /**
     * Binds a uniform block to the shader.
     * @param uniformGroup - the uniform group to bind
     * @param name - the name of the uniform block
     * @param index - the index of the uniform block
     */
    bindUniformBlock(uniformGroup: UniformGroup | BufferResource, name: string, index?: number): void;
    private _setProgram;
    /**
     * @param program - the program to get the data for
     * @internal
     */
    _getProgramData(program: GlProgram): GlProgramData;
    private _createProgramData;
    destroy(): void;
    /**
     * Creates a function that can be executed that will sync the shader as efficiently as possible.
     * Overridden by the unsafe eval package if you don't want eval used in your project.
     * @param shader - the shader to generate the sync function for
     * @param shaderSystem - the shader system to use
     * @returns - the generated sync function
     * @ignore
     */
    _generateShaderSync(shader: Shader, shaderSystem: GlShaderSystem): ShaderSyncFunction;
    resetState(): void;
}
