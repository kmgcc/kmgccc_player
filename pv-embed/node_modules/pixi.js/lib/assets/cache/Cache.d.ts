import type { CacheParser } from './CacheParser';
/** @internal */
declare class CacheClass {
    private readonly _parsers;
    private readonly _cache;
    private readonly _cacheMap;
    /** Clear all entries. */
    reset(): void;
    /**
     * Check if the key exists
     * @param key - The key to check
     */
    has(key: any): boolean;
    /**
     * Fetch entry by key
     * @param key - The key of the entry to get
     */
    get<T = any>(key: any): T;
    /**
     * Set a value by key or keys name
     * @param key - The key or keys to set
     * @param value - The value to store in the cache or from which cacheable assets will be derived.
     */
    set<T = any>(key: any | any[], value: T): void;
    /**
     * Remove entry by key
     *
     * This function will also remove any associated alias from the cache also.
     * @param key - The key of the entry to remove
     */
    remove(key: any): void;
    /**
     * All loader parsers registered
     * @advanced
     */
    get parsers(): CacheParser[];
}
/**
 * A global cache for all assets in your PixiJS application. The cache system provides fast
 * access to loaded assets and prevents duplicate loading.
 *
 * Key Features:
 * - Automatic caching of loaded assets
 * - Support for custom cache parsers
 * - Automatic parsing of complex assets (e.g., spritesheets)
 * - Memory management utilities
 * > [!IMPORTANT] You typically do not need to use this class directly.
 * > Use the main {@link Assets} class for high-level asset management.
 * > `Assets.get(key)` will automatically use the cache.
 * @example
 * ```ts
 * import { Cache } from 'pixi.js';
 *
 * // Store an asset in the cache
 * Cache.set('myTexture', texture);
 *
 * // Retrieve an asset
 * const texture = Cache.get('myTexture');
 *
 * // Check if an asset exists
 * if (Cache.has('myTexture')) {
 *     // Use the cached asset
 *     const sprite = new Sprite(Cache.get('myTexture'));
 * }
 *
 * // Remove an asset from cache
 * Cache.remove('myTexture');
 *
 * // Clear all cached assets
 * Cache.reset();
 * ```
 * @remarks
 * The Cache is a core component of PixiJS' asset management system:
 * - Used internally by the {@link Assets} class
 * - Supports automatic parsing via {@link CacheParser}
 * - Handles complex asset types like spritesheets
 * - Manages memory through asset removal
 *
 * > [!IMPORTANT]
 * > This is a singleton class and should not be instantiated directly.
 * > Use the exported `Cache` instance instead.
 * @see {@link Assets} For high-level asset management
 * @see {@link CacheParser} For custom cache parsing
 * @category assets
 * @class
 * @advanced
 */
export declare const Cache: CacheClass;
export {};
