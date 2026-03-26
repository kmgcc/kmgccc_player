/**
 * A generic class for managing a pool of items.
 * @template T The type of items in the pool. Must implement {@link PoolItem}.
 * @template I The type of argument passed to item's `init` method if it exists.
 * @category utils
 * @advanced
 */
export declare class Pool<T extends PoolItem, I = Parameters<NonNullable<T['init']>>[0]> {
    /** @internal */
    readonly _classType: PoolItemConstructor<T>;
    private readonly _pool;
    private _count;
    private _index;
    /**
     * Constructs a new Pool.
     * @param ClassType - The constructor of the items in the pool.
     * @param {number} [initialSize] - The initial size of the pool.
     */
    constructor(ClassType: PoolItemConstructor<T>, initialSize?: number);
    /**
     * Prepopulates the pool with a given number of items.
     * @param total - The number of items to add to the pool.
     */
    prepopulate(total: number): void;
    /**
     * Gets an item from the pool. Calls the item's `init` method if it exists.
     * If there are no items left in the pool, a new one will be created.
     * @param {I} [data] - Optional data to pass to the item's constructor.
     * @returns {T} The item from the pool.
     */
    get(data?: I): T;
    /**
     * Returns an item to the pool. Calls the item's `reset` method if it exists.
     * @param {T} item - The item to return to the pool.
     */
    return(item: T): void;
    /**
     * Gets the number of items in the pool.
     * @readonly
     */
    get totalSize(): number;
    /**
     * Gets the number of items in the pool that are free to use without needing to create more.
     * @readonly
     */
    get totalFree(): number;
    /**
     * Gets the number of items in the pool that are currently in use.
     * @readonly
     */
    get totalUsed(): number;
    /** clears the pool */
    clear(): void;
}
/**
 * An object that can be stored in a {@link Pool}.
 * @category utils
 * @advanced
 */
export type PoolItem = {
    init?: (data?: any) => void;
    reset?: () => void;
    destroy?: () => void;
    [key: string]: any;
};
/**
 * The constructor of an object that can be stored in a {@link Pool}.
 * @typeParam K - The type of the object that can be stored in a {@link Pool}.
 * @category utils
 * @advanced
 */
export type PoolItemConstructor<K extends PoolItem> = new () => K;
