import type { ParticleContainer } from '../shared/ParticleContainer';
import type { ParticleContainerAdaptor, ParticleContainerPipe } from '../shared/ParticleContainerPipe';
/**
 * A Canvas adaptor for the ParticleContainer that renders particles using Canvas2D.
 * @internal
 */
export declare class CanvasParticleContainerAdaptor implements ParticleContainerAdaptor {
    execute(particleContainerPipe: ParticleContainerPipe, container: ParticleContainer): void;
}
