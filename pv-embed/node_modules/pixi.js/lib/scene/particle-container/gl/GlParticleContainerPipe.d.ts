import { ExtensionType } from '../../../extensions/Extensions';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe';
import type { WebGLRenderer } from '../../../rendering/renderers/gl/WebGLRenderer';
/**
 * WebGL renderer for Particles that is designed for speed over feature set.
 * @category scene
 * @internal
 */
export declare class GlParticleContainerPipe extends ParticleContainerPipe {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'particle';
    };
    constructor(renderer: WebGLRenderer);
}
