import { Filter } from '../../Filter';
import type { RenderSurface } from '../../../rendering/renderers/shared/renderTarget/RenderTargetSystem';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { FilterSystem } from '../../FilterSystem';
import type { BlurFilterOptions } from './BlurFilter';
/**
 * Options for BlurFilterPass
 * @category filters
 * @internal
 */
export interface BlurFilterPassOptions extends BlurFilterOptions {
    /** Do pass along the x-axis (`true`) or y-axis (`false`). */
    horizontal: boolean;
}
/**
 * The BlurFilterPass applies a horizontal or vertical Gaussian blur to an object.
 * @category filters
 * @advanced
 * @example
 * import { BlurFilterPass } from 'pixi.js';
 *
 * const filter = new BlurFilterPass({ horizontal: true, strength: 8 });
 * sprite.filters = filter;
 *
 * // update blur
 * filter.blur = 16;
 */
export declare class BlurFilterPass extends Filter {
    /** Default blur filter pass options */
    static defaultOptions: Partial<BlurFilterPassOptions>;
    /** Do pass along the x-axis (`true`) or y-axis (`false`). */
    horizontal: boolean;
    /** The number of passes to run the filter. */
    passes: number;
    /** The strength of the blur filter. */
    strength: number;
    /** Whether to use legacy blur pass behavior. */
    legacy: boolean;
    private _quality;
    private readonly _uniforms;
    private readonly _blurUniforms;
    /**
     * @param options
     * @param options.horizontal - Do pass along the x-axis (`true`) or y-axis (`false`).
     * @param options.strength - The strength of the blur filter.
     * @param options.quality - The quality of the blur filter.
     * @param options.kernelSize - The kernelSize of the blur filter.Options: 5, 7, 9, 11, 13, 15.
     */
    constructor(options: BlurFilterPassOptions);
    /**
     * Applies the filter.
     * @param filterManager - The manager.
     * @param input - The input target.
     * @param output - The output target.
     * @param clearMode - How to clear
     */
    apply(filterManager: FilterSystem, input: Texture, output: RenderSurface, clearMode: boolean): void;
    private _applyLegacy;
    private _applyOptimized;
    /**
     * Calculates the initial strength for the first blur pass so that the combined
     * effect of all passes matches the filter's target strength.
     *
     * Uses variance addition property: for Gaussian blurs, σ_combined² = Σσᵢ²
     * With halving scheme (s, s/2, s/4, ...), sum of squared coefficients = 4/3
     */
    private _calculateInitialStrength;
    /**
     * Sets the strength of both the blur.
     * @default 16
     */
    get blur(): number;
    set blur(value: number);
    /**
     * Sets the quality of the blur by modifying the number of passes. More passes means higher
     * quality blurring but the lower the performance.
     * @default 4
     */
    get quality(): number;
    set quality(value: number);
}
