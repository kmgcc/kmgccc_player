import type { GlUniformData } from '../../rendering/renderers/gl/shader/GlProgram';
import type { UniformsSyncCallback } from '../../rendering/renderers/shared/shader/types';
import type { UniformGroup } from '../../rendering/renderers/shared/shader/UniformGroup';
/**
 * @param group
 * @param uniformData
 * @internal
 */
export declare function generateUniformsSyncPolyfill(group: UniformGroup, uniformData: Record<string, GlUniformData>): UniformsSyncCallback;
