import type { PRECISION } from '../../const';
interface EnsurePrecisionOptions {
    requestedVertexPrecision: PRECISION;
    requestedFragmentPrecision: PRECISION;
    maxSupportedVertexPrecision: PRECISION;
    maxSupportedFragmentPrecision: PRECISION;
}
/**
 * Sets the float precision on the shader, ensuring the device supports the request precision.
 * If the precision is already present, it just ensures that the device is able to handle it.
 * @param src
 * @param options
 * @param options.requestedVertexPrecision
 * @param options.requestedFragmentPrecision
 * @param options.maxSupportedVertexPrecision
 * @param options.maxSupportedFragmentPrecision
 * @param isFragment
 * @private
 */
export declare function ensurePrecision(src: string, options: EnsurePrecisionOptions, isFragment: boolean): string;
export {};
