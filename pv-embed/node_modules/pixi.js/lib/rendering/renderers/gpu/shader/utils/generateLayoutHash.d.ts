import type { ProgramLayout } from '../GpuProgram';
import type { StructsAndGroups } from './extractStructAndGroups';
/**
 * @param root0
 * @param root0.groups
 * @internal
 */
export declare function generateLayoutHash({ groups }: StructsAndGroups): ProgramLayout;
