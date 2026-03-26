import type { Container } from '../Container';
/** @ignore */
export interface FindMixinConstructor {
    /**
     * The instance label of the object.
     * @default null
     */
    label?: string;
}
/**
 * The FindMixin interface provides methods for finding children within a container by their label.
 * It allows for searching for a single child or multiple children with a specific label,
 * either directly or recursively through the container's hierarchy.
 * @category scene
 * @advanced
 */
export interface FindMixin extends Required<FindMixinConstructor> {
    /**
     * The instance name of the object.
     * @deprecated since 8.0.0
     * @see Container#label
     * @default null
     */
    name: string;
    /**
     * @deprecated since 8.0.0
     * @param {string} label - Instance name.
     * @param {boolean}[deep=false] - Whether to search recursively
     * @returns {Container} The child with the specified name.
     * @see Container#getChildByLabel
     */
    getChildByName(label: RegExp | string, deep?: boolean): Container | null;
    /**
     * Returns the first child in the container with the specified label.
     * Recursive searches are done in a pre-order traversal.
     * @example
     * ```ts
     * // Basic label search
     * const child = container.getChildByLabel('player');
     *
     * // Search with regular expression
     * const enemy = container.getChildByLabel(/enemy-\d+/);
     *
     * // Deep search through children
     * const deepChild = container.getChildByLabel('powerup', true);
     * ```
     * @param {RegExp|string} label - Instance label to search for
     * @param {boolean} deep - Whether to search recursively through children
     * @returns The first child with the specified label, or null if none found
     * @see {@link Container#getChildrenByLabel} For finding all matches
     * @see {@link Container#label} For setting labels
     */
    getChildByLabel(label: RegExp | string, deep?: boolean): Container | null;
    /**
     * Returns all children in the container with the specified label.
     * Recursive searches are done in a pre-order traversal.
     * @example
     * ```ts
     * // Basic label search
     * const enemies = container.getChildrenByLabel('enemy');
     * // Search with regular expression
     * const powerups = container.getChildrenByLabel(/powerup-\d+/);
     * // Deep search with collection
     * const buttons = [];
     * container.getChildrenByLabel('button', true, buttons);
     * ```
     * @param {string|RegExp} label  - Instance label to search for
     * @param {boolean}[deep=false] - Whether to search recursively through children
     * @param {Container[]} [out=[]]  - Optional array to store matching children in
     * @returns An array of children with the specified label
     * @see {@link Container#getChildByLabel} For finding first match
     * @see {@link Container#label} For setting labels
     */
    getChildrenByLabel(label: RegExp | string, deep?: boolean, out?: Container[]): Container[];
}
/** @internal */
export declare const findMixin: Partial<Container>;
