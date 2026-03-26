import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * The final color is similar to difference, but with less contrast.
 * As with difference, a black layer has no effect, while a white layer inverts the other layer's color.
 *
 * Available as `container.blendMode = 'exclusion'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'exclusion'
 * @category filters
 * @noInheritDoc
 */
export declare class ExclusionBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
