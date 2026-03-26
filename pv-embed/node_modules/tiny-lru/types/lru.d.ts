/**
 * Factory function to create a new LRU cache instance with parameter validation.
 * @param max Maximum number of items to store (default: 1000, 0 = unlimited)
 * @param ttl Time to live in milliseconds (default: 0, 0 = no expiration)
 * @param resetTtl Whether to reset TTL when accessing existing items via get() (default: false)
 * @returns A new LRU cache instance
 * @throws TypeError when parameters are invalid (negative numbers or wrong types)
 */
export function lru<T = any>(max?: number, ttl?: number, resetTtl?: boolean): LRU<T>;

/**
 * Internal structure representing a cache item in the doubly-linked list.
 */
export interface LRUItem<T> {
    /** Expiration timestamp in milliseconds (0 if no TTL) */
    expiry: number;
    /** The key associated with this item */
    key: any;
    /** Pointer to the previous item in the LRU list */
    prev: LRUItem<T> | null;
    /** Pointer to the next item in the LRU list */
    next: LRUItem<T> | null;
    /** The cached value */
    value: T;
}

/**
 * High-performance Least Recently Used (LRU) cache with optional TTL support.
 * All core operations (get, set, delete) are O(1).
 */
export class LRU<T = any> {
    /**
     * Creates a new LRU cache instance.
     * Note: Constructor does not validate parameters. Use lru() factory function for parameter validation.
     * @param max Maximum number of items to store (default: 0, 0 = unlimited)
     * @param ttl Time to live in milliseconds (default: 0, 0 = no expiration)
     * @param resetTtl Whether to reset TTL when accessing existing items via get() (default: false)
     */
    constructor(max?: number, ttl?: number, resetTtl?: boolean);
    
    /** Pointer to the least recently used item (first to be evicted) */
    readonly first: LRUItem<T> | null;
    /** Hash map for O(1) key-based access to cache nodes */
    readonly items: Record<any, LRUItem<T>>;
    /** Pointer to the most recently used item */
    readonly last: LRUItem<T> | null;
    /** Maximum number of items to store (0 = unlimited) */
    readonly max: number;
    /** Whether to reset TTL on each get() operation */
    readonly resetTtl: boolean;
    /** Current number of items in the cache */
    readonly size: number;
    /** Time-to-live in milliseconds (0 = no expiration) */
    readonly ttl: number;
    
    /**
     * Removes all items from the cache.
     * @returns The LRU instance for method chaining
     */
    clear(): this;
    
    /**
     * Removes an item from the cache by key.
     * @param key The key of the item to delete
     * @returns The LRU instance for method chaining
     */
    delete(key: any): this;
    
    /**
     * Returns an array of [key, value] pairs for the specified keys.
     * Order follows LRU order (least to most recently used).
     * @param keys Array of keys to get entries for (defaults to all keys)
     * @returns Array of [key, value] pairs in LRU order
     */
    entries(keys?: any[]): [any, T][];
    
    /**
     * Removes the least recently used item from the cache.
     * @param bypass Whether to force eviction even when cache is empty
     * @returns The LRU instance for method chaining
     */
    evict(bypass?: boolean): this;
    
    /**
     * Returns the expiration timestamp for a given key.
     * @param key The key to check expiration for
     * @returns The expiration timestamp in milliseconds, or undefined if key doesn't exist
     */
    expiresAt(key: any): number | undefined;
    
    /**
     * Retrieves a value from the cache by key. Updates the item's position to most recently used.
     * @param key The key to retrieve
     * @returns The value associated with the key, or undefined if not found or expired
     */
    get(key: any): T | undefined;
    
    /**
     * Checks if a key exists in the cache.
     * @param key The key to check for
     * @returns True if the key exists, false otherwise
     */
    has(key: any): boolean;
    
    /**
     * Returns an array of all keys in the cache, ordered from least to most recently used.
     * @returns Array of keys in LRU order
     */
    keys(): any[];
    
    /**
     * Sets a value in the cache. Updates the item's position to most recently used.
     * @param key The key to set
     * @param value The value to store
     * @param bypass Internal parameter for setWithEvicted method
     * @param resetTtl Whether to reset the TTL for this operation
     * @returns The LRU instance for method chaining
     */
    set(key: any, value: T, bypass?: boolean, resetTtl?: boolean): this;
    
    /**
     * Sets a value in the cache and returns any evicted item.
     * @param key The key to set
     * @param value The value to store
     * @param resetTtl Whether to reset the TTL for this operation
     * @returns The evicted item (if any) or null
     */
    setWithEvicted(key: any, value: T, resetTtl?: boolean): LRUItem<T> | null;
    
    /**
     * Returns an array of all values in the cache for the specified keys.
     * Order follows LRU order (least to most recently used).
     * @param keys Array of keys to get values for (defaults to all keys)
     * @returns Array of values corresponding to the keys in LRU order
     */
    values(keys?: any[]): T[];
}
