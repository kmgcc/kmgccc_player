import { ExtensionType } from '../../../extensions/Extensions';
import type { ICanvasRenderingContext2D } from '../../../environment/canvas/ICanvasRenderingContext2D';
import type { Filter } from '../../../filters/Filter';
import type { FilterInstruction } from '../../../filters/FilterSystem';
import type { System } from '../shared/system/System';
import type { Texture } from '../shared/texture/Texture';
/**
 * Interface for filters that can supply a CSS filter string for Canvas2D.
 * @category filters
 * @advanced
 */
export interface CanvasFilterCapable {
    /** Returns CSS filter string (e.g., 'blur(5px)') or null if not supported */
    getCanvasFilterString(): string | null;
}
/**
 * Check if a filter supports Canvas2D rendering.
 * @param filter - The filter to check
 * @returns True if the filter implements getCanvasFilterString()
 * @internal
 */
export declare function isCanvasFilterCapable(filter: Filter): filter is Filter & CanvasFilterCapable;
/**
 * Canvas2D filter system that applies compatible filters using CSS filter strings.
 * Unsupported filters are skipped with a warn-once message.
 * @category rendering
 * @advanced
 */
export declare class CanvasFilterSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "filter";
    };
    /** The renderer this system is attached to */
    readonly renderer: {
        canvasContext: {
            activeContext: ICanvasRenderingContext2D;
            activeResolution: number;
        };
    };
    private _filterStack;
    private _filterStackIndex;
    private _savedStates;
    private _alphaMultiplier;
    private _warnedFilterTypes;
    /**
     * @param renderer - The Canvas renderer
     * @param renderer.canvasContext
     * @param renderer.canvasContext.activeContext
     * @param renderer.canvasContext.activeResolution
     */
    constructor(renderer: {
        canvasContext: {
            activeContext: ICanvasRenderingContext2D;
            activeResolution: number;
        };
    });
    /**
     * Push a filter instruction onto the stack.
     * Called when entering a filtered container.
     * @param instruction - The filter instruction from FilterPipe
     */
    push(instruction: FilterInstruction): void;
    /** Pop a filter from the stack. Called when exiting a filtered container. */
    pop(): void;
    /**
     * Applies supported filters to a texture and returns a new texture.
     * Unsupported filters are skipped with a warn-once message.
     * @param params - The parameters for applying filters.
     * @param params.texture
     * @param params.filters
     * @returns The resulting texture after filters are applied.
     */
    generateFilteredTexture({ texture, filters }: {
        texture: Texture;
        filters: Filter[];
    }): Texture;
    /**
     * Calculate the filter area bounds.
     * @param instruction - Filter instruction
     * @param bounds - Bounds object to populate
     */
    private _calculateFilterArea;
    private _warnUnsupportedFilter;
    get alphaMultiplier(): number;
    private _pushFilterFrame;
    private _popFilterFrame;
    /** Destroys the system */
    destroy(): void;
}
