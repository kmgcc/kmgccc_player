import { type Renderer } from '../rendering/renderers/types';
/**
 * CanvasObserver class synchronizes the DOM element's transform with the canvas size and position.
 * It uses ResizeObserver for efficient updates and requestAnimationFrame for fallback.
 * This ensures that the DOM element is always correctly positioned and scaled relative to the canvas.
 * @internal
 */
export declare class CanvasObserver {
    /** A cached value of the last transform applied to the DOM element. */
    private _lastTransform;
    /** A ResizeObserver instance to observe changes in the canvas size. */
    private _observer;
    /** The canvas element that this observer is associated with. */
    private _canvas;
    /** The DOM element that will be transformed based on the canvas size and position. */
    private readonly _domElement;
    /** The renderer instance that this observer is associated with. */
    private readonly _renderer;
    /** The last scale values applied to the DOM element, used to avoid unnecessary updates. */
    private _lastScaleX;
    /** The last scale values applied to the DOM element, used to avoid unnecessary updates. */
    private _lastScaleY;
    /** A flag to indicate whether the observer is attached to the Ticker for continuous updates. */
    private _tickerAttached;
    constructor(options: {
        domElement: HTMLElement;
        renderer: Renderer;
    });
    /** The canvas element that this CanvasObserver is associated with. */
    get canvas(): HTMLCanvasElement;
    /** Attaches the DOM element to the canvas parent if it is not already attached. */
    ensureAttached(): void;
    /**
     * Updates the transform of the DOM element based on the canvas size and position.
     * This method calculates the scale and translation needed to keep the DOM element in sync with the canvas.
     */
    readonly updateTranslation: () => void;
    /** Sets up a ResizeObserver if available. This ensures that the DOM element is kept in sync with the canvas size . */
    private _attachObserver;
    /** Destroys the CanvasObserver instance, cleaning up observers and Ticker. */
    destroy(): void;
}
