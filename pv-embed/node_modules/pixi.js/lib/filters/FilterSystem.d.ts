import { ExtensionType } from '../extensions/Extensions';
import { Matrix } from '../maths/matrix/Matrix';
import { Texture } from '../rendering/renderers/shared/texture/Texture';
import { Bounds } from '../scene/container/bounds/Bounds';
import type { WebGLRenderer } from '../rendering/renderers/gl/WebGLRenderer';
import type { WebGPURenderer } from '../rendering/renderers/gpu/WebGPURenderer';
import type { Instruction } from '../rendering/renderers/shared/instructions/Instruction';
import type { Renderable } from '../rendering/renderers/shared/Renderable';
import type { RenderTarget } from '../rendering/renderers/shared/renderTarget/RenderTarget';
import type { RenderSurface } from '../rendering/renderers/shared/renderTarget/RenderTargetSystem';
import type { System } from '../rendering/renderers/shared/system/System';
import type { Container } from '../scene/container/Container';
import type { Sprite } from '../scene/sprite/Sprite';
import type { Filter } from './Filter';
import type { FilterEffect } from './FilterEffect';
/**
 * The filter pipeline is responsible for applying filters scene items!
 *
 * KNOWN BUGS:
 * 1. Global bounds calculation is incorrect if it is used when flip flopping filters. The maths can be found below
 * eg: filters [noiseFilter, blurFilter] noiseFilter will calculate the global bounds incorrectly.
 *
 * 2. RenderGroups do not work with filters. This is because the renderGroup matrix is not currently taken into account.
 *
 * Implementation notes:
 * 1. Gotcha - nesting filters that require blending will not work correctly. This creates a chicken and egg problem
 * the complexity and performance required to do this is not worth it i feel.. but lets see if others agree!
 *
 * 2. Filters are designed to be changed on the fly, this is means that changing filter information each frame will
 * not trigger an instruction rebuild. If you are constantly turning a filter on and off.. its therefore better to set
 * enabled to true or false on the filter. Or setting an empty array.
 *
 * 3. Need to look at perhaps aliasing when flip flopping filters. Really we should only need to antialias the FIRST
 * Texture we render too. The rest can be non aliased. This might help performance.
 * Currently we flip flop with an antialiased texture if antialiasing is enabled on the filter.
 * @internal
 */
export interface FilterInstruction extends Instruction {
    renderPipeId: 'filter';
    action: 'pushFilter' | 'popFilter';
    container?: Container;
    renderables?: Renderable[];
    filterEffect: FilterEffect;
}
/**
 * System that manages the filter pipeline
 * @category rendering
 * @advanced
 */
export declare class FilterSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem];
        readonly name: "filter";
    };
    readonly renderer: WebGLRenderer | WebGPURenderer;
    private _filterStackIndex;
    private _filterStack;
    private readonly _filterGlobalUniforms;
    private readonly _globalFilterBindGroup;
    private _activeFilterData;
    private _passthroughFilter;
    constructor(renderer: WebGLRenderer | WebGPURenderer);
    /**
     * The back texture of the currently active filter. Requires the filter to have `blendRequired` set to true.
     * @readonly
     */
    get activeBackTexture(): Texture | undefined;
    /**
     * Pushes a filter instruction onto the filter stack.
     * @param instruction - The instruction containing the filter effect and container.
     * @internal
     */
    push(instruction: FilterInstruction): void;
    /**
     * Applies filters to a texture.
     *
     * This method takes a texture and a list of filters, applies the filters to the texture,
     * and returns the resulting texture.
     * @param {object} params - The parameters for applying filters.
     * @param {Texture} params.texture - The texture to apply filters to.
     * @param {Filter[]} params.filters - The filters to apply.
     * @returns {Texture} The resulting texture after all filters have been applied.
     * @example
     *
     * ```ts
     * // Create a texture and a list of filters
     * const texture = new Texture(...);
     * const filters = [new BlurFilter(), new ColorMatrixFilter()];
     *
     * // Apply the filters to the texture
     * const resultTexture = filterSystem.applyToTexture({ texture, filters });
     *
     * // Use the resulting texture
     * sprite.texture = resultTexture;
     * ```
     *
     * Key Points:
     * 1. padding is not currently supported here - so clipping may occur with filters that use padding.
     * 2. If all filters are disabled or skipped, the original texture is returned.
     */
    generateFilteredTexture({ texture, filters }: {
        texture: Texture;
        filters: Filter[];
    }): Texture;
    /** @internal */
    pop(): void;
    /**
     * Copies the last render surface to a texture.
     * @param lastRenderSurface - The last render surface to copy from.
     * @param bounds - The bounds of the area to copy.
     * @param previousBounds - The previous bounds to use for offsetting the copy.
     */
    getBackTexture(lastRenderSurface: RenderTarget, bounds: Bounds, previousBounds?: Bounds): Texture<import("..").TextureSource<any>>;
    /**
     * Applies a filter to a texture.
     * @param filter - The filter to apply.
     * @param input - The input texture.
     * @param output - The output render surface.
     * @param clear - Whether to clear the output surface before applying the filter.
     */
    applyFilter(filter: Filter, input: Texture, output: RenderSurface, clear: boolean): void;
    /**
     * Multiply _input normalized coordinates_ to this matrix to get _sprite texture normalized coordinates_.
     *
     * Use `outputMatrix * vTextureCoord` in the shader.
     * @param outputMatrix - The matrix to output to.
     * @param {Sprite} sprite - The sprite to map to.
     * @returns The mapped matrix.
     */
    calculateSpriteMatrix(outputMatrix: Matrix, sprite: Sprite): Matrix;
    destroy(): void;
    private _getPassthroughFilter;
    /**
     * Sets up the bind groups and renders the filter.
     * @param filter - The filter to apply
     * @param input - The input texture
     * @param renderer - The renderer instance
     */
    private _setupBindGroupsAndRender;
    /**
     * Sets up the filter textures including input texture and back texture if needed.
     * @param filterData - The filter data to update
     * @param bounds - The bounds for the texture
     * @param renderer - The renderer instance
     * @param previousFilterData - The previous filter data for back texture calculation
     */
    private _setupFilterTextures;
    /**
     * Calculates and sets the global frame for the filter.
     * @param filterData - The filter data to update
     * @param offsetX - The X offset
     * @param offsetY - The Y offset
     * @param globalResolution - The global resolution
     * @param sourceWidth - The source texture width
     * @param sourceHeight - The source texture height
     */
    private _calculateGlobalFrame;
    /**
     * Updates the filter uniforms with the current filter state.
     * @param input - The input texture
     * @param output - The output render surface
     * @param filterData - The current filter data
     * @param offsetX - The X offset for positioning
     * @param offsetY - The Y offset for positioning
     * @param resolution - The current resolution
     * @param isFinalTarget - Whether this is the final render target
     * @param clear - Whether to clear the output surface
     */
    private _updateFilterUniforms;
    /**
     * Finds the correct resolution by looking back through the filter stack.
     * @param rootResolution - The fallback root resolution to use
     * @returns The resolution from the previous filter or root resolution
     */
    private _findFilterResolution;
    /**
     * Finds the offset from the previous non-skipped filter in the stack.
     * @returns The offset coordinates from the previous filter
     */
    private _findPreviousFilterOffset;
    /**
     * Calculates the filter area bounds based on the instruction type.
     * @param instruction - The filter instruction
     * @param bounds - The bounds object to populate
     */
    private _calculateFilterArea;
    private _applyFiltersToTexture;
    private _calculateFilterBounds;
    private _popFilterData;
    private _getPreviousFilterData;
    private _pushFilterData;
}
