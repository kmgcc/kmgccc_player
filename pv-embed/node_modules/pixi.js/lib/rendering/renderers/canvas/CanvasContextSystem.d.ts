import { ExtensionType } from '../../../extensions/Extensions';
import { Matrix } from '../../../maths/matrix/Matrix';
import type { ICanvasRenderingContext2D } from '../../../environment/canvas/ICanvasRenderingContext2D';
import type { BLEND_MODES } from '../shared/state/const';
import type { System } from '../shared/system/System';
import type { CanvasRenderer } from './CanvasRenderer';
/**
 * Canvas 2D context with vendor image smoothing flags.
 * @internal
 */
export interface CrossPlatformCanvasRenderingContext2D extends ICanvasRenderingContext2D {
    /** WebKit-specific image smoothing flag. */
    webkitImageSmoothingEnabled: boolean;
    /** Mozilla-specific image smoothing flag. */
    mozImageSmoothingEnabled: boolean;
    /** Opera-specific image smoothing flag. */
    oImageSmoothingEnabled: boolean;
    /** Microsoft-specific image smoothing flag. */
    msImageSmoothingEnabled: boolean;
}
/**
 * Available image smoothing flags for the current context.
 * @internal
 */
export type SmoothingEnabledProperties = 'imageSmoothingEnabled' | 'webkitImageSmoothingEnabled' | 'mozImageSmoothingEnabled' | 'oImageSmoothingEnabled' | 'msImageSmoothingEnabled';
/**
 * Canvas 2D context system for the CanvasRenderer.
 * @category rendering
 * @advanced
 */
export declare class CanvasContextSystem implements System {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.CanvasSystem];
        readonly name: "canvasContext";
    };
    private readonly _renderer;
    /** Root 2D context tied to the renderer's canvas. */
    rootContext: CrossPlatformCanvasRenderingContext2D;
    /** Active 2D context for rendering (root or render target). */
    activeContext: CrossPlatformCanvasRenderingContext2D;
    /** Resolution of the active context. */
    activeResolution: number;
    /** The image smoothing property to toggle for this browser. */
    smoothProperty: SmoothingEnabledProperties;
    /** Map of Pixi blend modes to canvas composite operations. */
    readonly blendModes: Record<BLEND_MODES, GlobalCompositeOperation>;
    /** Current canvas blend mode. */
    _activeBlendMode: BLEND_MODES;
    /** Optional projection transform for render targets. */
    _projTransform: Matrix;
    /** True when external blend mode control is in use. */
    _outerBlend: boolean;
    /** Tracks unsupported blend mode warnings to avoid spam. */
    private readonly _warnedBlendModes;
    /**
     * @param renderer - The owning CanvasRenderer.
     */
    constructor(renderer: CanvasRenderer);
    protected resolutionChange(resolution: number): void;
    /** Initializes the root context and smoothing flag selection. */
    init(): void;
    /**
     * Sets the current transform on the active context.
     * @param transform - Transform to apply.
     * @param roundPixels - Whether to round translation to integers.
     * @param localResolution - Optional local resolution multiplier.
     * @param skipGlobalTransform - If true, skip applying the global world transform matrix.
     */
    setContextTransform(transform: Matrix, roundPixels?: boolean, localResolution?: number, skipGlobalTransform?: boolean): void;
    /**
     * Clears the current render target, optionally filling with a color.
     * @param clearColor - Color to fill after clearing.
     * @param alpha - Alpha override for the clear color.
     */
    clear(clearColor?: number[] | string | number, alpha?: number): void;
    /**
     * Sets the active blend mode.
     * @param blendMode - Pixi blend mode.
     */
    setBlendMode(blendMode: BLEND_MODES): void;
    /** Releases context references. */
    destroy(): void;
}
