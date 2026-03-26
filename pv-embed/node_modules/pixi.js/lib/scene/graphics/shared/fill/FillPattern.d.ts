import { Matrix } from '../../../../maths/matrix/Matrix';
import type { Texture } from '../../../../rendering/renderers/shared/texture/Texture';
/**
 * Defines the repetition modes for fill patterns.
 *
 * - `repeat`: The pattern repeats in both directions.
 * - `repeat-x`: The pattern repeats horizontally only.
 * - `repeat-y`: The pattern repeats vertically only.
 * - `no-repeat`: The pattern does not repeat.
 * @category scene
 * @standard
 */
export type PatternRepetition = 'repeat' | 'repeat-x' | 'repeat-y' | 'no-repeat';
/**
 * A class that represents a fill pattern for use in Text and Graphics fills.
 * It allows for textures to be used as patterns, with optional repetition modes.
 * @category scene
 * @standard
 * @example
 * const txt = await Assets.load('https://pixijs.com/assets/bg_scene_rotate.jpg');
 * const pat = new FillPattern(txt, 'repeat');
 *
 * const textPattern = new Text({
 *     text: 'PixiJS',
 *     style: {
 *         fontSize: 36,
 *         fill: 0xffffff,
 *         stroke: { fill: pat, width: 10 },
 *     },
 * });
 *
 * textPattern.y = (textGradient.height);
 */
export declare class FillPattern implements CanvasPattern {
    /**
     * unique id for this fill pattern
     * @internal
     */
    readonly uid: number;
    /**
     * Internal tick counter to track changes in the pattern.
     * This is used to invalidate the pattern when the texture or transform changes.
     * @internal
     */
    _tick: number;
    /** @internal */
    _texture: Texture;
    /** The transform matrix applied to the pattern */
    transform: Matrix;
    constructor(texture: Texture, repetition?: PatternRepetition);
    /**
     * Sets the transform for the pattern
     * @param transform - The transform matrix to apply to the pattern.
     * If not provided, the pattern will use the default transform.
     */
    setTransform(transform?: Matrix): void;
    /** Internal texture used to render the gradient */
    get texture(): Texture;
    set texture(value: Texture);
    /**
     * Returns a unique key for this instance.
     * This key is used for caching.
     * @returns {string} Unique key for the instance
     */
    get styleKey(): string;
    /** Destroys the fill pattern, releasing resources. This will also destroy the internal texture. */
    destroy(): void;
}
