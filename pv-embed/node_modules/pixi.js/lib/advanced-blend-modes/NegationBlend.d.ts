import { BlendModeFilter } from '../filters/blend-modes/BlendModeFilter';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Implements the Negation blend mode which creates an inverted effect based on the brightness values.
 *
 * Available as `container.blendMode = 'negation'` after importing `pixi.js/advanced-blend-modes`.
 * @example
 * import 'pixi.js/advanced-blend-modes';
 * import { Sprite } from 'pixi.js';
 *
 * const sprite = Sprite.from('something.png');
 * sprite.blendMode = 'negation'
 * @category filters
 * @noInheritDoc
 */
export declare class NegationBlend extends BlendModeFilter {
    /** @ignore */
    static extension: ExtensionMetadata;
    constructor();
}
