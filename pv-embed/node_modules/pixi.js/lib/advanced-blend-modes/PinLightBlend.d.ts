import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Replaces colors based on the blend color.
 *
 * Available as `container.blendMode = 'pin-light'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'pin-light'
 * @category filters
 * @noInheritDoc
 */
export declare class PinLightBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
