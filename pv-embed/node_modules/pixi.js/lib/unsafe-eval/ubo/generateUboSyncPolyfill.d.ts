import type { UboElement, UniformsSyncCallback } from '../../rendering/renderers/shared/shader/types';
/**
 * @param uboElements
 * @internal
 */
export declare function generateUboSyncPolyfillSTD40(uboElements: UboElement[]): UniformsSyncCallback;
/**
 * @param uboElements
 * @internal
 */
export declare function generateUboSyncPolyfillWGSL(uboElements: UboElement[]): UniformsSyncCallback;
