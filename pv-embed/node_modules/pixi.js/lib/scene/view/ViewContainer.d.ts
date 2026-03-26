import { type GCable, type GCData } from '../../rendering/renderers/shared/GCSystem';
import { type InstructionSet } from '../../rendering/renderers/shared/instructions/InstructionSet';
import { type GPUDataOwner, type Renderer } from '../../rendering/renderers/types';
import { Bounds } from '../container/bounds/Bounds';
import { Container, type ContainerOptions } from '../container/Container';
import { type RenderLayer } from '../layers/RenderLayer';
import type { PointData } from '../../maths/point/PointData';
import type { View } from '../../rendering/renderers/shared/view/View';
import type { DestroyOptions } from '../container/destroyTypes';
/**
 * A GPU Data object
 * @internal
 */
export interface GPUData {
    destroy: () => void;
}
/** @internal */
export interface GPUDataContainer<GPU_DATA extends GPUData = any> {
    _gpuData: Record<number, GPU_DATA>;
    unload: () => void;
}
/**
 * Options for the construction of a ViewContainer.
 * @category scene
 * @advanced
 */
export interface ViewContainerOptions extends ContainerOptions, PixiMixins.ViewContainerOptions {
    /** If set to true, the resource will be garbage collected automatically when it is not used. */
    autoGarbageCollect?: boolean;
}
export interface ViewContainer<GPU_DATA extends GPUData = any> extends PixiMixins.ViewContainer, Container, GPUDataOwner<GPU_DATA>, GCable {
}
/**
 * A ViewContainer is a type of container that represents a view.
 * This view can be a Sprite, a Graphics object, or any other object that can be rendered.
 * This class is abstract and should not be used directly.
 * @category scene
 * @advanced
 */
export declare abstract class ViewContainer<GPU_DATA extends GPUData = any> extends Container implements View, GCable {
    /** @internal */
    readonly renderPipeId: string;
    /** @internal */
    readonly canBundle = true;
    /** @internal */
    allowChildren: boolean;
    /** @internal */
    _roundPixels: 0 | 1;
    /** @internal */
    _lastUsed: number;
    /** @internal */
    _gpuData: Record<number, GPU_DATA>;
    /** @internal */
    _gcData?: GCData;
    /** If set to true, the resource will be garbage collected automatically when it is not used. */
    autoGarbageCollect: boolean;
    /** @internal */
    _gcLastUsed: number;
    protected _bounds: Bounds;
    protected _boundsDirty: boolean;
    /**
     * The local bounds of the view in its own coordinate space.
     * Bounds are automatically updated when the view's content changes.
     * @example
     * ```ts
     * // Get bounds dimensions
     * const bounds = view.bounds;
     * console.log(`Width: ${bounds.maxX - bounds.minX}`);
     * console.log(`Height: ${bounds.maxY - bounds.minY}`);
     * ```
     * @returns The rectangular bounds of the view
     * @see {@link Bounds} For bounds operations
     */
    get bounds(): Bounds;
    /** @private */
    protected abstract updateBounds(): void;
    /**
     * Whether or not to round the x/y position of the sprite.
     * @example
     * ```ts
     * // Enable pixel rounding for crisp rendering
     * view.roundPixels = true;
     * ```
     * @default false
     */
    get roundPixels(): boolean;
    set roundPixels(value: boolean);
    constructor(options: ViewContainerOptions);
    /**
     * Checks if the object contains the given point in local coordinates.
     * Uses the view's bounds for hit testing.
     * @example
     * ```ts
     * // Basic point check
     * const localPoint = { x: 50, y: 25 };
     * const contains = view.containsPoint(localPoint);
     * console.log('Point is inside:', contains);
     * ```
     * @param point - The point to check in local coordinates
     * @returns True if the point is within the view's bounds
     * @see {@link ViewContainer#bounds} For the bounds used in hit testing
     * @see {@link Container#toLocal} For converting global coordinates to local
     */
    containsPoint(point: PointData): boolean;
    /** @private */
    abstract batched: boolean;
    /** @private */
    protected onViewUpdate(): void;
    /** Unloads the GPU data from the view. */
    unload(): void;
    destroy(options?: DestroyOptions): void;
    /**
     * Collects renderables for the view container.
     * @param instructionSet - The instruction set to collect renderables for.
     * @param renderer - The renderer to collect renderables for.
     * @param currentLayer - The current render layer.
     * @internal
     */
    collectRenderablesSimple(instructionSet: InstructionSet, renderer: Renderer, currentLayer: RenderLayer): void;
}
