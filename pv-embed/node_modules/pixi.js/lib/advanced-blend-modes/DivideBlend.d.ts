import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The Divide blend mode divides the RGB channel values of the bottom layer by those of the top layer.
 * The darker the top layer, the brighter the bottom layer will appear.
 * Blending any color with black yields white, and blending with white has no effect
 *
 * Available as `container.blendMode = 'divide'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'divide'
 * @category filters
 * @noInheritDoc
 */
export declare class DivideBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
