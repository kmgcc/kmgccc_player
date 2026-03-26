/** Interface for objects that can be cleaned up by the PoolCollector. */
interface Cleanable {
    clear(): void;
}
/**
 * A singleton collector that manages and provides cleanup for registered pools and caches.
 * Useful for cleaning up all pools/caches at once during application shutdown or reset.
 * @category utils
 * @internal
 */
export declare const GlobalResourceRegistry: {
    /**
     * Set of registered pools and cleanable objects.
     * @private
     */
    _registeredResources: Set<Cleanable>;
    /**
     * Registers a pool or cleanable object for cleanup.
     * @param {Cleanable} pool - The pool or object to register.
     */
    register(pool: Cleanable): void;
    /**
     * Unregisters a pool or cleanable object from cleanup.
     * @param {Cleanable} pool - The pool or object to unregister.
     */
    unregister(pool: Cleanable): void;
    /** Clears all registered pools and cleanable objects. This will call clear() on each registered item. */
    release(): void;
    /**
     * Gets the number of registered pools and cleanable objects.
     * @returns {number} The count of registered items.
     */
    readonly registeredCount: number;
    /**
     * Checks if a specific pool or cleanable object is registered.
     * @param {Cleanable} pool - The pool or object to check.
     * @returns {boolean} True if the item is registered, false otherwise.
     */
    isRegistered(pool: Cleanable): boolean;
    /**
     * Removes all registrations without clearing the pools.
     * Useful if you want to reset the collector without affecting the pools.
     */
    reset(): void;
};
export {};
