import type { Container } from '../../scene/container/Container';
import type { RenderGroup } from '../../scene/container/RenderGroup';
/**
 * @param container
 * @param depth
 * @param data
 * @param data.color
 * @internal
 */
export declare function logScene(container: Container, depth?: number, data?: {
    color?: string;
}): void;
/**
 * @param renderGroup
 * @param depth
 * @param data
 * @param data.index
 * @param data.color
 * @internal
 */
export declare function logRenderGroupScene(renderGroup: RenderGroup, depth?: number, data?: {
    index: number;
    color?: string;
}): void;
