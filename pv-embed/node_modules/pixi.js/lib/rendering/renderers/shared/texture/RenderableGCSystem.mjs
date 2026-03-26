import { ExtensionType } from '../../../../extensions/Extensions.mjs';
import { deprecation } from '../../../../utils/logging/deprecation.mjs';

"use strict";
const _RenderableGCSystem = class _RenderableGCSystem {
  /**
   * Creates a new RenderableGCSystem instance.
   * @param renderer - The renderer this garbage collection system works for
   */
  constructor(renderer) {
    this._renderer = renderer;
  }
  /**
   * Initializes the garbage collection system with the provided options.
   * @param options - Configuration options for the renderer
   */
  init(options) {
    options = { ..._RenderableGCSystem.defaultOptions, ...options };
    this.maxUnusedTime = options.renderableGCMaxUnusedTime;
  }
  /**
   * Gets whether the garbage collection system is currently enabled.
   * @returns True if GC is enabled, false otherwise
   */
  get enabled() {
    deprecation("8.15.0", "RenderableGCSystem.enabled is deprecated, please use the GCSystem.enabled instead.");
    return this._renderer.gc.enabled;
  }
  /**
   * Enables or disables the garbage collection system.
   * When enabled, schedules periodic cleanup of resources.
   * When disabled, cancels all scheduled cleanups.
   */
  set enabled(value) {
    deprecation("8.15.0", "RenderableGCSystem.enabled is deprecated, please use the GCSystem.enabled instead.");
    this._renderer.gc.enabled = value;
  }
  /**
   * Adds a hash table to be managed by the garbage collector.
   * @param context - The object containing the hash table
   * @param hash - The property name of the hash table
   */
  addManagedHash(context, hash) {
    deprecation("8.15.0", "RenderableGCSystem.addManagedHash is deprecated, please use the GCSystem.addCollection instead.");
    this._renderer.gc.addCollection(context, hash, "hash");
  }
  /**
   * Adds an array to be managed by the garbage collector.
   * @param context - The object containing the array
   * @param hash - The property name of the array
   */
  addManagedArray(context, hash) {
    deprecation("8.15.0", "RenderableGCSystem.addManagedArray is deprecated, please use the GCSystem.addCollection instead.");
    this._renderer.gc.addCollection(context, hash, "array");
  }
  /**
   * Starts tracking a renderable for garbage collection.
   * @param _renderable - The renderable to track
   * @deprecated since 8.15.0
   */
  addRenderable(_renderable) {
    deprecation("8.15.0", "RenderableGCSystem.addRenderable is deprecated, please use the GCSystem instead.");
    this._renderer.gc.addResource(_renderable, "renderable");
  }
  /**
   * Performs garbage collection by cleaning up unused renderables.
   * Removes renderables that haven't been used for longer than maxUnusedTime.
   */
  run() {
    deprecation("8.15.0", "RenderableGCSystem.run is deprecated, please use the GCSystem instead.");
    this._renderer.gc.run();
  }
  /** Cleans up the garbage collection system. Disables GC and removes all tracked resources. */
  destroy() {
    this._renderer = null;
  }
};
/**
 * Extension metadata for registering this system with the renderer.
 * @ignore
 */
_RenderableGCSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "renderableGC",
  priority: 0
};
/**
 * Default configuration options for the garbage collection system.
 * These can be overridden when initializing the renderer.
 * @deprecated since 8.15.0
 */
_RenderableGCSystem.defaultOptions = {
  /** Enable/disable the garbage collector */
  renderableGCActive: true,
  /** Time in ms before an unused resource is collected (default 1 minute) */
  renderableGCMaxUnusedTime: 6e4,
  /** How often to run garbage collection in ms (default 30 seconds) */
  renderableGCFrequency: 3e4
};
let RenderableGCSystem = _RenderableGCSystem;

export { RenderableGCSystem };
//# sourceMappingURL=RenderableGCSystem.mjs.map
