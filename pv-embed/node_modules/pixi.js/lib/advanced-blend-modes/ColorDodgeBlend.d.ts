import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color is the result of dividing the bottom color by the inverse of the top color.
 * A black foreground leads to no change.
 * A foreground with the inverse color of the backdrop leads to a fully lit color.
 * This blend mode is similar to screen, but the foreground need only be as light as the inverse of the backdrop to create a fully lit color.
 *
 * Available as `container.blendMode = 'color-dodge'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'color-dodge'
 * @category filters
 * @noInheritDoc
 */
export declare class ColorDodgeBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
