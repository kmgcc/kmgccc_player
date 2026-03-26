/**
 * deprecation name for version 8.0.0
 * @ignore
 * @internal
 */
export declare const v8_0_0 = "8.0.0";
/**
 * deprecation name for version 8.1.0
 * @ignore
 * @internal
 */
export declare const v8_3_4 = "8.3.4";
/**
 * Options for managing deprecation messages behavior globally
 * @category utils
 * @standard
 */
interface DeprecationOptions {
    /**
     * When set to true, all deprecation warning messages will be hidden.
     * Use this if you want to silence deprecation notifications.
     * @default false
     * @standard
     */
    quiet: boolean;
    /**
     * When set to true, deprecation messages will be displayed as plain text without color formatting.
     * Use this if you want to disable colored console output for deprecation warnings.
     * @default false
     * @standard
     */
    noColor: boolean;
}
/** @internal */
export type DeprecationFn = ((version: string, message: string, ignoreDepth?: number) => void) & DeprecationOptions;
/**
 * Helper for warning developers about deprecated features & settings.
 * A stack track for warnings is given; useful for tracking-down where
 * deprecated methods/properties/classes are being used within the code.
 *
 * Deprecation messages can be configured globally:
 * ```ts
 * // Suppress all deprecation messages
 * deprecation.quiet = true;
 *
 * // Put plain text to console instead of colorful messages
 * deprecation.noColor = true;
 * ```
 * @category utils
 * @ignore
 * @function deprecation
 * @param {string} version - The version where the feature became deprecated
 * @param {string} message - Message should include what is deprecated, where, and the new solution
 * @param {number} [ignoreDepth=3] - The number of steps to ignore at the top of the error stack
 *        this is mostly to ignore internal deprecation calls.
 */
export declare const deprecation: DeprecationFn;
export {};
