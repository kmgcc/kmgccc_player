import type { ProgramPipelineLayoutDescription } from '../GpuProgram';
import type { StructsAndGroups } from './extractStructAndGroups';
/**
 * @param root0
 * @param root0.groups
 * @internal
 */
export declare function generateGpuLayoutGroups({ groups }: StructsAndGroups): ProgramPipelineLayoutDescription;
