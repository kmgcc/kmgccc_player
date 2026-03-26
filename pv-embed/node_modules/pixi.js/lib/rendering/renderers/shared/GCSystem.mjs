import { ExtensionType } from '../../../extensions/Extensions.mjs';
import { cleanHash, cleanArray } from '../../../utils/data/clean.mjs';

"use strict";
const _GCSystem = class _GCSystem {
  /**
   * Creates a new GCSystem instance.
   * @param renderer - The renderer this garbage collection system works for
   */
  constructor(renderer) {
    /** Array of resources being tracked for garbage collection */
    this._managedResources = [];
    this._managedResourceHashes = [];
    this._managedCollections = [];
    this._ready = false;
    this._renderer = renderer;
  }
  /**
   * Initializes the garbage collection system with the provided options.
   * @param options - Configuration options
   */
  init(options) {
    options = { ..._GCSystem.defaultOptions, ...options };
    this.maxUnusedTime = options.gcMaxUnusedTime;
    this._frequency = options.gcFrequency;
    this.enabled = options.gcActive;
    this.now = performance.now();
  }
  /**
   * Gets whether the garbage collection system is currently enabled.
   * @returns True if GC is enabled, false otherwise
   */
  get enabled() {
    return !!this._handler;
  }
  /**
   * Enables or disables the garbage collection system.
   * When enabled, schedules periodic cleanup of resources.
   * When disabled, cancels all scheduled cleanups.
   */
  set enabled(value) {
    if (this.enabled === value) return;
    if (value) {
      this._handler = this._renderer.scheduler.repeat(
        () => {
          this._ready = true;
        },
        this._frequency,
        false
      );
      this._collectionsHandler = this._renderer.scheduler.repeat(
        () => {
          for (const hash of this._managedCollections) {
            const { context, collection, type } = hash;
            if (type === "hash") {
              context[collection] = cleanHash(context[collection]);
            } else {
              context[collection] = cleanArray(context[collection]);
            }
          }
        },
        this._frequency
      );
    } else {
      this._renderer.scheduler.cancel(this._handler);
      this._renderer.scheduler.cancel(this._collectionsHandler);
      this._handler = 0;
      this._collectionsHandler = 0;
    }
  }
  /**
   * Called before rendering. Updates the current timestamp.
   * @param options - The render options
   * @param options.container - The container to render
   */
  prerender({ container }) {
    this.now = performance.now();
    container.renderGroup.gcTick = this._renderer.tick++;
    this._updateInstructionGCTick(container.renderGroup, container.renderGroup.gcTick);
  }
  /** Performs garbage collection after rendering. */
  postrender() {
    if (!this._ready || !this.enabled) return;
    this.run();
    this._ready = false;
  }
  /**
   * Updates the GC tick counter for a render group and its children.
   * @param renderGroup - The render group to update
   * @param gcTick - The new tick value
   */
  _updateInstructionGCTick(renderGroup, gcTick) {
    renderGroup.instructionSet.gcTick = gcTick;
    renderGroup.gcTick = gcTick;
    for (const child of renderGroup.renderGroupChildren) {
      this._updateInstructionGCTick(child, gcTick);
    }
  }
  /**
   * Registers a collection for garbage collection tracking.
   * @param context - The object containing the collection
   * @param collection - The property name on context that holds the collection
   * @param type - The type of collection to track ('hash' or 'array')
   */
  addCollection(context, collection, type) {
    this._managedCollections.push({
      context,
      collection,
      type
    });
  }
  /**
   * Registers a resource for garbage collection tracking.
   * @param resource - The resource to track
   * @param type - The type of resource to track
   */
  addResource(resource, type) {
    if (resource._gcLastUsed !== -1) {
      resource._gcLastUsed = this.now;
      resource._onTouch?.(this.now);
      return;
    }
    const index = this._managedResources.length;
    resource._gcData = {
      index,
      type
    };
    resource._gcLastUsed = this.now;
    resource._onTouch?.(this.now);
    resource.once("unload", this.removeResource, this);
    this._managedResources.push(resource);
  }
  /**
   * Removes a resource from garbage collection tracking.
   * Call this when manually destroying a resource.
   * @param resource - The resource to stop tracking
   */
  removeResource(resource) {
    const gcData = resource._gcData;
    if (!gcData) return;
    const index = gcData.index;
    const last = this._managedResources.length - 1;
    if (index !== last) {
      const lastResource = this._managedResources[last];
      this._managedResources[index] = lastResource;
      lastResource._gcData.index = index;
    }
    this._managedResources.length--;
    resource._gcData = null;
    resource._gcLastUsed = -1;
  }
  /**
   * Registers a hash-based resource collection for garbage collection tracking.
   * Resources in the hash will be automatically tracked and cleaned up when unused.
   * @param context - The object containing the hash property
   * @param hash - The property name on context that holds the resource hash
   * @param type - The type of resources in the hash ('resource' or 'renderable')
   * @param priority - Processing priority (lower values are processed first)
   */
  addResourceHash(context, hash, type, priority = 0) {
    this._managedResourceHashes.push({
      context,
      hash,
      type,
      priority
    });
    this._managedResourceHashes.sort((a, b) => a.priority - b.priority);
  }
  /**
   * Performs garbage collection by cleaning up unused resources.
   * Removes resources that haven't been used for longer than maxUnusedTime.
   */
  run() {
    const now = performance.now();
    const managedResourceHashes = this._managedResourceHashes;
    for (const hashEntry of managedResourceHashes) {
      this.runOnHash(hashEntry, now);
    }
    let writeIndex = 0;
    for (let i = 0; i < this._managedResources.length; i++) {
      const resource = this._managedResources[i];
      writeIndex = this.runOnResource(resource, now, writeIndex);
    }
    this._managedResources.length = writeIndex;
  }
  updateRenderableGCTick(renderable, now) {
    const renderGroup = renderable.renderGroup ?? renderable.parentRenderGroup;
    const currentTick = renderGroup?.instructionSet?.gcTick ?? -1;
    if ((renderGroup?.gcTick ?? 0) === currentTick) {
      renderable._gcLastUsed = now;
      renderable._onTouch?.(now);
    }
  }
  runOnResource(resource, now, writeIndex) {
    const gcData = resource._gcData;
    if (gcData.type === "renderable") {
      this.updateRenderableGCTick(resource, now);
    }
    const isRecentlyUsed = now - resource._gcLastUsed < this.maxUnusedTime;
    if (isRecentlyUsed || !resource.autoGarbageCollect) {
      this._managedResources[writeIndex] = resource;
      gcData.index = writeIndex;
      writeIndex++;
    } else {
      resource.unload();
      resource._gcData = null;
      resource._gcLastUsed = -1;
      resource.off("unload", this.removeResource, this);
    }
    return writeIndex;
  }
  /**
   * Creates a clone of the hash, copying all non-null entries up to (but not including) the stop key.
   * @param hashValue - The original hash to clone from
   * @param stopKey - The key to stop at (exclusive)
   * @returns A new hash object with copied entries
   */
  _createHashClone(hashValue, stopKey) {
    const hashClone = /* @__PURE__ */ Object.create(null);
    for (const k in hashValue) {
      if (k === stopKey) break;
      if (hashValue[k] !== null) hashClone[k] = hashValue[k];
    }
    return hashClone;
  }
  runOnHash(hashEntry, now) {
    const { context, hash, type } = hashEntry;
    const hashValue = context[hash];
    let hashClone = null;
    let nullCount = 0;
    for (const key in hashValue) {
      const resource = hashValue[key];
      if (resource === null) {
        nullCount++;
        if (nullCount === 1e4 && !hashClone) {
          hashClone = this._createHashClone(hashValue, key);
        }
        continue;
      }
      if (resource._gcLastUsed === -1) {
        resource._gcLastUsed = now;
        resource._onTouch?.(now);
        if (hashClone) hashClone[key] = resource;
        continue;
      }
      if (type === "renderable") {
        this.updateRenderableGCTick(resource, now);
      }
      const isRecentlyUsed = now - resource._gcLastUsed < this.maxUnusedTime;
      if (!isRecentlyUsed && resource.autoGarbageCollect) {
        if (!hashClone) {
          if (nullCount + 1 !== 1e4) {
            hashValue[key] = null;
            nullCount++;
          } else {
            hashClone = this._createHashClone(hashValue, key);
          }
        }
        if (type === "renderable") {
          const res = resource;
          const renderGroup = res.renderGroup ?? res.parentRenderGroup;
          if (renderGroup) renderGroup.structureDidChange = true;
        }
        resource.unload();
        resource._gcData = null;
        resource._gcLastUsed = -1;
      } else if (hashClone) {
        hashClone[key] = resource;
      }
    }
    if (hashClone) {
      context[hash] = hashClone;
    }
  }
  /** Cleans up the garbage collection system. Disables GC and removes all tracked resources. */
  destroy() {
    this.enabled = false;
    this._managedResources.forEach((resource) => {
      resource.off("unload", this.removeResource, this);
    });
    this._managedResources.length = 0;
    this._managedResourceHashes.length = 0;
    this._managedCollections.length = 0;
    this._renderer = null;
  }
};
/** @ignore */
_GCSystem.extension = {
  type: [
    ExtensionType.WebGLSystem,
    ExtensionType.WebGPUSystem,
    ExtensionType.CanvasSystem
  ],
  name: "gc",
  priority: 0
};
/** Default options for the GCSystem */
_GCSystem.defaultOptions = {
  /** Enable/disable the garbage collector */
  gcActive: true,
  /** Time in ms before an unused resource is collected (default 1 minute) */
  gcMaxUnusedTime: 6e4,
  /** How often to run garbage collection in ms (default 30 seconds) */
  gcFrequency: 3e4
};
let GCSystem = _GCSystem;

export { GCSystem };
//# sourceMappingURL=GCSystem.mjs.map
