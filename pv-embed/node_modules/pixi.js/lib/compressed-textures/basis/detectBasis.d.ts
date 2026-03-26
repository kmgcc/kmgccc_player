import type { FormatDetectionParser } from '../../assets/detections/types';
/**
 * Detects if Basis textures are supported by the browser.
 * This is done by checking if WebGL or WebGPU is supported.
 * If either is supported, Basis textures can be used.
 * @category assets
 * @internal
 */
export declare const detectBasis: FormatDetectionParser;
