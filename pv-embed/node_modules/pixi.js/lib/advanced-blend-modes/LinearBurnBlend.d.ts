import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Looks at the color information in each channel and darkens the base color to
 * reflect the blend color by increasing the contrast between the two.
 *
 * Available as `container.blendMode = 'linear-burn'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'linear-burn'
 * @category filters
 * @noInheritDoc
 */
export declare class LinearBurnBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
