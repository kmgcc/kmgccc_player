import type { ExtensionMetadata } from '../extensions/Extensions';
import type { Renderer } from '../rendering/renderers/types';
type ResizeableRenderer = Pick<Renderer, 'resize'>;
/**
 * Application options for the {@link ResizePlugin}.
 * These options control how your application handles window and element resizing.
 * @example
 * ```ts
 * // Auto-resize to window
 * await app.init({ resizeTo: window });
 *
 * // Auto-resize to container element
 * await app.init({ resizeTo: document.querySelector('#game') });
 * ```
 * @category app
 * @standard
 */
export interface ResizePluginOptions {
    /**
     * Element to automatically resize the renderer to.
     * @example
     * ```ts
     * const app = new Application();
     * await app.init({
     *     resizeTo: window, // Resize to the entire window
     *     // or
     *     resizeTo: document.querySelector('#game-container'), // Resize to a specific element
     *     // or
     *     resizeTo: null, // Disable auto-resize
     * });
     * ```
     * @default null
     */
    resizeTo?: Window | HTMLElement;
}
/**
 * Middleware for Application's resize functionality. This plugin handles automatic
 * and manual resizing of your PixiJS application.
 *
 * Adds the following features to {@link Application}:
 * - `resizeTo`: Set an element to automatically resize to
 * - `resize`: Manually trigger a resize
 * - `queueResize`: Queue a resize for the next animation frame
 * - `cancelResize`: Cancel a queued resize
 * @example
 * ```ts
 * import { Application, ResizePlugin } from 'pixi.js';
 *
 * // Create application
 * const app = new Application();
 *
 * // Example 1: Auto-resize to window
 * await app.init({ resizeTo: window });
 *
 * // Example 2: Auto-resize to specific element
 * const container = document.querySelector('#game-container');
 * await app.init({ resizeTo: container });
 *
 * // Example 3: Change resize target at runtime
 * app.resizeTo = window;                    // Enable auto-resize to window
 * app.resizeTo = null;                      // Disable auto-resize
 * ```
 * @category app
 * @standard
 */
export declare class ResizePlugin {
    /** @ignore */
    static extension: ExtensionMetadata;
    /** @internal */
    static resizeTo: Window | HTMLElement;
    /** @internal */
    static resize: () => void;
    /** @internal */
    static renderer: ResizeableRenderer;
    /** @internal */
    static queueResize: () => void;
    /** @internal */
    static render: () => void;
    /** @internal */
    private static _resizeId;
    /** @internal */
    private static _resizeTo;
    /** @internal */
    private static _cancelResize;
    /**
     * Initialize the plugin with scope of application instance
     * @private
     * @param {object} [options] - See application options
     */
    static init(options: ResizePluginOptions): void;
    /**
     * Clean up the ticker, scoped to application
     * @private
     */
    static destroy(): void;
}
export {};
