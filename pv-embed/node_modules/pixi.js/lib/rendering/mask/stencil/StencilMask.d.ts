import { Container } from '../../../scene/container/Container';
import type { ExtensionMetadata } from '../../../extensions/Extensions';
import type { Point } from '../../../maths/point/Point';
import type { Bounds } from '../../../scene/container/bounds/Bounds';
import type { Effect } from '../../../scene/container/Effect';
import type { PoolItem } from '../../../utils/pool/Pool';
/**
 * A mask that uses the stencil buffer to clip the rendering of a container.
 * This is useful for complex masks that cannot be achieved with simple shapes.
 * It is more performant than using a `Graphics` mask, but requires WebGL support.
 * It is also useful for masking with `Container` objects that have complex shapes.
 * @category rendering
 * @advanced
 */
export declare class StencilMask implements Effect, PoolItem {
    static extension: ExtensionMetadata;
    priority: number;
    mask: Container;
    pipe: string;
    constructor(options: {
        mask: Container;
    });
    init(mask: Container): void;
    reset(): void;
    addBounds(bounds: Bounds, skipUpdateTransform: boolean): void;
    addLocalBounds(bounds: Bounds, localRoot: Container): void;
    containsPoint(point: Point, hitTestFn: (container: Container, point: Point) => boolean): boolean;
    destroy(): void;
    static test(mask: any): boolean;
}
