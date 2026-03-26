import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color has the saturation of the top color, while using the hue and luminosity of the bottom color.
 * A pure gray backdrop, having no saturation, will have no effect.
 *
 * Available as `container.blendMode = 'saturation'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'saturation'
 * @category filters
 * @noInheritDoc
 */
export declare class SaturationBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
