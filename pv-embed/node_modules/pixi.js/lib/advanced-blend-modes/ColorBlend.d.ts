import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color has the hue and saturation of the top color, while using the luminosity of the bottom color.
 * The effect preserves gray levels and can be used to colorize the foreground.
 *
 * Available as `container.blendMode = 'color'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'color'
 * @category filters
 * @noInheritDoc
 */
export declare class ColorBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
