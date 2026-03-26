import { type InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import { type Renderer } from '../../../rendering/renderers/types';
import { type RenderLayer } from '../../layers/RenderLayer';
import type { Container } from '../Container';
/**
 * The CollectRenderablesMixin interface defines methods for collecting renderable objects
 * from a container and its children. These methods add the renderables to an instruction set,
 * which is used by the renderer to process and display the scene.
 * @category scene
 * @internal
 */
export interface CollectRenderablesMixin {
    /**
     * Collects all renderables from the container and its children, adding them to the instruction set.
     * This method decides whether to use a simple or advanced collection method based on the container's properties.
     * @param {InstructionSet} instructionSet - The set of instructions to which the renderables will be added.
     * @param {Renderer} renderer - The renderer responsible for rendering the scene.
     * @param {RenderLayer} currentLayer - The current render layer being processed.
     * @internal
     */
    collectRenderables(instructionSet: InstructionSet, renderer: Renderer, currentLayer: RenderLayer): void;
    /**
     * Collects renderables using a simple method, suitable for containers marked as simple.
     * This method iterates over the container's children and adds their renderables to the instruction set.
     * @param {InstructionSet} instructionSet - The set of instructions to which the renderables will be added.
     * @param {Renderer} renderer - The renderer responsible for rendering the scene.
     * @param {RenderLayer} currentLayer - The current render layer being processed.
     * @internal
     */
    collectRenderablesSimple(instructionSet: InstructionSet, renderer: Renderer, currentLayer: RenderLayer): void;
    /**
     * Collects renderables using an advanced method, suitable for containers with complex processing needs.
     * This method handles additional effects and transformations that may be applied to the renderables.
     * @param {InstructionSet} instructionSet - The set of instructions to which the renderables will be added.
     * @param {Renderer} renderer - The renderer responsible for rendering the scene.
     * @param {RenderLayer} currentLayer - The current render layer being processed.
     * @internal
     */
    collectRenderablesWithEffects(instructionSet: InstructionSet, renderer: Renderer, currentLayer: RenderLayer): void;
}
/**
 * The collectRenderablesMixin provides implementations for the methods defined in the CollectRenderablesMixin interface.
 * It includes logic to determine the appropriate method for collecting renderables based on the container's properties.
 * @internal
 */
export declare const collectRenderablesMixin: Partial<Container>;
