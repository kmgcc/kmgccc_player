import { Matrix } from '../../../../maths/matrix/Matrix';
import { type WRAP_MODE } from '../../../../rendering/renderers/shared/texture/const';
import { Texture } from '../../../../rendering/renderers/shared/texture/Texture';
import type { ColorSource } from '../../../../color/Color';
import type { PointData } from '../../../../maths/point/PointData';
import type { TextureSpace } from '../FillTypes';
/**
 * Defines the type of gradient to create.
 *
 * It can be:
 * - 'linear': A linear gradient that transitions colors along a straight line.
 * - 'radial': A radial gradient that transitions colors in a circular pattern from an inner circle to an outer circle.
 * @category scene
 * @standard
 */
export type GradientType = 'linear' | 'radial';
/**
 * Represents the style options for a linear gradient fill.
 * @category scene
 * @standard
 */
export interface BaseGradientOptions {
    /** The type of gradient */
    type?: GradientType;
    /** Array of colors stops to use in the gradient */
    colorStops?: {
        offset: number;
        color: ColorSource;
    }[];
    /** Whether coordinates are 'global' or 'local' */
    textureSpace?: TextureSpace;
    /**
     * The size of the texture to use for the gradient - this is for advanced usage.
     * The texture size does not need to match the size of the object being drawn.
     * Due to GPU interpolation, gradient textures can be relatively small!
     * Consider using a larger texture size if your gradient has a lot of very tight color steps
     */
    textureSize?: number;
    /**
     * The wrap mode of the gradient.
     * This can be 'clamp-to-edge' or 'repeat'.
     * @default 'clamp-to-edge'
     */
    wrapMode?: WRAP_MODE;
}
/**
 * Options specific to linear gradients.
 * A linear gradient creates a smooth transition between colors along a straight line defined by start and end points.
 * @category scene
 * @standard
 */
export interface LinearGradientOptions extends BaseGradientOptions {
    /** The type of gradient. Must be 'linear' for linear gradients. */
    type?: 'linear';
    /**
     * The start point of the gradient.
     * This point defines where the gradient begins.
     * It is represented as a PointData object containing x and y coordinates.
     * The coordinates are in local space by default (0-1), but can be in global space if specified.
     */
    start?: PointData;
    /**
     * The end point of the gradient.
     * This point defines where the gradient ends.
     * It is represented as a PointData object containing x and y coordinates.
     * The coordinates are in local space by default (0-1), but can be in global space if specified.
     */
    end?: PointData;
}
/**
 * Options specific to radial gradients.
 * A radial gradient creates a smooth transition between colors that radiates outward in a circular pattern.
 * The gradient is defined by inner and outer circles, each with their own radius.
 * @category scene
 * @standard
 */
export interface RadialGradientOptions extends BaseGradientOptions {
    /** The type of gradient. Must be 'radial' for radial gradients. */
    type?: 'radial';
    /** The center point of the inner circle where the gradient begins. In local coordinates by default (0-1). */
    center?: PointData;
    /** The radius of the inner circle where the gradient begins. */
    innerRadius?: number;
    /** The center point of the outer circle where the gradient ends. In local coordinates by default (0-1). */
    outerCenter?: PointData;
    /** The radius of the outer circle where the gradient ends. */
    outerRadius?: number;
    /**
     * The y scale of the gradient, use this to make the gradient elliptical.
     * NOTE: Only applied to radial gradients used with Graphics.
     */
    scale?: number;
    /**
     * The rotation of the gradient in radians, useful for making the gradient elliptical.
     * NOTE: Only applied to radial gradients used with Graphics.
     */
    rotation?: number;
}
/**
 * Options for creating a gradient fill.
 * @category scene
 * @standard
 */
export type GradientOptions = LinearGradientOptions | RadialGradientOptions;
/**
 * Class representing a gradient fill that can be used to fill shapes and text.
 * Supports both linear and radial gradients with multiple color stops.
 *
 * For linear gradients, color stops define colors and positions (0 to 1) along a line from start point (x0,y0)
 * to end point (x1,y1).
 *
 * For radial gradients, color stops define colors between two circles - an inner circle centered at (x0,y0) with radius r0,
 * and an outer circle centered at (x1,y1) with radius r1.
 * @example
 * ```ts
 * // Create a vertical linear gradient from red to blue
 * const linearGradient = new FillGradient({
 *     type: 'linear',
 *     start: { x: 0, y: 0 },  // Start at top
 *     end: { x: 0, y: 1 },    // End at bottom
 *     colorStops: [
 *         { offset: 0, color: 'red' },   // Red at start
 *         { offset: 1, color: 'blue' }   // Blue at end
 *     ],
 *     // Use normalized coordinate system where (0,0) is the top-left and (1,1) is the bottom-right of the shape
 *     textureSpace: 'local'
 * });
 *
 * // Create a radial gradient from yellow center to green edge
 * const radialGradient = new FillGradient({
 *     type: 'radial',
 *     center: { x: 0.5, y: 0.5 },
 *     innerRadius: 0,
 *     outerCenter: { x: 0.5, y: 0.5 },
 *     outerRadius: 0.5,
 *     colorStops: [
 *         { offset: 0, color: 'yellow' }, // Center color
 *         { offset: 1, color: 'green' }   // Edge color
 *     ],
 *     // Use normalized coordinate system where (0,0) is the top-left and (1,1) is the bottom-right of the shape
 *     textureSpace: 'local'
 * });
 *
 * // Create a rainbow linear gradient in global coordinates
 * const globalGradient = new FillGradient({
 *     type: 'linear',
 *     start: { x: 0, y: 0 },
 *     end: { x: 100, y: 0 },
 *     colorStops: [
 *         { offset: 0, color: 0xff0000 },    // Red
 *         { offset: 0.33, color: 0x00ff00 }, // Green
 *         { offset: 0.66, color: 0x0000ff }, // Blue
 *         { offset: 1, color: 0xff00ff }     // Purple
 *     ],
 *     textureSpace: 'global'  // Use world coordinates
 * });
 *
 * // Create an offset radial gradient
 * const offsetRadial = new FillGradient({
 *     type: 'radial',
 *     center: { x: 0.3, y: 0.3 },
 *     innerRadius: 0.1,
 *     outerCenter: { x: 0.5, y: 0.5 },
 *     outerRadius: 0.5,
 *     colorStops: [
 *         { offset: 0, color: 'white' },
 *         { offset: 1, color: 'black' }
 *     ],
 *     // Use normalized coordinate system where (0,0) is the top-left and (1,1) is the bottom-right of the shape
 *     textureSpace: 'local'
 * });
 * ```
 *
 * Internally this creates a  texture of the gradient then applies a
 * transform to it to give it the correct size and angle.
 *
 * This means that it's important to destroy a gradient when it is no longer needed
 * to avoid memory leaks.
 *
 * If you want to animate a gradient then it's best to modify and update an existing one
 * rather than creating a whole new one each time. That or use a custom shader.
 * @category scene
 * @standard
 */
export declare class FillGradient implements CanvasGradient {
    /** Default options for creating a gradient fill */
    static readonly defaultLinearOptions: LinearGradientOptions;
    /** Default options for creating a radial gradient fill */
    static readonly defaultRadialOptions: RadialGradientOptions;
    /**
     * Unique identifier for this gradient instance
     * @internal
     */
    readonly uid: number;
    /**
     * Internal tick counter to track changes in the gradient.
     * This is used to invalidate the gradient when the texture changes.
     * @internal
     */
    _tick: number;
    /** Type of gradient - currently only supports 'linear' */
    readonly type: GradientType;
    /** Internal texture used to render the gradient */
    texture: Texture;
    /** Transform matrix for positioning the gradient */
    transform: Matrix;
    /** Array of color stops defining the gradient */
    colorStops: Array<{
        offset: number;
        color: string;
    }>;
    /** Whether gradient coordinates are in local or global space */
    textureSpace: TextureSpace;
    private readonly _textureSize;
    /** The start point of the linear gradient */
    start: PointData;
    /** The end point of the linear gradient */
    end: PointData;
    /** The wrap mode of the gradient texture */
    private readonly _wrapMode;
    /** The center point of the inner circle of the radial gradient */
    center: PointData;
    /** The center point of the outer circle of the radial gradient */
    outerCenter: PointData;
    /** The radius of the inner circle of the radial gradient */
    innerRadius: number;
    /** The radius of the outer circle of the radial gradient */
    outerRadius: number;
    /** The scale of the radial gradient */
    scale: number;
    /** The rotation of the radial gradient */
    rotation: number;
    /**
     * Creates a new gradient fill. The constructor behavior changes based on the gradient type.
     * @param {GradientOptions} options - The options for the gradient
     * @see {@link LinearGradientOptions}
     * @see {@link RadialGradientOptions}
     */
    constructor(options: GradientOptions);
    /**
     * Deprecated: Use the options object instead.
     * @deprecated since 8.5.2
     * @ignore
     */
    constructor(x0?: number, y0?: number, x1?: number, y1?: number, textureSpace?: TextureSpace, textureSize?: number);
    /**
     * Adds a color stop to the gradient
     * @param offset - Position of the stop (0-1)
     * @param color - Color of the stop
     * @returns This gradient instance for chaining
     */
    addColorStop(offset: number, color: ColorSource): this;
    /**
     * Builds the internal texture and transform for the gradient.
     * Called automatically when the gradient is first used.
     * @internal
     */
    buildLinearGradient(): void;
    /**
     * Builds the internal texture and transform for the gradient.
     * Called automatically when the gradient is first used.
     * @internal
     */
    buildGradient(): void;
    /**
     * Builds the internal texture and transform for the radial gradient.
     * Called automatically when the gradient is first used.
     * @internal
     */
    buildRadialGradient(): void;
    /** Destroys the gradient, releasing resources. This will also destroy the internal texture. */
    destroy(): void;
    /**
     * Returns a unique key for this gradient instance.
     * This key is used for caching and texture management.
     * @returns {string} Unique key for the gradient
     */
    get styleKey(): string;
}
