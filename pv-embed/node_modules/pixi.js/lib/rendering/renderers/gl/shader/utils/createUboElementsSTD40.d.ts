import type { UboLayout, UniformData } from '../../../shared/shader/types';
/** @internal */
export declare const WGSL_TO_STD40_SIZE: Record<string, number>;
/**
 * @param uniformData
 * @internal
 */
export declare function createUboElementsSTD40(uniformData: UniformData[]): UboLayout;
