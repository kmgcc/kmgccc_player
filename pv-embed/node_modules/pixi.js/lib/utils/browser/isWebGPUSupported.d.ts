/**
 * Helper for checking for WebGPU support in the current environment.
 * Results are cached after first call for better performance.
 * @example
 * ```ts
 * // Basic WebGPU support check
 * const hasWebGPU = await isWebGPUSupported();
 * console.log('WebGPU available:', hasWebGPU);
 * ```
 * @param options - The options for requesting a GPU adapter
 * @returns Promise that resolves to true if WebGPU is supported
 * @category utils
 * @standard
 */
export declare function isWebGPUSupported(options?: GPURequestAdapterOptions): Promise<boolean>;
