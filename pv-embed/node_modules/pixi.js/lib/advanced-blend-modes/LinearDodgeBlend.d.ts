import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Looks at the color information in each channel and brightens the base color to reflect the blend color by decreasing contrast between the two.
 *
 * Available as `container.blendMode = 'linear-dodge'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'linear-dodge'
 * @category filters
 * @noInheritDoc
 */
export declare class LinearDodgeBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
