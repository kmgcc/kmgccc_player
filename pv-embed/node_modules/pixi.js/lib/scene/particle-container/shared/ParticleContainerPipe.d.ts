import { ExtensionType } from '../../../extensions/Extensions';
import { Matrix } from '../../../maths/matrix/Matrix';
import { UniformGroup } from '../../../rendering/renderers/shared/shader/UniformGroup';
import { State } from '../../../rendering/renderers/shared/state/State';
import { ParticleBuffer } from './ParticleBuffer';
import type { InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../../../rendering/renderers/shared/instructions/RenderPipe';
import type { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import type { Renderer } from '../../../rendering/renderers/types';
import type { ParticleContainer } from './ParticleContainer';
/** @internal */
export interface ParticleContainerAdaptor {
    execute(particleContainerPop: ParticleContainerPipe, container: ParticleContainer): void;
}
/**
 * Renderer for Particles that is designer for speed over feature set.
 * @category scene
 * @internal
 */
export declare class ParticleContainerPipe implements RenderPipe<ParticleContainer> {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'particle';
    };
    /** The default shader that is used if a sprite doesn't have a more specific one. */
    defaultShader: Shader;
    /** @internal */
    adaptor: ParticleContainerAdaptor;
    /** @internal */
    readonly state: State;
    /** @internal */
    readonly renderer: Renderer;
    private readonly _managedContainers;
    /** Local uniforms that are used for rendering particles. */
    readonly localUniforms: UniformGroup<{
        uTranslationMatrix: {
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
        uResolution: {
            value: number[];
            type: "vec2<f32>";
        };
    }>;
    /**
     * @param renderer - The renderer this sprite batch works for.
     * @param adaptor
     */
    constructor(renderer: Renderer, adaptor: ParticleContainerAdaptor);
    validateRenderable(_renderable: ParticleContainer): boolean;
    addRenderable(renderable: ParticleContainer, instructionSet: InstructionSet): void;
    getBuffers(renderable: ParticleContainer): ParticleBuffer;
    private _initBuffer;
    updateRenderable(_renderable: ParticleContainer): void;
    execute(container: ParticleContainer): void;
    /** Destroys the ParticleRenderer. */
    destroy(): void;
}
