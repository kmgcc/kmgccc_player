import { type InstructionSet } from '../../../rendering/renderers/shared/instructions/InstructionSet';
import { type Renderer, type RenderPipes } from '../../../rendering/renderers/types';
import { type Container } from '../Container';
/**
 * Deprecated, please use container.collectRenderables instead.
 * @param container - The container to collect renderables from.
 * @param instructionSet - The instruction set to add the renderables to.
 * @param rendererOrPipes - The renderer to collect the renderables from.
 * @deprecated since version 8.7.0
 * @see container.collectRenderables
 * @internal
 */
export declare function collectAllRenderables(container: Container, instructionSet: InstructionSet, rendererOrPipes: Renderer | RenderPipes): void;
