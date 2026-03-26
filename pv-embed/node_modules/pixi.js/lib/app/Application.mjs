import { extensions, ExtensionType } from '../extensions/Extensions.mjs';
import { autoDetectRenderer } from '../rendering/renderers/autoDetectRenderer.mjs';
import { Container } from '../scene/container/Container.mjs';
import { ApplicationInitHook } from '../utils/global/globalHooks.mjs';
import { deprecation, v8_0_0 } from '../utils/logging/deprecation.mjs';
import './init.mjs';

"use strict";
const _Application = class _Application {
  constructor(...args) {
    /**
     * The root display container for your application.
     * All visual elements should be added to this container or its children.
     * @example
     * ```js
     * // Create a sprite and add it to the stage
     * const sprite = Sprite.from('image.png');
     * app.stage.addChild(sprite);
     *
     * // Create a container for grouping objects
     * const container = new Container();
     * app.stage.addChild(container);
     * ```
     */
    this.stage = new Container();
    if (args[0] !== void 0) {
      deprecation(v8_0_0, "Application constructor options are deprecated, please use Application.init() instead.");
    }
  }
  /**
   * Initializes the PixiJS application with the specified options.
   *
   * This method must be called after creating a new Application instance.
   * @param options - Configuration options for the application and renderer
   * @returns A promise that resolves when initialization is complete
   * @example
   * ```js
   * const app = new Application();
   *
   * // Initialize with custom options
   * await app.init({
   *     width: 800,
   *     height: 600,
   *     backgroundColor: 0x1099bb,
   *     preference: 'webgl', // or 'webgpu'
   * });
   * ```
   */
  async init(options) {
    options = { ...options };
    this.stage || (this.stage = new Container());
    this.renderer = await autoDetectRenderer(options);
    _Application._plugins.forEach((plugin) => {
      plugin.init.call(this, options);
    });
  }
  /**
   * Renders the current stage to the screen.
   *
   * When using the default setup with {@link TickerPlugin} (enabled by default), you typically don't need to call
   * this method directly as rendering is handled automatically.
   *
   * Only use this method if you've disabled the {@link TickerPlugin} or need custom
   * render timing control.
   * @example
   * ```js
   * // Example 1: Default setup (TickerPlugin handles rendering)
   * const app = new Application();
   * await app.init();
   * // No need to call render() - TickerPlugin handles it
   *
   * // Example 2: Custom rendering loop (if TickerPlugin is disabled)
   * const app = new Application();
   * await app.init({ autoStart: false }); // Disable automatic rendering
   *
   * function animate() {
   *     app.render();
   *     requestAnimationFrame(animate);
   * }
   * animate();
   * ```
   */
  render() {
    this.renderer.render({ container: this.stage });
  }
  /**
   * Reference to the renderer's canvas element. This is the HTML element
   * that displays your application's graphics.
   * @readonly
   * @type {HTMLCanvasElement}
   * @example
   * ```js
   * // Create a new application
   * const app = new Application();
   * // Initialize the application
   * await app.init({...});
   * // Add canvas to the page
   * document.body.appendChild(app.canvas);
   *
   * // Access the canvas directly
   * console.log(app.canvas); // HTMLCanvasElement
   * ```
   */
  get canvas() {
    return this.renderer.canvas;
  }
  /**
   * Reference to the renderer's canvas element.
   * @type {HTMLCanvasElement}
   * @deprecated since 8.0.0
   * @see {@link Application#canvas}
   */
  get view() {
    deprecation(v8_0_0, "Application.view is deprecated, please use Application.canvas instead.");
    return this.renderer.canvas;
  }
  /**
   * Reference to the renderer's screen rectangle. This represents the visible area of your application.
   *
   * It's commonly used for:
   * - Setting filter areas for full-screen effects
   * - Defining hit areas for screen-wide interaction
   * - Determining the visible bounds of your application
   * @readonly
   * @example
   * ```js
   * // Use as filter area for a full-screen effect
   * const blurFilter = new BlurFilter();
   * sprite.filterArea = app.screen;
   *
   * // Use as hit area for screen-wide interaction
   * const screenSprite = new Sprite();
   * screenSprite.hitArea = app.screen;
   *
   * // Get screen dimensions
   * console.log(app.screen.width, app.screen.height);
   * ```
   * @see {@link Rectangle} For all available properties and methods
   */
  get screen() {
    return this.renderer.screen;
  }
  /**
   * Destroys the application and all of its resources.
   *
   * This method should be called when you want to completely
   * clean up the application and free all associated memory.
   * @param rendererDestroyOptions - Options for destroying the renderer:
   *  - `false` or `undefined`: Preserves the canvas element (default)
   *  - `true`: Removes the canvas element
   *  - `{ removeView: boolean }`: Object with removeView property to control canvas removal
   * @param options - Options for destroying the application:
   *  - `false` or `undefined`: Basic cleanup (default)
   *  - `true`: Complete cleanup including children
   *  - Detailed options object:
   *    - `children`: Remove children
   *    - `texture`: Destroy textures
   *    - `textureSource`: Destroy texture sources
   *    - `context`: Destroy WebGL context
   * @example
   * ```js
   * // Basic cleanup
   * app.destroy();
   *
   * // Remove canvas and do complete cleanup
   * app.destroy(true, true);
   *
   * // Remove canvas with explicit options
   * app.destroy({ removeView: true }, true);
   *
   * // Detailed cleanup with specific options
   * app.destroy(
   *     { removeView: true },
   *     {
   *         children: true,
   *         texture: true,
   *         textureSource: true,
   *         context: true
   *     }
   * );
   * ```
   * > [!WARNING] After calling destroy, the application instance should no longer be used.
   * > All properties will be null and further operations will throw errors.
   */
  destroy(rendererDestroyOptions = false, options = false) {
    const plugins = _Application._plugins.slice(0);
    plugins.reverse();
    plugins.forEach((plugin) => {
      plugin.destroy.call(this);
    });
    this.stage.destroy(options);
    this.stage = null;
    this.renderer.destroy(rendererDestroyOptions);
    this.renderer = null;
  }
};
/**
 * Collection of installed plugins.
 * @internal
 */
_Application._plugins = [];
let Application = _Application;
extensions.handleByList(ExtensionType.Application, Application._plugins);
extensions.add(ApplicationInitHook);

export { Application };
//# sourceMappingURL=Application.mjs.map
