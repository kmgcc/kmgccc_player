import { Pool } from './Pool';
import type { PoolItem, PoolItemConstructor } from './Pool';
/**
 * A type alias for a constructor of a Pool.
 * @template T The type of items in the pool. Must extend PoolItem.
 * @category utils
 * @advanced
 */
export type PoolConstructor<T extends PoolItem> = new () => Pool<T>;
/**
 * A group of pools that can be used to store objects of different types.
 * @category utils
 * @advanced
 */
export declare class PoolGroupClass {
    /**
     * A map to store the pools by their class type.
     * @private
     */
    private readonly _poolsByClass;
    /**
     * Prepopulates a specific pool with a given number of items.
     * @template T The type of items in the pool. Must extend PoolItem.
     * @param {PoolItemConstructor<T>} Class - The constructor of the items in the pool.
     * @param {number} total - The number of items to add to the pool.
     */
    prepopulate<T extends PoolItem>(Class: PoolItemConstructor<T>, total: number): void;
    /**
     * Gets an item from a specific pool.
     * @template T The type of items in the pool. Must extend PoolItem.
     * @param {PoolItemConstructor<T>} Class - The constructor of the items in the pool.
     * @param {unknown} [data] - Optional data to pass to the item's constructor.
     * @returns {T} The item from the pool.
     */
    get<T extends PoolItem>(Class: PoolItemConstructor<T>, data?: unknown): T;
    /**
     * Returns an item to its respective pool.
     * @param {PoolItem} item - The item to return to the pool.
     */
    return(item: PoolItem): void;
    /**
     * Gets a specific pool based on the class type.
     * @template T The type of items in the pool. Must extend PoolItem.
     * @param {PoolItemConstructor<T>} ClassType - The constructor of the items in the pool.
     * @returns {Pool<T>} The pool of the given class type.
     */
    getPool<T extends PoolItem>(ClassType: PoolItemConstructor<T>): Pool<T>;
    /** gets the usage stats of each pool in the system */
    stats(): Record<string, {
        free: number;
        used: number;
        size: number;
    }>;
    /** Clears all pools in the group. This will reset all pools and free their resources. */
    clear(): void;
}
/**
 * A singleton instance of the PoolGroupClass that can be used throughout the application.
 * @internal
 */
export declare const BigPool: PoolGroupClass;
