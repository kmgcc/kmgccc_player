import type { UNIFORM_TYPES, UniformData } from '../types';
interface UniformParserDefinition {
    type: UNIFORM_TYPES;
    test(data: UniformData): boolean;
    ubo?: string;
    uboWgsl?: string;
    uboStd40?: string;
    uniform?: string;
}
/** @internal */
export declare const uniformParsers: UniformParserDefinition[];
export {};
