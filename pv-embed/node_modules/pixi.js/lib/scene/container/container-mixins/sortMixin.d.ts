import type { Container } from '../Container';
/** @ignore */
export interface SortMixinConstructor {
    /**
     * The zIndex of the container.
     *
     * Controls the rendering order of children within their parent container.
     *
     * A higher value will mean it will be moved towards the front of the rendering order.
     * @example
     * ```ts
     * // Add in any order
     * container.addChild(character, background, foreground);
     *
     * // Adjust rendering order
     * background.zIndex = 0;
     * character.zIndex = 1;
     * foreground.zIndex = 2;
     * ```
     * @see {@link Container#sortableChildren} For enabling sorting
     * @see {@link Container#sortChildren} For manual sorting
     * @default 0
     */
    zIndex?: number;
    /**
     * Should children be sorted by zIndex at the next render call.
     *
     * Will get automatically set to true if a new child is added, or if a child's zIndex changes.
     * @default false
     * @internal
     */
    sortDirty?: boolean;
    /**
     * If set to true, the container will sort its children by `zIndex` value
     * when the next render is called, or manually if `sortChildren()` is called.
     *
     * This actually changes the order of elements in the array of children,
     * so it will affect the rendering order.
     *
     * > [!NOTE] Also be aware of that this may not work nicely with the `addChildAt()` function,
     * > as the `zIndex` sorting may cause the child to automatically sorted to another position.
     * @example
     * ```ts
     * container.sortableChildren = true;
     * ```
     * @default false
     */
    sortableChildren?: boolean;
}
/**
 * The SortMixin interface provides methods and properties for sorting children of a container
 * based on their `zIndex` values. It allows for automatic sorting of children when their `zIndex`
 * changes or when new children are added. The mixin includes properties to manage sorting state
 * and methods to sort children explicitly.
 * @category scene
 * @advanced
 */
export interface SortMixin extends Required<SortMixinConstructor> {
    /** @internal */
    _zIndex: number;
    /**
     * Sorts children by zIndex value. Only sorts if container is marked as dirty.
     * @example
     * ```ts
     * // Basic sorting
     * particles.zIndex = 2;     // Will mark as dirty
     * container.sortChildren();
     * ```
     * @see {@link Container#sortableChildren} For enabling automatic sorting
     * @see {@link Container#zIndex} For setting child order
     */
    sortChildren: () => void;
    /** @internal */
    depthOfChildModified: () => void;
}
/** @internal */
export declare const sortMixin: Partial<Container>;
