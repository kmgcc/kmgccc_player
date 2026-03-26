import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color is the result of multiply if the top color is darker, or screen if the top color is lighter.
 * This blend mode is equivalent to overlay but with the layers swapped.
 * The effect is similar to shining a harsh spotlight on the backdrop.
 *
 * Available as `container.blendMode = 'hard-light'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'hard-light'
 * @category filters
 * @noInheritDoc
 */
export declare class HardLightBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
