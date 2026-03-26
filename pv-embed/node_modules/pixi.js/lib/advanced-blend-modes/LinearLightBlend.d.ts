import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Increase or decrease brightness by burning or dodging color values, based on the blend color
 *
 * Available as `container.blendMode = 'linear-light'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'linear-light'
 * @category filters
 * @noInheritDoc
 */
export declare class LinearLightBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
