import { type RenderLayer } from '../../layers/RenderLayer';
import { Bounds } from '../bounds/Bounds';
import type { Container } from '../Container';
/**
 * Interface for the GetFastGlobalBoundsMixin, which provides methods to compute
 * an approximate global bounding box for a container and its children.
 * @category scene
 * @advanced
 */
export interface GetFastGlobalBoundsMixin {
    /**
     * Computes an approximate global bounding box for the container and its children.
     * This method is optimized for speed by using axis-aligned bounding boxes (AABBs),
     * and uses the last render results from when it updated the transforms. This function does not update them.
     * which may result in slightly larger bounds but never smaller than the actual bounds.
     *
     * for accurate (but less performant) results use `container.getGlobalBounds`
     * @param {boolean} [factorRenderLayers] - A flag indicating whether to consider render layers in the calculation.
     * @param {Bounds} [bounds] - The output bounds object to store the result. If not provided, a new one is created.
     * @returns {Bounds} The computed bounds.
     * @advanced
     */
    getFastGlobalBounds(factorRenderLayers?: boolean, bounds?: Bounds): Bounds;
    /**
     * Recursively calculates the global bounds for the container and its children.
     * This method is used internally by getFastGlobalBounds to traverse the scene graph.
     * @param {boolean} factorRenderLayers - A flag indicating whether to consider render layers in the calculation.
     * @param {Bounds} bounds - The bounds object to update with the calculated values.
     * @param {RenderLayer} currentLayer - The current render layer being processed.
     * @internal
     */
    _getGlobalBoundsRecursive(factorRenderLayers: boolean, bounds: Bounds, currentLayer: RenderLayer): void;
}
/**
 * Mixin providing the implementation of the GetFastGlobalBoundsMixin interface.
 * It includes methods to compute and recursively calculate global bounds for containers.
 * @internal
 */
export declare const getFastGlobalBoundsMixin: Partial<Container>;
