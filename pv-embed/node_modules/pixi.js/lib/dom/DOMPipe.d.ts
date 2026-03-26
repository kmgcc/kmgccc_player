import { ExtensionType } from '../extensions/Extensions';
import { type DOMContainer } from './DOMContainer';
import type { InstructionSet } from '../rendering/renderers/shared/instructions/InstructionSet';
import type { RenderPipe } from '../rendering/renderers/shared/instructions/RenderPipe';
import type { Renderer } from '../rendering/renderers/types';
/**
 * The DOMPipe class is responsible for managing and rendering DOM elements within a PixiJS scene.
 * It maps dom elements to the canvas and ensures they are correctly positioned and visible.
 * @internal
 */
export declare class DOMPipe implements RenderPipe<DOMContainer> {
    /**
     * Static property defining the extension type and name for the DOMPipe.
     * This is used to register the DOMPipe with different rendering pipelines.
     */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLPipes, ExtensionType.WebGPUPipes, ExtensionType.CanvasPipes];
        readonly name: "dom";
    };
    private _renderer;
    /** Array to keep track of attached DOM elements */
    private readonly _attachedDomElements;
    /** The main DOM element that acts as a container for other DOM elements */
    private readonly _domElement;
    /** The CanvasTransformSync instance that keeps the DOM element in sync with the canvas */
    private _canvasObserver;
    /**
     * Constructor for the DOMPipe class.
     * @param renderer - The renderer instance that this DOMPipe will be associated with.
     */
    constructor(renderer: Renderer);
    /** Initializes the DOMPipe, setting up the main DOM element and adding it to the document body. */
    init(): void;
    /**
     * Adds a renderable DOM container to the list of attached elements.
     * @param domContainer - The DOM container to be added.
     * @param _instructionSet - The instruction set (unused).
     */
    addRenderable(domContainer: DOMContainer, _instructionSet: InstructionSet): void;
    /**
     * Updates a renderable DOM container.
     * @param _domContainer - The DOM container to be updated (unused).
     */
    updateRenderable(_domContainer: DOMContainer): void;
    /**
     * Validates a renderable DOM container.
     * @param _domContainer - The DOM container to be validated (unused).
     * @returns Always returns true as validation is not required.
     */
    validateRenderable(_domContainer: DOMContainer): boolean;
    /** Handles the post-rendering process, ensuring DOM elements are correctly positioned and visible. */
    postrender(): void;
    /** Destroys the DOMPipe, removing all attached DOM elements and cleaning up resources. */
    destroy(): void;
}
