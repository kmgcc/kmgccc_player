import type { IParticle } from '../../scene/particle-container/shared/Particle';
import type { ParticleRendererProperty } from '../../scene/particle-container/shared/particleData';
type ParticleUpdateFunction = (ps: IParticle[], f32v: Float32Array, u32v: Uint32Array, offset: number, stride: number) => void;
/**
 * @param properties
 * @internal
 */
export declare function generateParticleUpdatePolyfill(properties: Record<string, ParticleRendererProperty>): {
    dynamicUpdate: ParticleUpdateFunction;
    staticUpdate: ParticleUpdateFunction;
};
export {};
