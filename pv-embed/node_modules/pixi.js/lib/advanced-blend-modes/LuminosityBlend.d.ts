import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color has the luminosity of the top color, while using the hue and saturation of the bottom color.
 * This blend mode is equivalent to color, but with the layers swapped.
 *
 * Available as `container.blendMode = 'luminosity'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'luminosity'
 * @category filters
 * @noInheritDoc
 */
export declare class LuminosityBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
