import { Container } from '../Container';
import type { RenderGroup } from '../RenderGroup';
/**
 * @param renderGroup
 * @param updateChildRenderGroups
 * @internal
 */
export declare function updateRenderGroupTransforms(renderGroup: RenderGroup, updateChildRenderGroups?: boolean): void;
/**
 * @param renderGroup
 * @internal
 */
export declare function updateRenderGroupTransform(renderGroup: RenderGroup): void;
/**
 * @param container
 * @param updateTick
 * @param updateFlags
 * @internal
 */
export declare function updateTransformAndChildren(container: Container, updateTick: number, updateFlags: number): void;
