import { Ticker } from '../ticker/Ticker';
import type { ExtensionMetadata } from '../extensions/Extensions';
/**
 * Application options for the {@link TickerPlugin}.
 * These options control the animation loop and update cycle of your PixiJS application.
 * @example
 * ```ts
 * import { Application } from 'pixi.js';
 *
 * // Basic setup with default options
 * const app = new Application();
 * await app.init({
 *     autoStart: true,     // Start animation loop automatically
 *     sharedTicker: false  // Use dedicated ticker instance
 * });
 *
 * // Advanced setup with shared ticker
 * const app2 = new Application();
 * await app2.init({
 *     autoStart: false,    // Don't start automatically
 *     sharedTicker: true   // Use global shared ticker
 * });
 *
 * // Start animation when ready
 * app2.start();
 * ```
 * @remarks
 * The ticker is the heart of your application's animation system. It:
 * - Manages the render loop
 * - Provides accurate timing information
 * - Handles frame-based updates
 * - Supports priority-based execution order
 * @see {@link Ticker} For detailed ticker functionality
 * @see {@link UPDATE_PRIORITY} For update priority constants
 * @category app
 * @standard
 */
export interface TickerPluginOptions {
    /**
     * Controls whether the animation loop starts automatically after initialization.
     * > [!IMPORTANT]
     * > Setting this to `false` does NOT stop the shared ticker even if `sharedTicker` is `true`.
     * > You must stop the shared ticker manually if needed.
     * @example
     * ```ts
     * // Auto-start (default behavior)
     * await app.init({ autoStart: true });
     *
     * // Manual start
     * await app.init({ autoStart: false });
     * app.start(); // Start when ready
     * ```
     * @default true
     */
    autoStart?: boolean;
    /**
     * Controls whether to use the shared global ticker or create a new instance.
     *
     * The shared ticker is useful when you have multiple instances that should sync their updates.
     * However, it has some limitations regarding update order control.
     *
     * Update Order:
     * 1. System ticker (always runs first)
     * 2. Shared ticker (if enabled)
     * 3. App ticker (if using own ticker)
     * @example
     * ```ts
     * // Use shared ticker (global instance)
     * await app.init({ sharedTicker: true });
     *
     * // Use dedicated ticker (default)
     * await app.init({ sharedTicker: false });
     *
     * // Access ticker properties
     * console.log(app.ticker.FPS);    // Current FPS
     * console.log(app.ticker.deltaMS); // MS since last update
     * ```
     * @default false
     */
    sharedTicker?: boolean;
}
/**
 * Middleware for Application's {@link Ticker} functionality. This plugin manages the
 * animation loop and update cycle of your PixiJS application.
 *
 * Adds the following features to {@link Application}:
 * - `ticker`: Access to the application's ticker
 * - `start`: Start the animation loop
 * - `stop`: Stop the animation loop
 * @example
 * ```ts
 * import { Application, TickerPlugin, extensions } from 'pixi.js';
 *
 * // Create application
 * const app = new Application();
 *
 * // Example 1: Basic ticker usage (default autoStart)
 * await app.init({ autoStart: true });      // Starts ticker automatically
 *
 * // Example 2: Manual ticker control
 * await app.init({ autoStart: false });     // Don't start automatically
 * app.start();                              // Start manually
 * app.stop();                               // Stop manually
 *
 * // Example 3: Add custom update logic
 * app.ticker.add((ticker) => {
 *     // Run every frame, delta is the time since last update
 *     sprite.rotation += 0.1 * ticker.deltaTime;
 * });
 *
 * // Example 4: Control update priority
 * import { UPDATE_PRIORITY } from 'pixi.js';
 *
 * app.ticker.add(
 *     (ticker) => {
 *         // Run before normal priority updates
 *     },
 *     null,
 *     UPDATE_PRIORITY.HIGH
 * );
 *
 * // Example 5: One-time update
 * app.ticker.addOnce(() => {
 *     console.log('Runs next frame only');
 * });
 * ```
 * @see {@link Ticker} For detailed ticker functionality
 * @see {@link UPDATE_PRIORITY} For priority constants
 * @category app
 * @standard
 */
export declare class TickerPlugin {
    /** @ignore */
    static extension: ExtensionMetadata;
    /** @internal */
    static start: () => void;
    /** @internal */
    static stop: () => void;
    /** @internal */
    private static _ticker;
    /** @internal */
    static ticker: Ticker;
    /**
     * Initialize the plugin with scope of application instance
     * @private
     * @param {object} [options] - See application options
     */
    static init(options?: PixiMixins.ApplicationOptions): void;
    /**
     * Clean up the ticker, scoped to application.
     * @private
     */
    static destroy(): void;
}
