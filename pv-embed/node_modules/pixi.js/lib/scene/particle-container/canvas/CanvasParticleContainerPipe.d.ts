import { ExtensionType } from '../../../extensions/Extensions';
import { type CanvasRenderer } from '../../../rendering/renderers/canvas/CanvasRenderer';
import { ParticleContainerPipe } from '../shared/ParticleContainerPipe';
/**
 * Canvas renderer for Particles that is designed for speed over feature set.
 * @category scene
 * @internal
 */
export declare class CanvasParticleContainerPipe extends ParticleContainerPipe {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'particle';
    };
    constructor(renderer: CanvasRenderer);
}
