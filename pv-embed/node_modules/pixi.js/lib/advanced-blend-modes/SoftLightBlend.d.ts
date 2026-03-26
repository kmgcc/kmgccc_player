import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color is similar to hard-light, but softer. This blend mode behaves similar to hard-light.
 * The effect is similar to shining a diffused spotlight on the backdrop.
 *
 * Available as `container.blendMode = 'soft-light'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'soft-light'
 * @category filters
 * @noInheritDoc
 */
export declare class SoftLightBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
