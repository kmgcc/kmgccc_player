/**
 * Helper for checking for WebGL support in the current environment.
 *
 * Results are cached after first call for better performance.
 * @example
 * ```ts
 * // Basic WebGL support check
 * if (isWebGLSupported()) {
 *     console.log('WebGL is available');
 * }
 * ```
 * @param failIfMajorPerformanceCaveat - Whether to fail if there is a major performance caveat
 * @returns True if WebGL is supported
 * @category utils
 * @standard
 */
export declare function isWebGLSupported(failIfMajorPerformanceCaveat?: boolean): boolean;
