import { UniformGroup } from '../../shared/shader/UniformGroup';
/**
 * Automatically generates a uniform group that holds the texture samplers for a shader.
 * This is used mainly by the shaders that batch textures!
 * @param maxTextures - the number of textures that this uniform group will contain.
 * @returns a uniform group that holds the texture samplers.
 * @internal
 */
export declare function getBatchSamplersUniformGroup(maxTextures: number): UniformGroup<any>;
