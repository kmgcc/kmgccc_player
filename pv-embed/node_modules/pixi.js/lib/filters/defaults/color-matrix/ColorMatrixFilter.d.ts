import { Filter } from '../../Filter';
import type { ColorSource } from '../../../color/Color';
import type { ArrayFixed } from '../../../utils/types';
import type { FilterOptions } from '../../Filter';
/**
 * 5x4 matrix for transforming RGBA color and alpha
 * @category filters
 * @standard
 */
export type ColorMatrix = ArrayFixed<number, 20>;
/**
 * The ColorMatrixFilter class lets you apply color transformations to display objects using a 5x4 matrix.
 * The matrix transforms the RGBA color and alpha values of every pixel to produce a new set of values.
 *
 * The class provides convenient methods for common color adjustments like brightness, contrast, saturation,
 * and various photo filter effects.
 * @example
 * ```js
 * import { ColorMatrixFilter } from 'pixi.js';
 *
 * // Create a new color matrix filter
 * const colorMatrix = new ColorMatrixFilter();
 *
 * // Apply it to a container
 * container.filters = [colorMatrix];
 *
 * // Adjust contrast
 * colorMatrix.contrast(2);
 *
 * // Chain multiple effects
 * colorMatrix
 *     .saturate(0.5)     // 50% saturation
 *     .brightness(1.2)    // 20% brighter
 *     .hue(90);          // 90 degree hue rotation
 * ```
 *
 * Common use cases:
 * - Adjusting brightness, contrast, or saturation
 * - Applying color tints or color grading
 * - Creating photo filter effects (sepia, negative, etc.)
 * - Converting to grayscale
 * - Implementing dynamic day/night transitions
 * @author Clément Chenebault <clement@goodboydigital.com>
 * @category filters
 * @standard
 * @noInheritDoc
 */
export declare class ColorMatrixFilter extends Filter {
    constructor(options?: FilterOptions);
    /**
     * Transforms current matrix and set the new one
     * @param {number[]} matrix - 5x4 matrix
     * @param multiply - if true, current matrix and matrix are multiplied. If false,
     *  just set the current matrix with matrix
     */
    private _loadMatrix;
    /**
     * Multiplies two mat5's
     * @private
     * @param out - 5x4 matrix the receiving matrix
     * @param a - 5x4 matrix the first operand
     * @param b - 5x4 matrix the second operand
     * @returns {number[]} 5x4 matrix
     */
    private _multiply;
    /**
     * Adjusts the brightness of a display object.
     *
     * The brightness adjustment works by multiplying the RGB channels by a scalar value while keeping
     * the alpha channel unchanged. Values below 1 darken the image, while values above 1 brighten it.
     * @param b - The brightness multiplier to apply. Values between 0-1 darken the image (0 being black),
     *           while values > 1 brighten it (2.0 would make it twice as bright)
     * @param multiply - When true, the new matrix is multiplied with the current one instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * // Create a new color matrix filter
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Darken the image to 50% brightness
     * colorMatrix.brightness(0.5, false);
     *
     * // Chain with other effects by using multiply
     * colorMatrix
     *     .brightness(1.2, true)  // Brighten by 20%
     *     .saturate(1.1, true);   // Increase saturation by 10%
     * ```
     */
    brightness(b: number, multiply: boolean): void;
    /**
     * Sets each channel on the diagonal of the color matrix to apply a color tint.
     *
     * This method provides a way to tint display objects using the color matrix filter, similar to
     * the tint property available on Sprites and other display objects. The tint is applied by
     * scaling the RGB channels of each pixel.
     * @param color - The color to use for tinting, this can be any valid color source.
     * @param multiply - When true, the new tint matrix is multiplied with the current matrix instead
     *                  of replacing it. This allows for combining tints with other color effects.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply a red tint
     * colorMatrix.tint(0xff0000);
     *
     * // Layer a green tint on top of existing effects
     * colorMatrix.tint('green', true);
     *
     * // Chain with other color adjustments
     * colorMatrix
     *     .tint('blue')       // Blue tint
     *     .brightness(1.2, true) // Increase brightness
     * ```
     */
    tint(color: ColorSource, multiply?: boolean): void;
    /**
     * Converts the display object to greyscale by applying a weighted matrix transformation.
     *
     * The greyscale effect works by setting equal RGB values for each pixel based on the scale parameter,
     * effectively removing color information while preserving luminance.
     * @param scale - The intensity of the greyscale effect. Value between 0-1, where:
     *               - 0 produces black
     *               - 0.5 produces 50% grey
     *               - 1 produces white
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Convert to 50% grey
     * colorMatrix.greyscale(0.5, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .greyscale(0.6, true)    // Add grey tint
     *     .brightness(1.2, true);   // Brighten the result
     * ```
     */
    greyscale(scale: number, multiply: boolean): void;
    /**
     * Converts the display object to grayscale by applying a weighted matrix transformation.
     *
     * The grayscale effect works by setting equal RGB values for each pixel based on the scale parameter,
     * effectively removing color information while preserving luminance.
     * @param scale - The intensity of the grayscale effect. Value between 0-1, where:
     *               - 0 produces black
     *               - 0.5 produces 50% grey
     *               - 1 produces white
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Convert to 50% grey
     * colorMatrix.grayscale(0.5, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .grayscale(0.6, true)    // Add grey tint
     *     .brightness(1.2, true);   // Brighten the result
     * ```
     */
    grayscale(scale: number, multiply: boolean): void;
    /**
     * Converts the display object to pure black and white using a luminance-based threshold.
     *
     * This method applies a matrix transformation that removes all color information and reduces
     * the image to just black and white values based on the luminance of each pixel. The transformation
     * uses standard luminance weightings: 30% red, 60% green, and 10% blue.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Convert to black and white
     * colorMatrix.blackAndWhite(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .blackAndWhite(true)     // Apply B&W effect
     *     .brightness(1.2, true);   // Then increase brightness
     * ```
     */
    blackAndWhite(multiply: boolean): void;
    /**
     * Adjusts the hue of the display object by rotating the color values around the color wheel.
     *
     * This method uses an optimized matrix transformation that accurately rotates the RGB color space
     * around its luminance axis. The implementation is based on RGB cube rotation in 3D space, providing
     * better results than traditional matrices with magic luminance constants.
     * @param rotation - The angle of rotation in degrees around the color wheel:
     *                  - 0 = no change
     *                  - 90 = rotate colors 90° clockwise
     *                  - 180 = invert all colors
     *                  - 270 = rotate colors 90° counter-clockwise
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Rotate hue by 90 degrees
     * colorMatrix.hue(90, false);
     *
     * // Chain multiple color adjustments
     * colorMatrix
     *     .hue(45, true)          // Rotate colors by 45°
     *     .saturate(1.2, true)    // Increase saturation
     *     .brightness(1.1, true); // Slightly brighten
     * ```
     */
    hue(rotation: number, multiply: boolean): void;
    /**
     * Adjusts the contrast of the display object by modifying the separation between dark and bright values.
     *
     * This method applies a matrix transformation that affects the difference between dark and light areas
     * in the image. Increasing contrast makes shadows darker and highlights brighter, while decreasing
     * contrast brings shadows up and highlights down, reducing the overall dynamic range.
     * @param amount - The contrast adjustment value. Range is 0 to 1, where:
     *                - 0 represents minimum contrast (flat gray)
     *                - 0.5 represents normal contrast
     *                - 1 represents maximum contrast
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Increase contrast by 50%
     * colorMatrix.contrast(0.75, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .contrast(0.6, true)     // Boost contrast
     *     .brightness(1.1, true)   // Slightly brighten
     *     .saturate(1.2, true);    // Increase color intensity
     * ```
     */
    contrast(amount: number, multiply: boolean): void;
    /**
     * Adjusts the saturation of the display object by modifying color separation.
     *
     * This method applies a matrix transformation that affects the intensity of colors.
     * Increasing saturation makes colors more vivid and intense, while decreasing saturation
     * moves colors toward grayscale.
     * @param amount - The saturation adjustment value. Range is -1 to 1, where:
     *                - -1 produces grayscale
     *                - 0 represents no change
     *                - 1 produces maximum saturation
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Double the saturation
     * colorMatrix.saturate(1, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .saturate(0.5, true)     // Increase saturation by 50%
     *     .brightness(1.1, true)    // Slightly brighten
     *     .contrast(0.8, true);     // Reduce contrast
     * ```
     */
    saturate(amount?: number, multiply?: boolean): void;
    /**
     * Completely removes color information from the display object, creating a grayscale version.
     *
     * This is a convenience method that calls `saturate(-1)` internally. The transformation preserves
     * the luminance of the original image while removing all color information.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Convert image to grayscale
     * colorMatrix.desaturate();
     *
     * // Can be chained with other effects
     * colorMatrix
     *     .desaturate()         // Remove all color
     *     .brightness(1.2);     // Then increase brightness
     * ```
     */
    desaturate(): void;
    /**
     * Creates a negative effect by inverting all colors in the display object.
     *
     * This method applies a matrix transformation that inverts the RGB values of each pixel
     * while preserving the alpha channel. The result is similar to a photographic negative.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Create negative effect
     * colorMatrix.negative(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .negative(true)       // Apply negative effect
     *     .brightness(1.2, true) // Increase brightness
     *     .contrast(0.8, true);  // Reduce contrast
     * ```
     */
    negative(multiply: boolean): void;
    /**
     * Applies a sepia tone effect to the display object, creating a warm brown tint reminiscent of vintage photographs.
     *
     * This method applies a matrix transformation that converts colors to various shades of brown while
     * preserving the original luminance values.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply sepia effect
     * colorMatrix.sepia(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .sepia(true)           // Add sepia tone
     *     .brightness(1.1, true)  // Slightly brighten
     *     .contrast(0.9, true);   // Reduce contrast
     * ```
     */
    sepia(multiply: boolean): void;
    /**
     * Applies a Technicolor-style effect that simulates the early color motion picture process.
     *
     * This method applies a matrix transformation that recreates the distinctive look of the
     * Technicolor process. The effect produces highly
     * saturated colors with a particular emphasis on reds, greens, and blues.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply Technicolor effect
     * colorMatrix.technicolor(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .technicolor(true)      // Add Technicolor effect
     *     .contrast(1.1, true)    // Boost contrast
     *     .brightness(0.9, true); // Slightly darken
     * ```
     */
    technicolor(multiply: boolean): void;
    /**
     * Applies a vintage Polaroid camera effect to the display object.
     *
     * This method applies a matrix transformation that simulates the distinctive look of
     * Polaroid instant photographs, characterized by slightly enhanced contrast, subtle color shifts,
     * and a warm overall tone.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply Polaroid effect
     * colorMatrix.polaroid(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .polaroid(true)         // Add Polaroid effect
     *     .brightness(1.1, true)  // Slightly brighten
     *     .contrast(1.1, true);   // Boost contrast
     * ```
     */
    polaroid(multiply: boolean): void;
    /**
     * Swaps the red and blue color channels in the display object.
     *
     * This method applies a matrix transformation that exchanges the red and blue color values
     * while keeping the green channel and alpha unchanged.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Swap red and blue channels
     * colorMatrix.toBGR(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .toBGR(true)           // Swap R and B channels
     *     .brightness(1.1, true)  // Slightly brighten
     *     .contrast(0.9, true);   // Reduce contrast
     * ```
     */
    toBGR(multiply: boolean): void;
    /**
     * Applies a Kodachrome color effect that simulates the iconic film stock.
     *
     * This method applies a matrix transformation that recreates the distinctive look of Kodachrome film,
     * known for its rich, vibrant colors and excellent image preservation qualities. The effect emphasizes
     * reds and blues while producing deep, true blacks.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply Kodachrome effect
     * colorMatrix.kodachrome(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .kodachrome(true)       // Add Kodachrome effect
     *     .contrast(1.1, true)    // Boost contrast
     *     .brightness(0.9, true); // Slightly darken
     * ```
     */
    kodachrome(multiply: boolean): void;
    /**
     * Applies a stylized brown-tinted effect to the display object.
     *
     * This method applies a matrix transformation that creates a rich, warm brown tone
     * with enhanced contrast and subtle color shifts.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply browni effect
     * colorMatrix.browni(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .browni(true)          // Add brown tint
     *     .brightness(1.1, true)  // Slightly brighten
     *     .contrast(1.2, true);   // Boost contrast
     * ```
     */
    browni(multiply: boolean): void;
    /**
     * Applies a vintage photo effect that simulates old photography techniques.
     *
     * This method applies a matrix transformation that creates a nostalgic, aged look
     * with muted colors, enhanced warmth, and subtle vignetting.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply vintage effect
     * colorMatrix.vintage(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .vintage(true)          // Add vintage look
     *     .brightness(0.9, true)  // Slightly darken
     *     .contrast(1.1, true);   // Boost contrast
     * ```
     */
    vintage(multiply: boolean): void;
    /**
     * We don't know exactly what it does, kind of gradient map, but funny to play with!
     * @param desaturation - Tone values.
     * @param toned - Tone values.
     * @param lightColor - Tone values, example: `0xFFE580`
     * @param darkColor - Tone values, example: `0xFFE580`
     * @param multiply - if true, current matrix and matrix are multiplied. If false,
     *  just set the current matrix with matrix
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Create sepia-like effect with custom colors
     * colorMatrix.colorTone(
     *     0.3,        // Moderate desaturation
     *     0.2,        // Moderate toning
     *     0xFFE580,   // Warm highlight color
     *     0x338000,   // Dark green shadows
     *     false
     * );
     *
     * // Chain with other effects
     * colorMatrix
     *     .colorTone(0.2, 0.15, 0xFFE580, 0x338000, true)
     *     .brightness(1.1, true);  // Slightly brighten
     * ```
     */
    colorTone(desaturation: number, toned: number, lightColor: ColorSource, darkColor: ColorSource, multiply: boolean): void;
    /**
     * Applies a night vision effect to the display object.
     *
     * This method applies a matrix transformation that simulates night vision by enhancing
     * certain color channels while suppressing others, creating a green-tinted effect
     * similar to night vision goggles.
     * @param intensity - The intensity of the night effect (0-1):
     *                   - 0 produces no effect
     *                   - 0.1 produces a subtle night vision effect (default)
     *                   - 1 produces maximum night vision effect
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply night vision effect
     * colorMatrix.night(0.3, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .night(0.2, true)        // Add night vision
     *     .brightness(1.1, true)    // Slightly brighten
     *     .contrast(1.2, true);     // Boost contrast
     * ```
     */
    night(intensity: number, multiply: boolean): void;
    /**
     * Predator effect
     *
     * Erase the current matrix by setting a new independent one
     * @param amount - how much the predator feels his future victim
     * @param multiply - if true, current matrix and matrix are multiplied. If false,
     *  just set the current matrix with matrix
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply thermal vision effect
     * colorMatrix.predator(0.5, false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .predator(0.3, true)      // Add thermal effect
     *     .contrast(1.2, true)      // Boost contrast
     *     .brightness(1.1, true);   // Slightly brighten
     * ```
     */
    predator(amount: number, multiply: boolean): void;
    /**
     * Applies a psychedelic color effect that creates dramatic color shifts.
     *
     * This method applies a matrix transformation that produces vibrant colors
     * through channel mixing and amplification. Creates an effect reminiscent of
     * color distortions in psychedelic art.
     * @param multiply - When true, the new matrix is multiplied with the current matrix instead of replacing it.
     *                  This allows for cumulative effects when calling multiple color adjustments.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply psychedelic effect
     * colorMatrix.lsd(false);
     *
     * // Chain with other effects
     * colorMatrix
     *     .lsd(true)             // Add color distortion
     *     .brightness(0.9, true)  // Slightly darken
     *     .contrast(1.2, true);   // Boost contrast
     * ```
     */
    lsd(multiply: boolean): void;
    /**
     * Resets the color matrix filter to its default state.
     *
     * This method resets all color transformations by setting the matrix back to its identity state.
     * The identity matrix leaves colors unchanged, effectively removing all previously applied effects.
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply some effects
     * colorMatrix
     *     .sepia(true)
     *     .brightness(1.2, true);
     *
     * // Reset back to original colors
     * colorMatrix.reset();
     * ```
     */
    reset(): void;
    /**
     * The current color transformation matrix of the filter.
     *
     * This 5x4 matrix transforms RGBA color and alpha values of each pixel. The matrix is stored
     * as a 20-element array in row-major order.
     * @type {ColorMatrix}
     * @default [
     *     1, 0, 0, 0, 0,  // Red channel
     *     0, 1, 0, 0, 0,  // Green channel
     *     0, 0, 1, 0, 0,  // Blue channel
     *     0, 0, 0, 1, 0   // Alpha channel
     * ]
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     * // Get the current color matrix
     * const currentMatrix = colorMatrix.matrix;
     * // Modify the matrix
     * colorMatrix.matrix = [
     *     1, 0, 0, 0, 0,
     *     0, 1, 0, 0, 0,
     *     0, 0, 1, 0, 0,
     *     0, 0, 0, 1, 0
     * ];
     */
    get matrix(): ColorMatrix;
    set matrix(value: ColorMatrix);
    /**
     * The opacity value used to blend between the original and transformed colors.
     *
     * This value controls how much of the color transformation is applied:
     * - 0 = Original color only (no effect)
     * - 0.5 = 50% blend of original and transformed colors
     * - 1 = Fully transformed color (default)
     * @default 1
     * @example
     * ```ts
     * const colorMatrix = new ColorMatrixFilter();
     *
     * // Apply sepia at 50% strength
     * colorMatrix.sepia(false);
     * colorMatrix.alpha = 0.5;
     *
     * // Fade between effects
     * colorMatrix
     *     .saturate(1.5)      // Increase saturation
     *     .contrast(1.2);     // Boost contrast
     * colorMatrix.alpha = 0.7; // Apply at 70% strength
     * ```
     */
    get alpha(): number;
    set alpha(value: number);
}
