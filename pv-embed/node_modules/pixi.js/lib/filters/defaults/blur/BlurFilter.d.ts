import { Filter } from '../../Filter';
import { BlurFilterPass } from './BlurFilterPass';
import type { RenderSurface } from '../../../rendering/renderers/shared/renderTarget/RenderTargetSystem';
import type { Texture } from '../../../rendering/renderers/shared/texture/Texture';
import type { FilterOptions } from '../../Filter';
import type { FilterSystem } from '../../FilterSystem';
/**
 * Configuration options for the BlurFilter.
 * Controls how the Gaussian blur effect is applied.
 * @example
 * ```ts
 * // Basic blur with default values
 * const filter = new BlurFilter();
 *
 * // Custom blur configuration
 * const filter = new BlurFilter({
 *     strength: 8,        // Overall blur strength
 *     quality: 4,         // Higher quality = better blur
 *     kernelSize: 5      // Size of blur kernel
 * });
 *
 * // Different horizontal/vertical blur
 * const filter = new BlurFilter({
 *     strengthX: 4,      // Horizontal blur only
 *     strengthY: 12,     // Stronger vertical blur
 *     quality: 2         // Lower quality for better performance
 * });
 * ```
 * @remarks
 * - Higher quality values produce better blur but impact performance
 * - KernelSize affects blur precision and performance
 * - Strength values determine blur intensity
 * @see {@link BlurFilter} The filter that uses these options
 * @see {@link FilterOptions} Base filter options
 * @category filters
 * @standard
 */
export interface BlurFilterOptions extends FilterOptions {
    /**
     * The strength of the blur filter.
     * Applied to both horizontal and vertical blur if strengthX/Y not set.
     * @default 8
     */
    strength?: number;
    /**
     * The horizontal strength of the blur.
     * Overrides strength parameter for x-axis.
     * @default 8
     */
    strengthX?: number;
    /**
     * The vertical strength of the blur.
     * Overrides strength parameter for y-axis.
     * @default 8
     */
    strengthY?: number;
    /**
     * The quality of the blur filter.
     * Higher values mean better quality but slower performance.
     * @default 4
     */
    quality?: number;
    /**
     * The kernelSize of the blur filter.
     * Larger values create more precise blur but impact performance.
     * Options: 5, 7, 9, 11, 13, 15.
     * @default 5
     */
    kernelSize?: number;
    /**
     * When true, uses the legacy (pre-v8.x) blur pass behavior where strength
     * is distributed uniformly across passes (`strength / passes`) instead of
     * the optimized halving scheme. This also disables per-pass WebGPU UBO batching.
     * @default false
     */
    legacy?: boolean;
}
/**
 * The BlurFilter applies a Gaussian blur to an object.
 * The strength of the blur can be set for the x-axis and y-axis separately.
 * @example
 * ```ts
 * import { BlurFilter } from 'pixi.js';
 *
 * // Create with default settings
 * const filter = new BlurFilter();
 *
 * // Create with custom settings
 * const filter = new BlurFilter({
 *     strength: 8,      // Overall blur strength
 *     quality: 4,       // Blur quality (higher = better but slower)
 *     kernelSize: 5     // Size of blur kernel matrix
 * });
 *
 * // Apply to a display object
 * sprite.filters = [filter];
 *
 * // Update properties
 * filter.strength = 10;          // Set both X and Y blur
 * filter.strengthX = 5;          // Set only horizontal blur
 * filter.strengthY = 15;         // Set only vertical blur
 * filter.quality = 2;            // Adjust quality
 *
 * // Enable edge pixel clamping
 * filter.repeatEdgePixels = true;
 * ```
 * @remarks
 * - Higher quality values produce better blur but impact performance
 * - Strength controls blur intensity independently for X and Y
 * - Can be optimized using quality and kernelSize settings
 * - Supports edge pixel clamping for special effects
 * @see {@link BlurFilterPass} For single-direction blur
 * @see {@link FilterOptions} For base filter options
 * @category filters
 * @standard
 * @noInheritDoc
 */
export declare class BlurFilter extends Filter {
    /**
     * Default blur filter options
     * @example
     * ```ts
     * // Set default options for all BlurFilters
     * BlurFilter.defaultOptions = {
     *     strength: 10,       // Default blur strength
     *     quality: 2,        // Default blur quality
     *     kernelSize: 7      // Default kernel size
     * };
     * // Create a filter with these defaults
     * const filter = new BlurFilter(); // Uses default options
     * ```
     * @remarks
     * - These options are used when creating a new BlurFilter without specific parameters
     * - Can be overridden by passing options to the constructor
     * - Useful for setting global defaults for all blur filters in your application
     * @see {@link BlurFilterOptions} For detailed options
     * @see {@link BlurFilter} The filter that uses these options
     */
    static defaultOptions: Partial<BlurFilterOptions>;
    /**
     * The horizontal blur filter
     * @advanced
     */
    blurXFilter: BlurFilterPass;
    /**
     * The vertical blur filter
     * @advanced
     */
    blurYFilter: BlurFilterPass;
    private _repeatEdgePixels;
    /**
     * @param {filters.BlurFilterOptions} options - The options of the blur filter.
     */
    constructor(options?: BlurFilterOptions);
    /** @deprecated since 8.0.0 */
    constructor(strength?: number, quality?: number, resolution?: number | null, kernelSize?: number);
    /**
     * Applies the filter.
     * @param filterManager - The manager.
     * @param input - The input target.
     * @param output - The output target.
     * @param clearMode - How to clear
     * @advanced
     */
    apply(filterManager: FilterSystem, input: Texture, output: RenderSurface, clearMode: boolean): void;
    protected updatePadding(): void;
    /**
     * Sets the strength of both the blurX and blurY properties simultaneously.
     * Controls the overall intensity of the Gaussian blur effect.
     * @example
     * ```ts
     * // Set equal blur strength for both axes
     * filter.strength = 8;
     *
     * // Will throw error if X and Y are different
     * filter.strengthX = 4;
     * filter.strengthY = 8;
     * filter.strength; // Error: BlurFilter's strengthX and strengthY are different
     * ```
     * @default 8
     * @throws {Error} If strengthX and strengthY are different values
     */
    get strength(): number;
    set strength(value: number);
    /**
     * Sets the number of passes for blur. More passes means higher quality blurring.
     * Controls the precision and smoothness of the blur effect at the cost of performance.
     * @example
     * ```ts
     * // High quality blur (slower)
     * filter.quality = 8;
     *
     * // Low quality blur (faster)
     * filter.quality = 2;
     * ```
     * @default 4
     * @remarks Higher values produce better quality but impact performance
     */
    get quality(): number;
    set quality(value: number);
    /**
     * Sets the strength of horizontal blur.
     * Controls the blur intensity along the x-axis independently.
     * @example
     * ```ts
     * // Apply horizontal-only blur
     * filter.strengthX = 8;
     * filter.strengthY = 0;
     *
     * // Create motion blur effect
     * filter.strengthX = 16;
     * filter.strengthY = 2;
     * ```
     * @default 8
     */
    get strengthX(): number;
    set strengthX(value: number);
    /**
     * Sets the strength of the vertical blur.
     * Controls the blur intensity along the y-axis independently.
     * @example
     * ```ts
     * // Apply vertical-only blur
     * filter.strengthX = 0;
     * filter.strengthY = 8;
     *
     * // Create radial blur effect
     * filter.strengthX = 8;
     * filter.strengthY = 8;
     * ```
     * @default 8
     */
    get strengthY(): number;
    set strengthY(value: number);
    /**
     * Sets the strength of both the blurX and blurY properties simultaneously
     * @default 2
     * @deprecated since 8.3.0
     * @see BlurFilter.strength
     */
    get blur(): number;
    set blur(value: number);
    /**
     * Sets the strength of the blurX property
     * @default 2
     * @deprecated since 8.3.0
     * @see BlurFilter.strengthX
     */
    get blurX(): number;
    set blurX(value: number);
    /**
     * Sets the strength of the blurY property
     * @default 2
     * @deprecated since 8.3.0
     * @see BlurFilter.strengthY
     */
    get blurY(): number;
    set blurY(value: number);
    /**
     * If set to true the edge of the target will be clamped
     * @default false
     */
    get repeatEdgePixels(): boolean;
    set repeatEdgePixels(value: boolean);
}
