import type { IParticle } from '../../scene/particle-container/shared/Particle';
/** @internal */
export declare const particleUpdateFunctions: {
    aVertex: (ps: IParticle[], f32v: Float32Array, _u32v: Uint32Array, offset: number, stride: number) => void;
    aPosition: (ps: IParticle[], f32v: Float32Array, _u32v: Uint32Array, offset: number, stride: number) => void;
    aRotation: (ps: IParticle[], f32v: Float32Array, _u32v: Uint32Array, offset: number, stride: number) => void;
    aUV: (ps: IParticle[], f32v: Float32Array, _u32v: Uint32Array, offset: number, stride: number) => void;
    aColor: (ps: IParticle[], _f32v: Float32Array, u32v: Uint32Array, offset: number, stride: number) => void;
};
