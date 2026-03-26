import type { ContainerChild } from '../Container';
/**
 * Mixin interface for containers that allows them to manage children.
 * It provides methods for adding, removing, and manipulating child containers.
 * @category scene
 * @advanced
 */
export interface ChildrenHelperMixin<C = ContainerChild> {
    /** @internal */
    allowChildren: boolean;
    addChild<U extends C[]>(...children: U): U[0];
    removeChild<U extends C[]>(...children: U): U[0];
    /**
     * Removes all children from this container that are within the begin and end indexes.
     * @example
     * ```ts
     * // Remove all children
     * container.removeChildren();
     *
     * // Remove first 3 children
     * const removed = container.removeChildren(0, 3);
     * console.log('Removed:', removed.length); // 3
     *
     * // Remove children from index 2 onwards
     * container.removeChildren(2);
     *
     * // Remove specific range
     * const middle = container.removeChildren(1, 4);
     * ```
     * @param {number} beginIndex - The beginning position
     * @param {number} endIndex - The ending position. Default is container size
     * @returns List of removed children
     * @throws {RangeError} If begin/end indexes are invalid
     * @see {@link Container#addChild} For adding children
     * @see {@link Container#removeChild} For removing specific children
     */
    removeChildren(beginIndex?: number, endIndex?: number): C[];
    /**
     * Removes a child from the specified index position.
     * @example
     * ```ts
     * // Remove first child
     * const removed = container.removeChildAt(0);
     *
     * // type safe access
     * const sprite = container.removeChildAt<Sprite>(1);
     *
     * // With error handling
     * try {
     *     const child = container.removeChildAt(10);
     * } catch (e) {
     *     console.warn('Index out of bounds');
     * }
     * ```
     * @param {number} index - The index to remove the child from
     * @returns The child that was removed
     * @throws {Error} If index is out of bounds
     * @see {@link Container#removeChild} For removing specific children
     * @see {@link Container#removeChildren} For removing multiple children
     */
    removeChildAt<U extends C>(index: number): U;
    /**
     * Returns the child at the specified index.
     * @example
     * ```ts
     * // Get first child
     * const first = container.getChildAt(0);
     *
     * // Type-safe access
     * const sprite = container.getChildAt<Sprite>(1);
     *
     * // With error handling
     * try {
     *     const child = container.getChildAt(10);
     * } catch (e) {
     *     console.warn('Index out of bounds');
     * }
     * ```
     * @param {number} index - The index to get the child from
     * @returns The child at the given index
     * @throws {Error} If index is out of bounds
     * @see {@link Container#children} For direct array access
     * @see {@link Container#getChildByLabel} For name-based lookup
     */
    getChildAt<U extends C>(index: number): U;
    /**
     * Changes the position of an existing child in the container.
     * @example
     * ```ts
     * // Basic index change
     * container.setChildIndex(sprite, 0); // Move to front
     * container.setChildIndex(sprite, container.children.length - 1); // Move to back
     *
     * // With error handling
     * try {
     *     container.setChildIndex(sprite, 5);
     * } catch (e) {
     *     console.warn('Invalid index or child not found');
     * }
     * ```
     * @param {Container}child - The child Container instance to reposition
     * @param {number}index - The resulting index number for the child
     * @throws {Error} If index is out of bounds
     * @throws {Error} If child is not in container
     * @see {@link Container#getChildIndex} For getting current index
     * @see {@link Container#swapChildren} For swapping positions
     */
    setChildIndex(child: C, index: number): void;
    /**
     * Returns the index position of a child Container instance.
     * @example
     * ```ts
     * // Basic index lookup
     * const index = container.getChildIndex(sprite);
     * console.log(`Sprite is at index ${index}`);
     *
     * // With error handling
     * try {
     *     const index = container.getChildIndex(sprite);
     * } catch (e) {
     *     console.warn('Child not found in container');
     * }
     * ```
     * @param {Container} child - The Container instance to identify
     * @returns The index position of the child container
     * @throws {Error} If child is not in this container
     * @see {@link Container#setChildIndex} For changing index
     * @see {@link Container#children} For direct array access
     */
    getChildIndex(child: C): number;
    /**
     * Adds a child to the container at a specified index. If the index is out of bounds an error will be thrown.
     * If the child is already in this container, it will be moved to the specified index.
     *
     * When moving a child within the **same** container, `childAdded` and `added` events are
     * **not** emitted because the parent-child relationship hasn't changed. Events only fire when
     * a child is added from a different parent (or from no parent).
     * @example
     * ```ts
     * // Add at specific index
     * container.addChildAt(sprite, 0); // Add to front
     *
     * // Move existing child (no events emitted)
     * const index = container.children.length - 1;
     * container.addChildAt(existingChild, index); // Move to back
     *
     * // With error handling
     * try {
     *     container.addChildAt(sprite, 1000);
     * } catch (e) {
     *     console.warn('Index out of bounds');
     * }
     * ```
     * @param {Container} child - The child to add
     * @param {number} index - The index where the child will be placed
     * @returns The child that was added
     * @throws {Error} If index is out of bounds
     * @see {@link Container#addChild} For adding to the end
     * @see {@link Container#setChildIndex} For moving existing children
     */
    addChildAt<U extends C>(child: U, index: number): U;
    /**
     * Swaps the position of 2 Containers within this container.
     * @example
     * ```ts
     * // Basic swap
     * container.swapChildren(sprite1, sprite2);
     *
     * // With error handling
     * try {
     *     container.swapChildren(sprite1, sprite2);
     * } catch (e) {
     *     console.warn('One or both children not found in container');
     * }
     * ```
     * @remarks
     * - Updates render groups
     * - No effect if same child
     * - Triggers container changes
     * - Common in z-ordering
     * @param {Container} child - First container to swap
     * @param {Container} child2 - Second container to swap
     * @throws {Error} If either child is not in container
     * @see {@link Container#setChildIndex} For direct index placement
     * @see {@link Container#getChildIndex} For getting current positions
     */
    swapChildren<U extends C>(child: U, child2: U): void;
    /**
     * Remove the Container from its parent Container. If the Container has no parent, do nothing.
     * @example
     * ```ts
     * // Basic removal
     * sprite.removeFromParent();
     *
     * // With validation
     * if (sprite.parent) {
     *     sprite.removeFromParent();
     * }
     * ```
     * @see {@link Container#addChild} For adding to a new parent
     * @see {@link Container#removeChild} For parent removing children
     */
    removeFromParent(): void;
    /**
     * Reparent a child or multiple children to this container while preserving their world transform.
     * This ensures that the visual position and rotation of the children remain the same even when changing parents.
     * @example
     * ```ts
     * // Basic reparenting
     * const sprite = new Sprite(texture);
     * oldContainer.addChild(sprite);
     * // Move to new parent, keeping visual position
     * newContainer.reparentChild(sprite);
     *
     * // Reparent multiple children
     * const batch = [sprite1, sprite2, sprite3];
     * newContainer.reparentChild(...batch);
     * ```
     * @param {Container} child - The child or children to reparent
     * @returns The first child that was reparented
     * @see {@link Container#reparentChildAt} For index-specific reparenting
     * @see {@link Container#addChild} For simple parenting
     */
    reparentChild<U extends C[]>(...child: U): U[0];
    /**
     * Reparent the child to this container at the specified index while preserving its world transform.
     * This ensures that the visual position and rotation of the child remain the same even when changing parents.
     * @example
     * ```ts
     * // Basic index-specific reparenting
     * const sprite = new Sprite(texture);
     * oldContainer.addChild(sprite);
     * // Move to new parent at index 0 (front)
     * newContainer.reparentChildAt(sprite, 0);
     * ```
     * @param {Container} child - The child to reparent
     * @param {number} index - The index to reparent the child to
     * @returns The reparented child
     * @throws {Error} If index is out of bounds
     * @see {@link Container#reparentChild} For appending reparented children
     * @see {@link Container#addChildAt} For simple indexed parenting
     */
    reparentChildAt<U extends C>(child: U, index: number): U;
    /**
     * Replace a child in the container with a new child. Copying the local transform from the old child to the new one.
     * @param {Container} oldChild - The child to replace.
     * @param {Container} newChild - The new child to add.
     */
    replaceChild<U extends C, T extends C>(oldChild: U, newChild: T): void;
}
/** @internal */
export declare const childrenHelperMixin: ChildrenHelperMixin<ContainerChild>;
