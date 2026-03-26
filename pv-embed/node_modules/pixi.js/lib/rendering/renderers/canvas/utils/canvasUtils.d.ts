import type { ICanvas } from '../../../../environment/canvas/ICanvas';
import type { ICanvasRenderingContext2D } from '../../../../environment/canvas/ICanvasRenderingContext2D';
import type { ImageLike } from '../../../../environment/ImageLike';
import type { TextureSource } from '../../shared/texture/sources/TextureSource';
import type { Texture } from '../../shared/texture/Texture';
type CanvasSourceCache = {
    canvas: ICanvas;
    resourceId: number;
};
/**
 * Canvas helper utilities for tinting and pattern generation.
 * @internal
 */
export declare const canvasUtils: {
    canvas: ICanvas | null;
    convertTintToImage: boolean;
    cacheStepsPerColorChannel: number;
    canUseMultiply: boolean;
    tintMethod: (texture: Texture, color: number, canvas: ICanvas) => void;
    _canvasSourceCache: WeakMap<TextureSource<any>, CanvasSourceCache>;
    _unpremultipliedCache: WeakMap<TextureSource<any>, CanvasSourceCache>;
    getCanvasSource: (texture: Texture) => CanvasImageSource | null;
    getTintedCanvas: (sprite: {
        texture: Texture;
    }, color: number) => ICanvas | ImageLike;
    getTintedPattern: (texture: Texture, color: number) => CanvasPattern;
    /**
     * Applies a transform to a CanvasPattern.
     * @param pattern - The pattern to apply the transform to.
     * @param matrix - The matrix to apply.
     * @param matrix.a
     * @param matrix.b
     * @param matrix.c
     * @param matrix.d
     * @param matrix.tx
     * @param matrix.ty
     * @param invert
     */
    applyPatternTransform: (pattern: CanvasPattern, matrix: {
        a: number;
        b: number;
        c: number;
        d: number;
        tx: number;
        ty: number;
    }, invert?: boolean) => void;
    tintWithMultiply: (texture: Texture, color: number, canvas: ICanvas) => void;
    tintWithOverlay: (texture: Texture, color: number, canvas: ICanvas) => void;
    tintWithPerPixel: (texture: Texture, color: number, canvas: ICanvas) => void;
    /**
     * Applies inverse rotation transform to context for texture packer rotation compensation.
     * Supports all 16 groupD8 symmetries (rotations and reflections).
     * @param context - Canvas 2D context
     * @param rotate - The groupD8 rotation value
     * @param srcWidth - Source crop width (before rotation)
     * @param srcHeight - Source crop height (before rotation)
     */
    _applyInverseRotation: (context: ICanvasRenderingContext2D, rotate: number, srcWidth: number, srcHeight: number) => void;
};
export {};
