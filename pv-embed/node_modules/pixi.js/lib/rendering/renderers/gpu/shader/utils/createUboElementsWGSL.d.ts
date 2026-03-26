import type { UboLayout, UNIFORM_TYPES, UniformData } from '../../../shared/shader/types';
/** @internal */
export declare const WGSL_ALIGN_SIZE_DATA: Record<UNIFORM_TYPES | string, {
    align: number;
    size: number;
}>;
/**
 * @param uniformData
 * @internal
 */
export declare function createUboElementsWGSL(uniformData: UniformData[]): UboLayout;
