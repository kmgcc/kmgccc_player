import type { UboElement, UNIFORM_TYPES_SINGLE, UniformsSyncCallback } from '../types';
/**
 * @param uboElements
 * @param parserCode
 * @param arrayGenerationFunction
 * @param singleSettersMap
 * @internal
 */
export declare function createUboSyncFunction(uboElements: UboElement[], parserCode: 'uboWgsl' | 'uboStd40', arrayGenerationFunction: (uboElement: UboElement, offsetToAdd: number) => string, singleSettersMap: Record<UNIFORM_TYPES_SINGLE, string>): UniformsSyncCallback;
