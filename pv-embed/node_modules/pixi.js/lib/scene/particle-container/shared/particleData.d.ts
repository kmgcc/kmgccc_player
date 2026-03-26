import type { VertexFormat } from '../../../rendering/renderers/shared/geometry/const';
import type { IParticle } from './Particle';
/** @internal */
export interface ParticleRendererProperty {
    attributeName: string;
    format: VertexFormat;
    code: string;
    dynamic: boolean;
    updateFunction?: (ps: IParticle[], f32v: Float32Array, u32v: Uint32Array, offset: number, stride: number) => void;
}
/** @internal */
export declare const particleData: Record<string, ParticleRendererProperty>;
