import type { ParticleContainer } from '../shared/ParticleContainer';
import type { ParticleContainerAdaptor, ParticleContainerPipe } from '../shared/ParticleContainerPipe';
/** @internal */
export declare class GlParticleContainerAdaptor implements ParticleContainerAdaptor {
    execute(particleContainerPipe: ParticleContainerPipe, container: ParticleContainer): void;
}
