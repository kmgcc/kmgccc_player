import { Filter } from '../Filter';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
import type { Sprite } from '../../scene/sprite/Sprite';
import type { FilterOptions } from '../Filter';
import type { FilterSystem } from '../FilterSystem';
/** @internal */
export interface MaskFilterOptions extends FilterOptions {
    sprite: Sprite;
    inverse?: boolean;
    scale?: number | {
        x: number;
        y: number;
    };
}
/** @internal */
export declare class MaskFilter extends Filter {
    sprite: Sprite;
    private readonly _textureMatrix;
    constructor(options: MaskFilterOptions);
    set inverse(value: boolean);
    get inverse(): boolean;
    apply(filterManager: FilterSystem, input: Texture, output: Texture, clearMode: boolean): void;
}
