import { UniformGroup } from '../../../shared/shader/UniformGroup';
import type { UniformsSyncCallback } from '../../../shared/shader/types';
/**
 * @param group
 * @param uniformData
 * @internal
 */
export declare function generateUniformsSync(group: UniformGroup, uniformData: Record<string, any>): UniformsSyncCallback;
