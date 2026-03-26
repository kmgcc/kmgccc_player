import type { Point } from '../../../maths/point/Point';
import type { Bounds } from '../../../scene/container/bounds/Bounds';
import type { Container } from '../../../scene/container/Container';
import type { Effect } from '../../../scene/container/Effect';
/**
 * ScissorMask is an effect that applies a scissor mask to a container.
 * It restricts rendering to the area defined by the mask.
 * The mask is a Container that defines the area to be rendered.
 * The mask must be a Container that is not renderable or measurable.
 * This effect is used to create clipping regions in the rendering process.
 * @category rendering
 * @advanced
 */
export declare class ScissorMask implements Effect {
    priority: number;
    mask: Container;
    pipe: string;
    constructor(mask: Container);
    addBounds(bounds: Bounds, skipUpdateTransform?: boolean): void;
    addLocalBounds(bounds: Bounds, localRoot: Container): void;
    containsPoint(point: Point, hitTestFn: (container: Container, point: Point) => boolean): boolean;
    reset(): void;
    destroy(): void;
}
