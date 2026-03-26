/**
 * Automatically detects the environment and loads the appropriate extensions.
 * @param skip - whether to skip loading the default extensions
 * @category environment
 * @advanced
 */
export declare function loadEnvironmentExtensions(skip: boolean): Promise<void>;
/**
 * @param add - whether to add the default imports to the bundle
 * @deprecated since 8.1.6. Use `loadEnvironmentExtensions` instead
 * @category environment
 * @advanced
 */
export declare function autoDetectEnvironment(add: boolean): Promise<void>;
