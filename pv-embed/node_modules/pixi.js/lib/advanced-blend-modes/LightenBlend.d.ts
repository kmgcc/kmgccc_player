import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color is composed of the lightest values of each color channel.
 *
 * Available as `container.blendMode = 'lighten'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'lighten'
 * @category filters
 * @noInheritDoc
 */
export declare class LightenBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
