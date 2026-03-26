import { ExtensionType } from '../../../extensions/Extensions';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe';
import type { WebGPURenderer } from '../../../rendering/renderers/gpu/WebGPURenderer';
/**
 * WebGPU renderer for Particles that is designed for speed over feature set.
 * @category scene
 * @internal
 */
export declare class GpuParticleContainerPipe extends ParticleContainerPipe {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'particle';
    };
    constructor(renderer: WebGPURenderer);
}
