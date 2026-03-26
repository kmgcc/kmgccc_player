import type { ExtractedAttributeData } from '../../../gl/shader/program/extractAttributesFromGlProgram';
import type { ProgramSource } from '../GpuProgram';
/**
 * Extracts vertex attributes from a WGSL shader program.
 *
 * Supports two styles:
 * 1. Inline \@location decorators in function parameters
 * 2. Struct-based input where \@location decorators are in the struct definition
 * @param root0
 * @param root0.source
 * @param root0.entryPoint
 * @internal
 */
export declare function extractAttributesFromGpuProgram({ source, entryPoint }: ProgramSource): Record<string, ExtractedAttributeData>;
