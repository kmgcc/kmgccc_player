import type { ExtensionMetadata } from '../../../extensions/Extensions';
import type { Effect } from '../../../scene/container/Effect';
import type { PoolItem } from '../../../utils/pool/Pool';
/**
 * The ColorMask effect allows you to apply a color mask to the rendering process.
 * This can be useful for selectively rendering certain colors or for creating
 * effects based on color values.
 * @category rendering
 * @advanced
 */
export declare class ColorMask implements Effect, PoolItem {
    static extension: ExtensionMetadata;
    priority: number;
    mask: number;
    pipe: string;
    constructor(options: {
        mask: number;
    });
    init(mask: number): void;
    destroy(): void;
    static test(mask: any): boolean;
}
